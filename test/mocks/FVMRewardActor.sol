// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {USR_FORBIDDEN, USR_ILLEGAL_ARGUMENT, USR_NOT_FOUND, USR_UNHANDLED_MESSAGE} from "fvm-solidity/FVMErrors.sol";
import {CBOR_CODEC} from "fvm-solidity/FVMCodec.sol";
import {FVMPay} from "fvm-solidity/FVMPay.sol";
import {BURN_ADDRESS} from "fvm-solidity/FVMActors.sol";

import {
    SET_WEIGHT_RECORDS,
    STEP_WEIGHT_RECORDS,
    SET_SHARES,
    REGISTER_STREAM,
    REMOVE_STREAM,
    SET_DISTRIBUTION,
    CANCEL_PENDING,
    CLAIM,
    SWA_TIMELOCK
} from "../../src/lib/FVMRewardMethod.sol";
import {WeightRecord, DistributionKind, Share, PendingOp} from "../../src/lib/FVMRewardTypes.sol";
import {Epoch} from "../../src/lib/Epoch.sol";
import {FixedU18} from "../../src/lib/FixedU18.sol";

/// @dev Weights, and per-orchestrator shares, are WAD-scaled: 1e18 == 1.0 == 100%.
int256 constant WAD = 1e18;

/// @dev f02's caps, fixed by FIP-0118.
uint64 constant MAX_STREAMS = 8;
uint256 constant MAX_RECIPIENTS = 64;

/// @dev FRC-0042's floor. Below it a method is internal API, closed to EVM callers.
uint64 constant FIRST_EXPORTED_METHOD_NUMBER = 1 << 24;

/// @dev Same value as WAD, typed uint256, so summing shares needs no signed-to-unsigned cast.
uint256 constant SHARE_TOTAL = 1e18;

struct LedgerRow {
    address wallet;
    uint256 amount;
}

/// @dev Enumerable, prunable address->uint256 balance, as plain mappings plus an array. This is
/// not f02's on-chain shape, which is CBOR behind a CID, and no contract can read either one.
struct Ledger {
    mapping(address => uint256) amount;
    mapping(address => uint256) indexPlusOne; // 0 == not tracked
    address[] wallets;
}

/// @notice A registered stream (`id` is the mapping key) plus its per-stream ledgers;
/// `shares`/`writer`/`accrued`/the ledgers are unused for IMPLICIT streams.
struct Stream {
    bool exists;
    WeightRecord weightRecord;
    DistributionKind kind;
    address writer;
    Share[] shares;
    uint256 accrued;
    Ledger payableLedger;
    Ledger claimedPeriod;
}

/// @notice A removed stream's outstanding liabilities; a drained tombstone deletes itself.
struct Tombstone {
    bool exists;
    Ledger payableLedger;
}

/// @dev A queued SWA write. Keyed by (streamId, op); an occupied slot rejects, so revising a
/// pending write means cancel + requeue.
struct Pending {
    uint64 effectiveEpoch;
    WeightRecord weightRecord; // SET_WEIGHT / STEP_WEIGHT / REGISTER payload
    DistributionKind distributionKind; // REGISTER payload
    address writer; // REGISTER / SET_DISTRIBUTION payload
}

/// @notice A queued weight batch: the whole `SetWeightRecords` or `StepWeightRecords` call as one
/// entry. Both ops key their slot by op alone, so a second batch is rejected while one is pending
/// even when it names entirely different streams.
struct WeightBatch {
    uint64 effectiveEpoch;
    uint64[] ids;
    WeightRecord[] records;
}

/// @dev `hasId` is false for the two weight ops, whose slot is schedule-wide and carries a null id
/// on the wire.
struct PendingKey {
    bool hasId;
    uint64 id;
    PendingOp op;
}

struct StreamView {
    uint64 id;
    WeightRecord weightRecord;
    int256 weight; // clamped weight at the current epoch
    DistributionKind kind;
    address writer;
    uint256 accrued;
    Share[] shares;
    LedgerRow[] payableRows;
    LedgerRow[] claimedPeriodRows;
}

struct TombstoneView {
    uint64 id;
    LedgerRow[] payableRows;
}

struct PendingView {
    bool hasId; // false for the two schedule-wide weight slots
    uint64 id;
    PendingOp op;
    uint64 effectiveEpoch;
    WeightRecord weightRecord;
    DistributionKind distributionKind;
    address writer;
}

/// @notice Everything mockState reports, bundled so call sites don't juggle an 8-way tuple.
struct MockState {
    uint256 totalMintedReward;
    uint256 totalBurnMinted;
    uint256 totalServiceMinted;
    uint64 nextTransitionEpoch;
    uint64 swaTimelockEpochs;
    StreamView[] streams;
    TombstoneView[] tombstones;
    PendingView[] pendingWrites;
}

/// @notice Mock for the Filecoin Reward actor (f02), covering its stream-splitting methods.
/// @dev Etch at REWARD_ACTOR_ADDRESS via MockRewardTest, which also re-etches CALL_ACTOR_BY_ID
///      to reach handle_filecoin_method below.
contract FVMRewardActor {
    /// @dev Survives vm.etch: immutables are baked into runtime bytecode at deploy time.
    Vm private immutable VM;

    constructor(Vm vm_) {
        VM = vm_;
    }

    /// @notice Address authorized to call the SWA-only methods.
    address public swa;

    /// @notice Per-network SWA write hold, in epochs; mutable via mockSwaTimelockEpochs.
    /// @dev Left uninitialized inline (vm.etch copies bytecode, not storage -- an inline
    /// initializer would never apply); mockInit() sets it after etching.
    uint64 public swaTimelockEpochs;

    /// @notice Test helper flag: when set, SetShares returns USR_FORBIDDEN unconditionally.
    /// @dev A1 failure-injection switch - triggers the SetSharesFailed revert on the SRA
    ///      submitShares path. Etched storage starts zeroed, default false, other tests unaffected.
    bool public failSetShares;

    /// @notice Cumulative FIL minted through f02, all streams (T = position 9 / FilMined).
    uint256 public totalMintedReward;
    /// @notice Cumulative burn: w0 residual plus period-fold rounding dust (B).
    uint256 public totalBurnMinted;
    /// @notice Cumulative gross accrual to EXPLICIT streams (S); miner's share T-B-S is derived, never stored.
    uint256 public totalServiceMinted;

    /// @notice Minimum effectiveEpoch over pending writes; type(uint64).max sentinel when empty.
    uint64 public nextTransitionEpoch;

    mapping(uint64 streamId => Stream) internal _streams;
    uint64[] internal _streamIds;

    mapping(uint64 streamId => Tombstone) internal _tombstones;
    uint64[] internal _tombstoneIds;

    /// @dev A queued registration's initial share map, keyed by stream id alone since a stream has
    /// at most one pending registration. `delete _pending[id][op]` does not reach it; it is
    /// cleared where a registration applies and where one is queued.
    mapping(uint64 streamId => Share[]) internal _pendingShares;

    mapping(PendingOp => WeightBatch) internal _pendingWeight;
    mapping(PendingOp => bool) internal _pendingWeightExists;

    mapping(uint64 streamId => mapping(PendingOp => Pending)) internal _pending;
    mapping(uint64 streamId => mapping(PendingOp => bool)) internal _pendingExists;
    PendingKey[] internal _pendingKeys;

    event Claimed(uint64 indexed streamId, address indexed wallet, uint256 amount);
    /// @dev Fires only when an occupied slot is actually removed; cancelling an empty slot is a no-op.
    event PendingCancelled(uint64 indexed streamId, PendingOp op);
    event BlockRewardAwarded(uint256 br, uint256 minerPortion, uint256 servicePortion, uint256 burnAmount);
    /// @dev A due write that no longer validates. Events are the only surface a drop has, so an
    /// SWA cannot tell a dropped write from an applied one.
    event PendingDropped(uint64 indexed streamId, PendingOp op);

    /// @notice Test helper: sets the defaults an inline initializer would give this contract; call once, right after etching.
    function mockInit() external {
        swaTimelockEpochs = SWA_TIMELOCK;
        nextTransitionEpoch = type(uint64).max;
    }

    /// @notice Test helper: set the address authorized to call SWA-only methods.
    function mockSwa(address swa_) external {
        swa = swa_;
    }

    function mockSwaTimelockEpochs(uint64 epochs) external {
        swaTimelockEpochs = epochs;
    }

    /// @notice Test helper: flip the SetShares failure-injection flag (A1).
    function mockFailSetShares(bool fail) external {
        failSetShares = fail;
    }

    /// @notice Test helper: simulates AwardBlockReward, splitting `br` by clamped weight into a
    /// miner portion (IMPLICIT; the actual payout is the unmocked ApplyRewards path), a service
    /// portion (EXPLICIT, accrues for Claim/SetShares), and a burn residual.
    /// @dev Mints `br` into this contract's own balance via vm.deal -- a block reward is newly
    /// issued, not moved from an existing balance, so callers don't pre-fund it themselves.
    function mockAwardBlockReward(uint256 br)
        external
        returns (uint256 minerPortion, uint256 servicePortion, uint256 burnAmount)
    {
        VM.deal(address(this), address(this).balance + br);
        _settle();
        uint64 nowEpoch = uint64(block.number);
        for (uint256 i = 0; i < _streamIds.length; i++) {
            uint64 id = _streamIds[i];
            Stream storage s = _streams[id];
            int256 w = _clampWeight(s.weightRecord, nowEpoch);
            uint256 amount = (uint256(w) * br) / uint256(WAD);
            if (s.kind == DistributionKind.IMPLICIT) {
                minerPortion += amount;
            } else {
                uint256 storedShareTotal = _storedShareTotal(s);
                uint256 accrued = storedShareTotal == SHARE_TOTAL ? amount : (amount * storedShareTotal) / SHARE_TOTAL;
                servicePortion += accrued;
                s.accrued += accrued;
            }
        }
        burnAmount = br - minerPortion - servicePortion;

        totalMintedReward += br;
        totalBurnMinted += burnAmount;
        totalServiceMinted += servicePortion;

        if (burnAmount > 0) FVMPay.burn(burnAmount);
        emit BlockRewardAwarded(br, minerPortion, servicePortion, burnAmount);
    }

    /// @notice Test helper: an EXPLICIT stream's wallet-to-share map.
    function getShares(uint64 streamId) external view returns (Share[] memory) {
        return _streams[streamId].shares;
    }

    /// @notice Test helper: read back a live stream's payable ledger directly.
    function getPayable(uint64 streamId) external view returns (LedgerRow[] memory) {
        return _ledgerView(_streams[streamId].payableLedger);
    }

    /// @notice Test helper: read back a tombstone's payable ledger directly.
    function getTombstonePayable(uint64 streamId) external view returns (LedgerRow[] memory) {
        return _ledgerView(_tombstones[streamId].payableLedger);
    }

    /// @notice Test helper: the clamp(v_start + slope*(e-t_start), floor, cap) math, exposed
    /// directly: an SWA has to mirror this schedule itself, and the mock is where a divergence
    /// between its copy and f02's should surface.
    function clampWeight(WeightRecord memory record, uint64 epoch) external pure returns (int256) {
        return _clampWeight(record, epoch);
    }

    /// @notice A native actor: direct EVM CALL returns USR_UNHANDLED_MESSAGE rather than reverting.
    fallback() external {
        bytes memory response = abi.encode(uint32(USR_UNHANDLED_MESSAGE), uint64(0), bytes(""));
        assembly ("memory-safe") {
            return(add(response, 0x20), mload(response))
        }
    }

    /// @dev Routed here from FVMCallActorByIdWithReward's REWARD_ACTOR_ID branch. Never reverts
    /// for actor-level errors -- returns a non-zero exit code instead, per CALL_ACTOR_BY_ID.
    // forge-lint: disable-next-line(mixed-case-function)
    function handle_filecoin_method(uint64 method, uint64, bytes calldata params)
        external
        returns (uint32, uint64, bytes memory)
    {
        // restrict_internal_api: the internal API (AwardBlockReward, ThisEpochReward,
        // UpdateNetworkKPI, Constructor) is closed to EVM callers, and everything reaching a mock
        // through CALL_ACTOR_BY_ID is one. ThisEpochReward is not a back door.
        if (method < FIRST_EXPORTED_METHOD_NUMBER) return (USR_FORBIDDEN, 0, "");
        _settle();
        if (method == SET_WEIGHT_RECORDS) return _queueWeightWrite(PendingOp.SET_WEIGHT, params);
        if (method == STEP_WEIGHT_RECORDS) return _queueWeightWrite(PendingOp.STEP_WEIGHT, params);
        if (method == SET_SHARES) return _setShares(params);
        if (method == REGISTER_STREAM) return _registerStream(params);
        if (method == REMOVE_STREAM) return _removeStream(params);
        if (method == SET_DISTRIBUTION) return _setDistribution(params);
        if (method == CANCEL_PENDING) return _cancelPending(params);
        if (method == CLAIM) return _claim(params);
        return (USR_UNHANDLED_MESSAGE, 0, "");
    }

    // -------------------------------------------------------------------------
    // SetWeightRecords / StepWeightRecords -- SWA only, queued under separate ops.
    // -------------------------------------------------------------------------

    function _queueWeightWrite(PendingOp op, bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        // Params CBOR: [[id...], [[vStart,slope,tStart,floor,cap]...]]
        (uint64[] memory ids, WeightRecord[] memory records) = _decodeSetWeightRecordsParams(params);
        if (ids.length != records.length) return (USR_ILLEGAL_ARGUMENT, 0, "");

        // One slot per op for the whole schedule, so a pending batch blocks the next one outright.
        if (_pendingWeightExists[op]) return (USR_ILLEGAL_ARGUMENT, 0, "");
        if (ids.length == 0) return (USR_ILLEGAL_ARGUMENT, 0, "");

        uint64 effectiveEpoch = uint64(block.number) + swaTimelockEpochs;
        for (uint256 i = 0; i < ids.length; i++) {
            if (!_streams[ids[i]].exists) return (USR_NOT_FOUND, 0, "");
            if (!_sane(records[i])) return (USR_ILLEGAL_ARGUMENT, 0, "");
            for (uint256 j = 0; j < i; j++) {
                if (ids[j] == ids[i]) return (USR_ILLEGAL_ARGUMENT, 0, "");
            }
        }
        NewWrite memory proposed;
        proposed.present = true;
        proposed.op = op;
        proposed.effectiveEpoch = effectiveEpoch;
        proposed.batchIds = ids;
        proposed.batchRecords = records;
        if (!_admits(proposed)) return (USR_ILLEGAL_ARGUMENT, 0, "");

        WeightBatch storage batch = _pendingWeight[op];
        batch.effectiveEpoch = effectiveEpoch;
        for (uint256 i = 0; i < ids.length; i++) {
            batch.ids.push(ids[i]);
            batch.records.push(records[i]);
        }
        _pendingWeightExists[op] = true;
        _pendingKeys.push(PendingKey({hasId: false, id: 0, op: op}));
        if (effectiveEpoch < nextTransitionEpoch) nextTransitionEpoch = effectiveEpoch;
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // SetShares -- designated writer only, applied immediately; folds the closing period into
    // `payable` under the OLD map before installing the new one.
    // -------------------------------------------------------------------------

    function _setShares(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        // A1 failure injection: when the flag is set, reject unconditionally (USR_FORBIDDEN),
        // exercising the SRA's SetSharesFailed error handling.
        if (failSetShares) return (USR_FORBIDDEN, 0, "");
        // Params CBOR: [id, [[walletBytes, share]...]]
        (uint64 id, Share[] memory newShares) = _decodeSetSharesParams(params);
        Stream storage s = _streams[id];
        if (!s.exists) return (USR_NOT_FOUND, 0, "");
        if (s.kind != DistributionKind.EXPLICIT) return (USR_ILLEGAL_ARGUMENT, 0, "");
        if (msg.sender != s.writer) return (USR_FORBIDDEN, 0, "");
        if (!_sharesValid(newShares)) return (USR_ILLEGAL_ARGUMENT, 0, "");

        _foldAndBurnResidue(s);

        delete s.shares;
        _pushNonBurnShares(s.shares, newShares);
        return (0, 0, "");
    }

    /// @notice Test helper: the mock's whole state, read directly rather than through a method.
    /// @dev f02 exposes no reads at all, so an SWA or SRA must mirror anything it needs in its own
    /// state. Tests are not so constrained, and reading here keeps that asymmetry visible.
    /// @dev A true view: it does not settle. Advancing the epoch and reading without an
    /// intervening mutating call shows nothing applied, exactly as f02 behaves. Use mockSettle to
    /// apply due writes.
    function mockState() external view returns (MockState memory) {
        uint64 nowEpoch = uint64(block.number);

        StreamView[] memory streams = new StreamView[](_streamIds.length);
        for (uint256 i = 0; i < _streamIds.length; i++) {
            uint64 id = _streamIds[i];
            Stream storage s = _streams[id];
            streams[i] = StreamView({
                id: id,
                weightRecord: s.weightRecord,
                weight: _clampWeight(s.weightRecord, nowEpoch),
                kind: s.kind,
                writer: s.writer,
                accrued: s.accrued,
                shares: s.shares,
                payableRows: _ledgerView(s.payableLedger),
                claimedPeriodRows: _ledgerView(s.claimedPeriod)
            });
        }

        TombstoneView[] memory tombstones = new TombstoneView[](_tombstoneIds.length);
        for (uint256 i = 0; i < _tombstoneIds.length; i++) {
            uint64 id = _tombstoneIds[i];
            tombstones[i] = TombstoneView({id: id, payableRows: _ledgerView(_tombstones[id].payableLedger)});
        }

        PendingView[] memory pendingWrites = new PendingView[](_pendingKeys.length);
        for (uint256 i = 0; i < _pendingKeys.length; i++) {
            PendingKey memory k = _pendingKeys[i];
            if (!k.hasId) {
                // A weight slot carries no per-stream payload; its records are the batch. Reading
                // `_pending[0][op]` here would report an unrelated entry as this slot's payload.
                pendingWrites[i] = PendingView({
                    hasId: false,
                    id: 0,
                    op: k.op,
                    effectiveEpoch: _pendingWeight[k.op].effectiveEpoch,
                    weightRecord: WeightRecord({vStart: 0, slope: 0, tStart: Epoch.wrap(0), floor: 0, cap: 0}),
                    distributionKind: DistributionKind.IMPLICIT,
                    writer: address(0)
                });
                continue;
            }
            Pending storage p = _pending[k.id][k.op];
            pendingWrites[i] = PendingView({
                hasId: true,
                id: k.id,
                op: k.op,
                effectiveEpoch: p.effectiveEpoch,
                weightRecord: p.weightRecord,
                distributionKind: p.distributionKind,
                writer: p.writer
            });
        }

        return MockState({
            totalMintedReward: totalMintedReward,
            totalBurnMinted: totalBurnMinted,
            totalServiceMinted: totalServiceMinted,
            nextTransitionEpoch: nextTransitionEpoch,
            swaTimelockEpochs: swaTimelockEpochs,
            streams: streams,
            tombstones: tombstones,
            pendingWrites: pendingWrites
        });
    }

    /// @notice Test helper: applies due writes, as f02 does at the head of every mutating call.
    function mockSettle() external {
        _settle();
    }

    function _registerStream(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        (uint64 id, WeightRecord memory record, address writer, Share[] memory shares, uint64 activationEpoch) =
            _decodeRegisterStreamParams(params);
        DistributionKind kind = writer == address(0) ? DistributionKind.IMPLICIT : DistributionKind.EXPLICIT;

        // Zero is reserved, and could come to signify the burn stream; ids match the w1/w2
        // subscripts, so consensus is 1 and service is 2.
        if (id == 0) return (USR_ILLEGAL_ARGUMENT, 0, "");
        // Rejects any id collision it can see: a live stream, an undrained tombstone, or an
        // already-queued registration. Reuse after a tombstone fully drains is SWA discipline.
        if (_streams[id].exists || _tombstones[id].exists || _pendingExists[id][PendingOp.REGISTER]) {
            return (USR_ILLEGAL_ARGUMENT, 0, "");
        }
        // Count queued registrations too, or a burst of calls could blow past the cap.
        if (_streamIds.length + _pendingRegistrationCount() >= MAX_STREAMS) {
            return (USR_ILLEGAL_ARGUMENT, 0, "");
        }
        if (!_sane(record)) return (USR_ILLEGAL_ARGUMENT, 0, "");
        // validate_distribution_init runs the full share check at registration, so an explicit
        // stream is never live without a payable map; an implicit one carries none at all.
        if (kind == DistributionKind.EXPLICIT) {
            if (!_sharesValid(shares)) return (USR_ILLEGAL_ARGUMENT, 0, "");
        } else if (shares.length != 0) {
            return (USR_ILLEGAL_ARGUMENT, 0, "");
        }
        if (activationEpoch < uint64(block.number) + swaTimelockEpochs) return (USR_ILLEGAL_ARGUMENT, 0, "");

        NewWrite memory proposed;
        proposed.present = true;
        proposed.hasId = true;
        proposed.id = id;
        proposed.op = PendingOp.REGISTER;
        proposed.effectiveEpoch = activationEpoch;
        proposed.record = record;
        if (!_admits(proposed)) return (USR_ILLEGAL_ARGUMENT, 0, "");

        delete _pendingShares[id];
        _pushNonBurnShares(_pendingShares[id], shares);
        _queueWrite(
            id,
            PendingOp.REGISTER,
            Pending({effectiveEpoch: activationEpoch, weightRecord: record, distributionKind: kind, writer: writer})
        );
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // RemoveStream -- SWA only, queued; applying it folds the period then tombstones the rest.
    // -------------------------------------------------------------------------

    function _removeStream(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        // Params CBOR: a bare uint64 (streamId), no array wrapper
        uint64 id;
        (id,) = _decodeCborUint64(_calldataPos(params) + 1); // 1-element tuple header
        if (!_streams[id].exists) return (USR_NOT_FOUND, 0, "");
        if (_pendingExists[id][PendingOp.REMOVE]) return (USR_ILLEGAL_ARGUMENT, 0, "");

        NewWrite memory proposed;
        proposed.present = true;
        proposed.hasId = true;
        proposed.id = id;
        proposed.op = PendingOp.REMOVE;
        proposed.effectiveEpoch = uint64(block.number) + swaTimelockEpochs;
        if (!_admits(proposed)) return (USR_ILLEGAL_ARGUMENT, 0, "");

        _queueWrite(
            id,
            PendingOp.REMOVE,
            Pending({
                effectiveEpoch: uint64(block.number) + swaTimelockEpochs,
                weightRecord: WeightRecord({vStart: 0, slope: 0, tStart: Epoch.wrap(0), floor: 0, cap: 0}),
                distributionKind: DistributionKind.IMPLICIT,
                writer: address(0)
            })
        );
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // SetDistribution -- SWA only, queued; changes only the writer, folding the period first.
    // -------------------------------------------------------------------------

    function _setDistribution(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        (uint64 id, address writer) = _decodeSetDistributionParams(params);
        if (!_streams[id].exists) return (USR_NOT_FOUND, 0, "");
        // Only the writer moves; a stream's kind is fixed at registration, so an implicit stream
        // has no writer to change.
        if (writer == address(0)) return (USR_ILLEGAL_ARGUMENT, 0, "");
        if (_streams[id].kind != DistributionKind.EXPLICIT) return (USR_ILLEGAL_ARGUMENT, 0, "");
        if (_pendingExists[id][PendingOp.SET_DISTRIBUTION]) return (USR_ILLEGAL_ARGUMENT, 0, "");

        NewWrite memory proposed;
        proposed.present = true;
        proposed.hasId = true;
        proposed.id = id;
        proposed.op = PendingOp.SET_DISTRIBUTION;
        proposed.effectiveEpoch = uint64(block.number) + swaTimelockEpochs;
        if (!_admits(proposed)) return (USR_ILLEGAL_ARGUMENT, 0, "");

        _queueWrite(
            id,
            PendingOp.SET_DISTRIBUTION,
            Pending({
                effectiveEpoch: uint64(block.number) + swaTimelockEpochs,
                weightRecord: WeightRecord({vStart: 0, slope: 0, tStart: Epoch.wrap(0), floor: 0, cap: 0}),
                distributionKind: DistributionKind.EXPLICIT,
                writer: writer
            })
        );
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // CancelPending -- SWA only; cancelling an empty slot is a benign no-op.
    // -------------------------------------------------------------------------

    function _cancelPending(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        if (msg.sender != swa) return (USR_FORBIDDEN, 0, "");
        (bool hasId, uint64 id, PendingOp op) = _decodeCancelPendingParams(params);
        // StepWeightRecords is the one uncancellable op: the discretionary path must not be able
        // to revoke a governance-gated write.
        if (op == PendingOp.STEP_WEIGHT) return (USR_ILLEGAL_ARGUMENT, 0, "");
        // Shape mismatch: the weight slots are schedule-wide and are addressed with a null id,
        // every other op names its stream. Neither can be cancelled through the other's shape.
        if (hasId && op == PendingOp.SET_WEIGHT) return (USR_ILLEGAL_ARGUMENT, 0, "");
        // A weight write is one schedule-wide entry addressed with a null id. Until the slot model
        // matches, cancelling one clears every stream's share of that batch, which is the same
        // observable outcome.
        if (!hasId) {
            if (op != PendingOp.SET_WEIGHT) return (USR_ILLEGAL_ARGUMENT, 0, "");
            if (_pendingWeightExists[op]) {
                delete _pendingWeight[op];
                _pendingWeightExists[op] = false;
                _removePendingKey(false, 0, op);
                _recomputeNextTransition();
                emit PendingCancelled(0, op);
            }
            return (0, 0, "");
        }
        if (_pendingExists[id][op]) {
            delete _pending[id][op];
            _pendingExists[id][op] = false;
            _removePendingKey(true, id, op);
            _recomputeNextTransition();
            emit PendingCancelled(id, op);
        }
        return (0, 0, "");
    }

    // -------------------------------------------------------------------------
    // Claim -- permissionless, batched; zero-entitlement entries pay nothing, no revert.
    // -------------------------------------------------------------------------

    function _claim(bytes calldata params) internal returns (uint32, uint64, bytes memory) {
        // Params CBOR: [id, [walletBytes...]]
        (uint64 id, address[] memory wallets) = _decodeClaimParams(params);

        bool tombstoned = _tombstones[id].exists;
        Stream storage s = _streams[id];
        if (!tombstoned) {
            if (!s.exists) return (USR_NOT_FOUND, 0, "");
            if (s.kind != DistributionKind.EXPLICIT) return (USR_ILLEGAL_ARGUMENT, 0, "");
        }

        uint256 storedShareTotal;
        if (!tombstoned) storedShareTotal = _storedShareTotal(s);

        uint256[] memory amounts = new uint256[](wallets.length);
        for (uint256 i = 0; i < wallets.length; i++) {
            address wallet = wallets[i];
            uint256 entitlement;
            if (tombstoned) {
                entitlement = _tombstones[id].payableLedger.amount[wallet];
                if (entitlement == 0) continue;
                _ledgerRemove(_tombstones[id].payableLedger, wallet);
                if (_tombstones[id].payableLedger.wallets.length == 0) {
                    _tombstones[id].exists = false;
                    _removeTombstoneId(id);
                }
            } else {
                uint256 share = _shareOf(s, wallet);
                uint256 claimed = s.claimedPeriod.amount[wallet];
                uint256 grossLive = storedShareTotal == 0 ? 0 : (share * s.accrued) / storedShareTotal;
                uint256 live = grossLive > claimed ? grossLive - claimed : 0;
                uint256 payableAmount = s.payableLedger.amount[wallet];
                entitlement = live + payableAmount;
                if (entitlement == 0) continue;
                if (live > 0) _ledgerIncrement(s.claimedPeriod, wallet, live);
                if (payableAmount > 0) _ledgerRemove(s.payableLedger, wallet);
            }
            FVMPay.pay(wallet, entitlement); // method 0/SEND; cannot fail here
            emit Claimed(id, wallet, entitlement);
            amounts[i] = entitlement;
        }
        // Return CBOR: an array of Filecoin BigInt-encoded entitlements, one per wallet.
        return (0, CBOR_CODEC, _encodeCborBigIntArray(amounts));
    }

    // -------------------------------------------------------------------------
    // CBOR params/return encoding -- f02's real wire format; not gas-optimized, since only
    // FVMRewards (src/lib/FVMRewards.sol) and this mock need to agree on it.
    // -------------------------------------------------------------------------

    // Every decode helper below takes/returns an absolute calldata byte position (not an offset
    // into `params`), read via `calldataload` -- one word load per field, no `bytes calldata`
    // indexing or intermediate slicing.

    function _decodeSetWeightRecordsParams(bytes calldata params)
        private
        pure
        returns (uint64[] memory ids, WeightRecord[] memory records)
    {
        // [[[id, record], ...]] -- the outer array is the single-field parameter tuple.
        uint256 pos = _calldataPos(params);
        (, pos) = _decodeCborArrayHeader(pos); // the single-field tuple wrapper
        uint256 count;
        (count, pos) = _decodeCborArrayHeader(pos);
        ids = new uint64[](count);
        records = new WeightRecord[](count);
        for (uint256 i = 0; i < count; i++) {
            (, pos) = _decodeCborArrayHeader(pos); // each pair's own header
            (ids[i], pos) = _decodeCborUint64(pos);
            pos += 1; // the record's own 5-element header is always one byte
            (records[i], pos) = _decodeWeightRecord(pos);
        }
    }

    function _decodeSetSharesParams(bytes calldata params) private pure returns (uint64 id, Share[] memory newShares) {
        uint256 pos = _calldataPos(params) + 1; // 2-element tuple header
        (id, pos) = _decodeCborUint64(pos);
        (newShares, pos) = _decodeShares(pos);
    }

    /// @dev [[recipient, share], ...]
    function _decodeShares(uint256 pos) private pure returns (Share[] memory shares, uint256 newPos) {
        uint256 count;
        (count, pos) = _decodeCborArrayHeader(pos);
        shares = new Share[](count);
        for (uint256 i = 0; i < count; i++) {
            pos += 1; // per-entry 2-element header
            address wallet;
            (wallet, pos) = _decodeAddress(pos);
            uint64 share;
            (share, pos) = _decodeCborUint64(pos);
            shares[i] = Share({wallet: wallet, share: FixedU18.wrap(share)});
        }
        newPos = pos;
    }

    function _decodeRegisterStreamParams(bytes calldata params)
        private
        pure
        returns (uint64 id, WeightRecord memory record, address writer, Share[] memory shares, uint64 activationEpoch)
    {
        // [id, record, [writer, shares]|null, activationEpoch]. A stream's kind is not on the
        // wire: a present distribution is exactly what makes it explicit.
        uint256 pos = _calldataPos(params) + 1; // 4-element tuple header
        (id, pos) = _decodeCborUint64(pos);
        pos += 1; // the record's own 5-element header
        (record, pos) = _decodeWeightRecord(pos);
        if (_isNull(pos)) {
            pos += 1;
            shares = new Share[](0);
        } else {
            pos += 1; // the distribution's 2-element header
            (writer, pos) = _decodeAddress(pos);
            (shares, pos) = _decodeShares(pos);
        }
        (activationEpoch, pos) = _decodeCborUint64(pos);
    }

    function _decodeSetDistributionParams(bytes calldata params) private pure returns (uint64 id, address writer) {
        uint256 pos = _calldataPos(params) + 1; // 2-element tuple header
        (id, pos) = _decodeCborUint64(pos);
        (writer, pos) = _decodeAddress(pos);
    }

    function _decodeCancelPendingParams(bytes calldata params)
        private
        pure
        returns (bool hasId, uint64 id, PendingOp op)
    {
        // [id|null, op]. The two weight operations occupy one schedule-wide slot each and are
        // addressed with a null id; every other operation names its stream.
        uint256 pos = _calldataPos(params) + 1; // 2-element tuple header
        if (_isNull(pos)) {
            pos += 1;
        } else {
            hasId = true;
            (id, pos) = _decodeCborUint64(pos);
        }
        uint64 opOrdinal;
        (opOrdinal, pos) = _decodeCborUint64(pos);
        op = PendingOp(opOrdinal);
    }

    function _decodeClaimParams(bytes calldata params) private pure returns (uint64 id, address[] memory wallets) {
        uint256 pos = _calldataPos(params) + 1; // skip the top-level 2-element array header
        (id, pos) = _decodeCborUint64(pos);
        uint256 count;
        (count, pos) = _decodeCborArrayHeader(pos);
        wallets = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            (wallets[i], pos) = _decodeAddress(pos);
        }
    }

    /// @dev Bare CBOR uint64 (no array wrapper), e.g. RemoveStream's single streamId param.
    function _decodeWeightRecord(uint256 pos) private pure returns (WeightRecord memory record, uint256 newPos) {
        int256 vStart;
        int256 slope;
        uint64 tStart;
        int256 floor;
        int256 cap;
        (vStart, pos) = _decodeCborInt64(pos);
        (slope, pos) = _decodeCborInt64(pos);
        (tStart, pos) = _decodeCborUint64(pos);
        (floor, pos) = _decodeCborInt64(pos);
        (cap, pos) = _decodeCborInt64(pos);
        record = WeightRecord({vStart: vStart, slope: slope, tStart: Epoch.wrap(tStart), floor: floor, cap: cap});
        newPos = pos;
    }

    /// @dev The absolute calldata byte position of a calldata bytes value's content.
    function _calldataPos(bytes calldata data) private pure returns (uint256 pos) {
        assembly ("memory-safe") {
            pos := data.offset
        }
    }

    /// @dev Decodes a CBOR unsigned integer (major type 0) at absolute calldata position `pos`;
    /// also reused for array-length header counts (major type 4), since both encode their value
    /// the same way in the low 5 info bits. One `calldataload`, then shifts extract the width
    /// the info byte calls for -- no per-byte reads.
    function _decodeCborUint64(uint256 pos) private pure returns (uint64 v, uint256 newPos) {
        assembly ("memory-safe") {
            let w := calldataload(pos)
            let info := and(byte(0, w), 0x1f)
            let data := shl(8, w) // drop the header byte; field bytes now sit at the MSB end
            switch lt(info, 24)
            case 1 {
                v := info
                newPos := add(pos, 1)
            }
            default {
                switch info
                case 24 {
                    v := shr(248, data)
                    newPos := add(pos, 2)
                }
                case 25 {
                    v := shr(240, data)
                    newPos := add(pos, 3)
                }
                case 26 {
                    v := shr(224, data)
                    newPos := add(pos, 5)
                }
                default {
                    // info == 27
                    v := shr(192, data)
                    newPos := add(pos, 9)
                }
            }
        }
    }

    function _decodeCborArrayHeader(uint256 pos) private pure returns (uint256 count, uint256 newPos) {
        (uint64 c, uint256 np) = _decodeCborUint64(pos);
        return (c, np);
    }

    /// @dev Decodes a CBOR signed integer (major type 0 or 1) at absolute calldata position
    /// `pos`; the value fits int256 regardless of major type, since a CBOR-major-1 int64's
    /// magnitude is itself at most a uint64.
    function _decodeCborInt64(uint256 pos) private pure returns (int256 v, uint256 newPos) {
        uint256 major;
        assembly ("memory-safe") {
            major := shr(5, byte(0, calldataload(pos)))
        }
        uint64 magnitude;
        (magnitude, newPos) = _decodeCborUint64(pos);
        v = major == 0 ? int256(uint256(magnitude)) : -1 - int256(uint256(magnitude));
    }

    /// @dev A Filecoin address from its CBOR byte string, in either form a contract can hold.
    ///
    /// Protocol 0 (a zero byte then the actor id as an unsigned LEB128 varint) becomes the masked
    /// ID address, which is how the EVM names a Filecoin-native actor such as f099. Protocol 4
    /// with the EAM namespace carries the twenty address bytes directly. Any other protocol is a
    /// form no contract can name, so it decodes to the zero address and the caller rejects it.
    function _decodeAddress(uint256 pos) private pure returns (address addr, uint256 newPos) {
        uint256 len;
        (len, pos) = _decodeCborByteStringHeader(pos);
        uint256 protocol;
        assembly ("memory-safe") {
            protocol := byte(0, calldataload(pos))
        }

        if (protocol == 0) {
            uint256 id;
            uint256 shift;
            for (uint256 i = 1; i < len; i++) {
                uint256 b;
                assembly ("memory-safe") {
                    b := byte(0, calldataload(add(pos, i)))
                }
                id |= (b & 0x7f) << shift;
                shift += 7;
            }
            addr = address(uint160((uint256(0xff) << 152) | id));
        } else if (protocol == 4 && len == 22) {
            assembly ("memory-safe") {
                addr := shr(96, calldataload(add(pos, 2)))
            }
        }
        newPos = pos + len;
    }

    function _isNull(uint256 pos) private pure returns (bool isNull) {
        assembly ("memory-safe") {
            isNull := eq(byte(0, calldataload(pos)), 0xf6)
        }
    }

    function _decodeCborByteStringHeader(uint256 pos) private pure returns (uint256 len, uint256 newPos) {
        uint256 info;
        assembly ("memory-safe") {
            info := and(byte(0, calldataload(pos)), 0x1f)
        }
        if (info < 24) return (info, pos + 1);
        assembly ("memory-safe") {
            len := byte(0, calldataload(add(pos, 1)))
        }
        newPos = pos + 2;
    }

    /// @dev Writes a CBOR array(count) header at absolute memory position `pos`; returns the new
    /// position. `pos` is a raw pointer (like a calldata `.offset`), not an index into a `bytes
    /// memory` -- callers compute it once from their buffer instead of passing the buffer itself,
    /// so every write is a direct `mstore8` rather than a bounds-checked `bytes memory` index.
    function _writeCborArrayHeader(uint256 pos, uint256 count) private pure returns (uint256 newPos) {
        assembly ("memory-safe") {
            switch lt(count, 24)
            case 1 {
                mstore8(pos, or(0x80, count))
                newPos := add(pos, 1)
            }
            default {
                switch lt(count, 0x100)
                case 1 {
                    mstore8(pos, 0x98)
                    mstore8(add(pos, 1), count)
                    newPos := add(pos, 2)
                }
                default {
                    mstore8(pos, 0x99)
                    mstore8(add(pos, 1), shr(8, count))
                    mstore8(add(pos, 2), count)
                    newPos := add(pos, 3)
                }
            }
        }
    }

    /// @dev The minimal big-endian encoding length of `value` (no leading zero byte); `value` is nonzero.
    function _bigEndianLen(uint256 value) private pure returns (uint256 len) {
        len = 32;
        bytes32 full = bytes32(value);
        while (full[32 - len] == 0) {
            len--;
        }
    }

    /// @dev Writes `value`'s Filecoin BigInt CBOR encoding (a CBOR byte string containing a sign
    /// byte -- 0x00, since entitlements are never negative -- followed by the minimal big-endian
    /// magnitude; zero is the empty byte string, matching go-state-types' big.Int
    /// (de)serialization) at absolute memory position `pos`; returns the new position.
    function _writeCborBigInt(uint256 pos, uint256 value) private pure returns (uint256 newPos) {
        if (value == 0) {
            assembly ("memory-safe") {
                mstore8(pos, 0x40)
                newPos := add(pos, 1)
            }
            return newPos;
        }
        uint256 magLen = _bigEndianLen(value);
        uint256 contentLen = magLen + 1;
        assembly ("memory-safe") {
            let p := pos
            switch lt(contentLen, 24)
            case 1 {
                mstore8(p, or(0x40, contentLen))
                p := add(p, 1)
            }
            default {
                mstore8(p, 0x58)
                mstore8(add(p, 1), contentLen)
                p := add(p, 2)
            }
            mstore8(p, 0) // sign byte: positive
            p := add(p, 1)
            // Magnitude, big-endian, right-aligned in `value`; the mstore's trailing bytes past
            // magLen spill into the buffer's over-allocated slack (see below) and are harmless.
            mstore(p, shl(shl(3, sub(32, magLen)), value))
            newPos := add(p, magLen)
        }
    }

    /// @dev Claims the free memory pointer directly rather than `new bytes(...)`, since the exact
    /// length isn't known until after writing: `new bytes(worstCase)` would permanently bump the
    /// free pointer past memory this array never ends up using (memory is never freed), forcing
    /// every later allocation in the call to sit -- and pay expansion gas -- past that unused
    /// stretch regardless. Writing before the free pointer is moved, then moving it to the real
    /// (32-rounded) size afterward, is the standard memory-safe manual-allocation pattern: only
    /// memory at-or-past the free pointer at the time of each write is ever touched.
    function _encodeCborBigIntArray(uint256[] memory values) private pure returns (bytes memory out) {
        uint256 n = values.length;
        uint256 dataStart;
        assembly ("memory-safe") {
            out := mload(0x40)
            dataStart := add(out, 0x20)
        }
        // ClaimReturn is a single-field tuple, so the amounts array sits inside a 1-element array.
        uint256 pos = _writeCborArrayHeader(dataStart, 1);
        pos = _writeCborArrayHeader(pos, n);
        for (uint256 i = 0; i < n; i++) {
            pos = _writeCborBigInt(pos, values[i]);
        }
        uint256 actualLen = pos - dataStart;
        assembly ("memory-safe") {
            mstore(out, actualLen)
            mstore(0x40, add(dataStart, and(add(actualLen, 0x1f), not(0x1f))))
        }
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @dev clamp(v_start + slope * (e - t_start), floor, cap).
    function _clampWeight(WeightRecord memory w, uint64 e) internal pure returns (int256 weight) {
        int256 raw = w.vStart + w.slope * (int256(uint256(e)) - int256(uint256(Epoch.unwrap(w.tStart))));
        weight = raw < w.floor ? w.floor : (raw > w.cap ? w.cap : raw);
    }

    /// @dev Per-record sanity required at write time: 0 <= floor <= cap <= 1.
    /// @dev validate_weight_record: floor <= v_start <= cap <= DENOM. The lower bound on floor
    /// is implicit in f02, where these three are u64; here they are signed and it is not.
    /// @dev validate_shares: at most MAX_RECIPIENTS rows, every share nonzero, no repeated
    /// payee, and the whole wire map summing to one. Repeated burn instructions are equivalent.
    function _sharesValid(Share[] memory shares) internal pure returns (bool) {
        if (shares.length > MAX_RECIPIENTS) return false;
        uint256 total;
        for (uint256 i = 0; i < shares.length; i++) {
            if (FixedU18.unwrap(shares[i].share) == 0) return false;
            if (shares[i].wallet != BURN_ADDRESS) {
                for (uint256 j = 0; j < i; j++) {
                    if (shares[j].wallet == shares[i].wallet) return false;
                }
            }
            total += FixedU18.unwrap(shares[i].share);
        }
        return total == SHARE_TOTAL;
    }

    function _sane(WeightRecord memory w) internal pure returns (bool) {
        return w.floor >= 0 && w.floor <= w.cap && w.cap <= WAD && w.vStart >= w.floor && w.vStart <= w.cap;
    }

    // -------------------------------------------------------------------------
    // Projected-schedule validation
    //
    // A queued write is admitted by walking the queue in effective-epoch order, applying each
    // entry to a candidate state and checking the schedule from that entry's effective epoch.
    // Entries that fail are dropped. The write is refused if it fails in its own position, or if
    // the walk accepts fewer slots than it did without it.
    //
    // Not modelled: f02 lets SetWeightRecords repair a settled schedule that does not validate.
    // The mock cannot install one, so that path is unreachable.
    // -------------------------------------------------------------------------

    /// @dev A stream as the projection sees it: only what the schedule check reads.
    struct ProjectedStream {
        uint64 id;
        WeightRecord record;
    }

    /// @dev The write under consideration, spliced into the queue at its effective epoch.
    struct NewWrite {
        bool present;
        bool hasId;
        uint64 id;
        PendingOp op;
        uint64 effectiveEpoch;
        WeightRecord record; // REGISTER
        uint64[] batchIds; // SET_WEIGHT / STEP_WEIGHT
        WeightRecord[] batchRecords;
    }

    /// @dev Epochs where the weight sum can peak from `fromEpoch` on. Clamped linears peak on a
    /// kink or at the end, so this yields each record's anchor, its clamp crossings and the last
    /// epoch. Crossings carry neighbours either side, since integer division lands off the kink.
    function _breakpoints(WeightRecord memory r, uint64 fromEpoch, uint64[] memory out, uint256 c)
        private
        pure
        returns (uint256)
    {
        if (Epoch.unwrap(r.tStart) >= fromEpoch) out[c++] = Epoch.unwrap(r.tStart);
        if (r.slope == 0) return c;

        c = _crossing(r, r.slope > 0 ? r.cap : r.floor, fromEpoch, out, c);
        // The opposite bound is only crossed going forward when validation starts before the anchor.
        if (fromEpoch < Epoch.unwrap(r.tStart)) c = _crossing(r, r.slope > 0 ? r.floor : r.cap, fromEpoch, out, c);
        return c;
    }

    function _crossing(WeightRecord memory r, int256 bound, uint64 fromEpoch, uint64[] memory out, uint256 c)
        private
        pure
        returns (uint256)
    {
        int256 base = int256(uint256(Epoch.unwrap(r.tStart))) + (bound - r.vStart) / r.slope;
        for (int256 off = -1; off <= 1; off++) {
            int256 e = base + off;
            if (e >= int256(uint256(fromEpoch)) && e <= int256(uint256(type(uint64).max))) {
                out[c++] = uint64(uint256(e));
            }
        }
        return c;
    }

    /// @dev Whether the streams sum to at most one at every epoch from `fromEpoch` onward.
    function _scheduleValid(ProjectedStream[] memory live, uint256 n, uint64 fromEpoch) private pure returns (bool) {
        uint64[] memory epochs = new uint64[](n * 7 + 2);
        uint256 c = 0;
        epochs[c++] = fromEpoch;
        epochs[c++] = type(uint64).max;
        for (uint256 i = 0; i < n; i++) {
            c = _breakpoints(live[i].record, fromEpoch, epochs, c);
        }
        for (uint256 e = 0; e < c; e++) {
            int256 sum;
            for (uint256 i = 0; i < n; i++) {
                sum += _clampWeight(live[i].record, epochs[e]);
            }
            if (sum > WAD) return false;
        }
        return true;
    }

    function _settledProjection() private view returns (ProjectedStream[] memory live, uint256 n) {
        live = new ProjectedStream[](_streamIds.length + _pendingKeys.length + 2);
        n = _streamIds.length;
        for (uint256 i = 0; i < n; i++) {
            live[i] = ProjectedStream({id: _streamIds[i], record: _streams[_streamIds[i]].weightRecord});
        }
    }

    function _copy(ProjectedStream[] memory live, uint256 n) private pure returns (ProjectedStream[] memory out) {
        out = new ProjectedStream[](live.length);
        for (uint256 i = 0; i < n; i++) {
            out[i] = ProjectedStream({id: live[i].id, record: live[i].record});
        }
    }

    uint256 private constant NEW_ENTRY = type(uint256).max;

    /// @dev Applies one queued write to a copy of the projection. False when it cannot apply,
    /// which is how a weight batch naming an already-removed stream drops.
    function _applyToProjection(ProjectedStream[] memory live, uint256 n, uint256 idx, NewWrite memory nw)
        private
        view
        returns (ProjectedStream[] memory out, uint256 count, bool ok)
    {
        out = _copy(live, n);
        count = n;

        bool isNew = idx == NEW_ENTRY;
        PendingOp op = isNew ? nw.op : _pendingKeys[idx].op;
        uint64 id = isNew ? nw.id : _pendingKeys[idx].id;

        if (op == PendingOp.REGISTER) {
            WeightRecord memory rec = isNew ? nw.record : _pending[id][PendingOp.REGISTER].weightRecord;
            out[count++] = ProjectedStream({id: id, record: rec});
            return (out, count, true);
        }
        if (op == PendingOp.REMOVE) {
            for (uint256 i = 0; i < count; i++) {
                if (out[i].id != id) continue;
                out[i] = out[count - 1];
                return (out, count - 1, true);
            }
            return (out, count, false); // nothing left to remove
        }
        if (op == PendingOp.SET_DISTRIBUTION) {
            return (out, count, true); // no effect on the schedule
        }

        uint64[] memory ids = isNew ? nw.batchIds : _pendingWeight[op].ids;
        WeightRecord[] memory records;
        if (isNew) {
            records = nw.batchRecords;
        } else {
            records = new WeightRecord[](ids.length);
            for (uint256 i = 0; i < ids.length; i++) {
                records[i] = _pendingWeight[op].records[i];
            }
        }
        for (uint256 i = 0; i < ids.length; i++) {
            bool found;
            for (uint256 j = 0; j < count; j++) {
                if (out[j].id != ids[i]) continue;
                out[j].record = records[i];
                found = true;
                break;
            }
            if (!found) return (out, count, false);
        }
        return (out, count, true);
    }

    function _entryEpoch(uint256 idx, NewWrite memory nw) private view returns (uint64) {
        if (idx == NEW_ENTRY) return nw.effectiveEpoch;
        PendingKey memory k = _pendingKeys[idx];
        return k.hasId ? _pending[k.id][k.op].effectiveEpoch : _pendingWeight[k.op].effectiveEpoch;
    }

    /// @dev By effective epoch; a write queued now sorts last among equal epochs, as f02's
    /// push-then-stable-sort does.
    function _orderQueue(NewWrite memory nw) private view returns (uint256[] memory order) {
        uint256 total = _pendingKeys.length + (nw.present ? 1 : 0);
        order = new uint256[](total);
        for (uint256 i = 0; i < _pendingKeys.length; i++) {
            order[i] = i;
        }
        if (nw.present) order[total - 1] = NEW_ENTRY;

        for (uint256 i = 1; i < total; i++) {
            uint256 cur = order[i];
            uint64 e = _entryEpoch(cur, nw);
            uint256 j = i;
            while (j > 0 && _entryEpoch(order[j - 1], nw) > e) {
                order[j] = order[j - 1];
                j--;
            }
            order[j] = cur;
        }
    }

    function _keyOf(uint256 idx, NewWrite memory nw) private view returns (uint256) {
        if (idx == NEW_ENTRY) return _slotKey(nw.hasId, nw.id, nw.op);
        PendingKey memory k = _pendingKeys[idx];
        return _slotKey(k.hasId, k.id, k.op);
    }

    /// @dev Walks the queue, dropping entries that no longer validate, and reports what survived.
    function _walk(NewWrite memory nw)
        private
        view
        returns (uint256[] memory accepted, uint256 count, bool newAccepted)
    {
        uint256[] memory order = _orderQueue(nw);
        accepted = new uint256[](order.length);

        (ProjectedStream[] memory live, uint256 n) = _settledProjection();
        if (!_scheduleValid(live, n, uint64(block.number))) return (accepted, 0, false);

        for (uint256 i = 0; i < order.length; i++) {
            (ProjectedStream[] memory candidate, uint256 cn, bool ok) = _applyToProjection(live, n, order[i], nw);
            if (!ok || !_scheduleValid(candidate, cn, _entryEpoch(order[i], nw))) continue;
            live = candidate;
            n = cn;
            accepted[count++] = _keyOf(order[i], nw);
            if (order[i] == NEW_ENTRY) newAccepted = true;
        }
    }

    /// @dev Whether a due write still holds against the settled state it is about to change.
    function _stillValid(uint256 idx, uint64 nowEpoch) private view returns (bool) {
        NewWrite memory none;
        (ProjectedStream[] memory live, uint256 n) = _settledProjection();
        (ProjectedStream[] memory candidate, uint256 cn, bool ok) = _applyToProjection(live, n, idx, none);
        return ok && _scheduleValid(candidate, cn, nowEpoch);
    }

    /// @dev Whether f02 admits this write: it must survive its own position, and cost no
    /// surviving entry its place.
    function _admits(NewWrite memory nw) private view returns (bool) {
        NewWrite memory none;
        (uint256[] memory before, uint256 bn,) = _walk(none);
        (uint256[] memory later, uint256 ln, bool newAccepted) = _walk(nw);
        if (!newAccepted) return false;
        for (uint256 i = 0; i < bn; i++) {
            bool kept;
            for (uint256 j = 0; j < ln; j++) {
                if (later[j] != before[i]) continue;
                kept = true;
                break;
            }
            if (!kept) return false;
        }
        return true;
    }

    /// @dev Encodes a queue slot so the two walks' accepted sets can be compared.
    function _slotKey(bool hasId, uint64 id, PendingOp op) private pure returns (uint256) {
        return hasId ? (uint256(id) << 8) | uint256(op) : (uint256(1) << 72) | uint256(op);
    }

    function _pendingRegistrationCount() internal view returns (uint256 count) {
        for (uint256 i = 0; i < _pendingKeys.length; i++) {
            if (_pendingKeys[i].op == PendingOp.REGISTER) count++;
        }
    }

    function _shareOf(Stream storage s, address wallet) internal view returns (uint256) {
        for (uint256 i = 0; i < s.shares.length; i++) {
            if (s.shares[i].wallet == wallet) return FixedU18.unwrap(s.shares[i].share);
        }
        return 0;
    }

    function _storedShareTotal(Stream storage s) internal view returns (uint256 total) {
        for (uint256 i = 0; i < s.shares.length; i++) {
            total += FixedU18.unwrap(s.shares[i].share);
        }
    }

    function _pushNonBurnShares(Share[] storage target, Share[] memory shares) internal {
        for (uint256 i = 0; i < shares.length; i++) {
            if (shares[i].wallet != BURN_ADDRESS) target.push(shares[i]);
        }
    }

    /// @dev Closes out the current period: each recipient's earned-minus-claimed amount moves
    /// into `payable` under the OLD map, the rounding residue burns, and accrual state resets.
    function _foldAndBurnResidue(Stream storage s) internal {
        uint256 pool = s.accrued;
        uint256 shareTotal = _storedShareTotal(s);
        uint256 earnedSum;
        for (uint256 i = 0; i < s.shares.length; i++) {
            address wallet = s.shares[i].wallet;
            uint256 earned = (FixedU18.unwrap(s.shares[i].share) * pool) / shareTotal;
            earnedSum += earned;
            uint256 claimed = s.claimedPeriod.amount[wallet];
            if (earned > claimed) {
                _ledgerIncrement(s.payableLedger, wallet, earned - claimed);
            }
        }
        uint256 residue = pool - earnedSum;
        s.accrued = 0;
        _ledgerClearAll(s.claimedPeriod);

        if (residue > 0) {
            FVMPay.burn(residue);
            totalBurnMinted += residue;
        }
    }

    function _queueWrite(uint64 id, PendingOp op, Pending memory p) internal {
        _pending[id][op] = p;
        _pendingExists[id][op] = true;
        _pendingKeys.push(PendingKey({hasId: true, id: id, op: op}));
        if (p.effectiveEpoch < nextTransitionEpoch) nextTransitionEpoch = p.effectiveEpoch;
    }

    function _removePendingKey(bool hasId, uint64 id, PendingOp op) internal {
        for (uint256 i = 0; i < _pendingKeys.length; i++) {
            if (_pendingKeys[i].hasId == hasId && _pendingKeys[i].id == id && _pendingKeys[i].op == op) {
                _swapRemove(_pendingKeys, i);
                return;
            }
        }
    }

    /// @dev Remove index `i` by swapping in the last element; order is not preserved.
    function _swapRemove(PendingKey[] storage arr, uint256 i) internal {
        arr[i] = arr[arr.length - 1];
        arr.pop();
    }

    /// @dev Remove index `i` by swapping in the last element; order is not preserved.
    function _swapRemove(uint64[] storage arr, uint256 i) internal {
        arr[i] = arr[arr.length - 1];
        arr.pop();
    }

    function _recomputeNextTransition() internal {
        uint64 best = type(uint64).max;
        for (uint256 i = 0; i < _pendingKeys.length; i++) {
            PendingKey memory k = _pendingKeys[i];
            uint64 e = k.hasId ? _pending[k.id][k.op].effectiveEpoch : _pendingWeight[k.op].effectiveEpoch;
            if (e < best) best = e;
        }
        nextTransitionEpoch = best;
    }

    function _removeTombstoneId(uint64 id) internal {
        for (uint256 i = 0; i < _tombstoneIds.length; i++) {
            if (_tombstoneIds[i] == id) {
                _swapRemove(_tombstoneIds, i);
                return;
            }
        }
    }

    function _removeStreamId(uint64 id) internal {
        for (uint256 i = 0; i < _streamIds.length; i++) {
            if (_streamIds[i] == id) {
                _swapRemove(_streamIds, i);
                return;
            }
        }
    }

    function _ledgerIncrement(Ledger storage l, address wallet, uint256 delta) internal {
        if (delta == 0) return;
        if (l.indexPlusOne[wallet] == 0) {
            l.wallets.push(wallet);
            l.indexPlusOne[wallet] = l.wallets.length;
        }
        l.amount[wallet] += delta;
    }

    function _ledgerRemove(Ledger storage l, address wallet) internal {
        uint256 idx1 = l.indexPlusOne[wallet];
        if (idx1 == 0) return;
        uint256 lastIdx = l.wallets.length - 1;
        address lastWallet = l.wallets[lastIdx];
        l.wallets[idx1 - 1] = lastWallet;
        l.indexPlusOne[lastWallet] = idx1;
        l.wallets.pop();
        delete l.indexPlusOne[wallet];
        delete l.amount[wallet];
    }

    /// @dev Explicit teardown of both mappings: `delete` on a struct doesn't recurse into
    /// mapping members, so a later id-reuse could otherwise resurface stale entries.
    function _ledgerClearAll(Ledger storage l) internal {
        uint256 n = l.wallets.length;
        for (uint256 i = 0; i < n; i++) {
            address wallet = l.wallets[i];
            delete l.amount[wallet];
            delete l.indexPlusOne[wallet];
        }
        delete l.wallets;
    }

    function _ledgerView(Ledger storage l) internal view returns (LedgerRow[] memory rows) {
        rows = new LedgerRow[](l.wallets.length);
        for (uint256 i = 0; i < l.wallets.length; i++) {
            rows[i] = LedgerRow({wallet: l.wallets[i], amount: l.amount[l.wallets[i]]});
        }
    }

    /// @dev Applies every queued write whose effectiveEpoch has arrived, in (effectiveEpoch, id) order.
    function _settle() internal {
        uint64 nowEpoch = uint64(block.number);
        while (true) {
            bool found = false;
            uint256 bestIdx = 0;
            uint64 bestEpoch = 0;
            uint64 bestId = 0;
            for (uint256 i = 0; i < _pendingKeys.length; i++) {
                PendingKey memory k = _pendingKeys[i];
                uint64 e = k.hasId ? _pending[k.id][k.op].effectiveEpoch : _pendingWeight[k.op].effectiveEpoch;
                if (e > nowEpoch) continue;
                if (!found || e < bestEpoch || (e == bestEpoch && k.id < bestId)) {
                    found = true;
                    bestIdx = i;
                    bestEpoch = e;
                    bestId = k.id;
                }
            }
            if (!found) break;

            PendingKey memory key = _pendingKeys[bestIdx];
            // Admission checked this write against the queue as it stood then. A cancellation since
            // can have taken away what it depended on, so it is checked again here and dropped if
            // it no longer holds.
            if (!_stillValid(bestIdx, nowEpoch)) {
                emit PendingDropped(key.id, key.op);
                if (key.hasId) {
                    delete _pending[key.id][key.op];
                    _pendingExists[key.id][key.op] = false;
                    delete _pendingShares[key.id];
                } else {
                    delete _pendingWeight[key.op];
                    _pendingWeightExists[key.op] = false;
                }
                _pendingKeys[bestIdx] = _pendingKeys[_pendingKeys.length - 1];
                _pendingKeys.pop();
                continue;
            }
            if (key.hasId) {
                _apply(key.id, key.op);
                delete _pending[key.id][key.op];
                _pendingExists[key.id][key.op] = false;
            } else {
                _applyWeightBatch(key.op);
            }
            _pendingKeys[bestIdx] = _pendingKeys[_pendingKeys.length - 1];
            _pendingKeys.pop();
        }
        _recomputeNextTransition();
    }

    function _apply(uint64 id, PendingOp op) internal {
        Pending storage p = _pending[id][op];
        if (op == PendingOp.REGISTER) {
            Stream storage s = _streams[id];
            s.exists = true;
            s.weightRecord = p.weightRecord;
            s.kind = p.distributionKind;
            s.writer = p.writer;
            Share[] storage initial = _pendingShares[id];
            for (uint256 i = 0; i < initial.length; i++) {
                s.shares.push(initial[i]);
            }
            delete _pendingShares[id];
            _streamIds.push(id);
        } else if (op == PendingOp.SET_DISTRIBUTION) {
            Stream storage s = _streams[id];
            _foldAndBurnResidue(s);
            s.writer = p.writer;
        } else if (op == PendingOp.REMOVE) {
            _applyRemove(id);
        }
    }

    /// @dev A weight batch applies as one unit: every record in it lands, or the whole entry is
    /// still queued. That is what makes the slot schedule-wide rather than per stream.
    function _applyWeightBatch(PendingOp op) internal {
        WeightBatch storage batch = _pendingWeight[op];
        for (uint256 i = 0; i < batch.ids.length; i++) {
            _streams[batch.ids[i]].weightRecord = batch.records[i];
        }
        delete _pendingWeight[op];
        _pendingWeightExists[op] = false;
    }

    function _applyRemove(uint64 id) internal {
        Stream storage s = _streams[id];
        _foldAndBurnResidue(s);

        if (s.payableLedger.wallets.length > 0) {
            Tombstone storage t = _tombstones[id];
            t.exists = true;
            uint256 n = s.payableLedger.wallets.length;
            for (uint256 i = 0; i < n; i++) {
                address wallet = s.payableLedger.wallets[i];
                _ledgerIncrement(t.payableLedger, wallet, s.payableLedger.amount[wallet]);
            }
            _tombstoneIds.push(id);
        }
        _ledgerClearAll(s.payableLedger);

        delete _streams[id];
        _removeStreamId(id);
    }
}
