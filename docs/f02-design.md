# f02 reward-actor design for Solstice (FIP-0118)

This doc is a design proposal for the Solstice f02 implementation, how it works, and why. It assumes the [FIP-0118 text](https://github.com/filecoin-project/FIPs/pull/1270); SWA, SRA, orchestrator, and the w0/w1/w2 weight names are as defined there. In this design f02 becomes the stream engine: each block it evaluates the weight records, pays the miner, accrues the service stream's portion, and burns the exact residual; SWA governance writes queue inside f02 under the timelock and apply when due. Headlines: settlement is pull, not push, replacing the FIP's per-epoch payouts with a permissionless `Claim`, where funds go to the wallets the share map names; storage position 9 keeps the grand minted total, counted at accrual, so `FilMined` and every client's circulating-supply logic is untouched, with burn and service totals stored as counters and the miner total the derived residual; f02 is quarter-agnostic (periods, gates, and cadence are contract-side concerns); per-block-hot values stay inline as bare integers and everything else is offboarded.

## Settlement: pull, not push

The FIP has f02 pushing the service stream out to orchestrator wallets each epoch. Instead this document proposes the opposite: f02 accrues each stream's portion and recipients claim it with an explicit message. Value only leaves f02 inside a `Claim`.

Three reasons:
* Churn: f02's state block is rewritten every block, so every byte there is re-stored in every snapshot and archival node for the life of the chain; push puts `N` recipient-state writes on that path forever, accrual is one integer increment in a block that is already churning.
* Observability: the accounting pull needs for entitlements doubles as the ledger, so per-stream accrual and per-wallet entitlements are a state read at any epoch and every payout is an ordinary message with the transfer in its receipt, where push buries transfers in implicit executions that need a replay to see (balance-diffing doesn't recover them: no attribution, no per-epoch resolution).
* Failure modes: no consensus-path sends to gas-bound, and the FIP's failed-send-burns-your-share rule disappears; a failed `Claim` reverts and the entitlement stays put.

The cost is that someone must send a message and pay gas to get paid. `Claim` is proposed as **permissionless**, and funds can only go to the wallet the share map names, so a keeper settles on a recipient's behalf and money "just arrives" anyway.

## State

Today's f02 state is an 11-field CBOR tuple, rewritten every block. The rule for the changes below: per-block-mutating values are bare integers inline; everything else lives behind one CID, written only at governance, quarterly, or claim cadence.

```
Pos    Field                  Change
 9     total_minted_reward    Renamed from total_storage_power_reward, position kept.
                              Accrues the full block reward, all streams (was
                              miners-only in FIP). FilMined reads it unchanged.
10     simple_total           Deleted; use SIMPLE_TOTAL = 330,000,000 FIL.
11     baseline_total         Deleted; use canonical BASELINE_TOTAL below.

new    total_burn_minted      Cumulative burn (w0 residual + fold dust).
new    total_service_minted   Cumulative service accrual, all explicit streams.
new    service_accrued[id]    Per explicit stream: current period's gross accrual.
new    next_transition_epoch  Min effective_epoch over pending_writes; recomputed on
                              queue/apply/cancel; sentinel when empty. The per-block
                              path compares this one int and doesn't touch the CID.
new    swa_timelock_epochs    Per-network hold (7 days mainnet, short on calibnet);
                              migration-set only, FIP-0081 ramp-params pattern.
new    streams_root (CID)     Everything below.
```

Reward calculation uses `SIMPLE_TOTAL = TokenAmount::from_whole(330_000_000)` and `BASELINE_TOTAL = TokenAmount::from_atto(768335872210768889362796814u128)`. The latter is the exact mainnet value fixed by the actors-v2 baseline migration; that migration made the value history-dependent, and Solstice deliberately canonicalises mainnet's value across networks rather than carrying either field forward. At calibnet epoch 3,946,715 the stored value was `769999999891760986050180387` attoFIL, so this cutover reduces `this_epoch_reward` there by approximately 0.0000321% at that state.

Net roughly +63B on the 165B current f02 state root block (+91B added, -28B from the two deleted totals).

Serialisation is the Filecoin norm of only tuple representation, so "keyed by `(stream_id, wallet)`" is logical only: lookups scan the streams array matching on the stored `id`, and each explicit stream owns its own recipient arrays, so streams can't collide on a shared wallet and a claim rewrites only its own stream's rows. `id`s are SWA-supplied at `RegisterStream` and opaque to f02, which enforces uniqueness across `streams[]`, `tombstones[]`, and pending `RegisterStream` writes, checked at queue time. The SWA keeps the `id`-to-purpose mapping, where `id`s have meaning. Migration pins consensus = 1 and service = 2, matching the w1/w2 subscripts; 0 is reserved (in case we make burn an identified stream later).

The `streams_root` CID links to a block with the following structure:

```
streams[]        [ id, WeightRecord[v_start, slope, t_start, floor, cap], distribution ]
  # where `distribution` is a two-variant union (FIP's Distribution), encoded as an
  # Option since the IMPLICIT case carries no data:
  IMPLICIT  = null            # recipient resolved from protocol state; consensus
                              # stream only (the block winner)
  EXPLICIT  = [ writer,       # FIP "designated writer": may call SetShares.
                              # The SRA for the service stream. Not a payee.
      shares[]:         [[wallet, share], ...]   # payees; <= MAX_RECIPIENTS
      payable[]:        [[wallet, amount], ...]  # unclaimed from closed (previous) periods
      claimed_period[]: [[wallet, amount], ...] ] # claims this period; subtract Σ from
                                                  # service_accrued for what's still owed

tombstones[]     [ [id, payable[]], ... ]
                 # removed streams' outstanding liabilities, kept so claims stay
                 # addressable after removal; rows delete as they're claimed and a
                 # drained tombstone deletes with them.
pending_writes[] [ id, op, payload, effective_epoch ]
                 # a deferred-call list: op+payload capture an SWA method call
                 # (SetWeightRecords etc.) w/ args to be executed at effective_epoch
                 # = queue epoch + swa_timelock_epochs (RegisterStream may schedule
                 # later; the hold is a floor). SetShares never queues.
                 # One entry per (id, op) slot; queueing into an occupied slot is
                 # rejected. StepWeightRecords is the gate write (SWA mechanism
                 # path); it is the one op CancelPending won't touch.
```

Mutation cadence, per method:

| Method | streams block | inline tuple |
|---|---|---|
| `AwardBlockReward` (per block) | read (weight records); write only when applying a due queued write | `total_minted`, `total_burn`, `total_service`, `service_accrued`; `next_transition` on apply |
| `SetWeightRecords` / `StepWeightRecords` / `RegisterStream` / `RemoveStream` / `SetDistribution` | write: queue entry (second write later, at application) | `next_transition_epoch` |
| `CancelPending` | write: queue entry removed | `next_transition_epoch` |
| `SetShares` | write: `shares` / `payable` / `claimed_period` fold | `service_accrued` reset; `total_burn` (residue) |
| `Claim` | write: `claimed_period` rows, `payable` | none |
| `GetState` | read; projects due writes in memory, persists nothing | none |

The award path reads the streams block every block (the records live there). `GetState` projecting rather than persisting keeps reads read-only; the next mutating call or award does the real application.

**Block size.** The streams block is one inline block: any write re-serialises all of it, and the award reads all of it per block, so size costs both. The tails (payable, tombstones) self-drain (see state bounds below), so the steady state is config plus active payees: streams × recipients.

```
size ≈ 100 + S·(70 + 20·(2N + P))   # S streams, N recipients, P payable rows (rows 20B, 70B/stream fixed);
                                    # queue/tombstones extra, same row arithmetic
S=1, N=16: 313B idle, 921B every row populated (v1: fine)    S=8, N=64: ~21-31 KB (the caps, worst case)    S=100, N=1000: ~4.5 MB (not ok!)
```

`MAX_STREAMS` and `MAX_RECIPIENTS` are named but never valued in the FIP. Proposed: `MAX_STREAMS = 8`, `MAX_RECIPIENTS = 64`. S counts every registered stream, consensus included (IMPLICIT streams are ~50B); N is where growth lands, so it gets the headroom. At the caps the block is ~21-31 KB worst case, workable. Raising either requires a future FIP and network upgrade that also reshapes the affected structures for the new scale (using appropriate expandable data structures). Tombstones need no cap: growth is gated on `RemoveStream`, a governance-cadence op, anyone can flush their rows via `Claim`, and a drained tombstone deletes.

Every stored token value is a `TokenAmount` serialised via `bigint_ser` (sign byte + big-endian magnitude in a byte string), as the current `state.rs` fields are. Fractions are not tokens: `v_start`, `floor`, `cap`, and shares are `u64` fixed point, while `slope` is signed `i64` fixed point so the consensus ramp can decline; all use `DENOM = 1e18`. `1e18` over a power of two because the FIP percentages are exact integers in it, and `Σ shares == DENOM` becomes an exact integer check; the `w * BR` multiply promotes to bignum then `div_floor`s. Slope quantisation over the 9-quarter ramp is ~1e-10pp at this scale and the clamp endpoints are stored exact values, so the ramp rests at exactly 50% regardless *(nicer alternative would be to store the ramp by endpoints instead of a slope)*.

## Award path (per block, implicit)

```
AwardBlockReward(miner, penalty, gas_reward, win_count):
    if epoch >= next_transition_epoch: apply due queued writes
    evaluate w1, w2 from the weight records at this epoch (clamped linear)
    BR       = this_epoch_reward * win_count / EXPECTED_LEADERS_PER_EPOCH   # /5
    miner    = floor(w1 * BR)
    service  = floor(w2 * BR)                # shares sum to 1, all of w2 accrues
    burn     = BR - miner - service          # exact residual = w0 * BR
    total_minted_reward += BR
    send(f099, burn);  total_burn_minted += burn
    service_accrued += service;  total_service_minted += service
    miner receives miner + gas_reward via ApplyRewards
```

Burn is the exact residual, so conservation holds to the atto; independent floors of each weight would not conserve, and per-block is not equivalent to per-epoch division under integer rounding (the FIP says it is). Gas stays wholly with the miner and penalties are unchanged. Nothing on this path can fail: the only send is to f099. The one non-trivial step is applying due queued writes.

## SetShares (designated writer, at period boundaries)

```
SetShares(stream_id, new_map):
    caller must be the stream's designated writer
    validate sum(new_map shares) == 1
    resolve recipients to ID addresses; reject the call if any does not resolve
    (recipients must exist; the SRA pre-validates at registration, so this is
     a backstop against typos and stranded credits)
    pool = service_accrued[stream_id]
    for each (wallet, share) in the OLD map:
        earned = floor(share * pool)
        payable[wallet] += earned - claimed_period[wallet]
    residue = pool - sum(earned)             # rounding dust only
    send(f099, residue);  total_burn_minted += residue
    service_accrued[stream_id] = 0; clear claimed_period
    install new_map
```

Folding in this way wraps up the closing period. Each old recipient's `earned`-minus-`claimed` moves into `payable`, then the period resets. A wallet dropped from the new map keeps its `payable` until it claims. The residue is rounding dust only because shares sum to exactly 1.

A "period" in f02 is just the interval between `SetShares` calls: f02 knows no quarters, `SetShares` binds immediately whenever the writer sends it, and the quarterly cadence is upstream SRA discipline (`SubmitShares` runs once per quarter, post-verification-window, and submits only what SplitRule computes). The fold is what makes immediate binding safe: earnings materialise under the old shares before the new map applies, so a share change is strictly prospective.

## Claim (explicit message)

```
Claim(stream_id, wallets[]) -> amounts[]:
    for wallet in wallets:
        if stream_id is a tombstone:
            entitlement = its payable[wallet]              # nothing live on a tombstone
        else:
            s = the stream's EXPLICIT distribution
            live = floor(share_of(s.shares, wallet) * service_accrued[stream_id])
                 - amount_of(s.claimed_period, wallet)         # current period
            entitlement = live + amount_of(s.payable, wallet)  # + unclaimed previous
        if entitlement == 0: amounts[i] = 0; continue
        bump claimed_period[wallet] by live (live case); drop payable[wallet] row
        (tombstone case: delete the tombstone when its last payable row drops)
        send(wallet, entitlement)                          # method 0; cannot fail here
        emit event(stream_id, wallet, entitlement)
        amounts[i] = entitlement
    return amounts
```

Permissionless, batched, recipients fixed by the map, works mid-period. Zero-entitlement entries (unknown wallets, duplicates within the batch) pay nothing and return 0 at their position. An all-zero batch is a benign no-op success, not an error: nothing was written, there's nothing to revert, and keepers get idempotent re-runs for free.

## Supply accounting

Circulating supply is consensus-relevant (`GetFilMined` feeds initial pledge) and Lotus, Forest, and Venus each compute it independently, so its inputs would ideally not change. `FilMined` stays "read position 9 of f02": the split changes who receives issuance, not how much, so the field keeps meaning the total and no implementation changes its supply logic. The current FIP 2.5 (position 9 stays miners-only, `FilMined` becomes a sum of new fields) instead forces a lockstep change across three codebases; flipping it makes the correct behaviour the default.

Renaming the 9th field of f02 and keeping it as total minted is correct for `GetFilMined` in the circulating supply calculation but may be breaking for other uses that assume it refers to minted rewards transferred to miners. Code audits should check for such cases.

f02's own supply accounting is three stored counters and a derived residual.

* `T` (`total_minted_reward`) is position 9.
* `B` (`total_burn_minted`) and `S` (`total_service_minted`) are stored because the w0 and w2 contributions are otherwise difficult to recover independently (each needs the full weight and reward history).
* `M`, what miners have received, is derived: `M = T - B - S`. It is not stored.

Each award adds `BR = miner + service + burn` exactly and bumps `T`, `B`, and `S` by their parts. The counters account for FIL ever minted; the claim state accounts only for the slice still inside f02: at every epoch f02's balance covers `Σ (service_accrued - Σ claimed_period + Σ payable)` over streams and tombstones. Its terms are period-scoped but the invariant isn't; the fold just moves value between terms.

## Quarter-agnostic f02, and the schedule

f02 holds no `EPOCHS_PER_QUARTER` and no quarter logic; quarters, windows, and gate cadence are contract-side, and f02's only timing concept is the pending-write hold. Quarter length reaches f02 only through record slopes, so calibnet compression is migration values plus contract params, no code change.

## Methods

All FRC-0042 exported, since the callers are contracts (a `method_hash!` variant plus `actor_dispatch!` arm each): `SetWeightRecords`, `StepWeightRecords`, `RegisterStream`, `RemoveStream`, `SetDistribution` (SWA-only, queued under the timelock); `SetShares` (designated writer, not queued); `CancelPending` (SWA-relayed; every op but `StepWeightRecords`); `GetState` (read); `Claim` (permissionless, batched). `StepWeightRecords` is the gate write: payload-identical to `SetWeightRecords`, a separate method so that cancellability is a static per-op rule; which SWA path calls which is SWA code, not an assertion f02 has to trust. The existing methods keep their numbers and signatures; only `AwardBlockReward`'s internals change.

The timelock is enforced in f02: SWA writes queue with an effective epoch and apply after the hold. The duration is per-network (`swa_timelock_epochs` in state, migration-set only, FIP-0081 ramp-params style; mainnet 7 days, calibnet short).

Reads exist for contracts: another actor's state is unreachable on-chain except by calling it, while off-chain tooling reads state directly. A contract call arrives via the CALL_ACTOR precompile (read-only flag) and gets back raw CBOR (codec 0x51) to decode in Solidity, so contract-facing return shapes must be small and fixed.

`GetState()` returns the logical state as one tuple, `[total_minted_reward, total_burn_minted, total_service_minted, service_accrued[], next_transition_epoch, swa_timelock_epochs, streams[], tombstones[], pending_writes[]]`, shapes exactly as the state schema above with `streams_root` dereferenced, due writes projected. Claimable amounts need no method: `Claim` returns `amounts[]` and an all-zero batch is a no-op, so a read-only invocation is the query.

Gate-position correctness is the SWA's job: it must keep its own step counter rather than deriving position from f02's w2, which is stale while a write is queued (a check inside the hold re-fires a step it already fired) and, because w2's discrete steps bump up against its ceiling's continuous slope (`1 - w1`), the FIP's `(w2 - W2_BASE)/W2_STEP` stops returning an integer as w2 wanders off the 5% grid, so it doesn't provide the necessary stability.

## Lifecycle, queue, validation

Removing a stream or re-pointing its writer first settles the current period, exactly as `SetShares` does: each recipient's earned-but-unclaimed amount is banked as `payable` under the outgoing shares. On removal those debts move to the stream's tombstone; claims against the removed id pay from it, rows delete as they claim, and a drained tombstone deletes entirely, so nothing about a removed stream is permanent. Id non-reuse after that point is SWA discipline (f02 still rejects any duplicate it can see); violating it risks event-history ambiguity only, a deleted tombstone having zero payable by definition. `SetDistribution` changes only the writer; the share map stands until the new writer replaces it, and converting to IMPLICIT is not allowed.

Due writes apply in effective-epoch order (id as tiebreak) at the start of the award and of every mutating method, so no message ever executes against stale config. `CancelPending` is itself a mutating method, so a due write applies before a same-epoch cancel: the objection window is `[queue, effective)`.

The queue is a set of slots keyed `(id, op)`; queueing into an occupied slot is rejected, so revising a pending write is cancel + requeue and always restarts the hold. No path changes a pending payload while keeping its effective epoch. `CancelPending(stream_id, op)` deletes the slot and frees it immediately; `StepWeightRecords` slots have no cancel path. Cancelling an empty slot is a benign no-op, since both Safes may relay the same objection; the event fires only on removal. The key space bounds the queue at streams × ops.

Schedule validation happens at queue time: a new write is validated against the state **as it will be when it applies**, i.e. with the already-queued calls executed, because two writes each fine against today's records can sum past 1 together (w1:=70 and w2:=35 each pass against a current 60/20; jointly they're 105). Reject the write; the runtime sum check becomes an assertion. This replaces the FIP's underspecified last-valid-values/vector fallback and part of its SWA-side validation split.

State bounds: `MAX_RECIPIENTS` caps a share map but not history, and `Claim` deletes zeroed rows. In normal operation the history terms sit near empty: `payable` fills at the settle and drains as recipients claim, `claimed_period` resets each period, and any `payable` row (live or tombstoned) is flushable by anyone via the permissionless `Claim`. These structures exist for the edge cases (dropped wallets, an absent writer, removed streams), not the norm; a future iteration with _many_ streams may insert one or more HAMTs to contain them, currently considered overkill.

## Migration

The nv29 migration bootstraps two streams as clamped-linear records with `t_start` = activation:

```
w1 (consensus, id 1, IMPLICIT):  { v_start 0.95, slope -0.45/(9*EPOCHS_PER_QUARTER), floor 0.50, cap 0.95 }
w2 (service,   id 2, EXPLICIT):  { v_start 0.05, slope +0.45/(9*EPOCHS_PER_QUARTER), floor 0.05, cap 0.10 }
```

The slopes cancel over Q1 so nothing burns during bootstrap, and w2 hits its cap exactly at the Q1 boundary, auto-exiting the bootstrap ramp with no scheduled write needed. The service stream starts with the single-orchestrator share map (one wallet, share = 1) and the SRA as designated writer. `swa_timelock_epochs` is set per network here (the only place it's ever written).

## Testing

* **Reward constants after upgrade:** query f02 at two consecutive non-null tipsets whose stored `epoch` increases by one. Compute reward theta for each state from `effective_network_time`, `effective_baseline_power`, `cumsum_realized`, and `cumsum_baseline`; then require `compute_reward(post.epoch, pre_theta, post_theta, SIMPLE_TOTAL, BASELINE_TOTAL)` to equal the post-state `this_epoch_reward` exactly.
