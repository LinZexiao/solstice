// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// ============================================================================
// Service Rewards Actor (SRA) — FIP-0118 service-stream share computation contract (issue #4)
//
// Responsibilities: maintain the orchestrator registry, stablecoin/Filecoin Pay allowlists,
//       and quarterly volume FPV state; compute service-stream shares per SplitRule
//       (largest-remainder method) and write them to f02 (SetShares);
//       export AggregatedFPV(Q) for the SWA. The SRA never receives or holds value.
//
// Basis: docs/sra-design.md (design, tests, decisions, security review; C1-C8 conflict rulings)
//   - C1: registerPairs uses a named struct Pair[] (inline tuple-array params are illegal in Solidity)
//   - T1: largest-remainder method per design §2.5.3 (remainder descending, first residue entries +1)
//   - Identity: a uint64 id is the orchestrator identity; an address is only the current wallet mapping
//     (activeIdOf). bindings/fpv/freeze state key on the id, so replace = O(1) wallet re-point and
//     historical quarter data survives an operator-address change without migration; re-admit of a
//     replaced/removed address is a fresh id with zero residual state (no alias chain to clean).
//   - FIP-0118 (FIPs#1275): FIL→USD conversion moved off-chain — FPV is a single USD total, no
//     PricePeriod[]/FinalizeConversion/PRICE_BAND on-chain; all-zero quarter -> SubmitShares no-op
//   - D2: admitted (incl. frozen) <= 64; Admit rejects when full; only Remove releases; Freeze does not release
//   - D3a: correctVolume bidirectional correction (unanimousNoHold + in-body verification-window check)
//   - S5: freeze snapshot = stored frozenAtPostEnd flag (E+POST instant; set/cleared only before E+POST,
//     fixed from the verification window onward) + frozenSince (current freeze state); at the mirror
//     advance the flag is snapshotted into prevFpv (prevFpv <- frozenAtPostEnd ? 0 : fpv)
//
// Storage: 4 ERC-7201 namespaces (Registry/AdmittedLists/Quarter/Params),
//       reusing Solstice.Owners (dual Safe) and Solstice.PendingTasks (governance queue).
// ============================================================================

import {Epoch, currentEpoch} from "./lib/Epoch.sol";
import {FixedU18, ONE, ONE_WAD} from "./lib/FixedU18.sol";
import {FVMRewards} from "./lib/FVMRewards.sol";
import {Share} from "./lib/FVMRewardTypes.sol";
import {OwnersLibrary} from "./lib/Owners.sol";
import {UnanimousGovernance} from "./lib/UnanimousGovernance.sol";
import {IsASafe} from "./lib/IsASafe.sol";
// Top-level SRA types (Pair / FPV) and the ERC-7201 storage layout live in
// separate library files (SraTypes.sol / SraStorage.sol) — extracted to simplify
// the #5 proxy refactor; test files import the types from SraTypes.sol.
import {Pair, FPV} from "./lib/SraTypes.sol";
import {SraStorage} from "./lib/SraStorage.sol";

contract ServiceRewardsActor is UnanimousGovernance {
    using IsASafe for address;
    using OwnersLibrary for address;

    // ------------------------------------------------------------------------
    // Constants and immutable config (design §2.6: quarter/window/hold compile-time constants, passed via constructor)
    // ------------------------------------------------------------------------

    /// @dev f02's service stream fixed id = 2 (f02-design: "Migration pins consensus = 1 and service = 2").
    uint64 private constant SERVICE_STREAM_ID = 2;

    /// @dev Total share (f02 encoding constraint: Σ shares must be exactly == 1e18).
    uint256 private constant SHARE_TOTAL = 1e18;

    /// @dev PRICE_BAND in basis points (10000 = 100%).
    uint256 private constant BASIS_POINTS = 10_000;

    /// @dev D2: admitted orchestrator cap (incl. frozen), matching f02 MAX_RECIPIENTS.
    uint256 private constant MAX_ORCHESTRATORS = 64;
    uint256 private constant MAX_PAIRS = 64; // registerPairs batch bound, aligns with MAX_ORCHESTRATORS
    uint256 private constant MAX_ALLOWLIST = 64; // per-allowlist array bound

    /// @dev Business-domain upper bound on the quarterly FPV input (18-decimal FixedU18: 1e30 wraps 1e12 USD).
    ///      With the FIL→USD conversion moved off-chain (FIPs#1275), the FPV input is a single USD total,
    ///      so the on-chain arithmetic that must not overflow is only _computeShares:
    ///        - per-orchestrator usd_f ≤ 1e30 → usd_f × 1e18 ≤ 1e48 ≪ 2^256
    ///        - total (≤ MAX_ORCHESTRATORS 64) ≤ 64 × 1e30 = 6.4e31 ≪ 2^256
    ///      Magnitude rationale: the assumed business domain is ~1e6 USD/quarter (§5.5); 1e12 USD is ~6
    ///      orders of magnitude above it — loose-by-design headroom (immutable constant, permanent), while
    ///      the arithmetic chain still closes with ~29 orders of magnitude to spare (1e48 → 2^256 ≈ 1.16e77).
    ///      ⚠️ Maintenance: the closure assumes MAX_FPV_USD and MAX_ORCHESTRATORS(64) hold together.
    FixedU18 private constant MAX_FPV_USD = FixedU18.wrap(1e30); // single USD total per quarter per orchestrator (18-decimal)

    // Epoch-typed immutables (EPOCHS_PER_QUARTER public — sole source of truth for both the SRA
    // and the SWA; SWA reads it via the auto-generated getter instead of duplicating quarter config).
    // All quarter/window/hold values are Epoch-typed (epoch semantics -> Epoch type; POST_PERIOD,
    // VERIFICATION_WINDOW, ACTIVATION_EPOCH follow SRA_CANCEL_HOLD/EPOCHS_PER_QUARTER — no wraps at call sites).
    Epoch public immutable EPOCHS_PER_QUARTER;
    Epoch private immutable POST_PERIOD;
    Epoch private immutable VERIFICATION_WINDOW;
    Epoch private immutable SRA_CANCEL_HOLD;
    Epoch private immutable ACTIVATION_EPOCH;

    // ------------------------------------------------------------------------
    // ERC-7201 storage accessors — layout (structs, slots, assembly getters) lives in
    // SraStorage.sol (separate storage declarations for the #5 proxy refactor);
    // these thin wrappers keep the internal call sites unchanged.
    // ------------------------------------------------------------------------

    function _registry() internal pure returns (SraStorage.SraStorageRegistry storage r) {
        return SraStorage.registry();
    }

    function _lists() internal pure returns (SraStorage.SraStorageLists storage l) {
        return SraStorage.lists();
    }

    function _quarter() internal pure returns (SraStorage.SraStorageQuarter storage q) {
        return SraStorage.quarter();
    }

    function _params() internal pure returns (SraStorage.SraStorageParams storage p) {
        return SraStorage.params();
    }

    // ------------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------------

    event OrchestratorAdmitted(address indexed orchestrator);
    event OrchestratorRemoved(address indexed orchestrator);
    event OrchestratorFrozen(address indexed orchestrator);
    event OrchestratorUnfrozen(address indexed orchestrator);
    event OrchestratorReplaced(address indexed oldOrchestrator, address indexed newOrchestrator);
    event BindingDeclared(address indexed payer, address indexed operator, address indexed orchestrator);
    event BindingReassigned(address indexed payer, address indexed operator, address indexed orchestrator);
    event AdmittedListsUpdated(uint256 stablecoinCount, uint256 filecoinPayCount);
    event PricingParamsUpdated(uint256 minLot, uint256 priceBand);
    event VolumePosted(uint64 indexed q, address indexed orchestrator);
    event VolumeCorrected(uint64 indexed q, address indexed orchestrator);
    event SharesSubmitted(uint64 indexed q, uint256 recipientCount, FixedU18 totalUsd);

    error NotAdmitted(address orch);
    error AlreadyAdmitted(address orch);
    error NotFrozen(address orch);
    error AlreadyFrozen(address orch);
    error AtCapacity();
    error AlreadyBound(bytes32 pairId);
    error NotInPostingWindow(uint64 q);
    error NotInVerificationWindow(uint64 q);
    error NotBound(uint64 q);
    error AlreadyPosted(uint64 q);
    error AlreadySubmitted(uint64 q); // FIP: SubmitShares reverts once a quarter's map is submitted
    error NotLatestQuarter(uint64 q); // FIP-0118 §4.2: an older quarter's shares can never overwrite a newer quarter's
    error PendingShares(uint64 q); // FIP-0118 §3.2/§4.4: RemoveOrchestrator reverts while an ended quarter awaits its share map
    error TooManyPairs(); // registerPairs batch exceeds MAX_PAIRS
    error InvalidParameter();

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------

    /// @param owner1,owner2 governance dual Safe (must be Safe proxies)
    /// @param epochsPerQuarter quarter length (epochs)
    /// @param postPeriod posting window (epochs)
    /// @param verificationWindow verification window (epochs)
    /// @param cancelHold governance hold (epochs)
    /// @param activationEpoch end epoch of quarter 0 (window start)
    /// @param minLot,priceBand initial FIL pricing parameters (governable; authoritative for the off-chain indexer, FIPs#1275)
    constructor(
        address owner1,
        address owner2,
        uint64 epochsPerQuarter,
        uint64 postPeriod,
        uint64 verificationWindow,
        uint64 cancelHold,
        uint64 activationEpoch,
        uint256 minLot,
        uint256 priceBand
    ) {
        owner1.isProbablyASafe();
        owner2.isProbablyASafe();
        owner1.addOwner();
        owner2.addOwner();

        // deployment-time parameter validation, aligned with setPricingParams
        require(priceBand <= BASIS_POINTS, InvalidParameter());
        require(epochsPerQuarter > 0 && postPeriod > 0 && verificationWindow > 0, InvalidParameter());
        // The mirror advances only forward, so the windows must not overlap — a quarter's
        // verification window closing after the next quarter has begun would let a governance
        // CorrectVolume target an already-advanced quarter, rewinding activeQ (uint256 intermediate
        // guards the addition against overflow).
        require(uint256(postPeriod) + uint256(verificationWindow) <= uint256(epochsPerQuarter), InvalidParameter());

        EPOCHS_PER_QUARTER = Epoch.wrap(epochsPerQuarter);
        POST_PERIOD = Epoch.wrap(postPeriod);
        VERIFICATION_WINDOW = Epoch.wrap(verificationWindow);
        SRA_CANCEL_HOLD = Epoch.wrap(cancelHold);
        ACTIVATION_EPOCH = Epoch.wrap(activationEpoch);

        SraStorage.SraStorageParams storage p = _params();
        p.minLot = minLot;
        p.priceBand = priceBand;

        // id allocator starts at 1: 0 is the unregistered sentinel (activeIdOf[addr] == 0)
        _registry().nextId = 1;
    }

    // ------------------------------------------------------------------------
    // Window and quarter utilities (design §2.5.1: Epoch = block.number)
    // ------------------------------------------------------------------------

    function _qEnd(uint64 q) internal view returns (Epoch) {
        // S1C: Q × EPOCHS_PER_QUARTER uses a uint256 intermediate to guard overflow.
        //
        // Range guard: without the explicit check, an attacker-controlled huge q would wrap
        // inside Epoch.wrap and could collide into the current quarter window, bypassing the
        // window checks (enabling forged shares). The guard rejects end beyond the Epoch
        // width — at uint64, uint64.max × EPOCHS_PER_QUARTER ≥ 2^64 always overflows, so the
        // guard is the revert path for the MaxQuarter probes (test/SRAAdversarial.t.sol).
        uint256 end = uint256(Epoch.unwrap(ACTIVATION_EPOCH)) + uint256(q) * uint256(Epoch.unwrap(EPOCHS_PER_QUARTER));
        require(end <= type(uint64).max, InvalidParameter());
        return Epoch.wrap(uint64(end));
    }

    /// @dev posting window (E, E+POST].
    function _inPostingWindow(uint64 q) internal view returns (bool) {
        Epoch nowE = currentEpoch();
        Epoch e = _qEnd(q);
        return nowE > e && nowE <= e + POST_PERIOD;
    }

    /// @dev verification window (E+POST, E+POST+VERIFY].
    function _inVerificationWindow(uint64 q) internal view returns (bool) {
        Epoch nowE = currentEpoch();
        Epoch postEnd = _qEnd(q) + POST_PERIOD;
        return nowE > postEnd && nowE <= postEnd + VERIFICATION_WINDOW;
    }

    /// @dev post-binding: now > E+POST+VERIFY.
    function _afterBinding(uint64 q) internal view returns (bool) {
        Epoch nowE = currentEpoch();
        Epoch verifyEnd = _qEnd(q) + POST_PERIOD + VERIFICATION_WINDOW;
        return nowE > verifyEnd;
    }

    /// @dev The latest quarter whose volumes are bound but whose share map has not been submitted
    ///      (spec §3.2/§4.4: RemoveOrchestrator is not callable while an ended quarter awaits its
    ///      share map — governance clears it by cranking SubmitShares first). Mirrors submitShares'
    ///      latest-bound-quarter determination: the latest bound quarter is activeQ if it has passed
    ///      binding, else activeQ - 1 (an advance into a new quarter implies the previous one is past
    ///      E+POST, hence bound). Only the *latest* bound quarter matters — a superseded quarter
    ///      (skipped by a lag > 1) can never be submitted, so keying on it would deadlock removal.
    ///      lastSubmittedQ is a q+1 encoding (0 = none), so "awaiting" ⟺ lastSubmittedQ != latest + 1.
    function _pendingSharesQuarter() internal view returns (bool hasPending, uint64 q) {
        SraStorage.SraStorageQuarter storage qt = _quarter();
        // The latest bound quarter is a *time* property: derive it from
        // the clock via _quarterOf, not from the activeQ cache — the cache advances only on
        // writes, so a gap quarter (bound but unwritten) would be missed (activeQ still the
        // previous quarter) and removal would wrongly pass. nowQ > 0 guard mirrors the genesis
        // case below (q0's verification window: _afterBinding(0) false, nothing bound yet).
        uint64 nowQ = _quarterOf(currentEpoch());
        uint64 latest;
        if (_afterBinding(nowQ)) {
            latest = nowQ;
        } else if (nowQ > 0) {
            latest = nowQ - 1;
        } else {
            return (false, 0); // genesis: nothing bound yet
        }
        if (qt.lastSubmittedQ != latest + 1) return (true, latest);
        return (false, 0);
    }

    /// @dev Quarter containing `nowE`, derived from the clock alone:
    ///      E(q) = ACTIVATION_EPOCH + q * EPOCHS_PER_QUARTER, so the time quarter is a pure
    ///      function of the epoch. Unlike the activeQ mirror cache (which advances only on
    ///      writes), this never lags: a gap quarter with no volume is still a *time* quarter.
    ///      Pre-activation epochs (possible in test environments; the contract itself starts at
    ///      ACTIVATION_EPOCH) saturate to quarter 0, matching the initial activeQ = 0.
    function _quarterOf(Epoch nowE) internal view returns (uint64) {
        if (Epoch.unwrap(nowE) < Epoch.unwrap(ACTIVATION_EPOCH)) return 0;
        uint256 offset = uint256(Epoch.unwrap(nowE)) - uint256(Epoch.unwrap(ACTIVATION_EPOCH));
        return uint64(offset / uint256(Epoch.unwrap(EPOCHS_PER_QUARTER)));
    }

    /// @dev Time-correct the mirror cache before a write: if the active quarter lags the time
    ///      quarter (a gap quarter with no writes), advance in one step — gap quarters carry no
    ///      data, so prevFpv becomes 0 (one-step jump semantics, keeping the prevFpv == activeQ-1
    ///      invariant). Idempotent when already current. Keeps the slot semantics (fpv/prevFpv
    ///      ownership) aligned with the clock so no time judgment ever reads a stale cache.
    function _syncMirror(SraStorage.SraStorageQuarter storage qt) internal {
        uint64 nowQ = _quarterOf(currentEpoch());
        if (qt.activeQ < nowQ) _advanceMirror(qt, nowQ);
    }

    /// @dev Mirror advance guard: writes are forward-only. q < activeQ would rewind the mirror
    ///      (backing up and clearing a later quarter's contributions — possible when the windows
    ///      overlap, hence also forbidden at the constructor). q > activeQ (skipping one or more
    ///      quarters with no writes) is allowed: a quarter with no volume is necessarily unwritten
    ///      (postVolume rejects zero), and _advanceMirror jumps in one step, keeping
    ///      prevFpv = activeQ-1's data (0 for a gap quarter). The window checks bound q above
    ///      (can't write the far future); this guard only rejects rewinds.
    function _assertMirrorWindow(SraStorage.SraStorageQuarter storage qt, uint64 q) internal view {
        require(q >= qt.activeQ, InvalidParameter());
    }

    /// @dev Mirror advance: the first write of a new quarter (postVolume or correctVolume
    ///      with q != activeQ) backs the previous active-quarter contributions up into the previous-
    ///      quarter mirror — exclusion-fixed (frozenAtPostEnd ? 0 : fpv), because the freeze state
    ///      of the previous quarter's E+POST is no longer derivable once the quarter has advanced —
    ///      and clears the active slots for the new quarter. When q skips quarters (q > activeQ + 1,
    ///      a gap quarter with no volume — necessarily unwritten, postVolume rejects zero), the
    ///      mirror jumps in one step: quarter q-1 is a gap with no data, so prevFpv is zero; the
    ///      previous active-quarter data is superseded (that quarter has no legal submission path
    ///      once the gap quarter has bound — NotLatestQuarter). O(n) per write regardless of gap size.
    function _advanceMirror(SraStorage.SraStorageQuarter storage qt, uint64 q) internal {
        SraStorage.SraStorageRegistry storage r = _registry();
        bool adjacent = q == qt.activeQ + 1;
        for (uint256 i = 0; i < r.admittedIds.length; i++) {
            SraStorage.OrchestratorInfo storage o = r.orchestrators[r.admittedIds[i]];
            o.prevFpv = adjacent ? (o.frozenAtPostEnd ? FixedU18.wrap(0) : o.fpv) : FixedU18.wrap(0);
            o.fpv = FixedU18.wrap(0);
            o.frozenAtPostEnd = false; // new quarter: E+POST not reached, nothing frozen yet
        }
        qt.activeQ = q;
    }

    // ------------------------------------------------------------------------
    // 2.3.1 Orchestrator operations (called by self, no governance)
    // ------------------------------------------------------------------------

    /// @notice An admitted, non-frozen orchestrator declares binding pairs; reverts if the pair is already bound to another (uniqueness, spec §3.3).
    /// @dev C1: parameter uses a named struct Pair[] (inline tuple-array params are illegal in Solidity).
    function registerPairs(Pair[] calldata pairs) external {
        require(pairs.length <= MAX_PAIRS, TooManyPairs()); // batch bound
        // single storage pointer — avoids hashing the orchestrators mapping twice
        SraStorage.SraStorageRegistry storage r = _registry();
        uint64 id = r.activeIdOf[msg.sender];
        SraStorage.OrchestratorInfo storage o = r.orchestrators[id];
        require(id != 0 && o.admitted, NotAdmitted(msg.sender));
        require(o.frozenSince == Epoch.wrap(0), NotFrozen(msg.sender));

        for (uint256 i = 0; i < pairs.length; i++) {
            bytes32 pairId = _pairId(pairs[i].payer, pairs[i].operator);
            uint64 boundId = r.bindings[pairId];
            // Uniqueness: if bound and the bound id is still admitted -> reject; if the bound id was
            // Removed (admitted=false) -> treated as unclaimed, claimable (spec §4.2). ids are never
            // reused, so a removed id stays resolvable — no alias chain required.
            if (boundId != 0 && r.orchestrators[boundId].admitted) {
                revert AlreadyBound(pairId);
            }
            r.bindings[pairId] = id;
            emit BindingDeclared(pairs[i].payer, pairs[i].operator, msg.sender);
        }
    }

    /// @notice During posting, at most one posting per quarter; the value is a single USD total
    ///         (FPV_i(Q): stablecoin face USD + off-chain-converted FIL volume, FIP-0118 FIPs#1275).
    function postVolume(uint64 q, FixedU18 fpv) external {
        // single storage pointer — avoids hashing the orchestrators mapping twice
        SraStorage.SraStorageRegistry storage r = _registry();
        uint64 id = r.activeIdOf[msg.sender];
        SraStorage.OrchestratorInfo storage o = r.orchestrators[id];
        require(id != 0 && o.admitted, NotAdmitted(msg.sender));
        require(o.frozenSince == Epoch.wrap(0), NotFrozen(msg.sender));
        require(_inPostingWindow(q), NotInPostingWindow(q));

        // The single USD total is the only on-chain input that feeds _computeShares;
        // bound it at the entry so the share arithmetic cannot overflow (see MAX_FPV_USD).
        // Reject zero: a zero total is equivalent to not posting (both excluded from the
        // aggregate), so `usd == 0` unambiguously means "not posted".
        require(FixedU18.unwrap(fpv) > 0 && fpv <= MAX_FPV_USD, InvalidParameter());

        SraStorage.SraStorageQuarter storage qt = _quarter();

        // Time-correct the mirror cache first (a gap quarter advances on the clock, not on
        // writes), then validate the write target against the corrected cache.
        _syncMirror(qt);
        _assertMirrorWindow(qt, q);
        if (qt.activeQ != q) _advanceMirror(qt, q);
        require(FixedU18.unwrap(o.fpv) == 0, AlreadyPosted(q));
        o.fpv = fpv; // FixedU18 — 18-decimal USD, type-checked from the entry
        qt.totalUsd[q] = qt.totalUsd[q] + fpv;

        emit VolumePosted(q, msg.sender);
    }

    // ------------------------------------------------------------------------
    // 2.3.2 Governance operations (dual Safe + SRA_CANCEL_HOLD, unanimous path)
    // ------------------------------------------------------------------------

    /// @notice Admits an orchestrator; rejects when admitted total >= 64 (D2).
    /// @dev Re-admit of a previously removed/replaced address allocates a fresh id — a fresh identity with no
    ///      bindings, FPV, or freeze history. Because ids are never reused and the address mapping (activeIdOf)
    ///      is cleared on remove/replace, there is no residual alias-chain or frozen state to clean up.
    function admit(address orch) external unanimous(keccak256(msg.data), SRA_CANCEL_HOLD) {
        SraStorage.SraStorageRegistry storage r = _registry();
        require(r.activeIdOf[orch] == 0, AlreadyAdmitted(orch));
        require(r.admittedIds.length < MAX_ORCHESTRATORS, AtCapacity());
        uint64 id = r.nextId;
        r.nextId = id + 1; // 0.8.x checked arithmetic: reverts on uint64 overflow (unreachable at governance frequency)
        SraStorage.OrchestratorInfo storage o = r.orchestrators[id];
        o.wallet = orch;
        o.admitted = true;
        o.frozenSince = Epoch.wrap(0); // fresh identity: no residual freeze state
        o.frozenAtPostEnd = false;
        o.fpv = FixedU18.wrap(0);
        o.prevFpv = FixedU18.wrap(0);
        r.activeIdOf[orch] = id;
        r.admittedIds.push(id);
        emit OrchestratorAdmitted(orch);
    }

    /// @notice Permanent removal; releases all bindings (pairs return to unclaimed) (spec §4.2).
    /// @dev Timing guard (spec §3.2/§4.4): RemoveOrchestrator reverts while an ended quarter awaits
    ///      its share map — from the end of a quarter until that quarter's SubmitShares has run.
    ///      This guarantees the submitted map's collection (current admitted ids + prevFpv/fpv
    ///      snapshot) is always consistent with the quarter counter: no removal can bind between the
    ///      close of the posting period and SubmitShares, so a bound quarter's contributors are
    ///      exactly the orchestrators its map is computed over. Governance clears the pending quarter
    ///      by cranking SubmitShares first, then removes in a later message.
    /// @dev The id record is kept (wallet/fpv/prevFpv retained for audit); only the address mapping is
    ///      cleared, so a removed id is never reachable from an address and its pairs read as unclaimed.
    function remove(address orch) external unanimous(keccak256(msg.data), SRA_CANCEL_HOLD) {
        SraStorage.SraStorageRegistry storage r = _registry();
        uint64 id = r.activeIdOf[orch];
        SraStorage.OrchestratorInfo storage o = r.orchestrators[id];
        require(id != 0 && o.admitted, NotAdmitted(orch));
        (bool hasPending, uint64 pendingQ) = _pendingSharesQuarter();
        if (hasPending) revert PendingShares(pendingQ);
        // Mirror: drop the active-quarter contribution from the aggregate while the quarter is not
        // yet bound — an orchestrator removed before binding is excluded: omitted from the
        // submitted share map (it leaves the admitted list, which submitShares collects) and its
        // FPV does not enter AggregatedFPV(Q) (spec §2.2). Once the verification window has closed
        // the aggregate is a binding snapshot (the read view exposes the bound values directly) and
        // a later removal must not rewrite it. The boundary is binding (not E+POST — freeze's
        // boundary): unlike freeze, removal drops the orchestrator from the admitted list, so the
        // map and the aggregate must exclude it together for every pre-binding removal.
        uint64 q = _quarter().activeQ;
        if (!_afterBinding(q) && !o.frozenAtPostEnd && FixedU18.unwrap(o.fpv) > 0) {
            _quarter().totalUsd[q] = _quarter().totalUsd[q] - o.fpv;
        }
        o.admitted = false;
        o.frozenSince = Epoch.wrap(0);
        o.frozenAtPostEnd = false;
        r.activeIdOf[orch] = 0;
        _swapRemove(r.admittedIds, id);
        emit OrchestratorRemoved(orch);
    }

    /// @notice Freeze: suspends, zeroes shares, excludes FPV (spec §4.2). Freeze does not release a slot.
    function freeze(address orch) external unanimous(keccak256(msg.data), SRA_CANCEL_HOLD) {
        SraStorage.SraStorageRegistry storage r = _registry();
        uint64 id = r.activeIdOf[orch];
        SraStorage.OrchestratorInfo storage o = r.orchestrators[id];
        require(id != 0 && o.admitted, NotAdmitted(orch));
        require(o.frozenSince == Epoch.wrap(0), AlreadyFrozen(orch));
        Epoch nowE = currentEpoch();
        o.frozenSince = nowE;
        // fpv-effectiveness: a freeze before the posting window closes excludes the active
        // quarter (E+POST snapshot); from the verification window onward the quarter is fixed.
        uint64 q = _quarter().activeQ;
        if (nowE <= _qEnd(q) + POST_PERIOD && FixedU18.unwrap(o.fpv) > 0) {
            _quarter().totalUsd[q] = _quarter().totalUsd[q] - o.fpv; // fpv retained as unfreeze restore source
            o.frozenAtPostEnd = true;
        }
        emit OrchestratorFrozen(orch);
    }

    /// @notice Exact restoration (spec §4.2).
    function unfreeze(address orch) external unanimous(keccak256(msg.data), SRA_CANCEL_HOLD) {
        SraStorage.SraStorageRegistry storage r = _registry();
        uint64 id = r.activeIdOf[orch];
        SraStorage.OrchestratorInfo storage o = r.orchestrators[id];
        require(id != 0 && o.admitted, NotAdmitted(orch));
        require(!(o.frozenSince == Epoch.wrap(0)), NotFrozen(orch));
        Epoch nowE = currentEpoch();
        o.frozenSince = Epoch.wrap(0);
        // Symmetric with freeze: an unfreeze before the posting window closes re-includes the
        // active-quarter contribution (if posted); from the verification window onward it is fixed.
        uint64 q = _quarter().activeQ;
        if (nowE <= _qEnd(q) + POST_PERIOD && FixedU18.unwrap(o.fpv) > 0) {
            _quarter().totalUsd[q] = _quarter().totalUsd[q] + o.fpv;
            o.frozenAtPostEnd = false;
        }
        emit OrchestratorUnfrozen(orch);
    }

    /// @notice Operator address change (spec §4.2). Identity (frozen state, contribution slots) and all bindings transfer to newOrch.
    /// @dev O(1) wallet re-point: the id (identity) stays put, only the address mapping and the wallet field
    ///      change. bindings/fpv/freeze state all key on the id, so they follow the identity automatically —
    ///      no enumeration, no alias chain, and historical quarter FPV remains aggregated.
    function replace(address oldOrch, address newOrch) external unanimous(keccak256(msg.data), SRA_CANCEL_HOLD) {
        SraStorage.SraStorageRegistry storage r = _registry();
        uint64 id = r.activeIdOf[oldOrch];
        require(id != 0 && r.orchestrators[id].admitted, NotAdmitted(oldOrch));
        require(r.activeIdOf[newOrch] == 0, AlreadyAdmitted(newOrch));

        r.activeIdOf[oldOrch] = 0;
        r.activeIdOf[newOrch] = id;
        r.orchestrators[id].wallet = newOrch;
        // admittedIds unchanged (stores ids); bindings/fpv/freeze state all follow the id.
        emit OrchestratorReplaced(oldOrch, newOrch);
    }

    /// @notice Disputed pair reassignment; volume is credited to the new orchestrator from the change epoch onward (spec §4.2).
    function reassignBinding(address payer, address operator, address orch)
        external
        unanimous(keccak256(msg.data), SRA_CANCEL_HOLD)
    {
        uint64 id = _requireAdmittedId(orch);
        _registry().bindings[_pairId(payer, operator)] = id;
        emit BindingReassigned(payer, operator, orch);
    }

    /// @notice Owner rotation: dual-Safe, effective immediately (unanimousNoHold path,
    ///         aligned with upstream SWA's replaceOwner). newOwner must be a Safe proxy.
    function replaceOwner(address prevOwner, address newOwner) external unanimousNoHold(keccak256(msg.data)) {
        newOwner.isProbablyASafe();
        prevOwner.removeOwner();
        newOwner.addOwner();
    }

    /// @notice Updates the stablecoin + Filecoin Pay allowlists (exclusive update, spec §4.2).
    /// @dev Array parameters require normalization (only same-order calldata yields an identical taskId).
    function setAdmittedLists(address[] calldata stablecoins, address[] calldata filecoinPayContracts)
        external
        unanimous(keccak256(msg.data), SRA_CANCEL_HOLD)
    {
        require(stablecoins.length <= MAX_ALLOWLIST && filecoinPayContracts.length <= MAX_ALLOWLIST, InvalidParameter());
        SraStorage.SraStorageLists storage l = _lists();
        // Clear old entries
        for (uint256 i = 0; i < l.stablecoinList.length; i++) {
            delete l.stablecoins[l.stablecoinList[i]];
        }
        for (uint256 i = 0; i < l.filecoinPayList.length; i++) {
            delete l.filecoinPayContracts[l.filecoinPayList[i]];
        }
        // Write new entries
        delete l.stablecoinList;
        delete l.filecoinPayList;
        for (uint256 i = 0; i < stablecoins.length; i++) {
            l.stablecoins[stablecoins[i]] = true;
            l.stablecoinList.push(stablecoins[i]);
        }
        for (uint256 i = 0; i < filecoinPayContracts.length; i++) {
            l.filecoinPayContracts[filecoinPayContracts[i]] = true;
            l.filecoinPayList.push(filecoinPayContracts[i]);
        }
        emit AdmittedListsUpdated(stablecoins.length, filecoinPayContracts.length);
    }

    /// @notice Updates the FIL pricing parameters MIN_LOT/PRICE_BAND (spec §3.3/§5.2).
    ///         FIPs#1275: authoritative for the off-chain indexer's conversion, not an on-chain computation.
    function setPricingParams(uint256 minLot, uint256 priceBand)
        external
        unanimous(keccak256(msg.data), SRA_CANCEL_HOLD)
    {
        require(priceBand <= BASIS_POINTS, InvalidParameter());
        SraStorage.SraStorageParams storage p = _params();
        p.minLot = minLot;
        p.priceBand = priceBand;
        emit PricingParamsUpdated(minLot, priceBand);
    }

    /// @notice Either Safe calls _veto alone to discard a queued change (spec §4.2, _veto).
    function cancelPending(bytes32 taskId) external {
        _veto(taskId);
    }

    // ------------------------------------------------------------------------
    // 2.3.3 correctVolume (dual Safe + effective immediately within the window, unanimousNoHold path)
    // ------------------------------------------------------------------------

    /// @notice Only within the verification window, dual-Safe joint; replaces the posted value with the recomputed figure,
    ///         or supplies the recomputed figure for an unposted orchestrator; exempt from SRA_CANCEL_HOLD (spec §4.2/§5.3
    ///         window-is-hold), allows bidirectional correction. Value is a single USD total (FIP-0118 FIPs#1275).
    /// @dev The unanimousNoHold modifier handles dual-Safe owner validation; the function body validates the verification window.
    function correctVolume(address orch, uint64 q, FixedU18 value) external unanimousNoHold(keccak256(msg.data)) {
        require(_inVerificationWindow(q), NotInVerificationWindow(q));
        uint64 id = _requireAdmittedId(orch);

        // Freeze symmetry: postVolume gates on frozenSince (a frozen orchestrator cannot
        // post); correctVolume is the governance path into the same FPV storage, so it must not
        // re-admit a suspended orchestrator — otherwise a freeze → correctVolume → advance sequence
        // clears frozenAtPostEnd and the frozen orchestrator obtains shares in the next quarter.
        SraStorage.OrchestratorInfo storage o = _registry().orchestrators[id];
        require(o.frozenSince == Epoch.wrap(0), NotFrozen(orch));

        // Same business-domain bound as postVolume (governance path into the same FPV storage).
        require(value <= MAX_FPV_USD, InvalidParameter());

        SraStorage.SraStorageQuarter storage qt = _quarter();

        // Time-correct the mirror cache first (gap quarters advance on the clock), then
        // validate the write target against the corrected cache. correctVolume
        // can be the first writer of a quarter (supplying recomputed figures for a quarter nobody
        // posted); the advance backs the previous quarter's data up into prevFpv.
        _syncMirror(qt);
        _assertMirrorWindow(qt, q);
        if (qt.activeQ != q) _advanceMirror(qt, q);

        // Read the old value *after* the advance: on an advance the previous
        // quarter's fpv has already been backed up into prevFpv and fpv cleared, so oldUsd = 0
        // and the counter receives the full value; without an advance oldUsd is the current
        // quarter's value and the counter is adjusted by (value - oldUsd).
        FixedU18 oldUsd = o.fpv;
        o.fpv = value; // FixedU18 — 18-decimal USD; value==0 clears (equivalent to not posted)

        // E+POST has passed (verification window): frozenAtPostEnd is final — a frozen-at-E+POST
        // orchestrator never enters the aggregate (its value is recorded, not counted).
        if (!o.frozenAtPostEnd) {
            qt.totalUsd[q] = qt.totalUsd[q] + value - oldUsd;
        }

        emit VolumeCorrected(q, orch);
    }

    // ------------------------------------------------------------------------
    // 2.3.4 Mechanism operations (permissionless)
    // ------------------------------------------------------------------------

    /// @notice Permissionless after binding; SplitRule over the bound USD values → f02.SetShares(2, map) (spec §4.2).
    ///         Reverts when this quarter's map has already been submitted (FIP-0118 §4.2); an all-zero quarter is a
    ///         benign no-op: SplitRule is not evaluated and the existing share map stands (FIPs#1275, replacing D1 burn).
    function submitShares(uint64 q) external {
        require(_afterBinding(q), NotBound(q));
        // FIP-0118 §4.2: SubmitShares operates on the **latest** quarter whose volumes are bound, so an
        // older quarter's shares can never overwrite a newer quarter's. Because _afterBinding is monotonic
        // in q, q is the latest bound quarter iff q + 1 is not yet bound. (At q = uint64.max the first
        // require's _qEnd range guard already reverts, so q + 1 cannot overflow here.)
        require(!_afterBinding(q + 1), NotLatestQuarter(q));

        SraStorage.SraStorageRegistry storage r = _registry();
        SraStorage.SraStorageQuarter storage qt = _quarter();
        require(q + 1 != qt.lastSubmittedQ, AlreadySubmitted(q));

        // q is the latest bound quarter. The mirror has advanced only as far as the last written
        // quarter (activeQ): q == activeQ reads the active slot (fpv); q == activeQ - 1 reads the
        // previous-quarter mirror (prevFpv, exclusion-fixed at the advance). A q beyond activeQ
        // bound with no write (posting/verification elapsed with no postVolume/correctVolume) has
        // no data — an all-zero no-op: the quarter still counts as submitted, the existing map
        // stands.
        bool usePrev;
        if (q == qt.activeQ) {
            usePrev = false;
        } else if (qt.activeQ > 0 && q == qt.activeQ - 1) {
            usePrev = true;
        } else {
            qt.lastSubmittedQ = q + 1;
            return;
        }
        address[] memory wallets = new address[](r.admittedIds.length);
        FixedU18[] memory usds = new FixedU18[](r.admittedIds.length);
        uint256 count = 0;
        // Sum over the collected entries (the current admitted ids) — self-consistent with the
        // collection. The quarter counter (totalUsd) is a binding snapshot that can outlive a
        // lag-window remove, so it must not drive the largest-remainder split
        // (an oversized total underflowed the bump loop). aggregatedFPV keeps the counter (O(1)).
        FixedU18 total = FixedU18.wrap(0);
        for (uint256 i = 0; i < r.admittedIds.length; i++) {
            uint64 id = r.admittedIds[i];
            SraStorage.OrchestratorInfo storage o = r.orchestrators[id];
            if (usePrev) {
                if (FixedU18.unwrap(o.prevFpv) == 0) continue;
                wallets[count] = o.wallet; // current effective wallet (replace re-points it)
                usds[count] = o.prevFpv;
            } else {
                if (o.frozenAtPostEnd || FixedU18.unwrap(o.fpv) == 0) continue;
                wallets[count] = o.wallet;
                usds[count] = o.fpv;
            }
            total = total + usds[count];
            count++;
        }

        // FIP-0118: an all-zero quarter is a benign no-op — no SplitRule, no SetShares, existing map stands.
        // It still counts as submitted (the quarter cannot be resubmitted).
        if (FixedU18.unwrap(total) == 0) {
            qt.lastSubmittedQ = q + 1;
            return;
        }

        Share[] memory shares = _computeShares(wallets, usds, count, total);
        // Trim zero-share entries: the largest-remainder method can floor a tiny usd to 0
        // when the residue top-up round count is smaller than the number of orchestrators.
        // Real f02 SetShares rejects share==0 entries (as does the mock), so drop them here.
        uint256 kept = 0;
        for (uint256 i = 0; i < shares.length; i++) {
            if (shares[i].share > 0) shares[kept++] = shares[i];
        }
        if (kept < shares.length) {
            Share[] memory trimmed = new Share[](kept);
            for (uint256 i = 0; i < kept; i++) {
                trimmed[i] = shares[i];
            }
            shares = trimmed;
        }

        qt.lastSubmittedQ = q + 1; // CEI: mark before the external call
        FVMRewards.setShares(SERVICE_STREAM_ID, shares);
        emit SharesSubmitted(q, shares.length, total); // totalUsd as FixedU18 (18-decimal USD)
    }

    // ------------------------------------------------------------------------
    // 2.3.5 Read-only (for SWA and external audit)
    // ------------------------------------------------------------------------

    // forge-lint: disable-next-item(mixed-case-function) — FIP-0118 spec method name (selector-affecting)
    /// @notice Returns the post-binding USD aggregate (FIP-0118 §4.2): Σ of each non-excluded posted orchestrator's
    ///         bound USD value. Pure view — the FIL→USD conversion happens off-chain (FIPs#1275), so there is no
    ///         on-chain finalize to trigger. #10: O(1) via the active-quarter mirror (the SWA's hot path);
    ///         historical quarters fall back to a linear scan (audit/backfill only).
    /// @dev Reverts NotBound(q) before binding — distinguishes "quarter not yet bound" (call too early; the SWA
    ///      does not need to re-enforce the check) from "quarter with zero declared volume" (legitimately returns 0).
    function aggregatedFPV(uint64 q) external view returns (FixedU18 usd) {
        require(_afterBinding(q), NotBound(q));
        // Quarter counter array — O(1) for every quarter. Values are fixed once the mirror
        // advances (spec determinism: the registry is constant within a quarter, so the
        // aggregate cannot drift with later remove/replace).
        return _quarter().totalUsd[q];
    }

    /// @dev Quarter end epoch for quarter q (Epoch-typed; exposed per the IServiceRewardsActor interface the SWA consumes).
    function qEnd(uint64 q) external view returns (Epoch) {
        return _qEnd(q);
    }

    function isAdmitted(address orch) external view returns (bool) {
        SraStorage.SraStorageRegistry storage r = _registry();
        uint64 id = r.activeIdOf[orch];
        return id != 0 && r.orchestrators[id].admitted;
    }

    function isFrozen(address orch) external view returns (bool) {
        SraStorage.SraStorageRegistry storage r = _registry();
        uint64 id = r.activeIdOf[orch];
        return id != 0 && !(r.orchestrators[id].frozenSince == Epoch.wrap(0));
    }

    function admittedCount() external view returns (uint64) {
        return uint64(_registry().admittedIds.length); // MAX_ORCHESTRATORS bound keeps this < 2^64
    }

    function bindingOf(address payer, address operator) external view returns (address) {
        SraStorage.SraStorageRegistry storage r = _registry();
        uint64 id = r.bindings[_pairId(payer, operator)];
        return id == 0 ? address(0) : r.orchestrators[id].wallet; // unbound (0) -> address(0); bound id -> current wallet
    }

    function fpvOf(uint64 q, address orch) external view returns (FPV memory) {
        SraStorage.SraStorageRegistry storage r = _registry();
        uint64 id = r.activeIdOf[orch];
        SraStorage.OrchestratorInfo storage o = r.orchestrators[id];
        uint64 activeQ = _quarter().activeQ;
        // Mirror slots retain only the active and the previous quarter (spec: CorrectVolume is
        // bounded by the verification window, so no historical per-orchestrator corrections
        // exist); earlier quarters return 0 — the aggregate is the only historical read (totalUsd).
        if (q == activeQ) return FPV({usd: o.fpv});
        if (activeQ > 0 && q == activeQ - 1) return FPV({usd: o.prevFpv});
        return FPV({usd: FixedU18.wrap(0)});
    }

    function isStablecoinAdmitted(address token) external view returns (bool) {
        return _lists().stablecoins[token];
    }

    function getPricingParams() external view returns (uint256 minLot, uint256 priceBand) {
        SraStorage.SraStorageParams storage p = _params();
        return (p.minLot, p.priceBand);
    }

    function orchestratorCount() external view returns (uint64) {
        return uint64(_registry().admittedIds.length);
    }

    // ------------------------------------------------------------------------
    // Internal logic
    // ------------------------------------------------------------------------

    /// @dev SplitRule share computation: floor + largest-remainder method (design §2.5.3, T1: remainder descending, first residue entries +1).
    function _computeShares(address[] memory wallets, FixedU18[] memory usds, uint256 n, FixedU18 total)
        internal
        pure
        returns (Share[] memory shares)
    {
        shares = new Share[](n);
        uint256[] memory remainders = new uint256[](n);
        bool[] memory bumped = new bool[](n);
        uint256 residue = SHARE_TOTAL;
        // Remainders keep the integer-USD formulation (usd * 1e18 % total): the FixedU18 division
        // shareF = usds[i] * ONE / total computes div(mul(usd, 1e18), total), so its integer
        // remainder is usd * 1e18 % total — identical ordering to the previous uint256 path.
        uint256 totalUsd = FixedU18.unwrap(total);
        for (uint256 i = 0; i < n; i++) {
            // 18-decimal fixed-point: usd * SHARE_TOTAL / total, mathematically identical to the
            // integer-USD form (usd_f = usd, total_f = total are already 18-decimal). Type-safe
            // against integer/fixed-point magnitude mixing.
            FixedU18 shareF = usds[i] * ONE / total;
            shares[i] = Share({wallet: wallets[i], share: FixedU18.unwrap(shareF)});
            // remainder = (usd_f × 1e18) % total_f = (usd × 1e18 % total_int) × 1e18 — the integer-USD
            // remainder scaled by 1e18; the common ×1e18 factor preserves relative ordering, so the
            // largest-remainder assignment order is bit-identical to the integer formulation.
            remainders[i] = FixedU18.unwrap(usds[i]) * ONE_WAD % totalUsd;
            residue -= shares[i].share;
        }
        // Remainder descending: each round tops up +1 to the largest remaining remainder (n <= 64, O(n²) acceptable)
        for (uint256 r = 0; r < residue; r++) {
            uint256 best = type(uint256).max;
            uint256 bestRem = 0;
            for (uint256 i = 0; i < n; i++) {
                if (!bumped[i] && remainders[i] > bestRem) {
                    bestRem = remainders[i];
                    best = i;
                }
            }
            bumped[best] = true;
            shares[best].share += 1;
        }
    }

    /// @dev Resolves the current admitted id for an address; reverts NotAdmitted when unregistered/removed.
    function _requireAdmittedId(address orch) internal view returns (uint64 id) {
        SraStorage.SraStorageRegistry storage r = _registry();
        id = r.activeIdOf[orch];
        require(id != 0 && r.orchestrators[id].admitted, NotAdmitted(orch));
    }

    function _pairId(address payer, address operator) internal pure returns (bytes32 result) {
        // Scratch-memory assembly: both addresses fit in the 64-byte scratch space,
        // identical result to keccak256(abi.encode(payer, operator)) without the memory allocation.
        assembly {
            mstore(0, payer)
            mstore(32, operator)
            result := keccak256(0, 64)
        }
    }

    function _swapRemove(uint64[] storage list, uint64 id) internal {
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            if (list[i] == id) {
                list[i] = list[n - 1];
                list.pop();
                return;
            }
        }
    }
}
