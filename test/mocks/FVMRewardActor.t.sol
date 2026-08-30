// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {REWARD_ACTOR_ID, REWARD_ACTOR_ADDRESS, BURN_ACTOR_ID, BURN_ADDRESS} from "fvm-solidity/FVMActors.sol";
import {CALL_ACTOR_BY_ID} from "fvm-solidity/FVMPrecompiles.sol";
import {NO_FLAGS} from "fvm-solidity/FVMFlags.sol";
import {USR_FORBIDDEN, USR_ILLEGAL_ARGUMENT, USR_NOT_FOUND, USR_UNHANDLED_MESSAGE} from "fvm-solidity/FVMErrors.sol";
import {FVMPay} from "fvm-solidity/FVMPay.sol";
import {FVMMiner} from "fvm-solidity/FVMMiner.sol";

import {MockRewardTest} from "./MockRewardTest.sol";
import {
    WeightRecord,
    DistributionKind,
    Share,
    LedgerRow,
    PendingOp,
    StreamView,
    TombstoneView,
    MockState,
    WAD,
    MAX_STREAMS,
    MAX_RECIPIENTS,
    SHARE_TOTAL
} from "./FVMRewardActor.sol";
import {CLAIM, SWA_TIMELOCK} from "../../src/lib/FVMRewardMethod.sol";
import {FVMRewards} from "../../src/lib/FVMRewards.sol";
import {WeightRecordUpdate} from "../../src/lib/FVMRewardTypes.sol";
import {Epoch} from "../../src/lib/Epoch.sol";
import {FixedU18} from "../../src/lib/FixedU18.sol";

/// @dev A distinct external caller, so tests can check authorization by identity rather than
/// by happenstance of who the test contract is. The typed methods below go through FVMRewards
/// itself (production code, not a hand-rolled duplicate encoder) so these tests double as
/// FVMRewards<->mock wire-format coverage. `call` serves tests that send malformed params on
/// purpose.
contract RewardCaller {
    function call(uint64 method, bytes memory params) external returns (uint32 exitCode, bytes memory data) {
        bytes memory callData = abi.encode(method, uint256(0), NO_FLAGS, uint64(0), params, REWARD_ACTOR_ID);
        (bool success, bytes memory ret) = CALL_ACTOR_BY_ID.delegatecall(callData);
        require(success, "RewardCaller: precompile call failed");
        (exitCode,, data) = abi.decode(ret, (uint32, uint64, bytes));
    }

    function registerStream(uint64 id, WeightRecord memory record, uint64 activationEpoch)
        external
        returns (uint32 exitCode)
    {
        exitCode = uint32(uint256(FVMRewards.tryRegisterStream(id, record, activationEpoch)));
    }

    function registerStream(
        uint64 id,
        WeightRecord memory record,
        address writer,
        Share[] memory shares,
        uint64 activationEpoch
    ) external returns (uint32 exitCode) {
        exitCode = uint32(uint256(FVMRewards.tryRegisterStream(id, record, writer, shares, activationEpoch)));
    }

    function removeStream(uint64 id) external returns (uint32 exitCode) {
        exitCode = uint32(uint256(FVMRewards.tryRemoveStream(id)));
    }

    function setWeightRecords(WeightRecordUpdate[] memory updates) external returns (uint32 exitCode) {
        exitCode = uint32(uint256(FVMRewards.trySetWeightRecords(updates)));
    }

    function stepWeightRecords(WeightRecordUpdate[] memory updates) external returns (uint32 exitCode) {
        exitCode = uint32(uint256(FVMRewards.tryStepWeightRecords(updates)));
    }

    function setDistribution(uint64 id, address writer) external returns (uint32 exitCode) {
        exitCode = uint32(uint256(FVMRewards.trySetDistribution(id, writer)));
    }

    function cancelPending(uint64 id, PendingOp op) external returns (uint32 exitCode) {
        exitCode = uint32(uint256(FVMRewards.tryCancelPending(id, op)));
    }

    function cancelPendingWeight(PendingOp op) external returns (uint32 exitCode) {
        exitCode = uint32(uint256(FVMRewards.tryCancelPendingWeight(op)));
    }

    function setShares(uint64 id, Share[] memory shares) external returns (uint32 exitCode) {
        exitCode = uint32(uint256(FVMRewards.trySetShares(id, shares)));
    }

    function claim(uint64 id, address[] memory wallets) external returns (uint32 exitCode, uint256[] memory amounts) {
        int256 rawExitCode;
        (rawExitCode, amounts) = FVMRewards.tryClaim(id, wallets);
        exitCode = uint32(uint256(rawExitCode));
    }
}

contract FVMRewardActorTest is MockRewardTest {
    using FVMPay for uint64;

    event PendingDropped(uint64 indexed streamId, PendingOp op);

    RewardCaller swaCaller;
    RewardCaller writerCaller;
    RewardCaller otherWriterCaller;
    RewardCaller randomCaller;

    uint64 constant SERVICE_ID = 1;
    uint64 constant CONSENSUS_ID = 2;

    address constant RECIPIENT_A = address(0xBEEF);
    address constant RECIPIENT_B = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        swaCaller = new RewardCaller();
        writerCaller = new RewardCaller();
        otherWriterCaller = new RewardCaller();
        randomCaller = new RewardCaller();
        rewardActor().mockSwa(address(swaCaller));
    }

    // -------------------------------------------------------------------------
    // Call helpers
    // -------------------------------------------------------------------------

    function _call(uint64 method, bytes memory params) internal returns (uint32 exitCode, bytes memory data) {
        bytes memory callData = abi.encode(method, uint256(0), NO_FLAGS, uint64(0), params, REWARD_ACTOR_ID);
        (bool success, bytes memory ret) = CALL_ACTOR_BY_ID.delegatecall(callData);
        assertTrue(success, "precompile call failed");
        (exitCode,, data) = abi.decode(ret, (uint32, uint64, bytes));
    }

    function _record(int256 vStart, int256 slope, uint64 tStart, int256 floor, int256 cap)
        internal
        pure
        returns (WeightRecord memory)
    {
        return WeightRecord({vStart: vStart, slope: slope, tStart: Epoch.wrap(tStart), floor: floor, cap: cap});
    }

    /// @dev A record whose weight is the constant `w` at every epoch.
    function _constantRecord(int256 w) internal pure returns (WeightRecord memory) {
        return _record(w, 0, 0, 0, WAD);
    }

    /// @dev f02 requires an explicit stream to carry a valid share map at registration, so this
    /// supplies a placeholder. Tests that care about the map install their own.
    function _registerStream(uint64 id, WeightRecord memory record, DistributionKind kind, address writer)
        internal
        returns (uint32)
    {
        uint64 activation = uint64(block.number) + SWA_TIMELOCK;
        if (kind == DistributionKind.IMPLICIT) return swaCaller.registerStream(id, record, activation);
        return swaCaller.registerStream(id, record, writer, _shares(RECIPIENT_A, SHARE_TOTAL), activation);
    }

    /// @dev Bundles a single id/record into the batch SetWeightRecords takes.
    function _singleWeightRecord(uint64 id, WeightRecord memory record)
        internal
        pure
        returns (WeightRecordUpdate[] memory updates)
    {
        updates = new WeightRecordUpdate[](1);
        updates[0] = WeightRecordUpdate({id: id, record: record});
    }

    function _setWeightRecords(RewardCaller caller, uint64 id, WeightRecord memory record) internal returns (uint32) {
        return caller.setWeightRecords(_singleWeightRecord(id, record));
    }

    function _stepWeightRecords(RewardCaller caller, uint64 id, WeightRecord memory record) internal returns (uint32) {
        return caller.stepWeightRecords(_singleWeightRecord(id, record));
    }

    function _registerExplicit(uint64 id, address writer) internal {
        assertEq(_registerStream(id, _constantRecord(0.1e18), DistributionKind.EXPLICIT, writer), 0);
        _warpPastTimelockAndSettle();
    }

    function _warpPastTimelockAndSettle() internal {
        vm.roll(block.number + SWA_TIMELOCK);
        rewardActor().mockSettle();
    }

    /// @dev f02 has no read methods, so this reads the mock directly rather than dispatching.
    function _getState() internal view returns (MockState memory) {
        return rewardActor().mockState();
    }

    function _streams() internal view returns (StreamView[] memory) {
        return _getState().streams;
    }

    function _shares(address wallet, uint256 amount) internal pure returns (Share[] memory arr) {
        arr = new Share[](1);
        arr[0] = Share({wallet: wallet, share: FixedU18.wrap(amount)});
    }

    function _wallets(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    /// @dev Claim is permissionless, so this goes straight through FVMRewards rather than a
    /// RewardCaller identity.
    function _claim(uint64 id, address[] memory wallets_) internal returns (uint32 exitCode, uint256[] memory amounts) {
        int256 rawExitCode;
        (rawExitCode, amounts) = FVMRewards.tryClaim(id, wallets_);
        exitCode = uint32(uint256(rawExitCode));
    }

    function _payableRow(LedgerRow[] memory rows, address wallet) internal pure returns (uint256) {
        for (uint256 i = 0; i < rows.length; i++) {
            if (rows[i].wallet == wallet) return rows[i].amount;
        }
        return 0;
    }

    // The objection window is 7 days; epochs are 30s.
    function test_SwaTimelock_IsSevenDaysOfEpochs() public pure {
        assertEq(SWA_TIMELOCK, 7 * 24 * 60 * 60 / 30);
    }

    function test_SwaTimelockEpochs_DefaultsToConstant() public view {
        assertEq(rewardActor().swaTimelockEpochs(), SWA_TIMELOCK);
    }

    function test_MockSwaTimelockEpochs_Overrides() public {
        rewardActor().mockSwaTimelockEpochs(10);

        // _registerStream hardcodes SWA_TIMELOCK, not the override, so call directly with a
        // 10-epoch activation instead.
        uint32 exitCode = swaCaller.registerStream(SERVICE_ID, _constantRecord(0.1e18), uint64(block.number) + 10);
        assertEq(exitCode, 0);

        vm.roll(block.number + 10);
        rewardActor().mockSettle();
        assertEq(_streams().length, 1, "must settle after the overridden (short) hold");
    }

    // -------------------------------------------------------------------------
    // ClampWeight -- clamp(v_start + slope * (e - t_start), floor, cap). Not a dispatched
    // method; exposed directly.
    // -------------------------------------------------------------------------

    function _clampWeight(WeightRecord memory record, uint64 epoch) internal pure returns (int256) {
        return rewardActor().clampWeight(record, epoch);
    }

    function test_ClampWeight_AtTStart_ReturnsVStart() public pure {
        WeightRecord memory r = _record(0.95e18, -100, 1000, 0.5e18, 0.95e18);
        assertEq(_clampWeight(r, 1000), 0.95e18);
    }

    function test_ClampWeight_MidRamp_IsLinear() public pure {
        WeightRecord memory r = _record(0.95e18, -100, 1000, 0.5e18, 0.95e18);
        // 500 epochs after t_start: 0.95e18 - 100*500 = 0.95e18 - 50000
        assertEq(_clampWeight(r, 1500), 0.95e18 - 50_000);
    }

    function test_ClampWeight_PastFloor_ClampsToFloor() public pure {
        WeightRecord memory r = _record(0.95e18, -1e17, 1000, 0.5e18, 0.95e18);
        // 10 epochs after t_start at slope -1e17/epoch is already far past the 0.5e18 floor.
        assertEq(_clampWeight(r, 1010), 0.5e18);
    }

    function test_ClampWeight_BeforeTStart_ClampsToCap() public pure {
        // e < t_start with a negative slope means (e - t_start) < 0, so raw > v_start = cap.
        WeightRecord memory r = _record(0.95e18, -100, 1000, 0.5e18, 0.95e18);
        assertEq(_clampWeight(r, 0), 0.95e18);
    }

    function test_ClampWeight_ZeroSlope_IsConstant() public pure {
        WeightRecord memory r = _constantRecord(0.3e18);
        assertEq(_clampWeight(r, 0), 0.3e18);
        assertEq(_clampWeight(r, 1_000_000), 0.3e18);
    }

    function test_MockState_Empty_ReturnsNoStreams() public view {
        assertEq(_streams().length, 0);
    }

    function test_MockState_ReflectsRegisteredStream_WithMatchingWeight() public {
        WeightRecord memory r = _constantRecord(0.4e18);
        assertEq(_registerStream(SERVICE_ID, r, DistributionKind.EXPLICIT, address(writerCaller)), 0);
        _warpPastTimelockAndSettle();

        StreamView[] memory streams = _streams();
        assertEq(streams.length, 1);
        assertEq(streams[0].id, SERVICE_ID);
        assertEq(streams[0].weightRecord.vStart, r.vStart);
        assertEq(uint8(streams[0].kind), uint8(DistributionKind.EXPLICIT));
        assertEq(streams[0].writer, address(writerCaller));
        assertEq(streams[0].weight, _clampWeight(r, uint64(block.number)));
        assertEq(streams[0].accrued, 0);
    }

    function test_RegisterStream_NotSwa_Forbidden() public {
        uint32 exitCode =
            randomCaller.registerStream(SERVICE_ID, _constantRecord(0.1e18), uint64(block.number) + SWA_TIMELOCK);
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_RegisterStream_ActivationTooSoon_IllegalArgument() public {
        uint32 exitCode =
            swaCaller.registerStream(SERVICE_ID, _constantRecord(0.1e18), uint64(block.number) + SWA_TIMELOCK - 1);
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_RegisterStream_FloorAboveCap_IllegalArgument() public {
        WeightRecord memory r = _record(0.1e18, 0, 0, 0.6e18, 0.5e18);
        assertEq(_registerStream(SERVICE_ID, r, DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT);
    }

    function test_RegisterStream_CapAboveOne_IllegalArgument() public {
        WeightRecord memory r = _record(0.1e18, 0, 0, 0, WAD + 1);
        assertEq(_registerStream(SERVICE_ID, r, DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT);
    }

    // f02 declares floor, v_start and cap as u64, so a negative one cannot be encoded rather than
    // being sent and rejected. Solidity does not check narrowing casts, so the encoder does.
    function test_RegisterStream_FloorBelowZero_Reverts() public {
        WeightRecord memory r = _record(0.1e18, 0, 0, -1, WAD);
        vm.expectRevert(abi.encodeWithSelector(FVMRewards.ValueOutOfRange.selector, int256(-1)));
        swaCaller.registerStream(SERVICE_ID, r, uint64(block.number) + SWA_TIMELOCK);
    }

    // validate_weight_record pins v_start inside the clamp band. Outside it the record still
    // evaluates (compute_weight clamps) but its anchor claims a value the schedule can never take,
    // which makes the record's own numbers a lie about what it pays.
    function test_RegisterStream_VStartOutsideClampBand_IllegalArgument() public {
        WeightRecord memory below = _record(0.1e18, 0, 0, 0.2e18, 0.5e18);
        assertEq(_registerStream(SERVICE_ID, below, DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT);
        WeightRecord memory above = _record(0.6e18, 0, 0, 0.2e18, 0.5e18);
        assertEq(_registerStream(SERVICE_ID, above, DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT);
    }

    // f02 validates the initial map at registration, and an empty map does not sum to one. Named
    // for what it exercises: there is no "implicit with a writer" to test, since a stream is
    // implicit exactly when it carries no distribution.
    function test_RegisterStream_ExplicitWithEmptyShareMap_IllegalArgument() public {
        uint32 exitCode = swaCaller.registerStream(
            SERVICE_ID,
            _constantRecord(0.1e18),
            address(writerCaller),
            new Share[](0),
            uint64(block.number) + SWA_TIMELOCK
        );
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_RegisterStream_StripsBurnSentinels_AndFloorsSurvivorPool() public {
        uint256 third = SHARE_TOTAL / 3;
        Share[] memory shares_ = new Share[](4);
        shares_[0] = Share({wallet: RECIPIENT_A, share: FixedU18.wrap(third)});
        shares_[1] = Share({wallet: BURN_ADDRESS, share: FixedU18.wrap(third)});
        shares_[2] = Share({wallet: RECIPIENT_B, share: FixedU18.wrap(third)});
        shares_[3] = Share({wallet: BURN_ADDRESS, share: FixedU18.wrap(SHARE_TOTAL - third * 3)});

        uint32 exitCode = swaCaller.registerStream(
            SERVICE_ID, _constantRecord(WAD), address(writerCaller), shares_, uint64(block.number) + SWA_TIMELOCK
        );
        assertEq(exitCode, 0);
        _warpPastTimelockAndSettle();

        Share[] memory stored = rewardActor().getShares(SERVICE_ID);
        assertEq(stored.length, 2);
        assertEq(stored[0].wallet, RECIPIENT_A);
        assertEq(FixedU18.unwrap(stored[0].share), third);
        assertEq(stored[1].wallet, RECIPIENT_B);
        assertEq(FixedU18.unwrap(stored[1].share), third);

        (uint256 minerPortion, uint256 servicePortion, uint256 burnAmount) = rewardActor().mockAwardBlockReward(2);
        assertEq(minerPortion, 0);
        assertEq(servicePortion, 1, "floor the survivor pool before deriving burn");
        assertEq(burnAmount, 1);
        assertEq(_streams()[0].accrued, 1);
        assertEq(rewardActor().totalServiceMinted(), 1);
        assertEq(rewardActor().totalBurnMinted(), 1);
    }

    // Zero is reserved and could come to signify the burn stream.
    function test_RegisterStream_ZeroId_IllegalArgument() public {
        assertEq(
            _registerStream(0, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT
        );
    }

    function test_RegisterStream_DuplicateId_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(
            _registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)),
            USR_ILLEGAL_ARGUMENT
        );
    }

    function test_RegisterStream_AtMaxStreams_IllegalArgument() public {
        for (uint64 i = 1; i <= MAX_STREAMS; i++) {
            assertEq(_registerStream(i, _constantRecord(0), DistributionKind.IMPLICIT, address(0)), 0);
        }
        uint64 oneMoreId = MAX_STREAMS + 1;
        assertEq(
            _registerStream(oneMoreId, _constantRecord(0), DistributionKind.IMPLICIT, address(0)), USR_ILLEGAL_ARGUMENT
        );
    }

    function test_RegisterStream_SumWouldExceedOne_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.6e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
        assertEq(
            _registerStream(CONSENSUS_ID, _constantRecord(0.5e18), DistributionKind.IMPLICIT, address(0)),
            USR_ILLEGAL_ARGUMENT
        );
    }

    function test_RegisterStream_PendingUntilActivation() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(_streams().length, 0, "stream must not be live before its activation epoch");

        _warpPastTimelockAndSettle();
        StreamView[] memory streams = _streams();
        assertEq(streams.length, 1);
        assertEq(streams[0].id, SERVICE_ID);
    }

    function test_RegisterStream_TombstonedId_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setSharesExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(setSharesExit, 0);
        rewardActor().mockAwardBlockReward(1 ether); // 0.1 ether accrues, never claimed

        uint32 removeExit = swaCaller.removeStream(SERVICE_ID);
        assertEq(removeExit, 0);
        _warpPastTimelockAndSettle();

        assertEq(_getState().tombstones.length, 1, "sanity: the outstanding payable produced a tombstone");

        // f02 rejects any id collision it can see, including an undrained tombstone.
        assertEq(
            _registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)),
            USR_ILLEGAL_ARGUMENT
        );

        // Once the tombstone drains, the id is free again (f02 doesn't remember past that).
        _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
    }

    function test_SetWeightRecords_NotSwa_Forbidden() public {
        uint32 exitCode = _setWeightRecords(randomCaller, SERVICE_ID, _constantRecord(0.1e18));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_SetWeightRecords_NonexistentStream_NotFound() public {
        uint32 exitCode = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.1e18));
        assertEq(exitCode, USR_NOT_FOUND);
    }

    function test_SetWeightRecords_DuplicateIdInBatch_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        WeightRecordUpdate[] memory updates = new WeightRecordUpdate[](2);
        updates[0] = WeightRecordUpdate({id: SERVICE_ID, record: _constantRecord(0.5e18)});
        updates[1] = WeightRecordUpdate({id: SERVICE_ID, record: _constantRecord(0.5e18)});

        uint32 exitCode = swaCaller.setWeightRecords(updates);
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT, "a repeated id queues two PendingKeys for one slot");
    }

    function test_SetWeightRecords_InsaneRecord_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
        WeightRecord memory bad = _record(0, 0, 0, 0.9e18, 0.1e18); // floor > cap
        uint32 exitCode = _setWeightRecords(swaCaller, SERVICE_ID, bad);
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetWeightRecords_SumWouldExceedOne_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.3e18), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.3e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        uint32 exitCode = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.8e18));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetWeightRecords_SumWouldExceedOne_WithPendingWrite_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.4e18), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.4e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        uint32 firstExit = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.6e18));
        assertEq(firstExit, 0);

        uint32 secondExit = _setWeightRecords(swaCaller, CONSENSUS_ID, _constantRecord(0.6e18));
        assertEq(
            secondExit,
            USR_ILLEGAL_ARGUMENT,
            "guardrail must count SERVICE_ID's still-pending 0.6e18, not its stale 0.4e18"
        );
    }

    function test_SetWeightRecords_QueuedUntilTimelockElapses() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        uint32 setExit = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.7e18));
        assertEq(setExit, 0);

        StreamView[] memory before = _streams();
        assertEq(before[0].weightRecord.vStart, 0.1e18, "must not apply before the timelock elapses");

        _warpPastTimelockAndSettle();
        StreamView[] memory afterSettle = _streams();
        assertEq(afterSettle[0].weightRecord.vStart, 0.7e18);
    }

    // -------------------------------------------------------------------------
    // StepWeightRecords -- queued under its own (id, STEP_WEIGHT) slot, coexists with SetWeightRecords.
    // -------------------------------------------------------------------------

    function test_StepWeightRecords_NotSwa_Forbidden() public {
        uint32 exitCode = _stepWeightRecords(randomCaller, SERVICE_ID, _constantRecord(0.1e18));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_StepWeightRecords_QueuedUntilTimelockElapses() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        uint32 setExit = _stepWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.15e18));
        assertEq(setExit, 0);
        assertEq(_streams()[0].weightRecord.vStart, 0.1e18, "must not apply before the timelock elapses");

        _warpPastTimelockAndSettle();
        assertEq(_streams()[0].weightRecord.vStart, 0.15e18);
    }

    function test_StepWeightRecords_And_SetWeightRecords_AreIndependentSlots() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        // Both queue successfully: distinct (id, op) slots.
        uint32 stepExit = _stepWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.15e18));
        assertEq(stepExit, 0);
        uint32 setExit = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.2e18));
        assertEq(setExit, 0);

        assertEq(_getState().pendingWrites.length, 2);
    }

    function test_StepWeightRecords_OccupiedSlot_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        uint32 firstExit = _stepWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.15e18));
        assertEq(firstExit, 0);
        uint32 secondExit = _stepWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.2e18));
        assertEq(secondExit, USR_ILLEGAL_ARGUMENT, "revising a pending write is cancel + requeue, not a second queue");
    }

    function test_SetShares_NotWriter_Forbidden() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 exitCode = randomCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_SetShares_NonexistentStream_NotFound() public {
        uint32 exitCode = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(exitCode, USR_NOT_FOUND);
    }

    function test_SetShares_ImplicitStream_IllegalArgument() public {
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
        uint32 exitCode = randomCaller.setShares(CONSENSUS_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetShares_DoesNotSumToOne_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 under = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL - 1));
        assertEq(under, USR_ILLEGAL_ARGUMENT);
        uint32 over = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL + 1));
        assertEq(over, USR_ILLEGAL_ARGUMENT);
    }

    // A zero share is rejected outright rather than stored as a no-op row: validate_shares treats
    // "listed but paid nothing" as a caller mistake, since omitting the recipient says it exactly.
    function test_SetShares_ZeroShare_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        Share[] memory shares_ = new Share[](2);
        shares_[0] = Share({wallet: RECIPIENT_A, share: FixedU18.wrap(SHARE_TOTAL)});
        shares_[1] = Share({wallet: RECIPIENT_B, share: FixedU18.wrap(0)});
        assertEq(writerCaller.setShares(SERVICE_ID, shares_), USR_ILLEGAL_ARGUMENT);
    }

    // Duplicates are rejected rather than summed: two rows for one wallet make the map's meaning
    // depend on iteration order.
    function test_SetShares_DuplicateRecipient_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        Share[] memory shares_ = new Share[](2);
        shares_[0] = Share({wallet: RECIPIENT_A, share: FixedU18.wrap(SHARE_TOTAL / 2)});
        shares_[1] = Share({wallet: RECIPIENT_A, share: FixedU18.wrap(SHARE_TOTAL / 2)});
        assertEq(writerCaller.setShares(SERVICE_ID, shares_), USR_ILLEGAL_ARGUMENT);
    }

    function test_SetShares_TooManyRecipients_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint256 n = MAX_RECIPIENTS + 1;
        Share[] memory shares_ = new Share[](n);
        for (uint256 i = 0; i < n; i++) {
            shares_[i] = Share({wallet: address(uint160(i + 1)), share: FixedU18.wrap(SHARE_TOTAL / n)});
        }
        uint32 exitCode = writerCaller.setShares(SERVICE_ID, shares_);
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_SetShares_Valid_AppliesImmediately_NoTimelock() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        Share[] memory shares_ = _shares(RECIPIENT_A, SHARE_TOTAL);
        uint32 exitCode = writerCaller.setShares(SERVICE_ID, shares_);
        assertEq(exitCode, 0);

        // No vm.roll here: SetShares is the writer's own write, not queued under the timelock.
        Share[] memory got = rewardActor().getShares(SERVICE_ID);
        assertEq(got.length, 1);
        assertEq(got[0].wallet, RECIPIENT_A);
        assertEq(FixedU18.unwrap(got[0].share), SHARE_TOTAL);
    }

    function test_SetShares_FoldsAccruedIntoPayable_AndBurnsResidue() public {
        _registerExplicit(SERVICE_ID, address(writerCaller)); // weight 0.1e18
        uint32 firstSetExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(firstSetExit, 0);

        rewardActor().mockAwardBlockReward(1 ether); // service accrues 0.1 ether

        uint256 burnBefore = BURN_ADDRESS.balance;
        uint32 exitCode = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_B, SHARE_TOTAL));
        assertEq(exitCode, 0);

        // Sole recipient held 100%, so folding leaves no rounding residue.
        LedgerRow[] memory payableRows = rewardActor().getPayable(SERVICE_ID);
        assertEq(_payableRow(payableRows, RECIPIENT_A), 0.1 ether);
        assertEq(BURN_ADDRESS.balance, burnBefore, "an exact 100% share leaves no rounding dust to burn");
        assertEq(_streams()[0].accrued, 0, "accrual resets after the fold");

        // New map installed for the next period.
        Share[] memory got = rewardActor().getShares(SERVICE_ID);
        assertEq(got[0].wallet, RECIPIENT_B);
    }

    function test_SetShares_BurnSentinelCarvesAccrual_AndNeverBecomesClaimable() public {
        _registerExplicit(SERVICE_ID, address(writerCaller)); // weight 0.1e18

        Share[] memory partialBurn = new Share[](3);
        partialBurn[0] = Share({wallet: RECIPIENT_A, share: FixedU18.wrap(SHARE_TOTAL / 4)});
        partialBurn[1] = Share({wallet: BURN_ADDRESS, share: FixedU18.wrap(SHARE_TOTAL / 2)});
        partialBurn[2] = Share({wallet: RECIPIENT_B, share: FixedU18.wrap(SHARE_TOTAL / 4)});
        assertEq(writerCaller.setShares(SERVICE_ID, partialBurn), 0);

        Share[] memory stored = rewardActor().getShares(SERVICE_ID);
        assertEq(stored.length, 2);
        assertEq(stored[0].wallet, RECIPIENT_A);
        assertEq(stored[1].wallet, RECIPIENT_B);

        (, uint256 servicePortion, uint256 burnAmount) = rewardActor().mockAwardBlockReward(1 ether);
        assertEq(servicePortion, 0.05 ether);
        assertEq(burnAmount, 0.95 ether);
        assertEq(_streams()[0].accrued, 0.05 ether);

        (, uint256[] memory firstClaim) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(firstClaim[0], 0.025 ether, "live claims divide by the stored share total");

        assertEq(writerCaller.setShares(SERVICE_ID, _shares(BURN_ADDRESS, SHARE_TOTAL)), 0);
        assertEq(rewardActor().getShares(SERVICE_ID).length, 0);
        LedgerRow[] memory payableRows = rewardActor().getPayable(SERVICE_ID);
        assertEq(payableRows.length, 1);
        assertEq(payableRows[0].wallet, RECIPIENT_B);
        assertEq(payableRows[0].amount, 0.025 ether, "folds divide by the closing stored share total");
        assertEq(BURN_ADDRESS.balance, 0.95 ether, "the exact survivor pool leaves no fold residue");

        (, uint256[] memory finalClaims) = _claim(SERVICE_ID, _wallets(RECIPIENT_B, BURN_ADDRESS));
        assertEq(finalClaims[0], 0.025 ether);
        assertEq(finalClaims[1], 0, "the burn sentinel never has a claimable balance");

        (, servicePortion, burnAmount) = rewardActor().mockAwardBlockReward(1 ether);
        assertEq(servicePortion, 0);
        assertEq(burnAmount, 1 ether);
        assertEq(rewardActor().totalServiceMinted(), 0.05 ether);
        assertEq(rewardActor().totalBurnMinted(), 1.95 ether);
    }

    function test_RemoveStream_NotSwa_Forbidden() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 exitCode = randomCaller.removeStream(SERVICE_ID);
        assertEq(exitCode, USR_FORBIDDEN);
    }

    function test_RemoveStream_Nonexistent_NotFound() public {
        uint32 exitCode = swaCaller.removeStream(SERVICE_ID);
        assertEq(exitCode, USR_NOT_FOUND);
    }

    function test_RemoveStream_QueuedThenRemoved_AndSharesCleared() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(setExit, 0);

        uint32 removeExit = swaCaller.removeStream(SERVICE_ID);
        assertEq(removeExit, 0);
        assertEq(_streams().length, 1, "must still be live before the timelock elapses");

        _warpPastTimelockAndSettle();
        assertEq(_streams().length, 0);
        assertEq(rewardActor().getShares(SERVICE_ID).length, 0);
    }

    function test_RemoveStream_NoOutstandingPayable_NoTombstoneCreated() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 removeExit = swaCaller.removeStream(SERVICE_ID);
        assertEq(removeExit, 0);
        _warpPastTimelockAndSettle();

        assertEq(_getState().tombstones.length, 0, "nothing was ever owed, so nothing needs to stay addressable");
    }

    function test_RemoveStream_OutstandingPayable_MovesToTombstone_ClaimableAfterRemoval() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setSharesExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(setSharesExit, 0);

        rewardActor().mockAwardBlockReward(1 ether); // 0.1 ether accrues, never claimed

        uint32 removeExit = swaCaller.removeStream(SERVICE_ID);
        assertEq(removeExit, 0);
        _warpPastTimelockAndSettle();

        assertEq(_streams().length, 0);
        TombstoneView[] memory tombstones = _getState().tombstones;
        assertEq(tombstones.length, 1);
        assertEq(tombstones[0].id, SERVICE_ID);
        assertEq(_payableRow(tombstones[0].payableRows, RECIPIENT_A), 0.1 ether);

        (uint32 claimExit, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(claimExit, 0);
        assertEq(amounts[0], 0.1 ether);
        assertEq(RECIPIENT_A.balance, 0.1 ether);

        // Fully claimed: the tombstone drains and deletes.
        assertEq(_getState().tombstones.length, 0);
    }

    function test_SetDistribution_NotSwa_Forbidden() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 exitCode = randomCaller.setDistribution(SERVICE_ID, address(otherWriterCaller));
        assertEq(exitCode, USR_FORBIDDEN);
    }

    // A stream's kind is fixed at registration, so an implicit stream has no writer to reassign.
    function test_SetDistribution_ImplicitStream_IllegalArgument() public {
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
        assertEq(swaCaller.setDistribution(CONSENSUS_ID, address(writerCaller)), USR_ILLEGAL_ARGUMENT);
    }

    function test_SetDistribution_ZeroWriter_IllegalArgument() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 exitCode = swaCaller.setDistribution(SERVICE_ID, address(0));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    // The stream's current wallet-to-share map remains in force until the new writer
    // overwrites it via SetShares, so payments continue across the transition.
    function test_SetDistribution_OldWriterStaysAuthorizedUntilTimelockElapses() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 initialSet = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(initialSet, 0);

        uint32 distExit = swaCaller.setDistribution(SERVICE_ID, address(otherWriterCaller));
        assertEq(distExit, 0);

        // Before the timelock elapses: old writer still authorized, new writer is not.
        uint32 oldWriterExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_B, SHARE_TOTAL));
        assertEq(oldWriterExit, 0);
        uint32 newWriterExitTooEarly = otherWriterCaller.setShares(SERVICE_ID, _shares(address(0xF00D), SHARE_TOTAL));
        assertEq(newWriterExitTooEarly, USR_FORBIDDEN);

        _warpPastTimelockAndSettle();

        // After the timelock elapses: roles have swapped.
        uint32 oldWriterExitTooLate = writerCaller.setShares(SERVICE_ID, _shares(address(0xF00D), SHARE_TOTAL));
        assertEq(oldWriterExitTooLate, USR_FORBIDDEN);
        uint32 newWriterExit = otherWriterCaller.setShares(SERVICE_ID, _shares(address(0xF00D), SHARE_TOTAL));
        assertEq(newWriterExit, 0);
        assertEq(rewardActor().getShares(SERVICE_ID)[0].wallet, address(0xF00D));
    }

    function test_SetDistribution_ApplyFoldsAccruedIntoPayable() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setSharesExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(setSharesExit, 0);

        rewardActor().mockAwardBlockReward(1 ether); // 0.1 ether accrues under RECIPIENT_A

        uint32 distExit = swaCaller.setDistribution(SERVICE_ID, address(otherWriterCaller));
        assertEq(distExit, 0);
        _warpPastTimelockAndSettle();

        assertEq(_payableRow(rewardActor().getPayable(SERVICE_ID), RECIPIENT_A), 0.1 ether);
        assertEq(_streams()[0].accrued, 0);
        // The share map itself is untouched by the writer change.
        assertEq(rewardActor().getShares(SERVICE_ID)[0].wallet, RECIPIENT_A);
    }

    function test_CancelPending_NotSwa_Forbidden() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setExit = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.9e18));
        assertEq(setExit, 0);
        uint32 exitCode = randomCaller.cancelPending(SERVICE_ID, PendingOp.SET_WEIGHT);
        assertEq(exitCode, USR_FORBIDDEN);
    }

    // Cancelling a slot with nothing queued must succeed as a no-op, not error.
    function test_CancelPending_EmptySlot_BenignNoOp() public {
        assertEq(swaCaller.cancelPending(SERVICE_ID, PendingOp.REGISTER), 0);
        assertEq(swaCaller.cancelPendingWeight(PendingOp.SET_WEIGHT), 0);
    }

    // The two weight ops hold one schedule-wide slot each and are addressed with a null id; every
    // other op names its stream. Neither is reachable through the other's shape.
    function test_CancelPending_ShapeMismatch_IllegalArgument() public {
        assertEq(swaCaller.cancelPending(SERVICE_ID, PendingOp.SET_WEIGHT), USR_ILLEGAL_ARGUMENT);
        assertEq(swaCaller.cancelPendingWeight(PendingOp.REGISTER), USR_ILLEGAL_ARGUMENT);
    }

    // The slot is the whole schedule, not one stream's share of it, so a pending batch blocks the
    // next one even when the two name entirely different streams.
    function test_SetWeightRecords_PendingBatchBlocksAnotherStream() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        assertEq(_setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.2e18)), 0);
        assertEq(
            _setWeightRecords(swaCaller, CONSENSUS_ID, _constantRecord(0.2e18)),
            USR_ILLEGAL_ARGUMENT,
            "one weight slot for the whole schedule"
        );
    }

    // A batch applies as one unit, so both streams move at the same epoch or neither does.
    function test_SetWeightRecords_BatchAppliesAsOneEntry() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        WeightRecordUpdate[] memory updates = new WeightRecordUpdate[](2);
        updates[0] = WeightRecordUpdate({id: SERVICE_ID, record: _constantRecord(0.3e18)});
        updates[1] = WeightRecordUpdate({id: CONSENSUS_ID, record: _constantRecord(0.4e18)});
        assertEq(swaCaller.setWeightRecords(updates), 0);
        assertEq(_getState().pendingWrites.length, 1, "a batch is one queue entry");

        _warpPastTimelockAndSettle();
        StreamView[] memory streams = _streams();
        assertEq(streams[0].weightRecord.vStart, 0.3e18);
        assertEq(streams[1].weightRecord.vStart, 0.4e18);
    }

    function test_CancelPending_DiscardsQueuedSetWeightRecords() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setExit = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.9e18));
        assertEq(setExit, 0);

        uint32 cancelExit = swaCaller.cancelPendingWeight(PendingOp.SET_WEIGHT);
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        assertEq(_streams()[0].weightRecord.vStart, 0.1e18, "cancelled write must never apply");
    }

    function test_CancelPending_DiscardsQueuedRegisterStream() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        uint32 cancelExit = swaCaller.cancelPending(SERVICE_ID, PendingOp.REGISTER);
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        assertEq(_streams().length, 0, "cancelled registration must never take effect");
    }

    function test_CancelPending_DiscardsQueuedRemoveStream() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 removeExit = swaCaller.removeStream(SERVICE_ID);
        assertEq(removeExit, 0);

        uint32 cancelExit = swaCaller.cancelPending(SERVICE_ID, PendingOp.REMOVE);
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        assertEq(_streams().length, 1, "cancelled removal must never take effect");
    }

    // StepWeightRecords is uncancellable in f02, and that is enforced by the actor rather than
    // left to SWA discipline: the discretionary path must not be able to revoke a write the
    // governance gate produced.
    function test_CancelPending_StepWeightRecords_IsRejected() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 stepExit = _stepWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.9e18));
        assertEq(stepExit, 0);

        uint32 cancelExit = swaCaller.cancelPending(SERVICE_ID, PendingOp.STEP_WEIGHT);
        assertEq(cancelExit, USR_ILLEGAL_ARGUMENT, "a gate-originated write cannot be cancelled");

        _warpPastTimelockAndSettle();
        assertEq(_streams()[0].weightRecord.vStart, 0.9e18, "the gate write must still apply");
    }

    function test_CancelPending_OnlyCancelsMatchingOp() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setExit = _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.5e18));
        assertEq(setExit, 0);
        uint32 stepExit = _stepWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.6e18));
        assertEq(stepExit, 0);

        uint32 cancelExit = swaCaller.cancelPendingWeight(PendingOp.SET_WEIGHT);
        assertEq(cancelExit, 0);

        _warpPastTimelockAndSettle();
        // SET_WEIGHT was cancelled; STEP_WEIGHT still applied.
        assertEq(_streams()[0].weightRecord.vStart, 0.6e18);
    }

    // -------------------------------------------------------------------------
    // Projected-schedule validation
    // -------------------------------------------------------------------------

    /// @dev Registers two implicit streams at `a` and `b` and settles them.
    function _twoStreams(int256 a, int256 b) internal {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(a), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(b), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
    }

    // The sum is checked at every breakpoint from the effective epoch onward, not just at it. This
    // schedule is comfortably under one when it lands and breaches only as the ramp reaches its cap.
    function test_Schedule_RampBreachingAfterItLands_IllegalArgument() public {
        _twoStreams(0.5e18, 0.1e18);
        WeightRecord memory ramp = _record(0.1e18, 1e12, uint64(block.number), 0, 0.9e18);
        assertEq(_setWeightRecords(swaCaller, CONSENSUS_ID, ramp), USR_ILLEGAL_ARGUMENT);
    }

    // The same ramp, capped so the sum tops out at exactly one, is admitted: the check rejects
    // schedules that breach, not schedules that slope.
    function test_Schedule_RampReachingExactlyOne_Accepted() public {
        _twoStreams(0.5e18, 0.1e18);
        WeightRecord memory ramp = _record(0.1e18, 1e12, uint64(block.number), 0, 0.5e18);
        assertEq(_setWeightRecords(swaCaller, CONSENSUS_ID, ramp), 0);
    }

    // Admission projects the queue, so a stream a pending removal will have taken away is not
    // there to be weighted.
    function test_Schedule_WeightWriteForARemovedStream_IllegalArgument() public {
        _twoStreams(0.4e18, 0.2e18);
        assertEq(swaCaller.removeStream(CONSENSUS_ID), 0);
        assertEq(_setWeightRecords(swaCaller, CONSENSUS_ID, _constantRecord(0.3e18)), USR_ILLEGAL_ARGUMENT);
    }

    // Reject-on-strand. The registration is queued far enough out that the weight write lands
    // first; raising the live stream would leave no room for it, costing an already-accepted entry
    // its place, so the weight write is refused rather than silently stranding it.
    function test_Schedule_WriteThatStrandsAQueuedRegistration_IllegalArgument() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.4e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        uint32 registered = swaCaller.registerStream(
            CONSENSUS_ID, _constantRecord(0.5e18), address(0), new Share[](0), uint64(block.number) + 100_000
        );
        assertEq(registered, 0);

        assertEq(
            _setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.9e18)),
            USR_ILLEGAL_ARGUMENT,
            "must not strand the queued registration"
        );
        // The same write with room left for the registration is fine.
        assertEq(_setWeightRecords(swaCaller, SERVICE_ID, _constantRecord(0.5e18)), 0);
    }

    // Admission checked this registration against a queue that included the removal. Cancelling
    // the removal takes away the room it depended on, so it is dropped at settle rather than
    // applied into a schedule that sums above one.
    function test_Settle_DropsAWriteACancellationStranded() public {
        assertEq(_registerStream(SERVICE_ID, _constantRecord(0.4e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();

        assertEq(swaCaller.removeStream(SERVICE_ID), 0);
        uint64 activation = uint64(block.number) + SWA_TIMELOCK + 10;
        uint32 registered =
            swaCaller.registerStream(CONSENSUS_ID, _constantRecord(0.9e18), address(0), new Share[](0), activation);
        assertEq(registered, 0, "room exists while the removal is queued");

        assertEq(swaCaller.cancelPending(SERVICE_ID, PendingOp.REMOVE), 0);
        vm.roll(activation);

        // The event is the assertion that matters: an absent stream is equally consistent with the
        // write never having been reached, whereas this pins that it was reached and dropped.
        vm.expectEmit(true, false, false, true, REWARD_ACTOR_ADDRESS);
        emit PendingDropped(CONSENSUS_ID, PendingOp.REGISTER);
        rewardActor().mockSettle();

        StreamView[] memory streams = _streams();
        assertEq(streams.length, 1, "the stranded registration must not apply");
        assertEq(streams[0].id, SERVICE_ID);
    }

    // The peak here is transient: one epoch wide, at the epoch after the computed clamp crossing,
    // and lower both before it and at the end of the domain. Only the neighbours either side of a
    // crossing put a sample on it.
    function test_Schedule_TransientPeakAtACrossingNeighbour_IllegalArgument() public {
        _twoStreams(0.1e18, 0.1e18);
        uint64 f = uint64(block.number) + SWA_TIMELOCK;

        WeightRecordUpdate[] memory updates = new WeightRecordUpdate[](2);
        // Rises 3 per epoch to a cap of 11, so 11/3 truncates to 3 but the cap lands at 4.
        updates[0] = WeightRecordUpdate({id: SERVICE_ID, record: _record(0, 3, f, 0, 11)});
        // Falls 1 per epoch from just under the limit.
        updates[1] = WeightRecordUpdate({id: CONSENSUS_ID, record: _record(WAD - 6, -1, f, 0, WAD - 6)});

        assertEq(swaCaller.setWeightRecords(updates), USR_ILLEGAL_ARGUMENT);
    }

    // A falling ramp selects the floor as its crossing bound rather than the cap.
    function test_Schedule_FallingRamp() public {
        _twoStreams(0.5e18, 0.1e18);
        uint64 f = uint64(block.number) + SWA_TIMELOCK;
        assertEq(
            _setWeightRecords(swaCaller, CONSENSUS_ID, _record(0.5e18, -1e12, f, 0.1e18, 0.5e18)),
            0,
            "starts at the limit and only falls"
        );
        assertEq(
            _setWeightRecords(swaCaller, CONSENSUS_ID, _record(0.51e18, -1e12, f, 0.1e18, 0.51e18)),
            USR_ILLEGAL_ARGUMENT,
            "starts above it"
        );
    }

    // An anchor after the validation start: the weight sits at its floor until then and steps up,
    // so the breach is at the anchor rather than anywhere the ramp reaches.
    function test_Schedule_AnchorAfterTheStart_IllegalArgument() public {
        _twoStreams(0.5e18, 0.1e18);
        uint64 later = uint64(block.number) + SWA_TIMELOCK + 200_000;
        assertEq(
            _setWeightRecords(swaCaller, CONSENSUS_ID, _record(0.9e18, 1e12, later, 0.1e18, 0.9e18)),
            USR_ILLEGAL_ARGUMENT
        );
        assertEq(
            _setWeightRecords(swaCaller, CONSENSUS_ID, _record(0.5e18, 1e12, later, 0.1e18, 0.5e18)),
            0,
            "the same shape with room for it"
        );
    }

    function test_Claim_NonexistentStream_NotFound() public {
        (uint32 exitCode,) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(exitCode, USR_NOT_FOUND);
    }

    function test_Claim_ImplicitStream_IllegalArgument() public {
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.1e18), DistributionKind.IMPLICIT, address(0)), 0);
        _warpPastTimelockAndSettle();
        (uint32 exitCode,) = _claim(CONSENSUS_ID, _wallets(RECIPIENT_A));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    function test_Claim_UnknownWallet_ReturnsZero_NoRevert() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setSharesExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(setSharesExit, 0);

        (uint32 exitCode, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_B));
        assertEq(exitCode, 0, "an all-zero batch is a benign no-op success");
        assertEq(amounts[0], 0);
    }

    function test_Claim_PaysLiveAccrual() public {
        _registerExplicit(SERVICE_ID, address(writerCaller)); // weight 0.1e18
        uint32 setSharesExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(setSharesExit, 0);

        rewardActor().mockAwardBlockReward(1 ether); // service accrues 0.1 ether

        (uint32 exitCode, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(exitCode, 0);
        assertEq(amounts[0], 0.1 ether);
        assertEq(RECIPIENT_A.balance, 0.1 ether);
        assertEq(_streams()[0].accrued, 0.1 ether, "accrued is a period gross total, unaffected by claims");

        // A second claim in the same period pays nothing further: claimed_period tracks it.
        (, uint256[] memory secondAmounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(secondAmounts[0], 0);
        assertEq(RECIPIENT_A.balance, 0.1 ether);
    }

    function _wallets(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    // Every other Claim test only ever passes a single wallet, so FVMRewards.tryClaim's
    // returndata-array decode loop (and its trailing free-memory-pointer bump) never runs past
    // one iteration. This exercises count > 1, including the last element specifically.
    function test_Claim_MultipleWallets_ReturnsAmountsInOrder() public {
        _registerExplicit(SERVICE_ID, address(writerCaller)); // weight 0.1e18
        Share[] memory shares_ = new Share[](2);
        shares_[0] = Share({wallet: RECIPIENT_A, share: FixedU18.wrap(0.6e18)});
        shares_[1] = Share({wallet: RECIPIENT_B, share: FixedU18.wrap(0.4e18)});
        uint32 setSharesExit = writerCaller.setShares(SERVICE_ID, shares_);
        assertEq(setSharesExit, 0);

        rewardActor().mockAwardBlockReward(1 ether); // service accrues 0.1 ether, split 60/40

        (uint32 exitCode, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A, RECIPIENT_B));
        assertEq(exitCode, 0);
        assertEq(amounts.length, 2);
        assertEq(amounts[0], 0.06 ether);
        assertEq(amounts[1], 0.04 ether, "last element of the returned array");
        assertEq(RECIPIENT_A.balance, 0.06 ether);
        assertEq(RECIPIENT_B.balance, 0.04 ether);
    }

    function test_Claim_PaysPayablePlusLive() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 firstSetExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(firstSetExit, 0);

        rewardActor().mockAwardBlockReward(1 ether); // 0.1 ether accrues, never claimed

        // Fold the period (via a new SetShares) so the 0.1 ether moves into payable.
        uint32 secondSetExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(secondSetExit, 0);
        assertEq(_payableRow(rewardActor().getPayable(SERVICE_ID), RECIPIENT_A), 0.1 ether);

        rewardActor().mockAwardBlockReward(1 ether); // another 0.1 ether accrues, live this period

        (uint32 exitCode, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(exitCode, 0);
        assertEq(amounts[0], 0.2 ether, "payable (closed period) plus live (current period)");
        assertEq(RECIPIENT_A.balance, 0.2 ether);
        assertEq(rewardActor().getPayable(SERVICE_ID).length, 0, "claimed payable row drops");
    }

    function test_AwardBlockReward_SplitsAcrossMinerAndService_ConservationHolds() public {
        assertEq(_registerStream(CONSENSUS_ID, _constantRecord(0.85e18), DistributionKind.IMPLICIT, address(0)), 0);
        assertEq(
            _registerStream(SERVICE_ID, _constantRecord(0.1e18), DistributionKind.EXPLICIT, address(writerCaller)), 0
        );
        _warpPastTimelockAndSettle();

        (uint256 minerPortion, uint256 servicePortion, uint256 burnAmount) = rewardActor().mockAwardBlockReward(1 ether);

        assertEq(minerPortion, 0.85 ether);
        assertEq(servicePortion, 0.1 ether);
        assertEq(burnAmount, 0.05 ether);
        assertEq(minerPortion + servicePortion + burnAmount, 1 ether, "conservation: BR = miner + service + burn");

        assertEq(rewardActor().totalMintedReward(), 1 ether);
        assertEq(rewardActor().totalBurnMinted(), 0.05 ether);
        assertEq(rewardActor().totalServiceMinted(), 0.1 ether);
        // M = T - B - S is derived, never stored.
        assertEq(
            rewardActor().totalMintedReward() - rewardActor().totalBurnMinted() - rewardActor().totalServiceMinted(),
            minerPortion
        );
        assertEq(BURN_ADDRESS.balance, 0.05 ether);
    }

    function test_AwardBlockReward_NoStreams_AllBurn() public {
        (uint256 minerPortion, uint256 servicePortion, uint256 burnAmount) = rewardActor().mockAwardBlockReward(1 ether);
        assertEq(minerPortion, 0);
        assertEq(servicePortion, 0);
        assertEq(burnAmount, 1 ether);
        assertEq(BURN_ADDRESS.balance, 1 ether);
    }

    function test_AwardBlockReward_SelfIssues_ClaimPaysWithoutPreDeal() public {
        _registerExplicit(SERVICE_ID, address(writerCaller));
        uint32 setExit = writerCaller.setShares(SERVICE_ID, _shares(RECIPIENT_A, SHARE_TOTAL));
        assertEq(setExit, 0);

        rewardActor().mockAwardBlockReward(1 ether); // no vm.deal beforehand

        (uint32 exitCode, uint256[] memory amounts) = _claim(SERVICE_ID, _wallets(RECIPIENT_A));
        assertEq(exitCode, 0);
        assertEq(amounts[0], 0.1 ether);
        assertEq(RECIPIENT_A.balance, 0.1 ether, "claim must actually move funds, not just report bookkeeping");
    }

    // -------------------------------------------------------------------------
    // Fidelity: native-actor fallback and precompile guard
    // -------------------------------------------------------------------------

    // A native actor: direct EVM CALL fails with USR_UNHANDLED_MESSAGE, not like an account actor.
    function test_DirectEvmCall_ReturnsUnhandledMessage() public {
        (bool ok, bytes memory ret) = REWARD_ACTOR_ADDRESS.call("");
        assertTrue(ok);
        (uint32 exitCode,,) = abi.decode(ret, (uint32, uint64, bytes));
        assertEq(exitCode, USR_UNHANDLED_MESSAGE);
    }

    // restrict_internal_api: f02's internal API is closed to EVM callers, so ThisEpochReward is
    // not a back door to the weight schedule and AwardBlockReward cannot be driven from a
    // contract. Every method below FRC-0042's floor is forbidden, not merely unhandled.
    function test_InternalApi_ForbiddenToEvmCallers() public {
        uint64[4] memory internalMethods = [uint64(1), 2, 3, 4]; // Constructor, Award, ThisEpoch, KPI
        for (uint256 i = 0; i < internalMethods.length; i++) {
            (uint32 exitCode,) = swaCaller.call(internalMethods[i], "");
            assertEq(exitCode, USR_FORBIDDEN, "internal API must be forbidden, not unhandled");
        }
    }

    // Above the floor, an unrecognised method is merely unhandled.
    function test_UnknownExportedMethod_Unhandled() public {
        (uint32 exitCode,) = swaCaller.call(type(uint64).max, "");
        assertEq(exitCode, USR_UNHANDLED_MESSAGE);
    }

    // The real precompile requires delegatecall; a direct call/staticcall must fail.
    function test_DirectCallToPrecompile_Reverts() public {
        (bool ok,) = CALL_ACTOR_BY_ID.call("");
        assertFalse(ok);
    }

    // None of the reward actor's methods accept a value; the mock must not silently drop it.
    function test_NonzeroValue_IllegalArgument() public {
        bytes memory callData = abi.encode(CLAIM, uint256(1), NO_FLAGS, uint64(0), bytes(""), REWARD_ACTOR_ID);
        (bool ok, bytes memory ret) = CALL_ACTOR_BY_ID.delegatecall(callData);
        assertTrue(ok);
        (uint32 exitCode,,) = abi.decode(ret, (uint32, uint64, bytes));
        assertEq(exitCode, USR_ILLEGAL_ARGUMENT);
    }

    // -------------------------------------------------------------------------
    // Regression: FVMCallActorByIdWithReward must not break existing actor mocks
    // -------------------------------------------------------------------------

    // Exercises _handleBurn's balance debit through the new dispatcher (delegatecall keeps the caller's balance context).
    function test_Regression_Burn_StillDebitsCallerBalance() public {
        uint256 before = address(this).balance;
        assertEq(BURN_ADDRESS.balance, 0);
        BURN_ACTOR_ID.pay(10 ether);
        assertEq(BURN_ADDRESS.balance, 10 ether);
        assertEq(address(this).balance, before - 10 ether);
    }

    // Exercises the storage power actor branch (_handlePower) through the new dispatcher.
    function test_Regression_MinerPower_StillWorks() public {
        mockMiner(555);
        assertTrue(FVMMiner.isMiner(555));
        assertFalse(FVMMiner.isMiner(556));
    }
}
