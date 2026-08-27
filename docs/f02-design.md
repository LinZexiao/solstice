# f02 reward-actor design for Solstice (FIP-0118)

This is the implementation design for the Solstice f02 reward actor. It follows [FIP-0118](https://github.com/filecoin-project/FIPs/pull/1270) and is implemented in [builtin-actors PR #1774](https://github.com/filecoin-project/builtin-actors/pull/1774); SWA, SRA, orchestrator, and the w0/w1/w2 weight names are as defined there. f02 becomes the stream engine: each block it evaluates the weight records, pays the miner, accrues the service stream's portion, and burns the exact residual; SWA governance writes queue inside f02 under the timelock and apply when due. Settlement is pull, not push: f02 accrues each stream's portion and recipients withdraw through permissionless `Claim`, where funds go only to wallets named by the share map. Storage position 9 keeps the grand minted total, counted at accrual, so `FilMined` and circulating-supply logic remain unchanged. Burn and service totals are stored counters and the miner total is derived. f02 is quarter-agnostic, with per-block-hot values inline and everything else offboarded.

## Settlement: pull, not push

The FIP has f02 pushing the service stream out to orchestrator wallets each epoch. Instead this document proposes the opposite: f02 accrues each stream's portion and recipients claim it with an explicit message. Value only leaves f02 inside a `Claim`.

Three reasons:
* Churn: f02's state block is rewritten every block, so every byte there is re-stored in every snapshot and archival node for the life of the chain; push puts `N` recipient-state writes on that path forever, accrual is one integer increment in a block that is already churning.
* Observability: the accounting pull needs for entitlements doubles as the ledger, so per-stream accrual and per-wallet entitlements are a state read at any epoch and every payout is an ordinary message with the transfer in its receipt, where push buries transfers in implicit executions that need a replay to see (balance-diffing doesn't recover them: no attribution, no per-epoch resolution).
* Failure modes: no consensus-path sends to gas-bound, and the FIP's failed-send-burns-your-share rule disappears; a failed `Claim` reverts and the entitlement stays put.

The cost is that someone must send a message and pay gas to get paid. `Claim` is **permissionless**, and funds can only go to the wallet the share map names, so a keeper settles on a recipient's behalf and money "just arrives" anyway.

## State

Today's f02 state is an 11-field CBOR tuple, rewritten every block. The rule for the changes below: per-block-mutating values are bare integers inline; everything else lives behind one CID, written only at governance, quarterly, or claim cadence.

```
Pos    Field                  Change
 9     total_minted_reward    Renamed from total_storage_power_reward, position kept.
                              Accrues the full block reward, all streams.
                              FilMined reads it unchanged.
10     simple_total           Deleted; use SIMPLE_TOTAL = 330,000,000 FIL.
11     baseline_total         Deleted; use canonical BASELINE_TOTAL below.

new    total_burn_minted      Cumulative w0 award residual.
new    total_explicit_minted  Cumulative accrual across all explicit streams.
new    accrued[id]            Per explicit stream: current period's gross accrual.
new    swa_timelock_epochs    Per-network hold (7 days mainnet, short on calibnet);
                              migration-set only, FIP-0081 ramp-params pattern.
new    swa_actor              ID-form SWA address; migration-set and immutable.
new    streams_root (CID)     Everything below.
```

Reward calculation uses `SIMPLE_TOTAL = TokenAmount::from_whole(330_000_000)` and `BASELINE_TOTAL = TokenAmount::from_atto(768335872210768889362796814u128)`. The latter is the exact mainnet value fixed by the actors-v2 baseline migration; that migration made the value history-dependent, and Solstice deliberately canonicalises mainnet's value across networks rather than carrying either field forward. At calibnet epoch 3,946,715 the stored value was `769999999891760986050180387` attoFIL, so this cutover reduces `this_epoch_reward` there by approximately 0.0000321% at that state.

At current mainnet actor-ID scale, `swa_actor` adds 6B: one CBOR byte-string header, one protocol byte, and a four-byte unsigned-varint ID. Net roughly +68B on the 165B current f02 state root block after removing the two historical totals and adding two issuance counters, ordered current-period accruals, one epoch, the SWA identity, and the streams CID. Outstanding explicit-stream liability and the next transition epoch are deliberately derived rather than cached there.

Serialisation is the Filecoin norm of only tuple representation, so "keyed by `(stream_id, wallet)`" is logical only: lookups scan the streams array matching on the stored `id`, and each explicit stream owns its own recipient arrays, so streams can't collide on a shared wallet and a claim rewrites only its own stream's rows. Every keyed array sorts ascending by its key with unique keys (recipient tables by ID address; `streams`, `tombstones`, `accrued` by stream id); the queue alone is position-ordered, position being the apply tiebreak. `id`s are SWA-supplied at `RegisterStream` and opaque to f02, which enforces uniqueness across `streams[]`, `tombstones[]`, and pending `RegisterStream` writes, checked at queue time. The SWA keeps the `id`-to-purpose mapping; only the SWA gives an `id` meaning. Migration pins consensus = 1 and service = 2, matching the w1/w2 subscripts; 0 is reserved (in case we make burn an identified stream later).

`PendingWrite.payload` is a CBOR byte string wrapping a separately encoded operation tuple, not an inline nested array; `84 f6 00 41 81 0a` is the minimal fixture witness.

The `streams_root` CID links to a block with the following structure:

```
streams[]        [ id, WeightRecord[v_start, slope, t_start, floor, cap], distribution ]
                 # 0 <= floor <= v_start <= cap <= DENOM
  # where `distribution` is a two-variant union (FIP's Distribution), encoded as an
  # Option since the IMPLICIT case carries no data:
  IMPLICIT  = null            # recipient resolved from protocol state; consensus
                              # stream only (the block winner)
  EXPLICIT  = [ writer,       # FIP "designated writer": may call SetShares.
                              # The SRA for the service stream. Not a payee.
      shares[]:         [[wallet, share], ...]    # payees; <= MAX_RECIPIENTS.
                              # Sums to DENOM on the wire; stored shares may sum
                              # lower, the shortfall being the burn share (see
                              # "The f099 burn sentinel").
      payable[]:        [[wallet, amount], ...]   # unclaimed from closed periods
      claimed_period[]: [[wallet, amount], ...] ] # claimed from the current accrual

tombstones[]     [ [id, payable[]], ... ]
                 # removed streams' outstanding liabilities, kept so claims stay
                 # addressable after removal; rows delete as they're claimed and a
                 # drained tombstone deletes with them.
pending_writes[] [ id?, op, payload, effective_epoch ]
                 # captured SWA calls, ordered by effective epoch then queue position.
                 # Per-stream calls carry id; schedule-wide weight batches encode it as
                 # null, key their slot by op alone, and encode the whole batch in one
                 # payload. RegisterStream may schedule later than the timelock floor.
                 # SetShares never queues. StepWeightRecords is uncancellable.
```

Mutation cadence, per method:

| Method | streams block | inline tuple |
|---|---|---|
| `AwardBlockReward` (per block) | read (weights, liability rows, and queue head); write only when applying a due queued write | `total_minted`, `total_burn`, `total_explicit`, `accrued` |
| `SetWeightRecords` / `StepWeightRecords` / `RegisterStream` / `RemoveStream` / `SetDistribution` | write: queue entry (second write later, at application) | `accrued` if due application registers or removes an explicit stream |
| `CancelPending` | write: queue entry removed | `accrued` if due application registers or removes an explicit stream |
| `SetShares` | write: `shares` / `payable` / `claimed_period` fold | `accrued` reset; due-transition accounting |
| `Claim` | write: `claimed_period` rows, `payable` | due-transition accounting only |

The award path already reads and decodes the complete streams block for its weight records. It also derives outstanding explicit-stream liability from the decoded accrual, claim, payable, and tombstone rows before reserving the new reward.

**Block size.** The streams block is one inline block: any write re-serialises all of it, and the award reads all of it per block, so size costs both. `payable` is capped per stream and tombstones in aggregate; claims keep normal state close to configuration plus active payees.

```
size ≈ 100 + S·(70 + 20·(2N + P))   # S streams, N recipients, P payable rows (rows 20B, 70B/stream fixed);
                                    # queue/tombstones extra, same row arithmetic
S=1, N=16: 313B idle, 921B every row populated (v1: fine)    S=8, N=64, P=128: ~41 KB before queue/tombstones
```

The FIP fixes `MAX_STREAMS = 8`, `MAX_RECIPIENTS = 64`, `MAX_PAYABLE_ROWS_PER_STREAM = 2 * MAX_RECIPIENTS = 128`, `MAX_TOMBSTONE_ROWS = 256`, and `MAX_PENDING_WRITES = 26`. S counts every registered stream, consensus included (the single permitted IMPLICIT stream is ~50B); N is where growth lands, so it gets the headroom. The imposed queue limit, sized for all per-stream operations across a full stream table plus two schedule-wide slots, is enforced by an explicit length check; a 27th entry is rejected. Tombstone admission counts existing payable rows and conservatively reserves `max(MAX_RECIPIENTS, union(payable, shares))` rows for every pending removal. A removal is rejected if that total would exceed 256. While any removal is pending, `SetShares` recomputes the aggregate reservation after its fold and rejects a share change that would exceed the cap. Claims relieve the bound immediately, and a drained tombstone deletes. Raising any limit requires a future FIP and network upgrade that also reshapes the affected structures for the new scale.

`RegisterStream` checks the resulting count, so the eighth stream is valid and a ninth is rejected.

Every stored token value is a `TokenAmount` serialised via `bigint_ser` (sign byte + big-endian magnitude in a byte string), as the current `state.rs` fields are. Fractions are not tokens: `v_start`, `floor`, `cap`, and shares are `u64` fixed point, while `slope` is signed `i64` fixed point so the consensus ramp can decline; all use `DENOM = 1e18`. `1e18` over a power of two because the FIP percentages are exact integers in it, and `Σ shares == DENOM` becomes an exact integer check; the `w * BR` multiply promotes to bignum then `div_floor`s. The migration defines `RAMP_TOTAL = (DENOM / 100) * 45`, `RAMP_EPOCHS = 9 * EPOCHS_PER_QUARTER`, and `RAMP_SLOPE = (RAMP_TOTAL + RAMP_EPOCHS - 1) / RAMP_EPOCHS`, all as exact integer operations; `DENOM` is exactly divisible by 100, and this ordering keeps every intermediate in range. The final ceiling division makes w2 clamp to exactly 10% at the first epoch of Q2 and w1 clamp to exactly 50% no later than the 9-quarter boundary. The opposing integer slopes sum to zero throughout the half-open Q1 interval; once w2 clamps, the sub-one-ramp-epoch fixed-point overshoot becomes burn. The clamp endpoints remain exact regardless of quantisation.

Every admitted weight record satisfies `0 <= floor <= v_start <= cap <= DENOM`. The observable weight is the clamped line, so an out-of-band anchor always has an in-band equivalent obtained by shifting `t_start` to the band crossing. A delayed ramp uses a future `t_start`; back-extrapolation clamps it at the band edge until then. Canonical anchors make `v_start` the actual weight at `t_start` and leave at most one band exit in either direction from the anchor, simplifying breakpoint enumeration.

## Award path (per block, implicit)

```
AwardBlockReward(miner, penalty, gas_reward, win_count):
    abort if streams_root is missing or its store read fails
    if stream bytes cannot be decoded or decoded non-weight structure is malformed:
        pay gas_reward and apply the penalty; commit no state or counter change; return
    expected_BR = this_epoch_reward * win_count / EXPECTED_LEADERS_PER_EPOCH
    if current explicit liability cannot be computed:
        discard any due-write projection
        ceiling = min(STORAGE_MINING_ALLOCATION - total_minted_reward,
                      balance - gas_reward)
        accounting_valid = false
        weights = current weight records
    else:
        project valid due calls; project cancellation-stranded calls as drops
        liability = sum(accrued - claimed_period + payable)
                    over projected live streams and tombstones
        if projected liability cannot be computed:
            discard the projection
            ceiling = min(STORAGE_MINING_ALLOCATION - total_minted_reward,
                          balance - gas_reward)
            accounting_valid = false
            weights = current weight records
        else:
            ceiling = balance - gas_reward - liability - projected fold_dust
            accounting_valid = true
            weights = projected weight records
    if ceiling <= 0:
        pay gas_reward and apply the penalty; commit no state or counter change; return
    BR = min(expected_BR, ceiling)
    if any weight record is malformed or sum(evaluated weights) > DENOM:
        pay gas_reward and apply the penalty; commit no state or counter change; return
    miner = floor(w1 * BR)
    for each explicit stream:
        portion = floor(w_stream * BR)
        # burn sentinel: stored shares summing below DENOM burn the shortfall
        accrue_to_stream = floor(portion * stored_share_total / DENOM)
    explicit = sum(accrue_to_stream) if accounting_valid else 0
    burn = BR - miner - explicit
    total_minted_reward += BR
    total_burn_minted += burn
    total_explicit_minted += explicit
    if accounting_valid:
        commit projected calls and drops; accrued += explicit
        send(f099, burn + projected fold_dust)
    else:
        send(f099, burn)
    miner receives miner + gas_reward via ApplyRewards
```

Burn is the exact residual, so conservation holds to the atto; independent floors of each weight would not conserve, and per-block is not equivalent to per-epoch division under integer rounding. Gas stays wholly with the miner and penalties are unchanged. In valid actor state, the only send on the allocation path is to f099. A well-formed queued call stranded by cancellation is dropped before allocation, so it cannot weaken that totality or leave the queue wedged.

Degradation first establishes whether stream structure and weights are trusted, then selects a safe `BR` ceiling when only accounting is uncomputable. With computable accounting, the exact ceiling reserves `gas_reward`, current liability, and projected fold dust. With uncomputable accounting, the allocation-remainder ceiling is `min(STORAGE_MINING_ALLOCATION - total_minted_reward, balance - gas_reward)`, where `STORAGE_MINING_ALLOCATION = 1.1 billion FIL` is the amount credited to f02. This remains safe across stochastic leader counts: the nominal remainder tracks funds not yet minted, while the second term protects the gas outflow. The network must fund f02 with at least that nominal allocation at genesis, and the reserve identity also depends on clients satisfying the tip-freshness rule above. This path commits no due writes or accounting changes. The real w1 pays the miner and every other portion burns. A non-positive nominal remainder means nominal allocation exhaustion, not necessarily insolvency; donated funds may remain.

Malformed weight records, an evaluated aggregate above `DENOM`, malformed decoded stream structure, or deterministically undecodable `streams_root` bytes pay only `gas_reward` and apply the existing penalty, with no reward minted and no state or counter change. The award path does not abort on deterministic persisted-state faults because every node observes the same bytes. A missing block or blockstore read error still aborts: degrading on a node-local fault could make nodes commit different states from the same chain input. A constant fallback weight would let whichever party induced corruption move its own reward against the applied governance configuration. Weight failure takes precedence when accounting is also invalid; the allocation-remainder path applies only when weights and stream structure remain valid.

Across every mode, new issuance outflow is bounded by `BR + gas_reward` and `T`, `B`, and `S` never decrease; fold dust is an already-accounted service liability, not new issuance.

Applied and dropped events on this implicit path are best-effort. FIP-0107 is required to make them chain-visible, and an event failure must not convert an otherwise recoverable award into a tipset failure.

## SetShares (designated writer, at period boundaries)

```
SetShares(stream_id, new_map):
    caller must be the stream's designated writer
    validate sum(new_map shares) == DENOM and every share > 0
    resolve recipients to ID addresses; reject the call if any does not resolve
    (recipients must exist; the SRA pre-validates at registration, so this is
     a backstop against typos and stranded credits)
    strip any f099 rows before storing; their weight becomes the burn share
    pool = accrued[stream_id]
    for each (wallet, share) in the OLD map:
        earned = floor(share * pool / stored_share_total)
        payable[wallet] += earned - claimed_period[wallet]
    residue = pool - sum(earned)             # rounding dust only
    send(f099, residue)                       # neither counter moves
    accrued[stream_id] = 0; clear claimed_period
    install new_map
```

Folding closes the period under its outgoing shares. Earned-but-unclaimed value moves into `payable`, dropped wallets remain claimable, and indivisible residue burns without changing either issuance counter. The accounting rationale is below.

`SetShares` folds a cloned distribution, then admits the new map only when the union of post-fold `payable` recipients and incoming share recipients has at most `MAX_PAYABLE_ROWS_PER_STREAM` entries. It commits the distribution and cleared accrual together; rejection changes neither.

A "period" in f02 is just the interval between `SetShares` calls: f02 knows no quarters, `SetShares` binds immediately whenever the writer sends it, and the quarterly cadence is upstream SRA discipline (`SubmitShares` runs once per quarter, post-verification-window, and submits only what SplitRule computes). The fold is what makes immediate binding safe: earnings materialise under the old shares before the new map applies, so a share change is strictly prospective.

## Claim (explicit message)

```
Claim(stream_id, wallets[]) -> amounts[]:
    if stream_id is neither live nor tombstoned: return zeros(len(wallets))
    resolve each wallet to ID form; unresolvable wallets are zero entries
    for wallet in wallets:
        if stream_id is a tombstone:
            entitlement = its payable[wallet]              # nothing live on a tombstone
        else:
            s = the stream's EXPLICIT distribution
            live = floor(share_of(s.shares, wallet) * accrued[stream_id]
                         / stored_share_total(s.shares))       # zero total pays nothing
                 - amount_of(s.claimed_period, wallet)         # current period
            entitlement = live + amount_of(s.payable, wallet)  # + unclaimed previous
        if entitlement == 0: amounts[i] = 0; continue
        bump claimed_period[wallet] by live (live case); drop payable[wallet] row
        (tombstone case: delete the tombstone when its last payable row drops)
        send(wallet, entitlement)                          # method 0; failure aborts the call
        emit event(stream_id, wallet, entitlement)
        amounts[i] = entitlement
    return amounts
```

Permissionless, batched, recipients fixed by the map, works mid-period. A batch is capped at `MAX_RECIPIENTS`, so a full payable table drains in two calls. Zero-entitlement entries (unknown wallets, duplicates within the batch) pay nothing and return 0 at their position. An unknown or deleted stream id returns all zeros, so a repeated claim after its tombstone drains is benign. An all-zero batch succeeds.

## The f099 burn sentinel

f099 in an explicit share map is a burn instruction, not a payee. Wire shares still sum to
`DENOM`; share-map admission validates that checksum, then strips all f099 rows. The stored
shortfall is the burn share. Persisted state rejects f099, so it cannot accrue, be claimed, or
reach a tombstone.

For each explicit stream award:

```
accrue = floor(portion * stored_share_total / DENOM)
burn += portion - accrue
```

Only `accrue` enters the stream pool and `total_explicit_minted`; the remainder uses the
existing burn send and counter. Flooring the survivor side prevents a removal from improving
survivor earnings through rounding.

Claim and fold divide the survivor pool by `stored_share_total`, leaving stored share values
unchanged. A total of `DENOM` uses the ordinary path; zero accrues nothing and burns the whole
portion. The total is derived from the inline share vector, bounded by `MAX_RECIPIENTS`.

## Supply accounting

Circulating supply is consensus-relevant (`GetFilMined` feeds initial pledge) and Lotus, Forest, and Venus each compute it independently, so its inputs do not change. `FilMined` stays "read position 9 of f02": the split changes who receives issuance, not how much, so the field keeps meaning the total and no implementation changes its supply logic.

Renaming the 9th field of f02 and keeping it as total minted is correct for `GetFilMined` in the circulating supply calculation but may be breaking for other uses that assume it refers to minted rewards transferred to miners. Code audits should check for such cases.

f02's issuance accounting is three stored counters and a derived residual.

* `T` (`total_minted_reward`) is position 9.
* `B` (`total_burn_minted`) is the cumulative w0 award residual. `S` (`total_explicit_minted`) is gross explicit-stream accrual. Both are stored because each otherwise needs the full weight and reward history.
* `M`, the consensus allocation, is derived: `M = T - B - S`. It is not stored.

Each award adds `BR = miner + explicit + burn` exactly and bumps `T`, `B`, and `S` by their parts. Fold dust was already counted in `S`, so burning it changes no issuance counter; f099's receipts exceed `B` by cumulative dust while `M = T - B - S` remains exact and all three counters stay monotone.

Outstanding explicit-stream liability is derived as `Σ (accrued - Σ claimed_period + Σ payable)` over live streams and tombstones, and f02's balance must cover it. The award path computes it from the streams block already decoded for weight evaluation, avoiding a second state read and a cached scalar that every accrual, claim, fold, removal, and migration must keep synchronized. A due fold's dust is absent from the post-fold liability but remains separately reserved until the actor-layer burn send completes.

## Quarter-agnostic f02, and the schedule

f02 holds no `EPOCHS_PER_QUARTER` and no quarter logic; quarters, windows, and gate cadence are contract-side, and f02's only timing concept is the pending-write hold. Quarter length reaches f02 only through record slopes, so calibnet compression is migration values plus contract params, no code change.

## Methods

All FRC-0042 exported, since the callers are contracts (a `method_hash!` variant plus `actor_dispatch!` arm each): `SetWeightRecords`, `StepWeightRecords`, `RegisterStream`, `RemoveStream`, `SetDistribution` (SWA-only, queued under the timelock); `SetShares` (designated writer, not queued); `CancelPending` (SWA-relayed; every op but `StepWeightRecords`); `Claim` (permissionless, batched). `StepWeightRecords` is the gate write: payload-identical to `SetWeightRecords`, a separate method so that cancellability is a static per-op rule; which SWA path calls which is SWA code, not an assertion f02 has to trust. The existing methods keep their numbers and signatures; only `AwardBlockReward`'s internals change.
Parameter and return tuples, under the encoding rules above and reusing the state's component types. Registration supplies only the caller-suppliable subset of a distribution, `DistributionInit { writer, shares }`; f02 constructs the full `ExplicitDistribution` with empty accounting tables at application, so an invalid registration is unrepresentable, and the queue payload captures the subset as received. `CancelPending` names a slot exactly as the queue keys it (id null for schedule-wide ops); a mismatched id/op pair is rejected, not ignored. `Claim` resolves each supplied wallet to ID form before matching; an unresolvable wallet is a zero-entitlement entry. The configuration methods return nothing.

```
SetWeightRecordsParams  { updates: [[id, WeightRecord], ...] }
StepWeightRecordsParams   identical to SetWeightRecordsParams
RegisterStreamParams    { id, weight, distribution: Option<DistributionInit>, activation_epoch }
RemoveStreamParams      { id }
SetDistributionParams   { id, writer }
SetSharesParams         { id, shares: [[recipient, share], ...] }
CancelPendingParams     { id: Option, op }
ClaimParams             { id, wallets: [Address, ...] }
ClaimReturn             { amounts: [TokenAmount, ...] }   # positional with wallets
```

The timelock is enforced in f02: SWA writes queue with an effective epoch and apply after the hold. The duration is per-network (`swa_timelock_epochs` in state, migration-set only, FIP-0081 ramp-params style; mainnet 7 days, calibnet short).

Every SWA-gated method validates the immediate caller against the ID-form `swa_actor` stored in root state. The activation migration sets the deployed SWA ID for each network because Init-assigned actor IDs may differ across TestVM, calibnet, and mainnet. f02 has no setter; replacing the SWA requires a FIP and network upgrade. The SRA needs no global field: each explicit stream's `writer` address authorizes `SetShares`.

There are no read methods: contracts submit and rely on f02's call-time validation (reverts are cheap and non-advancing).

Gate-position correctness is the SWA's job: it must keep its own step counter rather than deriving position from f02's w2, which is stale while a write is queued (a check inside the hold re-fires a step it already fired) and is a fixed-point schedule value rather than a durable count of successful gates. As discrete w2 steps meet its continuously changing ceiling (`1 - w1`), `(w2 - W2_BASE) / W2_STEP` also stops returning an integer, so it cannot provide stable gate position.

## Events

The actor surface has five kebab-case event kinds:

| Event | Indexed identity fields | Unindexed value fields |
|---|---|---|
| `write-queued` | `op`, optional `stream-id` | `effective-epoch`, `payload` |
| `write-cancelled` | `op`, optional `stream-id` | `effective-epoch` |
| `write-applied` | `op`, optional `stream-id` | `effective-epoch` |
| `write-dropped` | `op`, optional `stream-id` | `effective-epoch` |
| `claim-payout` | `stream-id`, `recipient` | `amount` |

`write-queued` carries the captured payload so an observer can evaluate the complete proposal from the event. `claim-payout` fires once per non-zero transfer; zero-entitlement rows emit nothing. Implementation follows the existing built-in-actor `EventBuilder` pattern. Explicit methods propagate event construction or emission failures as `ActorError`. When `AwardBlockReward` applies or drops due writes on the implicit path, emission is best-effort and failures are logged without aborting the award; FIP-0107 is required before those implicit-path events are chain-visible.

## Lifecycle, queue, validation

Removing a stream or re-pointing its writer first settles the current period, exactly as `SetShares` does: each recipient's earned-but-unclaimed amount is banked as `payable` under the outgoing shares. On removal those debts move to the stream's tombstone; claims against the removed id pay from it, rows delete as they claim, and a drained tombstone deletes entirely, so nothing about a removed stream is permanent. Zero explicit streams is a valid state: the award path runs miner-plus-burn with an empty accrual loop. f02 special-cases no stream, including consensus; removal admission is subject to the reject-stranding rule like any write, so a stream cannot be removed while an uncancellable gate write targeting it is pending. Id non-reuse after that point is SWA discipline (f02 still rejects any duplicate it can see); violating it risks event-history ambiguity only, a deleted tombstone having zero payable by definition. `SetDistribution` changes only the writer; the share map stands until the new writer replaces it, and converting to IMPLICIT is not allowed.

The queue stores captured calls, not decomposed targets: one entry is the unit of validation, application and cancellation. Per-stream operations key slots by `(id, op)`. `SetWeightRecords` and `StepWeightRecords` each key one schedule-wide slot by `op`, encode `id` as null, and store the complete update batch. Queueing into an occupied slot is rejected, so revising a call is cancel plus requeue and always restarts the hold; no path changes a pending payload while preserving its effective epoch. Due calls apply by effective epoch, with equal epochs retaining queue position. Every stream-engine method, including `AwardBlockReward`, applies due calls first; `UpdateNetworkKPI` is not a stream-engine entry point. The objection window is exactly `[queue, effective)`, and `CancelPending` cannot cancel at the effective epoch.

Cancellation is unconditional and never revalidates the remaining queue. It names a slot exactly as the queue keys it (id null for schedule-wide operations; a mismatched id/op pair rejects), refuses `StepWeightRecords`, and treats an empty slot as a benign no-op. A queued call can consequently lose a prerequisite: cancellation can remove a registration required by a later weight update, or a headroom-producing decrease required by an increase.

Admission and application use the same transition and validation path. Admission projects earlier queue entries in order, treating calls already stranded by cancellation as future drops. It requires the new call itself to apply atomically and remain valid from its effective epoch onward without relying on later calls, and rejects a new call that would strand any currently valid queued call. At application, a well-formed due call that has lost a prerequisite is removed, emits a drop event, and processing continues; there is no fallback weight vector and the current configuration remains unchanged. A dropped non-terminal `StepWeightRecords` needs no special repair path because the next passing gate submits the full absolute level derived from the SWA counter.

That self-heal is for non-terminal steps: w2 remains one level low until the next passing gate. If the final step drops, `steps = 8` and no later gate exists; a discretionary `SetWeightRecords` write restores 50% while leaving the already-correct counter unchanged.

Only well-formed calls that have lost an admitted prerequisite are dropped. Payload decoding failures, non-canonical queued calls, and malformed non-weight state are illegal state: the method aborts without mutation, rather than misreporting corruption as governance cancellation fallout. Inconsistent persisted accounting remains illegal for settlement and governance mutations; `AwardBlockReward` alone suspends service accrual, reserves the independent `total_explicit_minted` counter, and continues paying the miner under the degradation matrix above.

Invalid weight records and an invalid aggregate envelope are the recoverable persisted-state exceptions. Due writes are processed from that state, but a write applies only if its resulting records and schedule pass full validation; otherwise it drops. Claims, cancellation, and immediate `SetShares` remain usable. New queued calls reject until repair except for `SetWeightRecords`: admission tolerates the invalid interval before its effective epoch, then requires the captured batch to restore valid records and a valid full-future envelope without stranding any pending call that was still valid. The repair receives the ordinary timelock; it cannot bind early.

Persisted-state validation enforces `|payable ∪ shares| <= MAX_PAYABLE_ROWS_PER_STREAM` for each live stream and caps `claimed_period` at `MAX_RECIPIENTS`. Writer replacement and removal fold the unchanged current map, so the admitted reservation already covers their output. `MAX_TOMBSTONE_ROWS` separately caps tombstones plus pending-removal reservations. Claims remove payable rows, immediately relieving those reservations.

## Migration

The nv29 migration bootstraps two streams as clamped-linear records with `t_start = activation_epoch` and the exact `RAMP_SLOPE` formula above:

```
w1 (consensus, id 1, IMPLICIT):  { v_start 0.95, slope -RAMP_SLOPE, floor 0.50, cap 0.95 }
w2 (service,   id 2, EXPLICIT):  { v_start 0.05, slope +RAMP_SLOPE, floor 0.05, cap 0.10 }
```

The slopes cancel throughout the half-open Q1 interval, so the weights leave no scheduled w0 share during bootstrap. Independent token-allocation floors can still leave an atto rounding residual, which burns under the exact-residual rule. At the first epoch of Q2, w2 clamps to exactly 10%; the ceiling-divided slope can put w1 below 90% by less than one ramp epoch, and that fixed-point residual burns. No scheduled write is needed to exit the bootstrap ramp. The service stream starts with the single-Orchestrator share map (one wallet, share = `DENOM`) and the SRA as designated writer. The migration normalizes the deployed SWA to ID form and stores it in `swa_actor`; it also sets `swa_timelock_epochs` per network. This is the only production write to either field.

## Testing

* **Reward constants after upgrade:** query f02 at two consecutive non-null tipsets whose stored `epoch` increases by one. Compute reward theta for each state from `effective_network_time`, `effective_baseline_power`, `cumsum_realized`, and `cumsum_baseline`; then require `compute_reward(post.epoch, pre_theta, post_theta, SIMPLE_TOTAL, BASELINE_TOTAL)` to equal the post-state `this_epoch_reward` exactly.
* **Decommissioning and recovery:** remove the sole explicit stream with accrued liabilities, cross its removal epoch, continue consensus-only awards, drain and delete its tombstone, and require a later claim to return zero. Reject removal admission when existing tombstone rows plus conservative reservations for all pending removals would exceed `MAX_TOMBSTONE_ROWS`; require claims to relieve the bound, and preserve it when share folds enlarge a pending removal's eventual recipient union. Reject a removal that would strand an admitted `StepWeightRecords`, admit it after the step applies, and reject a new step targeting the removed id. Exercise repeated awards with zero explicit streams, removal of the implicit consensus stream through the same queue path, stream-id reuse only after its tombstone drains, gas-only awards for malformed and aggregate-invalid weights, and ordinary timelocked repair of both cases.
* **Degradation matrix:** assert exact state and payout deltas for the full split, allocation-remainder accounting fallback, deterministic weight or structural corruption, their combination, and zero-ceiling gas-only awards. Require accounting degradation to preserve the unsafe rows and pending queue, including at a point where cumulative explicit minting exceeds the liquid balance; require every untrusted-weight and undecodable-root-byte case to pay gas only without aborting, minting, or moving counters; require missing roots to abort atomically; and require repair to restore ordinary allocation. Randomized valid-state operations must keep exact liability at or below `total_explicit_minted`.
