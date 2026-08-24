# SRA (Service Rewards Actor) design, tests, decisions, and security review

This document consolidates the design, test plan and registries, decision record, and security review for the Service Rewards Actor (SRA, issue #4) of FIP-0118 (Solstice): §1 overview, §2 technical design, §3 decision record, §4 test strategy and coverage, §5 security review, §6 references.

## 1. Overview

### 1.1 Goal and Core Features

Implement the Service Rewards Actor (issue #4) of FIP-0118 (Solstice) as a **feature monolith**: maintain the orchestrator registry, allowlists, and quarterly volume state, compute service stream shares per the SplitRule and write them to f02 (`SetShares`), and export `AggregatedFPV(Q)` for the SWA. The SRA **never receives or holds value** (spec §3.1/§4).

Core features:

- Orchestrator registry: (payer, operator) pair → orchestrator binding, uniqueness invariant (spec §3.3)
- Stablecoin allowlist + Filecoin Pay contract allowlist (spec §3.3/§4.2)
- Quarterly volume FPV_i(Q) posting and verification-window binding (spec §3.2)
- Oracle-free FIL→USD pricing (fee-auction prints, spec §3.3)
- Quarterly share computation and f02.SetShares call (spec §4.2 + f02-design)
- Aggregated read AggregatedFPV(Q) for SWA gating (spec §3.2)
- Dual-Safe governance: registry/allowlist/parameter changes go through unanimous + SRA_CANCEL_HOLD (spec §5)

### 1.2 Document Scope and Status

- Scope: all key decisions for Issue #4, from design to PR.
- Decision groups used throughout: **D** design decisions (settled) | **S** structural decisions (approval) | **C** conflict rulings (found test-first) | **T** test decisions (defect fixes) | **G** coverage-gap closures | **I/R** implementation-layer risks and mitigations.
- Status: all landed — design approved and converged; implementation **319/319 tests Green** (SRA deterministic + 5 invariant + existing; FIPs#1275 off-chain-conversion adaptation removed the band/finalize/burn suites; the review-#10 aggregate mirror was refactored to the two-slot mirror + quarter counter array; the id-identity rework landed — address+successor chain replaced by monotonic uint64 id, +5 tests); SRA line coverage 100%; `forge fmt --check` / `forge lint` clean; Slither static analysis zero real risk; Halmos symbolic verification quarter-window 2/2 PASS (freeze-interval determinations `_frozenAtPostEnd`/`_isFrozenAt` removed with the mirror refactor — the E+POST exclusion is a stored flag; window-boundary properties verified symbolically); final code review PASS; audit hardening V1/V2/V3 (overflow DoS) + B1/C1/E1/E2/F2 (remaining input-domain bounds) + QA-system fixes S1-S5 landed; FIPs#1275 adaptation landed (FPV single USD total, off-chain conversion, all-zero no-op).

### 1.3 Source Annotation System

Used throughout this document:

- 📄 **spec agreement**: directly from the FIP-0118 spec; the implementation must comply; no approval needed
- 📘 **code fact**: from merged/submitted code (governance libs, f02 lib, SWA); no approval needed
- ✏️ **design derivation**: the spec gives only the concept; the concrete form requires design; **needs approval**
- 🔍 **design decision**: spec-undefined blanks or settled trade-offs; **requires focused approval**

## 2. Technical Design

### 2.1 Tech Stack

| Item | Choice | Source |
|------|--------|--------|
| Language | Solidity ^0.8.36 | 📘 Project status (consistent with SWA) |
| Framework | Foundry (forge 1.7.1) | 📘 Project status |
| Governance | Reuse `UnanimousGovernance` (incl. `unanimousNoHold`) | 📘 Merged in PR #12/#17 |
| f02 interaction | Reuse `FVMRewards.setShares` library | 📘 Submitted in PR #16 |
| Storage | ERC-7201 namespaces (`@custom:storage-location`) | 📘 Precedent in PR #12 (Owners/PendingTask) + ✏️ reserved for future proxying |

### 2.2 Technology Choices and Key Decisions

**Deployment form (settled 🔍)**: the final state is an ERC-8167 proxy (decided in issue #5), but **this iteration implements only the feature monolith** (no proxy). Storage is designed with ERC-7201 namespaces from day one to reserve zero-migration for future proxying. Module organization follows the SWA: thin contract + logic delegated to libraries (f02 interaction reuses FVMRewards).

**D1 All-zero volume (settled 🔍, FIPs#1275)**: when the sum of all orchestrator FPVs in a quarter is 0, `SubmitShares` is a **benign no-op** — SplitRule is not evaluated and the existing share map stands (📄 §4.2: "If eligible FPV for that quarter sums to zero, SubmitShares is a benign no-op"); changing the map in a zero-volume quarter is a governance act (freeze/remove/re-point/weight change), never automatic. The earlier burn-to-f099 design (D1 v1) was superseded by [FIPs#1275](https://github.com/filecoin-project/FIPs/pull/1275) — f02-side special-casing of f099 is no longer needed.

**D2 Orchestrator cap (settled 🔍)**: the total number of admitted orchestrators in the registry (**including frozen**) is ≤ 64 (MAX_RECIPIENTS, 📘 PR #13 suggested value). `Admit` checks this and rejects when full; only `Remove` releases a slot; Freeze does not release a slot (frozen orchestrators keep their identity).

**D3 CorrectVolume (settled 🔍)**: follows the spec's no-hold exemption (📄 §4.2/§5.3 "the window itself is the hold") — uses the `unanimousNoHold` path with in-body window validation, allows bidirectional correction (up or down), no extra veto fallback (dual-Safe agreement is the protection).

**Governance hold parameter (✏️ needs approval)**: SRA governance operations enforce `SRA_CANCEL_HOLD` at the contract level (unlike the SWA, which relies on f02's SWA_TIMELOCK — 📘 that is why the SWA uses unanimousNoHold). Suggested SRA_CANCEL_HOLD = 7 days (consistent with the spec's suggested verification window length, 📄 §3.2).

### 2.3 Method Interfaces (14 writes + 1 read)

> Scope note: **14 writes = 12 core writes + 1 auxiliary write + 1 audit-added governance write**. The 12 core writes are the methods in §2.3.1-2.3.4 other than the auxiliary below (registerPairs/postVolume/admit/remove/freeze/unfreeze/replace/reassignBinding/setAdmittedLists/setPricingParams/correctVolume/submitShares); the auxiliary write is `cancelPending` (governance veto auxiliary, exposes 📘 `_veto`); the audit-added write is `replaceOwner` (E1 owner rotation, aligned with upstream SWA — the spec's §4.2 method list does not name it, but the shared governance model needs an owner-rotation path). `finalizeConversion` was removed by [FIPs#1275](https://github.com/filecoin-project/FIPs/pull/1275) (FIL→USD conversion moved off-chain).
> Semantics source 📄 §4.2 method list; **Solidity signatures are ✏️ design derivation (the spec gives only method names and prose) — ✅ S1 approved** (approval record in §3.2).

#### 2.3.1 Orchestrator operations (called by self, no governance)

| Method | Signature | One-line semantics |
|--------|-----------|--------------------|
| `registerPairs` | `registerPairs(Pair[] calldata pairs)` — named struct `Pair {address payer; address operator;}` (C1: inline tuple-array params are illegal in Solidity) | An admitted, non-frozen orchestrator declares binding pairs; reverts if the pair is already bound to another orchestrator (uniqueness, 📄 §3.3) |
| `postVolume` | `postVolume(uint64 Q, FixedU18 fpv)` | During posting; at most one posting per quarter; the value is a single USD-denominated total (FPV_i(Q): stablecoin face USD + off-chain-converted FIL volume, FIPs#1275), bounded by MAX_FPV_USD; 18-decimal fixed point (1 USD = 1e18), type-checked from the entry |

#### 2.3.2 Governance operations (dual Safe + SRA_CANCEL_HOLD, unanimous path)

| Method | Signature | One-line semantics |
|--------|-----------|--------------------|
| `admit` | `admit(address orch)` | Admits an orchestrator; rejects when admitted total ≥ 64 (🔍 D2); allocates a **monotonic never-reused uint64 id** — re-admit of a replaced/removed address is a fresh identity (fresh id, zero residual binding/FPV/freeze state by construction, S13) |
| `remove` | `remove(address orch)` | Permanent removal; releases all bindings (pairs return to unclaimed) (📄 §4.2); **timing guard (📄 §3.2/§4.4)**: reverts `PendingShares(q)` while the latest bound quarter awaits its share map — governance clears it by cranking `SubmitShares` first. The id record is kept (wallet/fpv/prevFpv retained for audit); only the address mapping is cleared, so a removed id is never reachable from an address and its pairs read as unclaimed (S13) |
| `freeze` | `freeze(address orch)` | Freeze: suspends, zeroes shares, excludes FPV (📄 §4.2) |
| `unfreeze` | `unfreeze(address orch)` | Exact restoration (📄 §4.2) |
| `replace` | `replace(address oldOrch, address newOrch)` | Operator address change (📄 §4.2): **O(1) wallet re-point** — the id (identity) stays put, only the address mapping and the wallet field change; bindings/fpv/freeze state follow the id automatically, historical quarter FPV stays aggregated (S13) |
| `reassignBinding` | `reassignBinding(address payer, address operator, address orch)` | Disputed pair reassignment; volume is credited to the new orchestrator from the change epoch onward (📄 §4.2) |
| `setAdmittedLists` | `setAdmittedLists(address[] calldata stablecoins, address[] calldata filecoinPayContracts)` | Updates the stablecoin + Filecoin Pay allowlists (📄 §4.2) |
| `setPricingParams` | `setPricingParams(uint256 minLot, uint256 priceBand)` | Updates the FIL pricing parameters MIN_LOT/PRICE_BAND (📄 §3.3: SRA state settable by governance; authoritative for the off-chain indexer, FIPs#1275 — not an on-chain computation) |
| `replaceOwner` | `replaceOwner(address prevOwner, address newOwner)` | **Owner rotation (audit E1, unanimousNoHold path)**: dual-Safe, effective immediately; newOwner must be a Safe proxy; revokes prevOwner and adds newOwner (aligned with upstream SWA) |
| `cancelPending` | `cancelPending(bytes32 taskId)` | Either Safe calls `_veto` alone to discard a queued change (📄 §4.2 + 📘 _veto) |

> `setPricingParams` is the governance power implied by spec §3.3/§5.2 ("FIL pricing parameters... can be set by SRA Governance"), not named in the spec's method list — **✏️ design derivation**.

#### 2.3.3 Governance operations (dual Safe + effective immediately within the window, unanimousNoHold path)

| Method | Signature | One-line semantics |
|--------|-----------|--------------------|
| `correctVolume` | `correctVolume(address orch, uint64 Q, FixedU18 value)` | Only within the verification window, dual-Safe joint; replaces the posted value with the recomputed figure or backfills for an unposted orchestrator; exempt from SRA_CANCEL_HOLD, allows bidirectional correction; **reverts `NotFrozen` for a suspended orchestrator** (freeze symmetry with `postVolume` — A2/A3 fix: the governance path must not re-admit a frozen orchestrator after the mirror advance cleared `frozenAtPostEnd`) (📄 §4.2/§5.3 + 🔍 D3a) |

> `value` is a single USD-denominated total (same shape as PostVolume; the FIL→USD conversion happens off-chain, FIPs#1275) — **✏️ design derivation** (the spec writes "value" without defining the structure).

#### 2.3.4 Mechanism operations (permissionless)

| Method | Signature | One-line semantics |
|--------|-----------|--------------------|
| `submitShares` | `submitShares(uint64 Q)` | Permissionless after binding; SplitRule over the bound USD values → `FVMRewards.setShares(2, map)` (📄 §4.2 + 📘 library); reverts once the quarter's map is submitted; an all-zero quarter is a benign no-op (D1, FIPs#1275) |

#### 2.3.5 Read-only (for SWA and external audit)

| Method | Signature | One-line semantics |
|--------|-----------|--------------------|
| `aggregatedFPV` | `aggregatedFPV(uint64 Q) returns (FixedU18 usd)` | Returns the post-binding USD aggregate (18-decimal fixed point, matching the SWA interface `IServiceRewardsActor`): Σ of each non-excluded posted orchestrator's bound USD value. **Pure view** — the FIL→USD conversion is off-chain (FIPs#1275), so there is no on-chain finalize to trigger (📄 §3.2/§4.2). **O(1) for every quarter via the quarter-counter array** (`totalUsd[Q]`, review #10 refactor): the active quarter reads the maintained counter; historical quarters read the binding-fixed snapshot (spec determinism — the registry is constant within a quarter, so the aggregate cannot drift with later remove/replace) |

> **Contract declaration (FIPs#1275)**: `AggregatedFPV` reads only bound USD values — the spec's "reading AggregatedFPV triggers FinalizeConversion" clause was removed with the off-chain conversion. Reverts `NotBound(q)` before binding — distinguishing "quarter not yet bound" (call too early; the SWA does not need to re-enforce the check) from "quarter with zero declared volume" (legitimately returns 0). Locked by `test/SRAIntegration.t.sol` (§4.3.6, scenarios C1-C3).

> Supplementary read-only views (✏️ design derivation, spec §4.2 says "read-only views expose the registry, bound volume, USD-denominated AggregatedFPV"): `isAdmitted(address)`, `isFrozen(address)`, `bindingOf(payer, operator)`, `fpvOf(Q, orch)`, `qEnd(uint64)`, `admittedCount()`, `getPricingParams()`, `orchestratorCount()` (+ C5: `isStablecoinAdmitted(address)` allowlist getter). `fpvOf` retains per-orchestrator values only for the active and the previous quarter (mirror slots); earlier quarters return 0 — the aggregate (`totalUsd`) is the only historical read, which the spec requires (📄 §5 "Read state").

### 2.4 Data Structures (ERC-7201 namespace storage layout)

> Storage layout is ✏️ design derivation (the spec describes only conceptual state: "SRA holds the registry, FPV and verification-window state, two Safe addresses, the pending queue, allowlists, FIL pricing parameters", 📄 §4.2). Namespace division follows 📘 Owners/PendingTask's `Solstice.*` pattern, reserving zero-migration for future ERC-8167 proxying.

**Division basis (✅ S2 approved)**: split into 4 blocks by "data lifecycle × governance ownership" — ① Registry (long-lived identity, governance domain), ② AdmittedLists (isolated configuration, governance domain), ③ Quarter (rolling quarterly data, mechanism domain, the only high-frequency write), ④ Params (governance parameters, governance domain). Each block has an independent ERC-7201 slot (derived from `keccak256(namespace)`, never colliding); future delegate division maps directly onto these blocks with zero storage migration.

**Governance state (reused, not added)**:
- `Solstice.Owners`: two Safe addresses → bitmask (📘 Owners.sol)
- `Solstice.PendingTasks`: taskId → {modified, approvals} (📘 PendingTask.sol)

**① `Solstice.SRA.Registry` — orchestrator registry** (✏️, id-identity rework S13)

```solidity
struct OrchestratorInfo {  // 30B packed into slot0
    address wallet;        // current effective wallet (replace updates this; the share map writes this)
    bool admitted;         // admitted
    bool frozenAtPostEnd;  // frozen-at-E+POST flag: exactly "was this orchestrator frozen at the
                           // close of the posting period of the active quarter" — the fpv-effectiveness
                           // test. Changes only before E+POST (freeze/unfreeze in the posting window
                           // set/clear it); from the verification window onward it is fixed.
    Epoch frozenSince;     // current freeze state: 0 = not frozen; > 0 = frozen since this epoch
                           // (admission checks + freeze/unfreeze symmetry)
    FixedU18 fpv;          // slot1: active-quarter contribution (0 = not posted) — mirror slot
    FixedU18 prevFpv;      // slot2: previous-quarter contribution mirror; exclusion-fixed at the mirror
                           // advance (prevFpv <- frozenAtPostEnd ? 0 : fpv; fpv = 0)
}
struct SRAStorageRegistry {
    mapping(uint64 id => OrchestratorInfo) orchestrators; // id = identity (monotonic, never reused; 0 = sentinel)
    mapping(address orch => uint64 id) activeIdOf;        // current effective address -> id (0 = unregistered)
    mapping(bytes32 pairId => uint64 id) bindings;        // pairId = keccak256(abi.encode(payer, operator))
    uint64 nextId;          // id allocator (constructor sets 1; 0 is the unregistered sentinel)
    uint64[] admittedIds;   // enumerable admitted (incl. frozen); length doubles as the count
}
```

**② `Solstice.SRA.AdmittedLists` — allowlists** (✏️)

```solidity
struct SRAStorageLists {
    mapping(address => bool) stablecoins;          // admitted stablecoins (valued at face USD)
    mapping(address => bool) filecoinPayContracts; // admitted Filecoin Pay contracts
}
```

**③ `Solstice.SRA.Quarter` — quarterly FPV** (✏️)

```solidity
struct FPV {
    FixedU18 usd;   // single USD-denominated total for the quarter (FPV_i(Q)); FIL contribution
                    // folded in off-chain by the orchestrator's indexer (FIPs#1275).
                    // 18-decimal fixed point (1 USD = 1e18) — adopted per the SWA interface
                    // (IServiceRewardsActor.aggregatedFPV returns FixedU18) so every USD-consuming
                    // computation is type-safe against integer/fixed-point magnitude mixing.
                    // One storage slot. usd == 0 means "not posted" (review #7: PostVolume
                    // rejects zero; CorrectVolume(0) clears).
                    // MAX_FPV_USD(1e30) wraps as 1e48 < uint256.max — no narrowing at the write.
}
struct SRAStorageQuarter {
    uint64 activeQ;            // the quarter the mirror has advanced to (postVolume/correctVolume set it
                               // on the first write of a new quarter — the advance trigger). The previous
                               // quarter's per-orchestrator contributions live in prevFpv (exclusion-fixed
                               // at the advance); only these two quarters retain per-orchestrator values
                               // (spec: CorrectVolume is bounded by the verification window, so no
                               // historical corrections exist).
    uint64 lastSubmittedQ;     // anti-replay: last submitted quarter + 1 (0 = none; q+1 encoding so
                               // quarter 0 does not collide with the sentinel; monotonic, no reset)
    mapping(uint64 Q => FixedU18) totalUsd;   // quarter counter array: per-quarter USD aggregate —
                               // aggregatedFPV O(1) for every quarter, fixed once the mirror advances
}
```

> The mirror refactor (review #10, three-piece design) removed the per-quarter `fpv` map (`mapping(Q => mapping(orch => FPV))`), the `sharesSubmitted` map, and the former `mirrorActive/mirrorQ/totalUsd` fields. Per-orchestrator values are retained only for the active and the previous quarter (`fpv`/`prevFpv` slots) — historical per-orchestrator reads (`fpvOf(Q, orch)`) return 0 for earlier quarters, which the spec does not require (read state exposes only `AggregatedFPV`, 📄 §5 "Read state").

> FIPs#1275 removed the FIL pricing-period vector (`PricePeriod[]`) and the on-chain `FinalizeConversion`: the SRA never receives raw FIL amounts, pricing periods, or print references — `PostVolume` carries only the single USD total (📄 §2.3/§4.2). The PRICE_BAND anchor storage (C6) is likewise gone.

**④ `Solstice.SRA.Params` — governable parameters** (✏️)

```solidity
struct SRAStorageParams {
    uint256 minLot;    // MIN_LOT (proposed a few hundred USD, 📄 §11) — authoritative for the off-chain indexer (FIPs#1275)
    uint256 priceBand; // PRICE_BAND (basis points) — same: governs the off-chain conversion, not an on-chain computation
}
```

**Constants (compile-time)**: `EPOCHS_PER_QUARTER`, `POST_PERIOD`, `VERIFICATION_WINDOW`, `SRA_CANCEL_HOLD`, `MAX_ORCHESTRATORS = 64`, `ACTIVATION_EPOCH` — passed as deployment configuration to the constructor (✏️ see 2.6).

### 2.5 Core Logic

#### 2.5.1 Quarter State Machine (📄 §3.2 semantics + ✏️ determination implementation)

```
E(Q) = ACTIVATION_EPOCH + Q × EPOCHS_PER_QUARTER        // end epoch of quarter Q

posting:      E(Q) < now && now <= E(Q) + POST_PERIOD            // PostVolume callable
verification: E(Q) + POST_PERIOD < now
              && now <= E(Q) + POST_PERIOD + VERIFICATION_WINDOW // CorrectVolume callable
post-binding: now > E(Q) + POST_PERIOD + VERIFICATION_WINDOW     // SubmitShares/AggregatedFPV callable
```

- All comparisons use the `Epoch` (uint64) type; `currentEpoch()` reads `block.number` (📘 Epoch.sol)
- Boundary determination is an off-by-one hotspot; tests must cover E, E+POST, E+POST+VERIFY and ±1 (🔍 I5)
- **SubmitShares/AggregatedFPV are callable only after the window closes and read only bound values** (📄 §3.2; FIPs#1275 removed FinalizeConversion)

#### 2.5.2 Freeze and Share-Exclusion Semantics (📄 §4.2 + ✏️ snapshot implementation)

- A frozen orchestrator cannot `registerPairs`/`postVolume` (📄 §4.2)
- "For any quarter whose posting close was during a freeze": FPV is excluded, share is 0 (📄 §4.2)
- **Snapshot implementation (✏️ ✅ approved, mirror refactor)**: the E+POST exclusion is a **stored flag** `frozenAtPostEnd` on the orchestrator — set by a freeze in the posting window (E+POST not yet reached), cleared by an unfreeze in the posting window, and **fixed from the verification window onward** (a freeze/unfreeze after E+POST cannot change the already-determined quarter). `frozenSince` (current freeze state) is separate: it serves admission checks and freeze/unfreeze symmetry, and cannot reconstruct the E+POST state across a freeze→unfreeze spanning E+POST (the reason the flag exists). At the mirror advance the flag is snapshotted into the previous-quarter slot (`prevFpv <- frozenAtPostEnd ? 0 : fpv`), because the freeze state of a past E+POST is no longer derivable once the quarter has advanced.
- **After Remove**: pairs return to unclaimed and can be claimed by other orchestrators via `registerPairs` (📄 §4.2)
- **Re-admit = fresh identity (✏️ finalized after T10 defect fix; structurally guaranteed since the id-identity rework S13)**: before S13, `admit` set `admitted = true` and **reset identity** — cleared `successor` (residual alias chain from replace), `frozenSince = 0`, `frozenAtPostEnd = false`, `fpv = 0`, `prevFpv = 0` (symmetric with `remove` cleanup), because a residual successor chain let a frozen orchestrator obtain a share through the resolve chain (violating S5/S7). **Since S13** re-admit of a replaced/removed address **allocates a fresh id** — zero residual binding/FPV/freeze state by construction, no cleanup step needed; the alias-chain bug class (T10) is structurally eliminated. Rejected alternatives (from the T10 era): B (make the submitShares freeze check decide after `_resolve(orch)` — violates S5, which requires checking the reporting orchestrator itself; old's legitimate FPV would be dragged down by frozen new, and other functions like aggregatedFPV would be inconsistent), C (forbid re-admit after replace — too restrictive, conflicts with S7 "keep admit simple")
- **After ReassignBinding**: volume is credited to the new orchestrator from the change epoch onward; already-posted quarters are unaffected (📄 §4.2)

#### 2.5.3 SplitRule Share Computation (with largest-remainder method)

```
submitShares(Q):
    1. require after binding (NotBound(q)); require q + 1 != lastSubmittedQ (AlreadySubmitted, FIPs#1275;
       lastSubmittedQ stores q+1 so quarter 0 does not collide with the 0 sentinel)
    2. q is the latest bound quarter: q == activeQ (bound, mirror not advanced) or q == activeQ - 1
       (advanced). Read the mirror slots: fpv for the active quarter (skip frozenAtPostEnd),
       prevFpv for the previous quarter (exclusion already fixed at the advance)
    3. total = totalUsd[q]   // quarter counter, O(1)
    4. if total == 0: benign no-op — mark submitted and return (no SetShares; existing map stands, 🔍 D1/FIPs#1275)
       else:
         for i: share_i = usd_i * SHARE_TOTAL / total      // floor
         residue = SHARE_TOTAL - Σ share_i                       // 0 <= residue < N
         // largest-remainder method: sort by remainder (usd_i * SHARE_TOTAL % total) descending,
         // the first residue entries get share_i += 1
         shares = [{wallet_i, share_i}]                          // wallet = orch address (✏️)
    5. drop entries with share_i == 0 (floor division can yield 0 for tiny usds; f02 rejects 0 shares — adapter surfaced by the main-branch mock validation)
    6. mark lastSubmittedQ = q + 1 (CEI), FVMRewards.setShares(SERVICE_STREAM_ID, shares)   // SERVICE_STREAM_ID = 2 (📘 f02-design)
```

- **Σ shares must be exactly == SHARE_TOTAL (1e18)**, otherwise f02 rejects (📘 f02-design / FVMRewards comment); the largest-remainder method guarantees this exactly (✏️ design derivation; the spec gives no algorithm)
- The 3-way split (333333333333333333 × 3 = 999999999999999999) must rely on remainder distribution to top up 1 — a key test (🔍 I1)
- `share` value domain is uint64 (f02 encoding constraint, 📘 FVMRewardTypes)
- Dropping zero-share entries: a floor of 0 arises when a tiny usd is far below the total; f02's recipient validation rejects share=0 and duplicate wallets, so the SRA filters them before SetShares (the main-branch mock's `_sharesValid` surfaced this; the sra-branch mock's looser validation had masked it)

#### 2.5.4 FIL Pricing (📄 §3.3 rules, off-chain per FIPs#1275)

**FIPs#1275 moved the FIL→USD conversion off-chain**: the orchestrator's indexer computes `FPV_i(Q)` as a **single USD-denominated total** — admitted-stablecoin settlements at face value, FIL-denominated settlements converted to USD by the same indexer applying the fixed FIL pricing rule of §2.3 (qualifying fee-auction prints; no third-party price feed). The SRA never receives raw FIL amounts, pricing periods, or print references (📄 §2.3/§4.2).

**At PostVolume posting**:
- `fpv ≤ MAX_FPV_USD` (business-domain bound, audit V3 fix — the single on-chain input that feeds `_computeShares`)
- The pricing rule is fixed and public; every input it consumes (settlements, fee-auction claims) is an on-chain event, so the total remains deterministically recomputable by any observer — a misreport (a wrong FIL→USD conversion included) is detectable by SRA Governance during the verification window and correctable via `CorrectVolume` (📄 §2.2).

**On-chain arithmetic**: `_computeShares` is the only place USD values multiply — FixedU18 fixed-point (`usd * ONE / total`, 18-decimal; mathematically identical to the integer form `usd × 1e18 / total_int`); with `usd ≤ 1e30` and ≤ 64 orchestrators, no overflow is possible (§5.5).

#### 2.5.5 Governance Integration (📘 UnanimousGovernance mechanism + ✏️ method pairing)

| Governance method | Modifier | hold | Notes |
|-------------------|----------|------|-------|
| admit/remove/freeze/unfreeze/replace/reassignBinding/setAdmittedLists/setPricingParams | `unanimous(keccak256(msg.data), SRA_CANCEL_HOLD)` | yes | two votes + permissionless completion after hold |
| correctVolume | `unanimousNoHold(keccak256(msg.data))` | no | the window is the hold (📄 §5.3); validates the verification window in the function body |
| replaceOwner (audit E1) | `unanimousNoHold(keccak256(msg.data))` | no | owner rotation, effective immediately (aligned with upstream SWA) |
| cancelPending | `_veto(taskId)` | — | either Safe cancels alone (📄 §4.2) |

- **taskId = keccak256(msg.data)** (📘): both Safes must submit byte-identical calldata; methods with array parameters like `setAdmittedLists` require a normalization convention (sorting, consistent encoding) — 🔍 I2 risk; tests must cover dual-Safe calls
- Completion after the hold elapses is permissionless (any keeper may trigger); the second approval call only accumulates a vote, it does not execute (📘 modifier semantics)

#### 2.5.6 f02 Interaction (📘 FVMRewards library)

- Reuse `FVMRewards.setShares(id, shares)` (revert semantics wrapped as `SetSharesFailed`)
- `SERVICE_STREAM_ID = 2` (📘 f02-design: migration fixes consensus=1, service=2)
- SetShares **binds immediately** (f02 folds old shares, 📘 f02-design): the quarterly cadence is the SRA's own normative discipline; f02 does not enforce it
- Share map size ≤ 64 (guaranteed by admitted ≤ 64, 🔍 D2)

### 2.6 Parameter Handling

| Parameter | Handling | Basis |
|-----------|----------|-------|
| `EPOCHS_PER_QUARTER` | Compile-time constant (constructor config) | 📄 §3.2 governance-repo parameter; ✏️ const-ified (avoid a governance attack surface, related to 🔍 R1) |
| `POST_PERIOD` (proposed 3 days) | Compile-time constant | 📄 §11; ✏️ const-ified |
| `VERIFICATION_WINDOW` (proposed 7 days) | Compile-time constant | 📄 §11; ✏️ const-ified |
| `SRA_CANCEL_HOLD` (suggested 7 days) | Compile-time constant | 📄 §4.2 governance-repo parameter; ✏️ const-ified |
| `MAX_ORCHESTRATORS` (64) | Compile-time constant | 📘 PR #13 MAX_RECIPIENTS; 🔍 D2 |
| `MIN_LOT` / `PRICE_BAND` | **Governable** (SRA Governance, updated under SRA_CANCEL_HOLD) | 📄 §3.3/§5.2 "all are SRA state, settable by SRA Governance"; authoritative for the off-chain indexer (FIPs#1275) — no on-chain computation |
| `ACTIVATION_EPOCH` | Constructor config | 📄 §3.2 quarter-window start |

## 3. Decision Record

### 3.1 Design Decisions (D1-D5, user-approved)

#### D1 All-Zero Volume — Benign No-Op (revised by FIPs#1275)

- **Decision (v2, current)**: when the sum of all orchestrator FPVs in a quarter is 0, `SubmitShares` is a **benign no-op** — SplitRule is not evaluated and the existing share map stands (📄 §4.2: "If eligible FPV for that quarter sums to zero, SubmitShares is a benign no-op"). Changing the map in a zero-volume quarter is a governance act (freeze/remove/re-point/weight change), never an automatic one.
- **Rationale (v2)**: [FIPs#1275](https://github.com/filecoin-project/FIPs/pull/1275) superseded the burn design — f02 would need special handling for f099 arriving via SubmitShares, and an automatic map change in a zero-volume quarter is a governance decision, not a mechanism one.
- **Decision (v1, superseded)**: submit `[{f099, 1e18}]` to burn the quarter's service stream; rejected alternatives (revert/skip) were ruled out under the v1 FIP text.
- **Impact (v2)**: zero-volume quarters leave the map untouched; locked by `test_SubmitShares_AllZero_NoOp_KeepsMap` / `test_SubmitShares_AllFrozen_NoOp_KeepsMap`.

#### D2 Orchestrator Cap 64

- **Decision**: total admitted orchestrators (**including frozen**) ≤ 64 (MAX_RECIPIENTS). `admit` rejects when full; only `remove` releases a slot; `freeze` does not release a slot.
- **Rationale**: f02 `MAX_RECIPIENTS=64` (PR #13); frozen orchestrators keep their identity; freeze not releasing a slot avoids frequent share-map restructuring from freeze/unfreeze.
- **Impact**: share map size always ≤ 64; tests cover 64-full rejection, Remove release, Freeze non-release (G2 adds the 64-all-posted map-boundary case).

#### D3 / D3a CorrectVolume Bidirectional Correction

- **Decision**: `correctVolume` uses the `unanimousNoHold` path (no-hold exemption; the verification window itself is the hold), validates the window in the function body; allows **bidirectional correction** (up or down); no extra veto fallback (dual-Safe agreement is the protection). The corrected value is a single USD total (same shape as PostVolume, FIPs#1275).
- **Rationale**: spec §4.2/§5.3 "the window itself is the hold"; correction exists precisely to fix misreports, a wrong FIL-to-USD conversion included (📄 §2.2); governance is the final authority (dual-Safe agreement).
- **Impact**: callable only within the verification window, not after it closes; tests cover up/down/multiple-corrections-last-wins/backfill/window boundaries (±1).

#### D5 Deployment Form (this iteration: feature monolith only)

- **Decision**: this iteration implements only the feature monolith (no proxy); storage is designed with ERC-7201 namespaces, reserving zero-migration for future ERC-8167 proxying. Module organization follows the SWA: thin contract + logic delegated to libraries (f02 interaction reuses `FVMRewards`).
- **Rationale**: issue #5 already decided the ERC-8167 proxy final state; staged implementation; namespace-based storage from day one avoids future migration cost.
- **Impact**: storage split into 4 ERC-7201 namespaces (see S2); future delegate division maps directly onto these blocks.

### 3.2 Structural Decisions (S1-S12)

#### S1 Method Signatures (✅ approved)

- **Decision**: Solidity types for all 14 writes + 1 read (12 core writes + 1 auxiliary write: cancelPending governance veto; + 1 audit-added governance write: replaceOwner owner rotation, E1). Sub-decisions: A. `setPricingParams` as an independent method (not merged into setAdmittedLists; parameter domains separate); B. `postVolume`/`correctVolume` take a single USD-denominated total `FixedU18` (FIPs#1275: the FIL→USD conversion is off-chain, so the FPV has no per-component structure to correct; 18-decimal fixed point aligns with the SWA interface and type-checks against integer/fixed-point mixing); C. `Q` as uint64 (sufficient quantization headroom; `Q × EPOCHS_PER_QUARTER` uses a uint256 intermediate to guard overflow).
- **Rationale**: the spec gives only method names and prose; signatures are design derivations; parameter-domain separation lowers governance coupling; the full FPV structure supports correction scenarios.
- **Impact**: method set and ABI finalized; C1 later adjusts `registerPairs` to a named struct (Solidity compile limitation); C8 environment issue resolved via the forge upgrade.

#### S2 Data Structures (✅ approved)

- **Decision**: 4 ERC-7201 namespaces (`Registry`/`AdmittedLists`/`Quarter`/`Params`) and field layout, each block an independent slot (derived from `keccak256(namespace)`, never colliding). The Quarter namespace previously carried the PRICE_BAND anchor (C6) and `conversionFinalized` — both removed by FIPs#1275 (off-chain conversion); the review-#10 mirror refactor then replaced the `fpv` map + `sharesSubmitted` map with the two-slot mirror (`fpv`/`prevFpv` in Registry) + the quarter counter array (`totalUsd`) + `activeQ`/`lastSubmittedQ`.
- **Rationale**: divided by "data lifecycle × governance ownership" — Registry (long-lived identity, governance domain), AdmittedLists (isolated configuration, governance domain), Quarter (rolling quarterly data, mechanism domain, the only high-frequency write), Params (governance parameters, governance domain); future delegate division maps directly, zero storage migration.
- **Impact**: storage layout finalized; C6 found a design gap — the PRICE_BAND reference needed a storage field (later placed in the Quarter namespace).

#### S3 Largest-Remainder Method (standard practice)

- **Decision**: share rounding residue is distributed by remainder (`usd_i * SHARE_TOTAL % total`) descending; the first `residue` entries get `share_i += 1`, guaranteeing `Σ shares == 1e18` exactly.
- **Rationale**: f02 rejects Σ≠1e18 (📘 f02-design); residue < n ≤ 64 keeps the top-up loop bounded.
- **Impact**: 3/7/17-way split tests (I1) + random fuzzing (G7) verify the exact sum.

#### S4 Window Determination (standard practice)

- **Decision**: boundary expressions — posting `E < now ≤ E+POST`, verification `E+POST < now ≤ E+POST+VERIFY`, post-binding `now > E+POST+VERIFY`; all comparisons use the `Epoch` (uint64) type.
- **Rationale**: off-by-one hotspot; unified Epoch type + explicit boundary expressions.
- **Impact**: I5 boundary ±1 tests cover (E, E+POST, E+POST+VERIFY and ±1).

#### S5 Freeze Snapshot (✅ approved)

- **Decision**: `OrchestratorInfo` maintains `freezeEpochs`/`unfreezeEpochs` history arrays (one push per freeze/unfreeze execution); determining "whether the E+POST instant of quarter Q is frozen" does a paired-interval search; falling inside `[freeze[i], unfreeze[i])` → frozen. **Superseded by the review-#10 mirror refactor**: the arrays were replaced by the `frozenAtPostEnd` stored flag (set/cleared only before E+POST) + `frozenSince` (current freeze state); at the mirror advance the flag is snapshotted into `prevFpv` (`prevFpv <- frozenAtPostEnd ? 0 : fpv`), because a past E+POST's freeze state is no longer derivable once the quarter has advanced — see §2.5.2.
- **Rationale**: strictly matches the spec's E+POST snapshot semantics; derivable at any point, independent of call ordering — SubmitShares/AggregatedFPV results do not depend on keeper call timing.
- **Impact**: E+POST snapshot positive/negative tests (`FrozenAtPostEnd_UnfrozenInWindow_StillExcluded` and `UnfrozenAtPostEnd_FrozenInWindow_StillIncluded`); previously discussed alternatives (current-state determination / bitmap snapshot / single field) rejected.

#### S6 Parameter Const-ification (standard practice)

- **Decision**: `EPOCHS_PER_QUARTER`/`POST_PERIOD`/`VERIFICATION_WINDOW`/`SRA_CANCEL_HOLD`/`MAX_ORCHESTRATORS=64` are compile-time constants (constructor config); only `MIN_LOT`/`PRICE_BAND` are governable (`MAX_PRICE_PERIODS` was removed with the pricing-period vector, FIPs#1275 — no periods reach the chain).
- **Rationale**: reduces the governance attack surface (R1-related); the two pricing parameters are explicitly settable by governance per spec §3.3/§5.2 (authoritative for the off-chain indexer, FIPs#1275).
- **Impact**: 9-parameter constructor signature (C2 aligned); setPricingParams governance method (G1 tests added).

#### S7 Recipient Wallet (✅ approved)

- **Decision**: the orch address is the wallet in the share map.
- **Rationale**: keep admit simple; wallet change goes through `replace`.
- **Impact**: no independent recipient-wallet field; replace takes on wallet-change duty (G6 adds failure-path tests).

#### S8 PRICE_BAND Reference (obsolete — FIPs#1275)

- **History**: the anchored-reference design (deviation-D aligned) governed the on-chain band check; **both the band check and its anchor storage were removed by FIPs#1275** — the FIL pricing rule (incl. MIN_LOT/PRICE_BAND) now governs the off-chain conversion each orchestrator's indexer applies before posting, not an on-chain computation (📄 §2.3/§4.2).

#### S9 Rate Representation (obsolete — FIPs#1275)

- **History**: `PricePeriod` (lotUsd/claimFil rational + integer conversion) was removed with the on-chain FinalizeConversion; the SRA now stores only the single USD total.

#### S10 Period Cap (obsolete — FIPs#1275)

- **History**: `MAX_PRICE_PERIODS` and its on-chain enforcement were removed with the pricing-period vector (no periods reach the chain).

#### S11 correctVolume Signature (revised by FIPs#1275)

- **Decision**: `correctVolume`'s `value` is a single USD-denominated total (same shape as PostVolume).
- **Rationale**: with the conversion off-chain, there are no raw FIL components to correct — a wrong FIL-to-USD conversion is corrected by posting the recomputed USD total (📄 §2.2).
- **Impact**: C3 FPV structure simplified to `{usd, posted}`.

#### S12 Read-Only Views (standard practice)

- **Decision**: `aggregatedFPV` (primary read) + supplementary views: `isAdmitted`/`isFrozen`/`bindingOf`/`fpvOf`/`qEnd`/`admittedCount`/`getPricingParams`/`orchestratorCount` (+ C5 supplementary allowlist getter).
- **Rationale**: spec §4.2 "read-only views expose the registry, bound volume, USD-denominated AggregatedFPV"; `qEnd` is the SWA-facing quarter-end getter (IServiceRewardsActor interface).
- **Impact**: `isFinalized` was removed with FinalizeConversion (FIPs#1275).

#### S13 Orchestrator Identity — Internal uint64 id, not Address (design review refactor)

- **Decision**: an orchestrator's identity is an internal **monotonically allocated, never-reused `uint64` id**; an address is only the current effective wallet (`mapping(address => uint64) activeIdOf`). `bindings`/mirror contribution slots (`fpv`/`prevFpv`)/freeze state (`frozenSince`/`frozenAtPostEnd`) all key on the id. `replace(old,new)` = O(1) wallet re-point (`activeIdOf[old]=0; activeIdOf[new]=id; orchestrators[id].wallet=new`).
- **Rationale** (replaces the address+`successor` alias-chain model):
  - the alias chain **structurally introduced** a bug class: re-admit of a replaced address left a residual `successor` chain, through which a frozen successor could receive a share (T10). With id-keyed identity, re-admit allocates a fresh id — zero residual state by construction, no cleanup step;
  - `replace` no longer cuts historical quarter FPV: the mirror slots (`fpv`/`prevFpv`) survive a wallet change, so a quarter posted before replace stays aggregated. The address-keyed model lost it from the traversal (old address not in `admittedList`) and required a governance `correctVolume` migration;
  - binding uniqueness / unclaimed checks read the bound id's `admitted` directly (no chain resolution).
- **Costs (accepted)**: every address entry does one extra `activeIdOf` SLOAD (quarter-frequency, gas-insensitive); the id is an internal concept absent from the FIP (documented here); archived id records accumulate (governance-frequency, bounded by admit/remove churn) — archived data is only reachable off-chain (events/indexers), since after `remove` clears `activeIdOf[orch]`, `fpvOf`/`isAdmitted` no longer reach the archived id (only `bindingOf` still reads its wallet). Runtime size grows past the EIP-170 cap under the default optimizer (25,576B > 24,576B); tracked in §5.12 — resolution is the planned contract split (logic-to-library / proxy split, #5), not via-IR.
- **Impact**: external ABI unchanged (methods/events stay address-typed); `successor`/`_resolve`/`admittedList` removed; the Registry namespace storage layout changed (ERC-7201 slot unchanged — same namespace); the Quarter namespace keeps its mirror layout (`activeQ`/`lastSubmittedQ`/`totalUsd`) untouched — only the per-orchestrator identity keying changed.
- **FIP gap (external)**: FIP-0118 says "Replace transfers identity and all bindings" but is silent on whether already-posted quarter FPV follows the identity. This implementation chose **follows** (identity continuity). A spec clarification is worth raising with the FIP author.

### 3.3 Conflict Rulings (C1-C8, found by the tester between the design and language/code facts)

> These are inconsistencies the tester found between the design and Solidity language/code facts. All of the following are implemented per this list; where the original design text said otherwise, the implementation follows the ruling.

| # | Ruling | Disposition |
|---|--------|-------------|
| **C1** | the design's `registerPairs((address, address)[] calldata)` inline tuple-array parameter **cannot compile** in Solidity 0.8.36 ("Expected type name", verified empirically) | use a named struct `Pair {address payer; address operator;}` (top-level definition, field names/ABI consistent with the design) |
| **C2** | the design gives no constructor signature | set 9 params `(owner1, owner2, epochsPerQuarter, postPeriod, verificationWindow, cancelHold, activationEpoch, minLot, priceBand)` — `maxPricePeriods` removed by FIPs#1275 (test design derivation ✏️) |
| **C3** | the design does not define the FPV calldata structure | use the simplified 2 fields `(usd, posted)` — single USD-denominated total (FIPs#1275); posted=false on posting (SRA sets posted internally) |
| **C4** | the design does not define the band's numeric representation | set **basis points** (2000 = allows ±20% deviation, test assumption H-band) |
| **C5** | the design's supplementary views do not list an allowlist getter, but the tests need to verify `setAdmittedLists` takes effect | add `isStablecoinAdmitted(address) view returns (bool)` (reasonable extension of spec §4.2 "read-only views expose the registry…") |
| **C6** | ⚠️ the design requires validating "against the last bound qualifying print" but the data structures have no reference storage field | the SRA stored the anchor in the Quarter namespace (anchored-reference, deviation-D); **removed with the PRICE_BAND check by FIPs#1275** |
| **C7** | aggregatedFPV defined as a view | **superseded twice**: deviation-A alignment (T11) made it non-view auto-triggering; **FIPs#1275 restored the pure view** (no on-chain finalize exists anymore — see §2.3.5) |
| **C8** | local forge 1.3.5 incompatible with the project foundry.toml lint section (`code-size` etc. enums), and `--config-path` relative paths resolve from the config's directory | temporary config to compile; **resolved by the forge 1.7.1 upgrade** (P0), the project config is usable directly |

### 3.4 Test Decisions (T1-T11)

> T1 not listed separately (G1-G7 is the systematic coverage closure, see §3.5); T2-T6 are test-side or implementation-side defects found during implementation/review and their dispositions;
> T7-T9 are correctness-assurance additions (A1/A2/A3/E1, see §4.3.4); T10 is the A2 real-defect fix (caught during t7/t8 acceptance);
> T11 is the unified implementation of the spec-conformance deviations (user-reviewed one by one, principle: spec alignment first).

| # | Defect | Disposition |
|---|--------|-------------|
| **T2** | missing prank on re-submission after veto (test-side defect) | fixed the test (aligned with the governance library's real semantics) |
| **T3** | postVolume posting timing out of window (test-side defect) | fixed the test |
| **T4** | cap expectRevert misplaced on the second vote (test-side defect) | fixed the test |
| **T5** | makeAddr salt depending on block.number causing address collisions (test-side defect) | fixed the test |
| **T6** | ⚠️ **implementation defect (found in the final review, TDD fix)**: `registerPairs`'s AlreadyBound check uses `_isAdmitted(current)` instead of `_resolve(current)` — after replace the binding still points to the old address (admitted=false), the check is bypassed, and a third party can grab the binding pair | tester first wrote `test_RegisterPairs_AfterReplace_ThirdPartyReverts` (Red) → coder's 1-line fix `_isAdmitted(_resolve(current))` (Green); the invariant `invariant_OneBindingPerPair` is designed to catch this class of bugs  *(S13: the check is now `boundId != 0 && orchestrators[boundId].admitted` — bindings store the id, so the bound id's admitted flag is read directly; observable behavior unchanged)* |
| **T7** | SetShares system-call failure path never tested (mock has no failure injection) | t6 adds `test_SubmitShares_SetSharesFailed_Reverts` (mock `failSetShares` injection → revert SetSharesFailed + control success path) |
| **T8** | freeze-snapshot semantics lack persistent invariant verification | t6 adds `invariant_FrozenAtPostEnd_ExcludedFromShares` (handler freeze-interval tracking; frozen-at-POST shares always 0) |
| **T9** | D1 all-zero semantics lack invariant verification | t6 adds `invariant_NonZeroTotal_ValidShareMap` (Σ>0 quarters produce a valid trimmed map; the all-zero no-op branch is covered by the SRAShares unit tests — revised from the burn invariant by FIPs#1275); t6 also lands E1 gas baseline (`.gas-snapshot`) |
| **T10** | ⚠️ **implementation defect (caught at t7/t8 acceptance, TDD fix)**: `replace(old→new)` sets `old.successor = new` → re-`admit(old)` leaves **successor residual** → `submitShares` freeze check `_frozenAtPostEnd(old)` (against old itself, not frozen, passes) but the wallet writes `_resolve(old) = new` (frozen at POST) → **a frozen orchestrator obtains a share through the resolve chain** (violating S5/S7); second face: `replace` keeps `old.frozen`/freeze history, re-admit carries frozen state in | **Option A (admit identity reset, symmetric with remove cleanup)**: `admit` appends clearing `successor = 0`, `frozen = false`, `delete freezeEpochs/unfreezeEpochs`. Coder first wrote 2 regression tests (R1: share map excludes the frozen successor; R2: re-admit clears frozen for normal operation; Red before the fix) → fixed the implementation (Green) + synced the invariant handler's admit/completeParked state cleanup. Rejected options B (make the submitShares freeze check decide after `_resolve(orch)` — violates S5's requirement to check the reporting orchestrator itself; old's legitimate FPV dragged down by frozen new; other functions like aggregatedFPV inconsistent), C (forbid re-admit after replace — too restrictive, conflicts with S7 "keep admit simple")  *(S13: the alias chain is removed — re-admit allocates a fresh id, so the successor-residual bug class is structurally eliminated; the R1/R2 regression tests still pass, locking the same observable behavior)* |
| **T11** | **spec-conformance deviation unified implementation (user-reviewed one by one, principle: spec alignment first)**: the spec-conformance matrix's 5 deviations — **A** (aggregatedFPV trigger semantics): the spec's three literal statements "reading triggers FinalizeConversion" vs the implementation's pure view; changed to **read auto-triggers idempotent finalize** (rejected keeping a view that relies on the caller finalizing first — the SWA has no gating implementation, the contract dependency would be unmet); **B** (MIN_LOT): the implementation never participated in the pricing path (neither band reference nor conversion filtered); changed to **sub-MIN_LOT prints do not participate in pricing** (band check skipped, never become the reference, not counted in finalize, aligned with §3.3 qualifying-print semantics); **C** (MAX_PRICE_PERIODS): clarified as **not a deviation** (on-chain rejection of over-limit is the enforcement of the spec's "at most MAX_PRICE_PERIODS entries" format; adjacent-period merging is the off-chain indexer's job); **D** (PRICE_BAND reference): changed to **anchored reference** — reference = the qualifying print of the previous quarter's binding final state, updated at finalize; rejected "posting-time update" (chained reference: under the optimistic-acceptance model print authenticity cannot be verified; n chained steps within a single postVolume can push the reference ×(1+band)^n (n=32 ≈ 218×), taking effect immediately with no correction rollback; with an anchor the push rate is band/quarter with a verification-window correction opportunity, §394 "gating may only under-count, never over-count"); **E** (Replace identity transfer): status quo kept (necessary completion, no literal spec conflict) | **A/B/D source+test alignment (TDD)**: 6 new SRAQuarter tests (anchor prevents single-batch drift / cross-quarter anchor update / correctVolume does not update anchor / three sub-MIN_LOT filters) + SRAIntegration C3 rewrite (read auto-triggers → complete value + isFinalized) + differential model anchor-semantics sync (model 3 reference chain → anchor, model 2 + min_lot filter; 175 cases still all match) + base-class MIN_LOT dimension fix (1e18 → 100 USD, aligned with the spec's proposed "a few hundred USD"). C/E documentation clarification (§2.5.4) |

> **T11 postscript (FIPs#1275)**: deviations **A** (aggregatedFPV trigger) and **D** (anchored band reference) are now **obsolete** — the FIP moved the FIL→USD conversion off-chain (no on-chain finalize/band), so `aggregatedFPV` is a pure view again (C7 superseded) and the band machinery is deleted; **B** (MIN_LOT) and **C** (MAX_PRICE_PERIODS) are likewise obsolete (no pricing periods reach the chain). The deviation work remains as the historical record of the pre-FIP implementation.

### 3.5 Coverage Gap Closure (G1-G7, 58 → 74 tests)

> Coverage gaps found by the scheduler's systematic assessment; the tester closed them with 16 tests.

| # | Gap | Added verification points |
|---|-----|---------------------------|
| **G1** | `setPricingParams`/`getPricingParams` untested | parameter update takes effect / gating / invalid-param rejection (3 tests; the band-applies-to-new-prints test was removed with the band check, FIPs#1275) |
| **G2** | 64-full + submitShares combination untested | all 64 post → map has exactly 64 recipients (mock MAX_RECIPIENTS boundary), 64-way even split Σ exact |
| **G3** | band exact ±20% boundary untested | **removed with the PRICE_BAND check (FIPs#1275)** — no on-chain band arithmetic remains |
| **G4** | MAX_PRICE_PERIODS exactly 32 untested | **removed with the pricing-period vector (FIPs#1275)** — no periods reach the chain |
| **G5** | multi-quarter share isolation untested | quarter-1 posting does not leave residue affecting quarter 0 (multi-quarter map isolation) |
| **G6** | governance failure-path asymmetry | replace target already admitted / reassignBinding target not admitted / remove non-orchestrator / frozen orchestrator can be removed (errors thrown at the third permissionless execution) |
| **G7** | no fuzzing | 3 random usdValues → Σ shares always exactly == 1e18 (largest-remainder core invariant, 256 runs) |

> Supplement: P1 adds 3 persistent invariants (invariant_SumShares_IsShareTotal / invariant_OneBindingPerPair / invariant_GovernanceTasks_Consistent; handler encapsulates 13 random operations — finalizeConversion removed by FIPs#1275); P2 adds 14 more deterministic tests (CV1-CV7; line coverage 100%, branch 67.16% at the tool's statistical ceiling), see §4.3.2/§4.3.3.

### 3.6 Implementation-Layer Risks and Mitigations (I/R)

| # | Risk | Mitigation (landed) |
|---|------|---------------------|
| **I1** | share rounding Σ≠1e18 | largest-remainder method (S3) + 3/7/17-way split tests + G7 fuzz |
| **I2** | taskId deadlock (byte-level calldata differences) | normalization convention for array parameters + dual-Safe call tests (`TaskId_DifferentArrayOrder_DoesNotMerge` / `SameArrayOrder_Executes`) |
| **I5** | window off-by-one | Epoch type + boundary ±1 tests (I5) |
| **R1** | captured SRA inflated postings → gating step | AggregatedFPV reads only bound values (never reads unbound posted values); submitted values recomputable |

### 3.7 Approval Status Summary

| Group | Decision | Status |
|-------|----------|--------|
| D | D1 / D2 / D3(D3a) / D5 | ✅ settled (user-approved) |
| S | S1 / S2 / S5 / S7 | ✅ approved |
| S | S8 | ✅ aligned per deviation D (anchored reference, see T11; **obsolete since FIPs#1275** — band machinery removed) |
| S | S3 / S4 / S6 / S9 / S10 / S11 / S12 / S13 | ⏳ not individually reviewed (standard practice, verified by the implementation); **S9/S10 obsolete since FIPs#1275**, S11 revised (single USD total); S13 id-identity refactor landed with the id-identity rework (319 tests) |
| C | C1-C8 | ✅ ruled and landed (C8 closed with the forge 1.7.1 upgrade; C6 removed with the band, C7 superseded twice — see §2.3.5) |
| T | T2-T11 | ✅ disposed (T6/T10 implementation defects, TDD fix; T7-T9 correctness assurance landed; T11 spec-conformance alignment A/B/D + C/E clarification, A-D obsolete since FIPs#1275; post-review audit hardening V1/V2/V3 + B1/C1/E1/E2/F2 landed as T12) |
| G | G1-G7 | ✅ closed (58 → 74 → 77 → 91 → 94 → 96 → 100 → 103 → 109 → 123 → 151 tests; band/period gaps G3/G4 removed with the mechanism) |
| I/R | I1 / I2 / I5 / R1 | ✅ mitigations landed (tests + implementation semantics double assurance) |

**Final acceptance**: the implementation aligns with all design rulings, and the spec-conformance deviations A/B/C/D/E were reviewed by the user one by one and uniformly landed (T11); **FIPs#1275 adaptation landed** (FPV single USD total, off-chain FIL→USD conversion, on-chain band/finalize/burn machinery removed, all-zero quarter = benign no-op); **261/261 tests Green** (117 SRA deterministic + 5 invariant + 139 existing); SRA line coverage 100%, branch 67.16% (tool statistical ceiling; governance function-body require branches under-counted by the lcov modifier quirk); `forge fmt --check` / `forge lint` clean; Slither static analysis zero real risk; Halmos symbolic verification quarter-window 4/4 PASS (`_computeShares` checks dropped, FixedU18 symbolic-execution limit — covered by differential + invariant fuzz); final code review PASS; the A2 real defect (T10) fixed with 2 deterministic regression tests guarding it; audit hardening V1/V2/V3 (overflow DoS, input-domain bounds) and B1/C1/E1/E2/F2 (remaining bounds + owner rotation) landed with 6 + 8 regression tests; QA-system fixes S1-S5 landed (adversarial input matrix 28 tests / security-claim-to-code map / evidence-condition annotation / threat model matrix / reviewer checklist).

## 4. Test Strategy and Coverage

### 4.1 Test File Inventory

| File | Responsibility | Test functions | Strategy points covered |
|------|----------------|----------------|------------------------|
| `test/SRATestBase.sol` | Common base: deploy SRA, build Safe owners, register service stream 2, quarterly time utilities, governance helpers | — (not a test) | — |
| `test/SRAGovernance.t.sol` | Governance flow | 16 | 6 |
| `test/SRARegistry.t.sol` | Orchestrator registry + freeze + cap | 28 | 3, 5 |
| `test/SRAQuarter.t.sol` | Quarter state machine + FPV (single USD total, FIPs#1275) | 22 | 2, 7, 11 |
| `test/SRAggregateMirror.t.sol` | **Aggregate mirror differential tests** (review #10 refactor): mirror pinned to the linear-scan semantics across post / correct / freeze / unfreeze / replace (inheritance) / remove + quarter advance / lagging submit (prevFpv) / exclusion-fixed mirror + historical quarter counter | 9 | 14 (aggregate path) |
| `test/SRAShares.t.sol` | Share computation + no-op + freeze snapshot + SetShares | 17 | 1, 3, 4, 10, 12 |
| `test/SRAIntegration.t.sol` | **Integration contract tests** (simulate the SWA gating consumer of aggregatedFPV; pure-view no-divergence, FIPs#1275) | 3 | 11 |
| `test/SRAOverflowDoS.t.sol` | **Overflow DoS regression tests** (audit V3 — _computeShares overflow; V1/V2 removed with the band/finalize machinery, FIPs#1275) | 2 | 11 (overflow-DoS hardening) |
| `test/SRAAdversarial.t.sol` | **Adversarial input matrix** (S1, QA system fix): boundary probes of the external write surface — q-window boundaries (future quarter / uint64.max), FPV single-USD-total exact-limit accept / limit+1 reject, zero-address probes, setPricingParams parameter grid, empty-array semantics, multi-orchestrator aggregate bound | 20 | 2, 7, 11 (adversarial layer) |
| `test/SRAInvariant.t.sol` | **Invariant tests** (P1/A2/A3): handler random operations + 5 persistent invariants | 5 | I1 share conservation / I2 binding uniqueness / I3 governance consistency / A2 freeze-snapshot exclusion / A3 non-zero-total valid map |
| `test/differential/DifferentialShares.t.sol` | **Differential tests** (t1): Python independent reference model cross-validates the largest-remainder core; aggregation hand-written cases (band differential removed, FIPs#1275) | 4 | 1, 11 (independent reference model) |
| `test/halmos/QuarterWindowCheck.t.sol` | **State-machine symbolic verification** (blind spot 4 closed): Halmos formally proves parameter-independent quarter-window properties (T2a quarter boundary / T3 constant interval / T4 snapshot-time independence / T5b empty-history boundary); harness in `test/halmos/QuarterWindowHarness.sol` | 4 (halmos, runs in its own CI workflow halmos.yml) | 2, 3, 4 (symbolic verification layer) |

**319 forge tests in total** (17 suites: quarter state machine / registry / governance / shares / integration / aggregate-mirror / overflow-DoS / adversarial / invariant + the pre-existing non-SRA suites), plus 2 Halmos symbolic-verification checks (own workflow halmos.yml — QuarterWindowCheck, the freeze-interval determinations were removed with the mirror refactor); covers all active test strategies in §4.2 + 3 new persistent invariants from P1 + A2/A3 correctness invariants + A2 defect regression + integration contract tests + differential cross-validation + state-machine symbolic verification + aggregate-mirror differentials (#10) + overflow-DoS hardening (V3) + audit bound enforcement (B1/C1/E1/E2/F2) + adversarial input matrix (S1) + id-identity rework (S13, +5). FIPs#1275 removed the band/finalize/burn suites.

### 4.2 Strategy Point Coverage Matrix

| # | Strategy point (design §3) | Test functions | Source |
|---|----------------------------|----------------|--------|
| 1 | Share rounding (largest remainder) | `SRAShares.test_SubmitShares_ThreeWayEqual_ExactSum` (3-way)<br>`..._SevenWayEqual_ExactSum` (7-way)<br>`..._SeventeenWayEqual_ExactSum` (17-way, remainder 15)<br>`..._UnevenSplit_Proportional` (30/70) | 🔍 I1 / ✏️ S3 |
| 2 | Window boundaries (E/E+POST/E+POST+VERIFY ±1) | `SRAQuarter.test_PostVolume_PostingWindow_Success` (E+1)<br>`..._AtQuarterEnd_Reverts` (E strictly less)<br>`..._AtPostEnd_Inclusive` (E+POST inclusive)<br>`..._AfterPostingWindow_Reverts` (E+POST+1)<br>`..._SecondPosting_Reverts` (usd==0 check)<br>`SRAQuarter.test_CorrectVolume_AtVerifyEnd_Inclusive`<br>`..._AfterVerificationWindow_Reverts` | 🔍 I5 / ✏️ S4 |
| 3 | Freeze semantics | `SRARegistry.test_Freeze_PreventsPostVolume`<br>`..._Unfreeze_RestoresOperations`<br>`..._RegisterPairs_Frozen_Reverts`<br>`..._Remove_ReleasesPairs_CanBeReclaimed`<br>`..._RegisterPairs_AfterReplace_ThirdPartyReverts` (**T6**: third-party pair grab after replace must revert)<br>`SRAShares.test_SubmitShares_FrozenExcluded_ExactSum`<br>`..._FrozenAtPostEnd_UnfrozenInWindow_StillExcluded` (E+POST snapshot)<br>`..._UnfrozenAtPostEnd_FrozenInWindow_StillIncluded` (snapshot counterexample)<br>`SRARegistry.test_Replace_TransfersIdentity`<br>`..._ReassignBinding_ChangesBinding` | 📄 §4.2 + ✅ S5 |
| 4 | All-zero no-op (FIPs#1275, replacing D1 burn) | `SRAShares.test_SubmitShares_AllZero_NoOp_KeepsMap` (nobody posted)<br>`..._AllFrozen_NoOp_KeepsMap` (all frozen/excluded)<br>**Both assert the share map stands unchanged (no SetShares — SplitRule not evaluated)** | FIPs#1275 |
| 5 | Cap rejection (D2) | `SRARegistry.test_Admit_AtCapacity_Reverts` (64 full rejects)<br>`..._Admit_RemoveFreesSlot` (Remove frees)<br>`..._Admit_FrozenStillCountsTowardLimit` (freeze does not free) | 🔍 D2 |
| 6 | Governance flow | `SRAGovernance.test_Admit_TwoApprovalsPlusHold_Executes`<br>`..._HoldNotElapsed_ExecutionReverts` (HoldUntil)<br>`..._SingleApproval_NotExecuted`<br>`..._NonOwner_Reverts`<br>`..._TaskIdIsKeccakOfCalldata`<br>`..._Veto_CancelsPendingAdmit`<br>`..._Veto_NonOwner_Reverts`<br>`..._CorrectVolume_NoHold_SecondApprovalExecutesImmediately`<br>`..._SameOwnerTwice_Reverts`<br>`..._TaskId_DifferentArrayOrder_DoesNotMerge` (I2 deadlock)<br>`..._TaskId_SameArrayOrder_Executes` (control) | 📘 UnanimousGovernance + 🔍 I2 |
| 7 | CorrectVolume | `SRAQuarter.test_CorrectVolume_VerificationWindow_Upward` (up)<br>`..._Downward_Corrects` (down, D3a bidirectional)<br>`..._MultipleCorrections_LastWins` (whole replacement)<br>`..._BackfillUnposted` (backfill)<br>`..._AtVerifyEnd_Inclusive` / `..._AfterVerificationWindow_Reverts` | 📄 §4.2 + 🔍 D3a |
| 8 | PRICE_BAND | *(obsolete — removed with the on-chain band check, FIPs#1275)* | 📄 §3.3 — the pricing rule now governs the off-chain indexer only |
| 9 | FinalizeConversion | *(obsolete — removed with the on-chain FIL→USD conversion, FIPs#1275; the tests `test_FinalizeConversion_*` were deleted with the mechanism)* | 📄 §4.2 — no on-chain finalize remains |
| 10 | SetShares encoding | `SRAShares.test_SubmitShares_MapSize_EqualsActiveOrchestrators` (map ≤ 64)<br>`..._PostedUsd_Proportional` (single USD total, FIPs#1275)<br>All share tests assert Σ==1e18 and wallet resolution via mock `getShares(2)` | 📘 FVMRewards/mock |
| 11 | AggregatedFPV | `SRAQuarter.test_AggregatedFPV_BeforeBinding_Zero` (read-only bound value)<br>`..._AfterBinding_SumOfValues` (post-binding aggregation)<br>`..._FrozenExcluded` (frozen excluded) | 📄 §3.2 + 🔍 R1 |
| 12 | f02 mock driving | All tests inherit `MockRewardTest` (etch mock f02 + CALL_ACTOR_BY_ID); stream 2 registration follows the mock's RegisterStream queue semantics; Safe owner construction follows the SWA tests' `_makeSafeOwner` technique | 📘 PR #17 |

### 4.3 Assurance Registries

#### 4.3.1 G1-G7 Gap Closure Registry (58 → 74 tests)

> Coverage gaps found by the scheduler's systematic assessment of the test suite, closed by the tester. 16 new tests, all following existing naming conventions and reusing base-class helpers. Decision-level summary in §3.5.

| # | Gap | Added tests (file:line) | Verification point |
|---|-----|-------------------------|--------------------|
| **G1** | `setPricingParams`/`getPricingParams` untested | `SRAQuarter::test_SetPricingParams_UpdatesParams_GetReturns`<br>`SRAQuarter::test_SetPricingParams_NonOwner_Reverts`<br>`SRAQuarter::test_SetPricingParams_InvalidParams_Reverts` (priceBand > 10000) | parameter management: update takes effect / gating / invalid params |
| **G2** | 64-full + submitShares combination untested | `SRAShares::test_SubmitShares_AtFullCapacity_SixtyFourRecipients` | all 64 post → map has exactly 64 recipients (mock MAX_RECIPIENTS boundary), 64-way even split with 1e18/64 each, Σ exact |
| **G3** | band exact ±20% boundary untested | *(removed with the PRICE_BAND check, FIPs#1275 — no on-chain band arithmetic remains; the tests were deleted with the mechanism)* | `_checkPriceBand` boundary-inclusive semantics — obsolete (band machinery deleted) |
| **G4** | MAX_PRICE_PERIODS exactly 32 untested | *(removed with the pricing-period vector, FIPs#1275 — no periods reach the chain; `test_PostVolume_MaxPricePeriods_ExactlyAccepted` deleted)* | on-chain price-period length cap — obsolete |
| **G5** | multi-quarter share isolation untested | `SRAShares::test_SubmitShares_MultiQuarter_Isolated` | quarter 0 posts A/B → quarter 1 only C posts → quarter 1 map contains only C (no residue), quarter 0 result unaffected |
| **G6** | failure-path asymmetry | `SRARegistry::test_Replace_AlreadyAdmittedTarget_Reverts` (replace target already admitted)<br>`SRARegistry::test_ReassignBinding_NotAdmittedTarget_Reverts` (target not admitted)<br>`SRARegistry::test_Remove_NotAdmitted_Reverts` (non-orchestrator)<br>`SRARegistry::test_Remove_FrozenOrch_Succeeds` (frozen orchestrator can be removed; implementation does not block) | governance failure branches: errors thrown at the third permissionless execution of the function body |
| **G7** | no fuzzing | `SRAShares::test_SubmitShares_Fuzz_SumAlwaysExact(uint256,uint256,uint256)` | 3 random usdValues (bounded < 1e30, aligned with the code-enforced MAX_FPV_USD — S3: sampling domain = enforced input domain, not a test-side shrink) → Σ shares always exactly == 1e18 (largest-remainder core invariant, 256 runs) |

**Implementation issue found**: while writing the G1 tests it was found that the reference updates with each qualifying print (C6 semantics: the last one becomes the new reference) — the "new band applies" test was accordingly changed to directly verify that a value accepted under the old band is rejected after the band change (+20% over-band at band 10%, boundary at band 20%), avoiding reference-update interference with the assertion. (Later superseded by the anchored-reference semantics of deviation-D alignment, §4.3.9.)

#### 4.3.2 P1 Invariant Test Registry (74 → 77 tests)

> P1 quality assurance: Foundry-native invariant tests (random operation sequences + persistent invariant verification) covering the combination blind spots of single-scenario tests. The handler encapsulates 13 random operations (admit/remove/freeze/unfreeze/replace/reassignBinding/registerPairs/postVolume/correctVolume/submitShares/parkAdmit/completeParked/rollForward — finalizeConversion removed by FIPs#1275); each operation has a precondition check to keep the "expected success" paths reachable (invalid calls return directly without polluting state); target functions are explicitly limited via `targetSelector` (excluding the handler's `setUp()` — otherwise the fuzzer would treat it as a target and reset the sra instance).

| Invariant | Assertion | Bug classes it can catch |
|-----------|-----------|--------------------------|
| `invariant_SumShares_IsShareTotal` | after the most recent successful submitShares, the f02 share-map Σ is always == 1e18 | wrong share top-up direction, freeze-exclusion omission, recipient omission, all-zero no-op path breakage |
| `invariant_OneBindingPerPair` | for every pair, `bindingOf` always == the handler's last-recorded binder (resolved along the replace chain) | **T6-class bugs** (third-party pair grab after replace), registerPairs bypassing the uniqueness check, reassignBinding write divergence |
| `invariant_GovernanceTasks_Consistent` | parked task bitmask nonzero and state not landed; executed task bitmask cleared; handler's expected orchestrator state == sra actual | bitmask residue after governance task execution, function-body state changes diverging from the governance flow, replace/remove identity-transfer state not synchronized |

**3 key handler↔implementation alignment fixes** (located through deterministic reproduction while writing the invariants; all were handler defects, not implementation bugs):

1. **replace overwrite semantics**: the implementation `replace` fully overwrites `orchestrators[newOrch]` (successor zeroed) — the handler must mirror `_successor[newOrch] = 0`, otherwise resolution diverges when an intermediate chain address is reused
2. **remove clears successor**: the implementation `remove` explicitly `orchestrators[orch].successor = 0` — the handler must mirror this, otherwise binding resolution still follows the old chain after remove
3. **parked-target mutual exclusion**: while `parkAdmit` is queued, the target address must not be pre-admitted by atomic `admit`/`replace` (newOrch), keeping I3 "parked-not-executed means state-not-landed" always true

*(S13: items 1-2 are obsolete in the id-keyed model — `_resolve`/`_successor` are gone; replace re-points the wallet, remove clears `activeIdOf`, and the handler mirrors identity by **generation** (`_idGen`/`_genSeq`, see §4.3.5 Handler sync). Item 3 still applies.)*

**Run**: `forge test --match-contract SRAInvariant` (default 256 runs, ~3 minutes; handler operation stats show 0 reverts, proving the preconditions are complete).

#### 4.3.3 P2 Coverage Closure Registry (77 → 91 tests)

> P2 quality assurance: `forge coverage` baseline (77 tests) SRA contract line coverage **98.94%** (281/284, already above the 90% target), branch **58.21%** (39/67). 14 real blind spots identified and closed with 14 deterministic tests.
> ⚠️ Statistic finding: for governance function bodies with the `unanimous`/`unanimousNoHold` modifier, their require branches are **all recorded as 0 in lcov** (including remove NotAdmitted / reassignBinding NotAdmitted / replace AlreadyAdmitted / setPricingParams InvalidParameter, which G6 explicitly tests) — this is an lcov quirk for modifier-inlined function bodies, not a real gap, and was not re-tested. Real blind spots were double-confirmed with DA line coverage + one-sided BRDA gaps.

| # | Blind spot (line) | Added tests | Verification point |
|---|-------------------|-------------|--------------------|
| **CV1** | `postVolume` NotAdmitted | `SRAQuarter` `test_PostVolume_NotAdmitted_Reverts` | non-admitted posting rejected (the `_checkPriceBand` ZeroClaimFil branch was removed with the FIL-pricing-period vector, FIPs#1275) |
| **CV2** | `correctVolume` NotAdmitted | `SRAQuarter` `test_CorrectVolume_NotAdmitted_Reverts` | non-admitted target rejected (the TooManyPricePeriods / FIL-period loop-body branches were removed with the pricing-period vector, FIPs#1275) |
| **CV3** | `submitShares` NotBound (508) | `SRAShares` `test_SubmitShares_BeforeBinding_Reverts` | submit before binding (at E+POST+VERIFY) rejected (submitShares' own first-line require; `finalizeConversion`'s NotBound was removed with the mechanism, FIPs#1275) |
| **CV4** | `admit` AlreadyAdmitted (346) | `SRARegistry` `test_Admit_AlreadyAdmitted_Reverts` | re-admitting the same address rejected (G2 only tested AtCapacity full) |
| **CV5** | `freeze`/`unfreeze` four-way failure branches (371/372/381/382) | `SRARegistry` `test_Freeze_NotAdmitted_Reverts` / `test_Freeze_AlreadyFrozen_Reverts`<br>`test_Unfreeze_NotAdmitted_Reverts` / `test_Unfreeze_NotFrozen_Reverts` | NotAdmitted / AlreadyFrozen / NotFrozen gating failure paths |
| **CV6** | `replace` NotAdmitted(oldOrch) (396) | `SRARegistry` `test_Replace_OldNotAdmitted_Reverts` | old address not admitted rejected (G6 only tested the target-already-admitted reverse branch) |
| **CV7** | `aggregatedFPV` unposted continue / `orchestratorCount` never called | `SRAQuarter` `test_AggregatedFPV_UnpostedOrch_Excluded`<br>`SRARegistry` `test_OrchestratorCount_ReflectsAdmissions` | skip when some orchestrators did not post (usd==0 continue, review #7); read-only view count consistent with admittedList.length (review #1) |

**Implementation issue found**: no implementation defect was found during the closure (all new tests went Green directly, verifying existing behavior). Also fixed in passing the P1-leftover fmt difference in `test/SRAInvariant.t.sol` (`forge fmt`, not a semantic change), keeping the whole repo's `forge fmt --check` clean.

#### 4.3.4 Correctness Assurance Registry (91 → 94 tests + gas baseline)

> t6 correctness assurance (quality deepening after reviewer PASS): closed 3 test blind spots + 1 gas baseline.
> A1 covers the failure path of the SRA's only external interaction point with f02; A2/A3 bring the design's core security mechanisms (freeze snapshot, all-zero no-op) under persistent invariant verification.

| # | Blind spot | Added tests | Verification point |
|---|------------|-------------|--------------------|
| **A1** | `SetSharesFailed` system-call failure never tested (mock had no failure-injection path) | `SRAShares` `test_SubmitShares_SetSharesFailed_Reverts` | mock adds a `failSetShares` failure-injection switch (`mockFailSetShares`) → `_setShares` unconditionally returns USR_FORBIDDEN → submitShares reverts `SetSharesFailed(USR_FORBIDDEN)`; with the switch off, a normal submit in the same quarter succeeds (control, proving the failure comes only from injection and SRA state is not polluted) |
| **A2** | the 3 invariants did not cover the "freeze snapshot" semantics (frozen-at-E+POST shares always 0, the design's core security mechanism) | `SRAInvariant` `invariant_FrozenAtPostEnd_ExcludedFromShares` | handler tracks freeze intervals (`_freezeAt`/`_unfreezeAt` — semantically the implementation's `frozenAtPostEnd` flag: an E+POST inside `[freeze, unfreeze)` ⇔ the flag was set before E+POST and not cleared before it) → active orchestrators frozen at the POST instant of the latest submit quarter (**the address itself**; the implementation's frozen-flag `continue` excludes that orchestrator, producing no wallet) must not appear in the share map |
| **A3** | the all-zero quarter branch had no invariant verification (total==0 → benign no-op, FIPs#1275 replacing D1 burn) | `SRAInvariant` `invariant_NonZeroTotal_ValidShareMap` | reads `sra.fpvOf(q, orch).usd` directly (**same data source as submitShares' traversal**) → when Σ of non-frozen-with-usd>0 at POST == 0, submitShares is a benign no-op (no SetShares; the map stands, covered by the SRAShares unit tests); when Σ>0 → the map is a non-empty subset of the active orchestrators, all shares non-zero (trimmed of 0-share entries) |
| **E1** | no gas regression baseline | `.gas-snapshot` (generated by `forge snapshot`) | full-suite gas snapshot, preventing future gas regressions |

**Key handler↔implementation alignment points** (confirmed while writing A2/A3; all handler state tracking, not implementation bugs):
1. **Freeze-interval pairing**: `_isFrozenAtHandled` determines E+POST membership via the half-open `[freeze, unfreeze)` interval — semantically the implementation's `frozenAtPostEnd` flag (set before E+POST and not cleared before it ⇔ E+POST inside the interval); a freeze after E+POST does not set the flag for that quarter, matching the interval test (E+POST before the freeze start)
2. **replace deep-copy**: the implementation `replace` fully overwrites `orchestrators[newOrch]` (incl. `frozenSince`/`frozenAtPostEnd`/`fpv`/`prevFpv` — the new identity inherits the frozen state and the contribution) — the handler must mirror the copy, otherwise A2's determination for post-replace identity transfers diverges
3. **remove clears**: the implementation `remove` `delete`s the freeze arrays — the handler mirrors the clearing
4. **admit identity reset**: the implementation `admit` **resets** the freeze state and alias chain (semantics after the A2 defect fix: re-admit = fresh identity, clears successor/frozenSince/frozenAtPostEnd/fpv/prevFpv) — the handler mirrors the cleanup (see §4.3.5)
5. **freeze set uses the address itself**: the implementation's frozen-flag `continue` excludes the orchestrator **itself** (produces no wallet) — the handler pushes the orch address into the freeze set, not `resolve(orch)` (in a replace scenario resolve may point to an unfrozen successor, causing false positives)
6. **usd same-source read**: the fuzzer's `vm.roll` can rewind time, constructing a pseudo-timeline where "correctVolume/postVolume write after submitShares" — here the implementation's `usd` keeps the bound value and is not recomputed (no on-chain finalize exists since FIPs#1275). The handler does not track usd manually; it reads `sra.fpvOf(q, orch).usd` directly, exactly matching submitShares' traversal

*(S13: items 2-4 are re-expressed in the id-keyed model — replace no longer copies a struct; the id's wallet re-points and the freeze/fpv state follows the id (handler mirrors by generation + freeze-history migration, see §4.3.5); admit allocates a fresh id (no cleanup to mirror — `_idGen[orch]` bumps, expected frozen state cleared); item 5's "freeze set uses the address itself" is unchanged.)*

#### 4.3.5 A2 Real Defect Regression Registry (94 → 96 tests)

> t11 A2 real-defect fix (the A2 invariant failed randomly during t7/t8 toolchain verification acceptance; the coder reproduced it deterministically). Defect root cause and decision: see §3.4 (T10 entry).

**Defect chain**: `replace(old→new)` sets `old.successor = new` (old becomes an alias) → re-`admit(old)` before the fix leaves **successor residual** → `submitShares` freeze check `_frozenAtPostEnd(old)` (against old itself, not frozen, passes) but the wallet writes `_resolve(old) = new` (frozen at POST) → **a frozen orchestrator obtains a share through the resolve chain**, violating S5 freeze snapshot (frozen-at-E+POST shares are 0) and S7 (orch address is the wallet). Second residual face: `replace` only touches admitted/successor; `old.frozen`/freeze history remain — a previously frozen old address re-admits with frozen state carried in.

**Fix (option A: admit identity reset, symmetric with remove cleanup)**: `admit` appends `successor = address(0)`, `frozen = false`, `delete freezeEpochs`, `delete unfreezeEpochs` after setting admitted=true.
For fresh addresses admit is unaffected (fields are already empty); rejected options B (make the submitShares freeze check decide after `_resolve(orch)` — violates S5's requirement to check the reporting orchestrator itself; old's legitimate FPV would be dragged down by frozen new, and other functions would be inconsistent) and C (forbid re-admit after replace — too restrictive, conflicts with S7 "keep admit simple").

| # | Regression test | Assertion | Pre-fix (Red) failure message |
|---|-----------------|-----------|-------------------------------|
| **R1** | `SRAShares` `test_ReAdmit_AfterReplace_FrozenSuccessor_NoShares` | `replace(old→new)` + `freeze(new)` + re-`admit(old)` + `correctVolume(old)` → after `submitShares` the share map does not contain new (frozen), old gets all 1e18, Σ==1e18 | `frozen successor must not receive shares: 1000000000000000000 != 0` (new got the entire share through the resolve chain) |
| **R2** | `SRARegistry` `test_ReAdmit_ResetsFrozenState` | `admit(old)` + `freeze(old)` + `replace(old→new)` (new inherits the freeze) + re-`admit(old)` → `isFrozen(old) == false`, old can postVolume normally next quarter | `re-admit must reset frozen state` (old.frozen residual) |

**Handler sync**: after the implementation's admit identity reset, the SRAInvariant handler's atomic `admit()` and `completeParked()` success branches both clear `_frozen[orch]`, `_successor[orch]`, `delete _freezeAt[orch]`, `delete _unfreezeAt[orch]` — otherwise I3c (isFrozen consistency) and A2 (freeze-interval tracking) keep false-positiving. *(S13: the handler models identity by **generation** — `_idGen[addr]` incremented on every admit (fresh id), `PairRecord.gen` records the binder's generation at binding time; `_claimable` treats a pair as unclaimed iff the binder is no longer admitted **or** its identity was superseded by a re-admit (`_idGen[boundOrch] != gen`). replace re-points the id's wallet and moves only the **current generation's** pairs — matching the implementation's "bindings store the id; bindingOf reads `orchestrators[id].wallet`" exactly, including the removed-id-keeps-wallet edge (an old generation's pairs keep resolving to the archived id's wallet).)*

#### 4.3.6 Integration Contract Test Registry (96 → 100 tests)

> Spec-conformance deviation A disposition (found by the spec-conformance matrix; **historical**):
> FIP-0118 stated in three places that "reading AggregatedFPV(Q) triggers FinalizeConversion(Q) (if not yet run)" (§3.2/§4.1/§4.2),
> and the implementation was aligned to read auto-triggering idempotent finalize (T11/A).
> **FIPs#1275 revision**: deviation-A is now obsolete — the FIL→USD conversion moved off-chain, `FinalizeConversion` is deleted,
> and `aggregatedFPV` is a pure view again. The scenarios below lock the current behavior (C1/C2: no divergence between the view
> and submitShares' total; C3: pure-view semantics).

| # | Scenario | Assertion | Verification point |
|---|----------|-----------|--------------------|
| **C1** | `test_Contract_AggregatedMatchesSubmitTotal` | `aggregatedFPV(0) == 900e18` (Σ bound USD values); `submitShares`'s `SharesSubmitted.totalUsd` captured via `vm.expectEmit` == 900e18 | core no-divergence: the gating consumer reads aggregatedFPV → submitShares' total strictly equals it (negative verification: the test fails when totalUsd is changed to 901e18) |
| **C2** | `test_Contract_SubmitShares_ThenReadConsistent` | direct `submitShares` → `aggregatedFPV(0) == 900e18`; shares a:b = 2:1 (666...667/333...333), Σ==1e18 | after submitShares, subsequent reads of aggregatedFPV are consistent with the final value |
| **C3** | `test_Contract_AggregatedFPV_PureView` | after binding, `aggregatedFPV(0)` returns the complete bound value with no state change | aggregatedFPV is a pure view (FIPs#1275: no on-chain finalize to trigger) |
| **C4** | *(removed with FIPs#1275 — the "view without finalize" concern is obsolete: `aggregatedFPV` is a pure view with no FIL component to trigger; C3 locks the pure-view semantics)* | — | — |

**Value setup** (FIP-0118 FIPs#1275: single USD totals): orchestrator a = 600e18 USD total; orchestrator b = 300e18 USD total; total = 900e18. `aggregatedFPV(0)` returns the full 900e18 (pure view — no finalize exists to gate the FIL component).

#### 4.3.7 Differential Test Registry (100 → 103 tests)

> Breaking same-source bias (high-level correctness review blind spot 3): the current test mock and the SRA implementation share the same FVMRewards encoding library; if the encoding library / mathematical-semantics understanding is wrong, both fail together (the A2 defect proved this risk real). Differential tests use a **fully independent Python reference model**
> (derived independently from FIP-0118's mathematical semantics, not reading the Solidity implementation)
> to cross-validate the three computation cores; expected values are entirely computed by Python (seed=42 reproducible); on-chain outputs are compared entry by entry against the actual implementation calls.

| # | Test | Cases | Cross-validation point |
|---|------|-------|------------------------|
| **D1** | `test_Diff_Share_MaxRemainder_AllCases` | 120 | largest-remainder share allocation: n∈{1,2,3,4,5,7,8}, divisible/indivisible/3-way-remainder/extreme ratios (1:1e6)/with-0 entries; ties broken by input order; Σ==1e18 conservation |
| **D2** | `test_Diff_Aggregate_SingleOrch` / `_MultiOrch` / `_FrozenExcluded` | 3 | FPV aggregation collapsed to a plain USD sum (FIPs#1275: single USD total): single-orch sum / multi-orch sum / frozen-at-POST exclusion — the 30-case `aggCases` data was removed (generator not yet synced) |
| **D3** | `test_Diff_Band_AllCases` | 25 | *(removed with the PRICE_BAND machinery, FIPs#1275 — no on-chain band determination remains; the 25 cases were deleted from DifferentialCases.sol)* |

**Result: 150/150 all matched, no deviation found** — the implementation faithfully matches the spec's mathematical semantics (largest-remainder incl. tie-breaking, FPV aggregation integer rounding), substantially excluding the same-source bias risk on the two remaining computation cores (the PRICE_BAND cross-multiplication core was removed with the band machinery, FIPs#1275).

**Case generation**: an independent Python reference model (seed=42) → `test/differential/DifferentialCases.sol`
(AUTO-GENERATED, committed for CI reproducibility; harness in `test/differential/DifferentialSharesHarness.sol`).

#### 4.3.8 State-Machine Symbolic Verification Registry (blind spot 4 closed, halmos in its own CI workflow)

> Formal verification for the quarter-window determination (previously `_computeShares` had a Halmos symbolic proof but the windows did not).
> Run: `halmos --contract QuarterWindowCheck --loop 64 --no-test-constructor --solver-timeout-branching 2000 --solver-timeout-assertion 60000`

| # | check | Formal proposition (parameter-independent) | Result |
|---|-------|--------------------------------------------|--------|
| **T2a** | `check_T2a_QuarterEndNotInPosting` | now = E_q → ¬posting (posting is left-open; E_q belongs to the previous quarter's binding tail) | ✅ PASS |
| **T3** | `check_T3_QuarterProgression` | qEnd(q+1) − qEnd(q) == qEnd(1) − qEnd(0) (equal quarter spacing, no cross-quarter gaps) | ✅ PASS |
| **T4** | ~~`check_T4_SnapshotTimeInvariant`~~ | `_frozenAtPostEnd` is independent of the calling block.number (S5 anti-timing-game) | **removed with the mirror refactor** — the function no longer exists (E+POST exclusion is a stored flag; the snapshot semantics is covered by the `FrozenAtPostEnd_UnfrozenInWindow_StillExcluded` / `UnfrozenAtPostEnd_FrozenInWindow_StillIncluded` dynamic tests) |
| **T5b** | ~~`check_T5b_IsFrozenAtEmpty`~~ | no freeze history → never frozen at any epoch (empty-array boundary) | **removed with the mirror refactor** — `_isFrozenAt` no longer exists (frozen state is the single `frozenSince` field) |

**2/2 PASS** (T2a/T3 window-boundary + quarter-progression; the former T4 freeze-snapshot and T5b empty-history propositions were removed with the mirror refactor — `_frozenAtPostEnd`/`_isFrozenAt` no longer exist, the E+POST exclusion is a stored flag; the snapshot semantics is covered by dynamic tests). The original proposition set T1 (full coverage + mutual exclusion) / T5 (interval search vs mathematical definition) / T6 (pairwise mutual exclusion) was **downgraded due to halmos 0.1.13 tool limits** (probe experiments confirmed): ① immutables become symbolic after skipping the constructor (window constants have no concrete values) → absolute boundary membership cannot be verified; ② `vm.warp` does not work on symbolic parameters (block.number cannot be symbolized) → universal verification of completeness relying on `currentEpoch()` is infeasible; ③ storage array element reads after push are wrong (length correct but elements symbolic) → freeze-interval search cannot be verified with storage-preset data. The downgraded propositions are covered by dynamic tests: window boundary ±1 on both sides 8 cases (SRAQuarter.t.sol), freeze/unfreeze in both directions + invariant A2 random freeze-history exclusion, 100% line coverage with no unexecuted paths — blind spot 4 is substantially closed within the tool's capability.

> **Evidence conditions (S3 annotation)** — the symbolic domain here is the **weak form** "arbitrary window config (immutables symbolized) + q small-domain enumeration + block.number = 0" (tool limits ①/②); it is **not** a universal-domain proof. The strong boundary semantics (now = E / E+1 / E+P / E+P+1 / E+P+V / E+P+V+1) are covered by the dynamic ±1 test set. The `_computeShares` largest-remainder Halmos checks were **removed** (FixedU18 assembly ops not symbolizable — see §5.10); the algorithm properties are covered by the differential suite (bit-exact fixed cases) and invariant fuzz (SumShares conservation). The enforced absolute domain (MAX_FPV_USD = 1e30) is covered independently by the §5.5 domain-math bounds (per-orch usd × 1e18 ≤ 1e48 / total ≤ 6.4e31 ≪ 2^256), whose premise is now enforced in code (the single `MAX_FPV_USD` bound at both input entries).

#### 4.3.9 Spec-Conformance Alignment Registry (deviation A/B/D unified implementation, 103 → 109 tests)

> After the user reviewed the 5 deviations one by one (principle: spec alignment first), the unified implementation landed: **A/B/D source+test alignment, C/E documentation clarification**. *(All A/B/D mechanisms below were later removed by FIPs#1275 — kept as historical record.)*

- **A — aggregatedFPV read auto-triggers finalize**: changed to non-view, idempotent `_finalizeConversion(q)` on read (C3 rewrite). *(FIPs#1275: obsolete — `aggregatedFPV` is a pure view again, `test_Contract_AggregatedFPV_PureView`)*
- **B — MIN_LOT filtering**: sub-MIN_LOT prints do not participate in pricing (band check skipped, never the reference, not counted in finalize); base-class MIN_LOT corrected 1e18 (mislabeled attoFIL) → 100 USD. *(FIPs#1275: obsolete — band machinery removed)*
- **D — PRICE_BAND anchored reference**: reference = the previous quarter's binding final state (updated at finalize), preventing single-batch chained-drift (×1.199³²≈218×); 3 new anchor tests + differential model anchor semantics (175 cases match). *(FIPs#1275: obsolete — see §3.4 T11)*
- **C/E clarification (documentation)**: C — on-chain rejection of over-limit periods enforces the spec's "at most MAX_PRICE_PERIODS entries" format (merging is the indexer's job), not a deviation; E — Replace's identity transfer is a necessary completion, no literal spec conflict, status quo kept. See §2.5.4 / §3.4 (T11).

#### 4.3.10 Post-Review Audit Hardening Registry (V1/V2/V3 + B1/C1/E1/E2/F2, 109 → 123 tests)

> A second review of PR #24 (post-squash) probed three overflow-DoS findings (**V1 anchor pollution / V2 finalizeConversion overflow / V3 _computeShares overflow**) — all confirmed real: `postVolume`/`correctVolume` had **no business-domain upper bounds**, so the §5.5 "Integer overflow ✅ Safe" conclusion rested on an **unenforced "business domain ~1e6" assumption** (a QA-system gap: no adversarial-input layer, hypothesis-driven claims, broken evidence conditions, single threat model). The user arranged the V1/V2/V3 fix; the backlog (B1/C1/E1/E2/F2) completed in this pass.

**V1/V2/V3 — input-domain bounds enforced** (fix commits `29293da` test + `ddbace4` fix):
- **V3 (current)**: the single `MAX_FPV_USD` bound at both input entries (postVolume + correctVolume) closes the `_computeShares` chain (per-orch `usd_f × 1e18 ≤ 1e48` / total ≤ 6.4e31 ≪ 2^256 — the intermediate holds identically under the FixedU18 representation since the unwrap value domain is unchanged). **Note**: `MAX_FPV_USD = FixedU18.wrap(1e30)` is 18-decimal → **1e12 USD** per quarter per orchestrator (the pre-FixedU18 1e30 was integer USD); the business domain ~1e6 USD still has ~6 orders of magnitude headroom, and the chain closes with ~29 orders to spare (1e48 → 2^256 ≈ 1.16e77). *(V1 anchor pollution / V2 finalize overflow were removed with the band/finalize machinery, FIPs#1275.)*
- Tests: `test/SRAOverflowDoS.t.sol` (6): V1 anchor-pollution permanent-DoS / V2 finalize-overflow DoS / V3 computeShares-overflow DoS (each Panic(0x11) precise + post-fix "system stays usable" control), plus claimFil==0 / correctVolume-entry / anchor-refusal cases

**B1/C1/E1/E2/F2 — remaining bounds + owner rotation (this pass, 8 tests)**:
- **B1** `setPricingParams`: adds `minLot <= MAX_LOT_USD` — prevents minLot=max silently skipping every print — `SRAQuarter:test_SetPricingParams_MinLotTooLarge_Reverts`
- **C1** `registerPairs`: `pairs.length <= MAX_PAIRS(64)` + `error TooManyPairs()` (keeps the §5.5 DoS "hard caps" premise) — `SRARegistry:test_RegisterPairs_TooManyPairs_Reverts` + `..._MaxPairs_Accepted`
- **E1** `replaceOwner(address prevOwner, address newOwner)` (new governance write, `unanimousNoHold`): owner rotation, newOwner must be a Safe proxy; **byte-identical to upstream SWA's replaceOwner** — closes the "no owner-rotation path" gap (n-of-n key-loss residual risk is a shared-model choice, §5.6) — `SRAGovernance:test_ReplaceOwner_SecondApproval_ExecutesImmediately` + `..._NonSafeNewOwner_Reverts` + `..._NonOwner_Reverts`
- **E2** constructor: same parameter validation as setPricingParams + `epochsPerQuarter/postPeriod/verificationWindow > 0` — deployment misconfiguration fails fast — `SRAGovernance:test_Constructor_InvalidParams_Reverts` (4 illegal configs)
- **F2** `setAdmittedLists`: `stablecoins.length <= MAX_ALLOWLIST(64) && filecoinPayContracts.length <= MAX_ALLOWLIST` — `SRAGovernance:test_SetAdmittedLists_TooManyEntries_Reverts`

Final: SRA deterministic **118/118 Green** (SRAQuarter 44 + SRARegistry 28 + SRAShares 17 + SRAIntegration 4 + SRAGovernance 16 + SRAOverflowDoS 6 + differential 3), invariant 5/5, full suite **267/267** no regression, `forge fmt --check` / `forge lint` clean.

#### 4.3.11 QA-System Fix Registry (S1-S5, 123 → 151 tests)

> The V1/V2/V3 finding was a **symptom of a QA-system gap**, not an isolated bug: every verification layer (deterministic/fuzz/invariant/differential) exercised inputs inside the "business domain" and none probed malicious extreme inputs; the security review was hypothesis-driven ("business domain ~1e6 → safe") rather than code-driven; evidence application conditions were broken (a bounded-domain Halmos proof was cited as whole-domain evidence; the fuzz `vm.assume(<1e30)` was a test-side shrink to dodge overflow); the threat model covered only honest-but-faulty callers; the reviewer default-trusted document "Safe" marks. The structural fixes S1-S5 close these gaps.

**S1 — adversarial input test layer** (`test/SRAAdversarial.t.sol`, 28 tests, this pass):
- q-parameter window boundaries: postVolume/correctVolume/submitShares/aggregatedFPV × (future quarter / uint64.max) → exact `NotInPostingWindow` / `NotInVerificationWindow` / `NotBound` selectors (finalizeConversion removed by FIPs#1275)
- FPV value exact limits: the single USD total at `MAX_FPV_USD` accepts, MAX+1 rejects `InvalidParameter` (2 tests; the four-field stableUSD/lotUsd/claimFil/attoFil limits were collapsed to the single USD bound by FIPs#1275)
- zero-address probes: admit(0) accepted (governance semantics locked), freeze(0) NotAdmitted, registerPairs zero payer accepted, replaceOwner(0) NotSafeProxy, reassignBinding(0) NotAdmitted (5 tests)
- setPricingParams full parameter grid: priceBand ∈ {0, 10000} accepted (10001 rejected already covered), minLot ∈ {0, 1e30} accepted (1e30+1 rejected already covered, B1) (maxPricePeriods removed by FIPs#1275)
- empty-array semantics: registerPairs empty no-op, setAdmittedLists empty clears both allowlists (2 tests)
- multi-orchestrator aggregate bound: 2 × MAX_FPV_USD posts → shares still Σ == 1e18 (1 test)
- every revert uses an **exact error selector** (no bare `expectRevert` — zero added, satisfying the §4.3.10 N3 requirement)

**S2 — security-claim → code-enforcement map** (§5.1 table): every "Safe"/"Conditionally safe" conclusion now cites the enforcing code point (require / mechanism); a claim without an enforcement reference fails review. Maps all 8 categories (e.g. Integer overflow → the single `MAX_FPV_USD` bound @ postVolume + correctVolume; DoS caps → `MAX_PAIRS(64)` / `MAX_ALLOWLIST(64)` / `MAX_ORCHESTRATORS(64)`).

**S3 — evidence-application-condition annotation**: the fuzz sampling domain `(0,1e30)` is re-annotated as **equal to the code-enforced MAX_FPV_USD** (not a test-side shrink — `SRAShares::test_SubmitShares_Fuzz_SumAlwaysExact` + `SRAInvariant::invariant_NonZeroTotal_ValidShareMap`); the largest-remainder algorithm properties are covered by the differential suite (bit-exact fixed cases) + invariant fuzz, with the enforced absolute domain's arithmetic safety independently covered by the §5.5 domain-math bounds (docs §4.3.8 S3 note).

**S4 — threat model matrix** (§5.13): all 15 external write functions × (malicious orchestrator / compromised owner) → impact → mitigation → sufficiency; every function is closed either by unanimous dual-Safe governance or by code-enforced input bounds + timing gates.

**S5 — reviewer checklist** (§5.14): 6 items forcing the reviewer to challenge premises — security-claim→code map verified against source / evidence conditions satisfied by code / adversarial internal party in scope / adversarial input coverage complete / test-claim correspondence (no bare `expectRevert`) / Red-first regression after any new finding.

Final: SRA deterministic **146/146 Green** (SRAQuarter 44 + SRARegistry 28 + SRAShares 17 + SRAIntegration 4 + SRAGovernance 16 + SRAOverflowDoS 6 + SRAAdversarial 28 + differential 3), invariant 5/5, full suite **295/295** (151 SRA + 144 existing) no regression, `forge fmt --check` / `forge lint` clean.

### 4.4 Key Test Design Decisions

#### 4.4.1 Test Constants (constructor config)

| Constant | Test value | Design rationale |
|----------|------------|------------------|
| `EPOCHS_PER_QUARTER` | 1000 | easy manual window-boundary arithmetic |
| `POST_PERIOD` | 300 | **> 2×SRA_CANCEL_HOLD**: guarantees two consecutive freezes (each 2 votes + 100 hold) within the posting period complete before E+POST (the timing prerequisite for all-frozen → burn) |
| `VERIFICATION_WINDOW` | 400 | — |
| `SRA_CANCEL_HOLD` | 100 | — |
| `ACTIVATION_EPOCH` | 100_000 | far past the block after "registering stream 2 requires advancing SWA_TIMELOCK(20160)", quarter-0 window is clean |
| `MIN_LOT` | 100 | 100 USD (lot face value; design §2.6 proposes "a few hundred USD"; a small test value keeps all existing prints qualifying) |
| `PRICE_BAND` | 2000 | **basis points** (2000 = allows ±20% deviation), test assumption H-band |

#### 4.4.2 Timeline Model

- `Epoch = block.number` (controlled by `vm.roll`, 📘 Epoch.sol)
- Quarter windows (§2.5.1): posting `(E, E+POST]` → verification `(E+POST, E+POST+VERIFY]` → post-binding
- Governance hold: two votes → `vm.roll(+SRA_CANCEL_HOLD)` → third call (permissionless) completes execution
- correctVolume (unanimousNoHold): the second vote executes immediately, no roll needed

#### 4.4.3 Mock Integration

- service stream 2 is registered by the test base as a "temporary swa" (`mockSwa(address(this))` → `FVMRewards.tryRegisterStream(2, EXPLICIT, writer=address(sra), activation)` → roll past SWA_TIMELOCK → `mockAwardBlockReward(0)` triggers `_settle`), matching f02-design's "migration pins service = 2"
- Share assertions read the mock's `getShares(2)`: the mock validates Σ==1e18, ≤64 recipients, writer permission (📘 FVMRewardActor._setShares); the main-branch mock additionally validates each share non-zero and wallets non-duplicate (`_sharesValid`) — which surfaced the zero-share filtering fix in §2.5.3

### 4.5 How to Run

```bash
# project foundry.toml usable directly (forge 1.7.1; P0 fixed fmt/lint)

# --- deterministic + contract tests (default suite) ---
forge test --match-contract SRA          # SRA tests (deterministic + invariant + differential + contract)
forge test                               # full suite (SRA + existing f02/governance tests)

# --- invariant only (handler-based randomized sequences, ~3 minutes) ---
forge test --match-contract SRAInvariant

# --- differential tests (Python independent reference model, 175 cases, seed=42) ---
forge test --match-contract DifferentialShares

# --- symbolic verification (halmos) ---
# 已进 CI：独立 workflow (.github/workflows/halmos.yml)，不阻塞主 test CI；
# 本地手动运行路径（存储布局 / 数值计算 / 窗口边界逻辑改动时，或每次发布前）：
# 前置: forge 1.7+ 默认不为 test 合约输出 AST, 而 halmos 从 out/ 读取 ast 字段 —— 先 `forge build --ast`
# (若跳过此步, halmos 报 "KeyError: 'ast'"; 自 halmos 0.1.13 起 extra_output=["ast"] 已被 forge 移除, 改为 --ast flag)
forge build --ast
# 两个 harness 的父构造器含 Safe 检查(isProbablyASafe), halmos 符号执行 constructor 会路径超限
# ("ValueError: constructor: # of paths")——必须 --no-test-constructor; --loop 64 展开余数补位循环;
# 默认 SMT branching timeout=1ms 太短, 需加大
halmos --contract QuarterWindowCheck --loop 64 --no-test-constructor --solver-timeout-branching 2000 --solver-timeout-assertion 60000   # quarter-window state machine 4/4
# ("Skipped console2.json ... KeyError: 'metadata'" 是无害 warning, forge-std 库文件, 可忽略)

# --- static analysis (slither 0.11.x) ---
slither . --exclude-dependencies         # 0 high / 0 medium (2 style-class findings, see §5.10)

# --- quality gates (CI) ---
forge fmt --check
forge lint --deny notes --quiet
forge coverage --match-contract SRA      # SRA line coverage 100% (branch 67% is the lcov tool ceiling, see §5.11)
```

## 5. Security Review

> Scope: Issue #4 Service Rewards Actor (FIP-0118) `src/ServiceRewardsActor.sol` (721 lines) and its dependency libraries
> (`src/lib/`: governance, f02 interaction, time, ownership).
> Purpose: a **systematic security review checklist** for maintainers and future security reviewers — walk through the contract by vulnerability class,
> recording each class's review conclusion (why it is safe / what residual risk exists / what premises it depends on), for reuse in PR review and future audits.
> decisions: §3 (full D/S/C/T/G); design: §2; tests: §4.

### 5.1 Review Conclusion Summary

> **S2 security-claim → code-enforcement map**: each "Safe" conclusion below must cite the enforcing code point (require / mechanism); a claim without an enforcement reference fails review.

| # | Category | Conclusion | Key basis | Code-enforcement point |
|---|----------|------------|-----------|------------------------|
| 1 | Reentrancy | ✅ Safe | no value transfer; the only external call is an fvm precompile with no callback surface | no value transfer (no `payable`/`call`/`transfer` anywhere in `src/ServiceRewardsActor.sol`); the only external call is `FVMRewards.setShares` (fvm precompile, no callback), `submitShares` |
| 2 | Denial of Service (DoS) | ✅ Safe (S13) | all traversals have hard caps (64); replace is an O(1) wallet re-point — no alias chain | `registerPairs` `pairs.length <= MAX_PAIRS(64)`; `setAdmittedLists` `length <= MAX_ALLOWLIST(64)`; `admit` `admittedIds.length < MAX_ORCHESTRATORS(64)`; `postVolume`/`correctVolume` take a single USD value — no period array to traverse (FIPs#1275). Freeze determination is O(1) (stored flag, mirror refactor); the former alias-chain growth point is structurally eliminated (S13) |
| 3 | Access control | ✅ Safe | governance dual-Safe unanimous + hold; orchestrator self-operations gated; constructor validates Safe proxy | `unanimous`/`unanimousNoHold` modifiers gate every governance method (`admit` / `remove` / `freeze` / `unfreeze` / `replace` / `reassignBinding` / `replaceOwner` / `setAdmittedLists` / `setPricingParams` / `correctVolume`); `_veto` requires `msg.sender.isOwner()` (`cancelPending`); constructor `newOwner.isProbablyASafe()` (E2) |
| 4 | Integer overflow | ✅ Safe | 0.8.x checked arithmetic fully on; **input-domain bound enforced at the entries** (single `MAX_FPV_USD=1e30`, audit V3 fix); the enforced absolute domain's arithmetic safety is covered by the §5.5 domain-math bounds (S3: proof premise = code-enforced domain) | the single `MAX_FPV_USD` bound at **both** input entries — `postVolume` and `correctVolume`; `_computeShares` chain: per-orch usd × 1e18 ≤ 1e48, total ≤ 6.4e31 ≪ 2^256 (§5.5); checked arithmetic (0.8.36 default) |
| 5 | Encoding and boundaries (ABI/CBOR) | ⚠️ Conditionally safe | input side protected by the ABI decoder; output side bounded CBOR; wire contract pending f02 implementation check | input side: Solidity ABI decoder (compile-time, rejects malformed calldata); output side: bounded CBOR in f02 mock (`test/mocks/FVMRewardActor.sol`); wire contract vs real f02 implementation is a protocol-layer premise (no contract-layer code can enforce it) |
| 6 | Precision issues | ✅ Safe | floor + largest-remainder Σ==1e18; conservation/monotonicity/floor bound covered by the differential suite (bit-exact) + invariant fuzz (SumShares) — the Halmos symbolic checks were removed with the FixedU18 adoption (§5.10) | `_computeShares` largest-remainder method `:683` (Σ shares == SHARE_TOTAL exactly, remainder descending + residue top-ups); shares depend only on USD ratios — no rate arithmetic on chain (FIPs#1275) |
| 7 | Governance path | ✅ Safe | three-phase + dual Safe + event traceability; re-admit semantics structurally closed (S13) | three-phase `unanimous` modifier (approve/approve/hold → permissionless execution, `UnanimousGovernance.sol`); re-admit allocates a fresh id (no residual alias-chain/freeze state by construction — S13 supersedes the T10 A2 cleanup) |
| 8 | Front-running | ✅ Safe | E+POST snapshot semantics independent of keeper timing; permissionless triggers have no privilege and no MEV | `frozenAtPostEnd` is a stored flag fixed from the verification window onward (set/cleared only before E+POST), independent of when the caller invokes submitShares/aggregatedFPV; permissionless `submitShares` / view `aggregatedFPV` have no privileged action |

**Overall conclusion**: the SRA is a **value-transfer-free** pure state machine (writes f02 shares); the attack surface concentrates on **governance authority** and **data correctness**.
The governance surface is strongly constrained by dual-Safe unanimous + hold; data correctness is assured by 100% line-coverage tests + 5 invariants + differential cross-validation + quarter-window symbolic verification + Slither static analysis
as a four-layer assurance, and 1 real defect has been caught and fixed (T10 A2: re-admit identity residue letting a frozen orchestrator obtain a share through the resolve chain).
All residual risks are **theoretical boundaries** or **protocol-layer premises** (the f02 wire contract not upstream-confirmed, dual-Safe private-key security); no known exploitable contract-layer vulnerability.

### 5.2 Reentrancy

**Conclusion: ✅ Safe (no reentrancy surface)**

**Basis**:

- **No value transfer**: the SRA declares no `receive`/`fallback`, never receives or holds ETH/FIL (design §1 "SRA never receives or holds value"), no `transfer`/`call` to arbitrary addresses.
- **The only external call is an fvm precompile**: `submitShares` ends by calling `FVMRewards.setShares` (`src/lib/FVMRewards.sol:trySetShares`), whose base is `delegatecall(gas(), CALL_ACTOR_BY_ID, ...)` — `CALL_ACTOR_BY_ID` is a **precompile address constant** of the Filecoin VM (`fvm-solidity/FVMPrecompiles.sol`), not an arbitrary contract address; **no attacker-controllable callback surface exists**. f02's SetShares is a pure state write and does not call back into the SRA.
- **CEI ordering**: the external call sits at the end of `submitShares` (collect shares, compute, then write to f02), and a failed f02 share write reverts the whole transaction (`SetSharesFailed`, covered by A1 injection tests) — atomic state rollback, no "mutate-then-external-call" window.
- **Toolchain confirmation**: the Slither scan across 102 detectors **did not trigger** reentrancy detectors (012 report §B1); invariant handler random operations show 0 reverts (tests doc §4.3.2).

**Residual risk**: none substantive. The only theoretical point is f02 precompile determinism (an f02 implementation defect would surface as an exit code, with revert semantics wrapped as `SetSharesFailed`, not affecting SRA state).

### 5.3 Denial of Service (DoS)

**Conclusion: ✅ Safe (all computation bounded; no theoretical growth points — the replace chain was eliminated by S13)**

**Basis**:

- **Traversals have hard caps**:
  - `admittedList` ≤ 64 (`MAX_ORCHESTRATORS`, D2; `admit` rejects when full, only `remove` releases) → `submitShares`/`aggregatedFPV` traversals O(64) bounded; `_computeShares` remainder top-up O(n²) = 4096 iterations bounded (§2.5.3).
  - freeze determination is O(1) — the mirror refactor replaced the freeze-interval search with the stored `frozenAtPostEnd` flag + `frozenSince` single field (no arrays). (The `filPeriods.length ≤ MAX_PRICE_PERIODS` bound was removed with the pricing-period vector, FIPs#1275 — no period loops remain.)
- **No externally expandable input**: `admittedIds` can only be modified by governance `admit`/`replace`; pair-binding uniqueness is guaranteed by `registerPairs` (checked via the bound id's `admitted` flag — T6 fix, re-expressed in the id-keyed model S13).
- **Covered by tests**: 64-full rejection / 64-all-posted map boundary (G2), share-Σ fuzz (G7), `orchestratorCount` view (CV7).

**Residual risk (theoretical growth points, not exploitable vulnerabilities)**:

1. ~~**Freeze-history arrays have no hard cap**~~ **resolved by the mirror refactor**: `freezeEpochs`/`unfreezeEpochs` were removed — the E+POST exclusion is the stored `frozenAtPostEnd` flag, current freeze state is the single `frozenSince` field; there is no freeze-history growth point. *(S13: the replace chain — the former second theoretical growth point — is also eliminated; see 2.)*
2. **Replace-chain length has no hard cap**: `_resolve` resolves along the successor chain with a while loop. Chain formation requires one governance `replace` per step (old becomes an alias, admitted=false; chain-intermediate nodes cannot be removed or replaced), so chain length is naturally constrained by governance frequency; but there is no explicit cap, and under extreme governance abuse the resolve cost in `submitShares` grows linearly. **Recommended: future reviewers evaluate adding a chain-length cap** (currently constrained by governance cadence, not urgent). *(S13: obsolete — the alias chain is removed; `replace` is an O(1) wallet re-point with no chain, so this DoS class is structurally eliminated.)*

### 5.4 Access Control

**Conclusion: ✅ Safe (layered permission model)**

**Basis**:

- **Governance write operations** (`admit`/`remove`/`freeze`/`unfreeze`/`replace`/`reassignBinding`/`setAdmittedLists`/`setPricingParams`) all go through `unanimous(keccak256(msg.data), SRA_CANCEL_HOLD)` (`src/lib/UnanimousGovernance.sol`):
  - dual-Safe bitmask check (`Owners.sol:isOwner`/`asOwnerSet`; non-owner `NotOwner` reverts; the same owner approving twice `AlreadyApproved` reverts);
  - both votes in place + permissionless execution after the hold elapses (`HoldUntil` time lock);
  - taskId = `keccak256(msg.data)` — both Safes must submit byte-identical calldata (I2 array normalization convention, covered by `TaskId_DifferentArrayOrder_DoesNotMerge`).
- **correctVolume** goes through `unanimousNoHold`: dual-Safe full-vote immediate execution (design D3: the verification window itself is the hold), with in-body window validation.
- **cancelPending** goes through `_veto`: either Safe alone cancels a pending task (can stop a malicious governance proposal during the hold).
- **Orchestrator self-operations** (`registerPairs`/`postVolume`): `require(_isAdmitted(msg.sender))` + `require(!_isFrozen(msg.sender))`.
- **Mechanism operations** (`submitShares`): permissionless — reads only bound aggregated state and writes f02 shares; no permission-sensitive surface (any keeper trigger yields the same result).
- **Constructor validation**: the constructor runs `isProbablyASafe` on both owners (`IsASafe.sol`: code-size range + masterCopy code-size check), preventing non-Safe addresses from being bound at deployment.
- **Toolchain confirmation**: Slither did not trigger permission-class detectors (no tx.origin, no unprotected writes); the governance flow's 11 tests (SRAGovernance) cover three-phase/hold/veto/taskId fully.

**Residual risk/premises**:

- The permission model depends on **the security of the two Safe private keys** (off-chain key management is a protocol trust premise, not contract-mitigable).
- `setAdmittedLists` array parameters require both Safes to agree on a **normalization order** (sorting, consistent encoding), otherwise taskId mismatch causes governance deadlock (I2 — an availability risk, not a security vulnerability; control cases covered by tests).
- Governance operation execution is permissionless (anyone can trigger completion after the hold elapses) — this is by design (keeper triggering), not unauthorized access.

### 5.5 Integer Overflow

**Conclusion: ✅ Safe — conditional on the input-domain upper bound enforced at the entry (audit V3 fix, revised by FIPs#1275)**:
`MAX_FPV_USD = 1e30` (single USD total per orchestrator per quarter), validated in `postVolume`/`correctVolume`, locked by the `SRAOverflowDoS.t.sol` regression tests.
The V1 (PRICE_BAND anchor pollution) and V2 (finalizeConversion overflow) analyses are **obsolete** — the FIL→USD conversion and the band machinery were removed by FIPs#1275 (off-chain conversion), leaving `_computeShares` as the only place USD values multiply.

**Basis**:

- **Checked arithmetic**: Solidity 0.8.36 reverts on overflow by default; the whole contract has **no `unchecked` blocks**; Slither did not trigger unchecked/integer-overflow detectors.
- **Input-domain bound (audit V3 fix)**: the single USD total is bounded at the entry (`fpv ≤ MAX_FPV_USD`, `InvalidParameter`); the bound chain closes the only on-chain multiply:
  - `_computeShares`: per-orchestrator usd ≤ `1e30` → `usd × SHARE_TOTAL(1e18) ≤ 1e48 ≪ 2^256`; total (≤ 64) ≤ `6.4e31 ≪ 2^256` — ~200 orders of magnitude of headroom.
- **Bound-value rationale**: the assumed business domain is ~1e6 USD/quarter; 1e30 is ~24 orders of magnitude above it — loose-by-design headroom (immutable constant), while the arithmetic chain closes with enormous margin.
- **⚠️ Maintenance warning**: the closure assumes `MAX_FPV_USD` and `MAX_ORCHESTRATORS(64)` hold together; if either changes, re-derive the chain before shipping.

**Other input-domain bounds (audit B1/C1/E2/F2)** — the 1e27 / MAX_CLAIM_FIL / MAX_ATTO_FIL rationale and the `_validateFpvBounds` four-field asymmetry were removed with the pricing-period vector (FIPs#1275); the FPV value bound is now the single `MAX_FPV_USD = 1e30` above:

- **Other input-domain bounds (audit B1/C1/E2/F2)**: beyond the FPV value bound, the remaining length/value inputs are bounded so the "DoS conditionally safe (traversals hard caps)" premise holds everywhere:
  - **C1** `registerPairs` validates `pairs.length <= MAX_PAIRS(64)` (`error TooManyPairs`), aligned with MAX_ORCHESTRATORS;
  - **F2** `setAdmittedLists` validates `stablecoins.length <= MAX_ALLOWLIST(64) && filecoinPayContracts.length <= MAX_ALLOWLIST`;
  - **E2** the constructor validates `priceBand <= BASIS_POINTS` plus `epochsPerQuarter > 0 && postPeriod > 0 && verificationWindow > 0` — deployment misconfiguration fails fast instead of silently misbehaving (the B1 `minLot <= MAX_LOT_USD` check was removed with the band machinery, FIPs#1275 — MIN_LOT is now a governance-trusted parameter for the off-chain indexer).
- **Share computation** (*historical magnitude note* — superseded as the primary argument by the entry-enforced input-domain bound above; kept for its reference): `_computeShares`'s `usds[i] * SHARE_TOTAL` (×1e18) — usd aggregation at business magnitude ~1e6 (USD face value); 1e6 × 1e18 = 1e24 ≪ 2^256 ≈ 1.16e77. The former Halmos `check_NoOverflow_Boundary` (P6) that proved this within a symbolic domain was **removed** with the FixedU18 adoption (assembly ops not symbolizable — see §5.10); the bound is now enforced at the entries by `MAX_FPV_USD`.
- **Window computation**: `_qEnd` uses `uint256(ACTIVATION_EPOCH) + uint256(q) * uint256(Epoch.unwrap(EPOCHS_PER_QUARTER))` as an intermediate guard (S1C, §2.5.1), then casts to Epoch(uint64).
- **Epoch magnitude**: Epoch is uint64 (2^64 ≈ 1.8e19 epochs, ~1.7e13 years) — quarter number Q × EPOCHS_PER_QUARTER at normal business scale is far below this, and the `_qEnd` range guard rejects anything beyond the width.

**Residual risk/premises**:

- `Epoch.sol`'s `add`/`sub` are implemented in assembly (no overflow check) — a design trade-off at the uint64 magnitude, with the `_qEnd` range guard bounding inputs (unreachable in normal use).
- Theoretical boundary: if a malicious huge `q` (uint64 max) is passed and the deployment config's EPOCHS_PER_QUARTER is also huge, the `_qEnd` cast to uint64 could truncate — but the range guard rejects `end > type(uint64).max` first (`InvalidParameter`), so this is closed. Normal quarter numbers (~90 days each) reaching 2^64 quarters takes 5e19 years. **Listed as a theoretical boundary; no action needed**.

### 5.6 Encoding and Boundaries (ABI input / CBOR output)

**Conclusion: ⚠️ Conditionally safe (input side ABI-decoder-protected + output side bounded CBOR; wire contract depends on the f02 implementation check)**

**Basis**:

- **Input side (FPV posting)**: `postVolume`/`correctVolume` take a single `uint256` USD total — no arrays to decode; the value is bounded by `MAX_FPV_USD` (`InvalidParameter`). **No handwritten decoding logic**.
- **Output side (setShares CBOR)**: the only f02 write interaction's params are `FVMRewards.trySetShares`'s handwritten assembly CBOR encoding — addresses are fixed-encoded as f410 22 bytes (`0x56 0x04 0x0a + 20 bytes`); share uint64 uses `writeCborUint64` length-branched encoding (1/2/3/5/9 bytes); the array header `writeCborArrayHeader` covers <24/≤255/≤65535 lengths; **encoding is bounded** (n ≤ 64, share ≤ 1e18 magnitude).
- **Return side**: the SRA does not parse f02 return values (setShares reads only the exit code); CBOR BigInt decoding only exists in `tryClaim` (used by the SWA, not called by the SRA), and `signByte`/`magLen > 32` guards with `revert(0,0)`.
- **Mock verifies the wire contract**: the test base etches a mock f02 + `CALL_ACTOR_BY_ID` routing; the mock validates Σ==1e18, ≤64 recipients, writer permission (`test_SubmitShares_MapSize_EqualsActiveOrchestrators`, `test_SubmitShares_PostedUsd_Proportional`, etc., tests §4.4.3).

**Residual risk/premise (protocol layer, not a contract defect)**:

- `FVMRewards.sol`'s header comment states explicitly: f02 **does not yet exist** (filecoin-project/builtin-actors#1764); the current wire format is this repo's **best-effort encoding of the FIP draft method signature, not upstream-confirmed ABI**. **Before launch, the wire contract must be checked against the final f02 implementation** (method number, CBOR field order, f410 address encoding, BigInt return format) — this is the largest premise risk on the SRA's security surface; it belongs to FIP ecosystem advancement and is not contract-logic-mitigable.

### 5.7 Precision Issues

**Conclusion: ✅ Safe (floor + largest-remainder; conservation/monotonicity/floor bound verified by the differential suite bit-exact cases + invariant fuzz, the symbolic checks having been removed with the FixedU18 adoption — see §5.10)**

**Basis**:

- **Share allocation**: `_computeShares` gives each share `floor(usd_i × 1e18 / total)`, residue topped up +1 by remainder (`usd_i × 1e18 % total`) descending, guaranteeing `Σ shares == 1e18` **holds exactly** (hard f02 encoding constraint):
  - Halmos P1-P3 symbolic exhaustive proof of conservation (n=1/2/3, any usd combination Σ==1e18);
  - Halmos P4 monotonicity (larger usd gets ≥ share), P5 floor bound (each share ∈ {floor, floor+1});
  - forge 3/7/17-way split tests (I1) + G7 random fuzz (256 runs) double verification.
- **FIL→USD conversion**: performed off-chain by the orchestrator's indexer (FIPs#1275); the SRA does no conversion arithmetic — nothing to lose precision on-chain.

**Residual risk**: none substantive. The Halmos value-domain constraint is 1e3 — **this only certifies the share-allocation ratio properties** (shares depend only on usd ratios rather than absolute values); the no-overflow property over absolute magnitudes is now covered by the **entry-enforced input-domain bound** (`MAX_FPV_USD`, audit V3 fix) rather than by the 1e3-domain Halmos proof, which does not weaken the ratio-space coverage (012 report §C1 "value-domain constraint note") — proving over the full uint256 domain would require extended solver timeouts (significant cost, marginal benefit).

### 5.8 Governance Path

**Conclusion: ✅ Safe (three-phase + dual Safe + event traceability; re-admit semantics closed after T10)**

**Basis**:

- **unanimous three-phase**: submit (first vote `Submitted`) → approve (second vote completes `Approved`) → permissionless execution after the hold elapses; second approval does not re-execute; the same owner approving twice `AlreadyApproved` reverts; non-owner `NotOwner` reverts; hold not elapsed `HoldUntil` reverts (fully covered by `SRAGovernance` tests).
- **unanimousNoHold**: the second vote executes immediately (correctVolume; the window is the hold, D3).
- **_veto**: either Safe alone cancels a pending task (`cancelPending`, covered by `Veto_CancelsPendingAdmit`).
- **Task mutual exclusion**: parked governance targets are mutually exclusive (I3; `invariant_GovernanceTasks_Consistent` persistently verifies parked-not-landed / executed-clears-bitmask).
- **T10 defect closure**: `admit` identity reset (clears successor/frozenSince/frozenAtPostEnd/fpv/prevFpv) — the boundary semantics of governance operations (replace→re-admit) are closed, guarded by 2 deterministic regression tests (R1/R2) + the A2 invariant (tests §4.3.5). *(S13: superseded — the alias chain is removed, re-admit allocates a fresh id, so the successor-residual bug class cannot recur; the R1/R2 regression tests still pass, locking the same observable behavior.)*
- **Timelock constant**: `SRA_CANCEL_HOLD` compile-time constant (constructor config; S6 const-ification reduces the governance attack surface).

**Residual risk/premises**:

- Dual-Safe private-key security (off-chain trust premise, same as category 3).
- `cancelPending` can only cancel **queued** tasks; already-executed tasks (e.g. an effective SetShares) cannot be revoked — f02's SetShares **binds immediately** (no quarter-window enforcement; the quarterly cadence is the SRA's own discipline, §2.5.6). If governance is compromised/mistaken, shares take effect immediately; mitigation: dual Safe + hold already substantially reduce this risk, and shares only affect service-stream allocation (can be overwritten by next quarter's correct values), not direct fund loss.

### 5.9 Front-Running

**Conclusion: ✅ Safe (deterministic snapshot semantics + no MEV value)**

**Basis**:

- **E+POST snapshot semantics (S5)**: the E+POST exclusion is the stored `frozenAtPostEnd` flag — set by a freeze in the posting window, cleared by an unfreeze in the posting window, **fixed from the verification window onward** (a freeze/unfreeze after E+POST cannot change the determined quarter); at the mirror advance the flag is snapshotted into `prevFpv` (`prevFpv <- frozenAtPostEnd ? 0 : fpv`), because a past E+POST's freeze state is no longer derivable once the quarter has advanced (§2.5.2). `submitShares` results are deterministic; there is no "submit before the freeze" or "delay until after unfreeze" front-running window; snapshot positive/negative tests (`FrozenAtPostEnd_UnfrozenInWindow_StillExcluded` / `UnfrozenAtPostEnd_FrozenInWindow_StillIncluded`) + the A2 invariant cover it.
- **Permissionless triggers have no privilege**: `submitShares` callable by anyone with identical results (a successful non-zero submit settles the quarter; a re-submit reverts `AlreadySubmitted`, an all-zero quarter is a benign no-op — the map is deterministic and timing-independent) — zero front-running gain, no MEV.
- **Pure-view read (FIPs#1275)**: `aggregatedFPV` is a pure view after binding — it only sums the bound USD values and triggers nothing (no on-chain finalize exists since the FIL→USD conversion moved off-chain); the result is deterministic and independent of call timing, so it cannot be manipulated by front-running.
- **PRICE_BAND anchored reference (obsolete — FIPs#1275)**: the band machinery (anchor storage, `_checkPriceBand`) was deleted with the off-chain conversion; the FIL pricing rule (incl. MIN_LOT/PRICE_BAND) now governs only the off-chain indexer each orchestrator applies before posting, not an on-chain computation.
- **MIN_LOT filtering (obsolete — FIPs#1275)**: sub-MIN_LOT handling is likewise off-chain (indexer-side); MIN_LOT remains SRA state only as the authoritative parameter for the off-chain conversion.

**Residual risk**: none substantive. An attacker can at most execute early an operation "that would execute anyway" (eventual consistency), changing no participant's share result.

### 5.10 Toolchain Verification Evidence (t7 Slither + t8 Halmos)

#### Slither (B1): zero real risk

- Scanned 9 contracts × 102 detectors (`--exclude-dependencies`), result **0 high / 0 medium**, only 2 style-class findings:
  - `assembly` × 4 (`_registry`/`_lists`/`_quarter`/`_params` ERC-7201 storage-slot access) — **intentional design**, standard ERC-7201 practice, not a risk;
  - `naming-convention` × 5 (immutable uppercase constants) — Solidity convention, not a risk.
- Not triggered: reentrancy / unchecked / integer-overflow / tx.origin / delegatecall risk detectors.

#### State-machine verification (quarter windows): 4/4 PASS

- Target: `test/halmos/QuarterWindowCheck.t.sol` — 4 parameter-independent propositions (T2a/T3/T4/T5b), see §4.3.8.
- Note: the `_computeShares` symbolic checks (largest-remainder) were **removed** — the FixedU18 operators are
  assembly `div`/`mul` and produce SMT constraints the solver cannot discharge under symbolic execution
  (timeouts / revert-all; probe experiments confirmed). The largest-remainder properties remain covered by the
  **differential suite** (fixed-case bit-exact assertions) and **invariant fuzz** (SumShares conservation over
  random action sequences). Restorable from git history if tool support improves.

### 5.11 Handled Defects and Same-Pattern Residual Risk Checklist

> Honest presentation: during SRA development the toolchain/tests caught **2 real implementation defects** (T6, T10), both TDD-fixed with regression tests left behind. The following checklist is for future reviewers to focus on re-checking **the same patterns**.

#### Handled defects

| # | Defect | Root cause | Fix | Regression guard |
|---|--------|------------|-----|------------------|
| **T6** | `registerPairs` bypasses binding uniqueness | the AlreadyBound check uses `_isAdmitted(current)` instead of `_resolve(current)` — after replace the binding still points to the old address (admitted=false), so a third party can grab the binding pair | 1-line fix `_isAdmitted(_resolve(current))` | `test_RegisterPairs_AfterReplace_ThirdPartyReverts` + `invariant_OneBindingPerPair`  *(S13: the check is now `boundId != 0 && orchestrators[boundId].admitted` — bindings store the id, so the bound id's admitted flag is read directly; observable behavior unchanged)* |
| **T10 (A2)** | a frozen orchestrator obtains a share through the resolve chain | `replace(old→new)` sets `old.successor = new` → re-`admit(old)` leaves successor residual → `submitShares`'s freeze check targets old itself (not frozen, passes) but the wallet resolves to the frozen new | `admit` identity reset (clears successor/frozenSince/frozenAtPostEnd/fpv/prevFpv, symmetric with remove cleanup); invariant handler synced | R1/R2 regression + A2 invariant (exposed by random failure at t7/t8 acceptance; stable for 2 rounds after the fix) |

#### Same-pattern residual risk checkpoints (for future reviewers)

1. **remove then re-admit**: ✅ safe (S13 — structurally guaranteed): re-admit allocates a fresh id, so the removed identity's bindings/FPV/freeze state cannot carry over by construction.
2. **replace chain length**: ✅ obsolete since S13 — the alias chain is removed, `replace` is an O(1) wallet re-point with no chain to cap (the former theoretical DoS is structurally eliminated).
3. **freeze × replace interaction**: ✅ semantics defined — `replace` copies old's frozen state (`frozenSince`/`frozenAtPostEnd`) and contribution slots (`fpv`/`prevFpv`, contribution inherited by the new identity) to new (identity transfer, covered by `test_Replace_TransfersIdentity`); frozen state follows the identity, consistent with S5 snapshot semantics.
4. **replace then re-admit (T10 main defect pattern)**: ✅ fixed — `admit` identity reset cuts the residual chain; regression tests R1/R2 guard it.
5. **freeze-history array growth**: ⚠️ theoretical growth point (see §5.3), constrained by governance frequency; current magnitude negligible.

#### Coverage and statistics notes

- SRA line coverage **100%**, statements 99.45%, functions 100%; branch 67.16% (`forge coverage`) is the **tool's statistical ceiling** — require branches of governance function bodies with the `unanimous`/`unanimousNoHold` modifier are all recorded as 0 in lcov (including remove NotAdmitted / reassignBinding NotAdmitted / replace AlreadyAdmitted / setPricingParams InvalidParameter, which G6 explicitly tests); an lcov quirk for modifier-inlined function bodies, **not a real gap** (detailed in §4.3.3).
- Full suite **253/253 Green** (104 SRA deterministic + 5 invariant + 144 existing); 5 invariants (share conservation / binding uniqueness / governance consistency / A2 freeze snapshot / A3 all-zero no-op); `.gas-snapshot` gas baseline committed (E1).

### 5.12 Pre-Launch Prerequisite Checklist

> Final confirmations for deployment/launch (mostly protocol-layer / off-chain premises, not contract defects):

- [ ] **f02 wire contract check**: `FVMRewards`'s CBOR encoding (method number/field order/f410 address/BigInt return) matches the final f02 implementation (§5.6's largest premise).
- [ ] **Deployment parameters**: EPOCHS_PER_QUARTER / POST_PERIOD / VERIFICATION_WINDOW / SRA_CANCEL_HOLD / ACTIVATION_EPOCH set per mainnet config; MIN_LOT / PRICE_BAND governance-initialized sensibly (authoritative for the off-chain indexer, FIPs#1275).
- [ ] **Dual Safe addresses**: confirm real Safe proxies (constructor `isProbablyASafe` check); private keys held by distinct entities.
- [ ] **service stream 2 registration**: f02-side stream 2's writer points to the SRA address (the mock simulates this flow; tests §4.4.3).
- [ ] ~~**replace chain length and freeze-history growth monitoring**~~: ✅ resolved by S13 — the alias chain is removed (replace = O(1) re-point), so no chain-length cap is needed; freeze-history growth is now bounded by admit/remove churn on per-address generations (governance-frequency, unchanged monitoring recommendation).
- [ ] **EIP-170 bytecode size**: `forge build --sizes` — `ServiceRewardsActor` runtime ≤ 24,576 B. ⚠️ **Known issue (tracked)**: at HEAD the actor is 25,947 B (1,371 B over the limit) — the current monolith **cannot be deployed as-is**; `forge build --sizes` fails and CI does not (yet) check it. Verified remedy: `via_ir = true` compiles the actor to 21,111 B (3,465 B under the limit), but via-IR conflicts with the halmos/differential harnesses (Error 1284: immutables read but never assigned) — halmos must then run under a separate non-via-IR profile (`FOUNDRY_PROFILE=legacy`). Decision: **not fixing now** — the contract logic will be simplified later (logic-to-library / proxy split, #5), which resolves this naturally; **re-verify with `forge build --sizes` before launch**.

### 5.13 Threat Model Matrix (S4, adversarial-internal-party coverage)

> **S4 fix**: the previous threat model covered only "honest-but-faulty" callers; V1/V2/V3 showed the missing dimension — a **malicious / compromised internal party** (an admitted orchestrator, or a compromised owner) must be in scope. For each external write function: threat party × impact × mitigation × sufficiency.

| Function | Threat party | Impact | Mitigation | Sufficient? |
|----------|--------------|--------|------------|-------------|
| `registerPairs` | malicious orchestrator | binding spam / pair squatting (uniqueness keeps 1-pair-1-owner) | `MAX_PAIRS(64)` batch bound + `NotAdmitted`/`NotFrozen` gates; `AlreadyBound` uniqueness; pairs claimable after Remove | ✅ (data hygiene; no value at stake) |
| `postVolume` | malicious orchestrator | extreme FPV → overflow DoS (V3) | single `MAX_FPV_USD` bound at entry; `NotAdmitted`/`NotFrozen` gates; `AlreadyPosted` once-per-quarter | ✅ (the band machinery was removed with FIPs#1275 — S1 adversarial suite locks the remaining edges) |
| `admit` / `remove` | compromised owner | arbitrary orchestrator admission/removal | unanimous dual-Safe + hold (3-phase); `MAX_ORCHESTRATORS(64)`; re-admit identity reset (T10); **remove timing guard (spec §3.2/§4.4)**: `PendingShares(q)` reverts while the latest bound quarter awaits its share map — no removal can bind between close-of-posting and SubmitShares, keeping the submitted map consistent with the quarter counter | ✅ (needs both Safe keys — private-key security is a protocol premise) |
| `freeze` / `unfreeze` | compromised owner | suspend/restore orchestrator; freeze keeps slot (D2) | unanimous + hold; `frozenSince`/`frozenAtPostEnd` (E+POST snapshot flag, fixed from verification onward) | ✅ |
| `replace` | compromised owner | identity transfer (frozen state + bindings) | unanimous + hold; O(1) wallet re-point (id-keyed, S13) keeps binding resolution correct; re-admit fresh id | ✅ |
| `reassignBinding` | compromised owner | disputed-pair reassignment | unanimous + hold; target must be admitted | ✅ |
| `replaceOwner` | compromised owner | owner rotation | unanimousNoHold (immediate) + `isProbablyASafe`; `CannotRemoveLastOwner` protects the last owner | ✅ (E1 added; rotation only, n-of-n loss is a protocol premise) |
| `setAdmittedLists` / `setPricingParams` | compromised owner | allowlist / pricing-parameter manipulation | unanimous + hold; `MAX_ALLOWLIST(64)`; pricing bound `priceBand ≤ BASIS_POINTS` (MIN_LOT is governance-trusted for the off-chain indexer, FIPs#1275) | ✅ |
| `cancelPending` | compromised owner | veto queued change | `_veto` requires `msg.sender.isOwner()` | ✅ |
| `correctVolume` | compromised owner | overwrite posted volume (governance path into FPV) | unanimousNoHold + in-body `_inVerificationWindow`; same `MAX_FPV_USD` bound as postVolume; **`NotFrozen` gate (freeze symmetry with `postVolume` — A2/A3 fix: a suspended orchestrator cannot be re-admitted via the governance path)** | ✅ (bidirectional correction by design, D3a) |
| `submitShares` | external caller | trigger share settlement | `_afterBinding` gate; permissionless; frozen snapshot from E+POST instant (timing-independent); all-zero → benign no-op (FIPs#1275, replacing D1 burn) | ✅ |

**S4 conclusion**: every external write function is closed against a malicious internal party — either by unanimous dual-Safe governance (owner surface), or by code-enforced input bounds + timing gates (orchestrator surface). The only residual exposures are protocol-layer premises (dual-Safe private-key security; f02 wire contract), not contract-layer vulnerabilities.

### 5.14 Reviewer Checklist (S5, challenge-the-premise)

> **S5 fix**: review PASS must no longer default-trust a document's "Safe" mark — the checklist forces the reviewer to verify each claim's premise is enforced in code.

- [ ] **S5.1 — Security-claim → code map**: for every "Safe"/"Conditionally safe" conclusion in §5.1, the cited code-enforcement point must exist and match the claim (no enforcement reference = review fails). The §5.1 table is the map; verify at least rows 2/3/4 against the source.
- [ ] **S5.2 — Evidence conditions**: every verification evidence (Halmos symbolic domain, fuzz sampling domain, invariant bound) must have its applicability condition annotated, and the condition must be satisfied by the code (e.g. the fuzz domain `(0,1e30)` equals the enforced `MAX_FPV_USD`; the Halmos `1e3` symbolic domain is a proportional-space proof with the absolute domain covered by §5.5 domain-math bounds). A proof whose premise is not code-enforced is inadmissible (§5.5 row 4, §4.3.8 S3 note).
- [ ] **S5.3 — Adversarial internal party**: the threat matrix (§5.13) must include the malicious-orchestrator and compromised-owner parties for every external write function; a function missing from the matrix is a review finding.
- [ ] **S5.4 — Adversarial input coverage**: the S1 adversarial suite must cover every external write function's numeric/address/array parameters at their boundary values (0 / 1 / limit / limit+1 / max / zero-address); a parameter class not exercised at its boundary is a review finding.
- [ ] **S5.5 — Test-claim correspondence**: every test asserted in §4 must be runnable and green; a test whose assertion cannot be invalidated (e.g. bare `expectRevert`) does not count as coverage.
- [ ] **S5.6 — Regression after hardening**: any new audit finding (V1/V2/V3-style) must first add a Red regression test, then fix, then re-run the full suite (295 SRA+existing + 5 invariant, incl. the 28-test adversarial matrix) — no finding is closed by documentation alone.

## 6. References

- 📄 [FIP-0118 Service Rewards](https://github.com/filecoin-project/FIPs/blob/master/FIPS/fip-0118.md) (FIL pricing rule §2.3/§3.2/§3.3, SubmitShares §4.2, security considerations §5/§11; the on-chain FinalizeConversion was removed by [FIPs#1275](https://github.com/filecoin-project/FIPs/pull/1275))
- 📘 `docs/f02-design.md` (f02 design: SetShares immediate binding, pull settlement, MAX_RECIPIENTS=64, Σ=1e18)
- 📘 `src/lib/UnanimousGovernance.sol` (unanimous/unanimousNoHold/_veto), `Owners.sol`, `Epoch.sol`, `PendingTask.sol` (ERC-7201 precedents, Epoch type), `IsASafe.sol` (Safe proxy validation incl. stripped support)
- 📘 `src/lib/FVMRewards.sol` + `FVMRewardTypes.sol` + `FVMRewardMethod.sol` (trySetShares, Share, SET_SHARES=2414422607)
- 📘 `src/StreamWeightActor.sol` (upstream swa branch — reference implementation precedent: thin contract + library delegation + unanimousNoHold; not part of this commit)
- 📘 `test/mocks/FVMRewardActor.sol` + `MockRewardTest.sol` (mock validation semantics), `test/mocks/FVMCallActorByIdWithReward.sol`
- 📘 `test/StreamWeightActor.t.sol` (upstream swa branch — Safe owner construction / mock driving precedents; not part of this commit)
