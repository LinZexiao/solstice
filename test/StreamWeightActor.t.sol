// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {USR_FORBIDDEN, USR_ILLEGAL_ARGUMENT, USR_NOT_FOUND} from "fvm-solidity/FVMErrors.sol";

import {MockRewardTest} from "./mocks/MockRewardTest.sol";
import {FVMRewardActor, MockState, WAD, MAINNET_TIMELOCK} from "./mocks/FVMRewardActor.sol";
import {StreamWeightActor} from "../src/StreamWeightActor.sol";
import {IServiceRewardsActor} from "../src/interfaces/IServiceRewardsActor.sol";
import {DistributionKind, PendingOp, Share, WeightRecord, WeightRecordUpdate} from "../src/lib/FVMRewardTypes.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";
import {FVMRewards} from "../src/lib/FVMRewards.sol";

contract StreamWeightActorTest is MockRewardTest {
    StreamWeightActor actor;
    address owner1;
    address owner2;

    uint64 constant STREAM_ID = 1;
    address constant WRITER = address(0xBEEF);

    Epoch constant TEST_QUARTER = Epoch.wrap(262980); // epochs per 365.25/4 days

    function setUp() public override {
        super.setUp();
        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");

        address sra = makeAddr("sra");
        vm.mockCall(
            sra, abi.encodeWithSelector(IServiceRewardsActor.EPOCHS_PER_QUARTER.selector), abi.encode(TEST_QUARTER)
        );

        // mainnet hold: StreamWeightGate tests exercise the timelock boundary at MAINNET_TIMELOCK
        actor = new StreamWeightActor(owner1, owner2, IServiceRewardsActor(sra), Epoch.wrap(MAINNET_TIMELOCK));
        rewardActor().mockSwa(address(actor));
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _record(int256 w) internal pure returns (WeightRecord memory) {
        return WeightRecord({vStart: w, slope: 0, tStart: Epoch.wrap(0), floor: 0, cap: WAD});
    }

    function _activation() internal view returns (uint64) {
        return uint64(block.number) + MAINNET_TIMELOCK;
    }

    function _shares() internal pure returns (Share[] memory shares) {
        shares = new Share[](1);
        shares[0] = Share({wallet: WRITER, share: FixedU18.wrap(uint256(WAD))});
    }

    function _singleWeightRecord(uint64 id, WeightRecord memory record)
        internal
        pure
        returns (WeightRecordUpdate[] memory updates)
    {
        updates = new WeightRecordUpdate[](1);
        updates[0] = WeightRecordUpdate({id: id, record: record});
    }

    /// @dev Registers STREAM_ID (EXPLICIT, WRITER) through both owners, then rolls past the
    /// timelock so the next dispatched call settles it into existence.
    function _registerAndActivate(uint64 id) internal {
        vm.prank(owner1);
        actor.registerStream(id, _record(0.1e18), WRITER, _shares(), _activation());
        vm.prank(owner2);
        actor.registerStream(id, _record(0.1e18), WRITER, _shares(), _activation());
        vm.roll(block.number + MAINNET_TIMELOCK);
    }

    /// @dev Whether f02 currently holds a queued per-stream op for `id` (reads the mock's state).
    function _hasPending(uint64 id, PendingOp op) internal view returns (bool) {
        MockState memory st = rewardActor().mockState();
        for (uint256 i = 0; i < st.pendingWrites.length; i++) {
            if (st.pendingWrites[i].hasId && st.pendingWrites[i].id == id && st.pendingWrites[i].op == op) {
                return true;
            }
        }
        return false;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    function test_Constructor_AddsBothOwners() public {
        // Indirect proof of ownership: cancelPendingWeight's owner check only lets a real owner
        // through, and the mock accepts the empty-slot no-op once it does.
        vm.prank(owner1);
        actor.cancelPendingWeight(PendingOp.SET_WEIGHT);
        vm.prank(owner2);
        actor.cancelPendingWeight(PendingOp.SET_WEIGHT);
    }

    // -------------------------------------------------------------------------
    // registerStream
    // -------------------------------------------------------------------------

    function test_RegisterStream_Success() public {
        vm.prank(owner1);
        actor.registerStream(STREAM_ID, _record(0.1e18), WRITER, _shares(), _activation());
        vm.prank(owner2);
        actor.registerStream(STREAM_ID, _record(0.1e18), WRITER, _shares(), _activation());
    }

    function test_RegisterStream_NotSwa_RevertsForbidden() public {
        rewardActor().mockSwa(address(0xDEAD));

        vm.prank(owner1);
        actor.registerStream(STREAM_ID, _record(0.1e18), WRITER, _shares(), _activation());
        vm.prank(owner2);
        vm.expectRevert(
            abi.encodeWithSelector(FVMRewards.RegisterStreamFailed.selector, int256(uint256(USR_FORBIDDEN)))
        );
        actor.registerStream(STREAM_ID, _record(0.1e18), WRITER, _shares(), _activation());
    }

    // Also proves the first registration itself succeeded: a nonexistent stream can't collide.
    function test_RegisterStream_DuplicatePendingId_RevertsIllegalArgument() public {
        vm.prank(owner1);
        actor.registerStream(STREAM_ID, _record(0.1e18), WRITER, _shares(), _activation());
        vm.prank(owner2);
        actor.registerStream(STREAM_ID, _record(0.1e18), WRITER, _shares(), _activation());

        vm.prank(owner1);
        actor.registerStream(STREAM_ID, _record(0.1e18), WRITER, _shares(), _activation());
        vm.prank(owner2);
        vm.expectRevert(
            abi.encodeWithSelector(FVMRewards.RegisterStreamFailed.selector, int256(uint256(USR_ILLEGAL_ARGUMENT)))
        );
        actor.registerStream(STREAM_ID, _record(0.1e18), WRITER, _shares(), _activation());
    }

    /// @dev The 3-arg overload (no writer/shares) queues an IMPLICIT registration: f02 resolves
    /// the recipient from protocol state, so the queued and applied stream carry no writer or map.
    function test_RegisterStream_ImplicitOverload_QueuesImplicitRegistration() public {
        vm.prank(owner1);
        actor.registerStream(STREAM_ID, _record(0.1e18), _activation());
        vm.prank(owner2);
        actor.registerStream(STREAM_ID, _record(0.1e18), _activation());

        // Both approvals executed the body: f02 holds a queued REGISTER with a null distribution.
        MockState memory st = rewardActor().mockState();
        bool found;
        for (uint256 i = 0; i < st.pendingWrites.length; i++) {
            if (
                st.pendingWrites[i].hasId && st.pendingWrites[i].id == STREAM_ID
                    && st.pendingWrites[i].op == PendingOp.REGISTER
            ) {
                found = true;
                assertEq(
                    uint256(st.pendingWrites[i].distributionKind),
                    uint256(DistributionKind.IMPLICIT),
                    "queued as IMPLICIT"
                );
                assertEq(st.pendingWrites[i].writer, address(0), "implicit registration carries no writer");
            }
        }
        assertTrue(found, "REGISTER queued for the stream");

        // Settling applies it as a live IMPLICIT stream.
        vm.roll(block.number + MAINNET_TIMELOCK);
        rewardActor().mockSettle();

        st = rewardActor().mockState();
        assertEq(st.streams.length, 1, "registration applied");
        assertEq(st.streams[0].id, STREAM_ID);
        assertEq(uint256(st.streams[0].kind), uint256(DistributionKind.IMPLICIT), "applied as IMPLICIT");
        assertEq(st.streams[0].writer, address(0));
    }

    // -------------------------------------------------------------------------
    // removeStream
    // -------------------------------------------------------------------------

    function test_RemoveStream_Success() public {
        _registerAndActivate(STREAM_ID);

        vm.prank(owner1);
        actor.removeStream(STREAM_ID);
        vm.prank(owner2);
        actor.removeStream(STREAM_ID);
    }

    function test_RemoveStream_NotSwa_RevertsForbidden() public {
        rewardActor().mockSwa(address(0xDEAD));

        vm.prank(owner1);
        actor.removeStream(STREAM_ID);
        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(FVMRewards.RemoveStreamFailed.selector, int256(uint256(USR_FORBIDDEN))));
        actor.removeStream(STREAM_ID);
    }

    function test_RemoveStream_Nonexistent_RevertsNotFound() public {
        vm.prank(owner1);
        actor.removeStream(STREAM_ID);
        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(FVMRewards.RemoveStreamFailed.selector, int256(uint256(USR_NOT_FOUND))));
        actor.removeStream(STREAM_ID);
    }

    // -------------------------------------------------------------------------
    // setWeightRecords
    // -------------------------------------------------------------------------

    function test_SetWeightRecords_Success() public {
        _registerAndActivate(STREAM_ID);
        WeightRecordUpdate[] memory updates = _singleWeightRecord(STREAM_ID, _record(0.2e18));

        vm.prank(owner1);
        actor.setWeightRecords(updates);
        vm.prank(owner2);
        actor.setWeightRecords(updates);
    }

    function test_SetWeightRecords_NotSwa_RevertsForbidden() public {
        rewardActor().mockSwa(address(0xDEAD));
        WeightRecordUpdate[] memory updates = _singleWeightRecord(STREAM_ID, _record(0.2e18));

        vm.prank(owner1);
        actor.setWeightRecords(updates);
        vm.prank(owner2);
        vm.expectRevert(
            abi.encodeWithSelector(FVMRewards.SetWeightRecordsFailed.selector, int256(uint256(USR_FORBIDDEN)))
        );
        actor.setWeightRecords(updates);
    }

    function test_SetWeightRecords_Nonexistent_RevertsNotFound() public {
        WeightRecordUpdate[] memory updates = _singleWeightRecord(STREAM_ID, _record(0.2e18));

        vm.prank(owner1);
        actor.setWeightRecords(updates);
        vm.prank(owner2);
        vm.expectRevert(
            abi.encodeWithSelector(FVMRewards.SetWeightRecordsFailed.selector, int256(uint256(USR_NOT_FOUND)))
        );
        actor.setWeightRecords(updates);
    }

    // -------------------------------------------------------------------------
    // setDistribution
    // -------------------------------------------------------------------------

    function test_SetDistribution_Success() public {
        _registerAndActivate(STREAM_ID);

        vm.prank(owner1);
        actor.setDistribution(STREAM_ID, WRITER);
        vm.prank(owner2);
        actor.setDistribution(STREAM_ID, WRITER);
    }

    function test_SetDistribution_NotSwa_RevertsForbidden() public {
        rewardActor().mockSwa(address(0xDEAD));

        vm.prank(owner1);
        actor.setDistribution(STREAM_ID, WRITER);
        vm.prank(owner2);
        vm.expectRevert(
            abi.encodeWithSelector(FVMRewards.SetDistributionFailed.selector, int256(uint256(USR_FORBIDDEN)))
        );
        actor.setDistribution(STREAM_ID, WRITER);
    }

    function test_SetDistribution_Nonexistent_RevertsNotFound() public {
        vm.prank(owner1);
        actor.setDistribution(STREAM_ID, WRITER);
        vm.prank(owner2);
        vm.expectRevert(
            abi.encodeWithSelector(FVMRewards.SetDistributionFailed.selector, int256(uint256(USR_NOT_FOUND)))
        );
        actor.setDistribution(STREAM_ID, WRITER);
    }

    function test_SetDistribution_ZeroWriter_RevertsIllegalArgument() public {
        _registerAndActivate(STREAM_ID);

        vm.prank(owner1);
        actor.setDistribution(STREAM_ID, address(0));
        vm.prank(owner2);
        vm.expectRevert(
            abi.encodeWithSelector(FVMRewards.SetDistributionFailed.selector, int256(uint256(USR_ILLEGAL_ARGUMENT)))
        );
        actor.setDistribution(STREAM_ID, address(0));
    }

    // -------------------------------------------------------------------------
    // cancelPending -- ungoverned: any single owner may call immediately.
    // -------------------------------------------------------------------------

    function test_CancelPending_NotOwner_Reverts() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        actor.cancelPendingWeight(PendingOp.SET_WEIGHT);
    }

    function test_CancelPending_Owner_EmptySlot_Succeeds() public {
        vm.prank(owner1);
        actor.cancelPendingWeight(PendingOp.SET_WEIGHT);
    }

    function test_CancelPending_NotSwa_RevertsForbidden() public {
        rewardActor().mockSwa(address(0xDEAD));

        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(FVMRewards.CancelPendingFailed.selector, int256(uint256(USR_FORBIDDEN))));
        actor.cancelPendingWeight(PendingOp.SET_WEIGHT);
    }

    /// @dev Cancelling a genuinely queued per-stream op: the registration is approved by both
    /// owners and queued at f02, so the cancel clears the occupied slot and the stream never lands.
    function test_CancelPending_QueuedRegister_RemovesPending() public {
        vm.prank(owner1);
        actor.registerStream(STREAM_ID, _record(0.1e18), WRITER, _shares(), _activation());
        vm.prank(owner2);
        actor.registerStream(STREAM_ID, _record(0.1e18), WRITER, _shares(), _activation());
        assertTrue(_hasPending(STREAM_ID, PendingOp.REGISTER), "registration pending before the cancel");

        vm.expectEmit(true, true, true, true);
        emit FVMRewardActor.PendingCancelled(STREAM_ID, PendingOp.REGISTER);
        vm.prank(owner2); // either owner cancels immediately
        actor.cancelPending(STREAM_ID, PendingOp.REGISTER);

        assertFalse(_hasPending(STREAM_ID, PendingOp.REGISTER), "pending slot cleared by the cancel");

        // Rolling past the registration's activation epoch applies nothing.
        vm.roll(block.number + MAINNET_TIMELOCK);
        rewardActor().mockSettle();
        assertEq(rewardActor().mockState().streams.length, 0, "cancelled registration never applies");

        // The freed slot admits a fresh registration for the same id.
        vm.prank(owner1);
        actor.registerStream(STREAM_ID, _record(0.1e18), WRITER, _shares(), _activation());
        vm.prank(owner2);
        actor.registerStream(STREAM_ID, _record(0.1e18), WRITER, _shares(), _activation());
    }

    // -------------------------------------------------------------------------
    // replaceOwner
    // -------------------------------------------------------------------------

    function test_ReplaceOwner_Success_SwapsApprovalRights() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner1);
        actor.replaceOwner(owner2, newOwner);
        vm.prank(owner2);
        actor.replaceOwner(owner2, newOwner);

        // owner2 was removed: no longer recognized by cancelPending's owner check.
        vm.prank(owner2);
        vm.expectRevert();
        actor.cancelPendingWeight(PendingOp.SET_WEIGHT);

        // newOwner was added: recognized immediately.
        vm.prank(newOwner);
        actor.cancelPendingWeight(PendingOp.SET_WEIGHT);
    }
}
