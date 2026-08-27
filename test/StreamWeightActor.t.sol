// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {SafeProxy} from "@safe/proxies/SafeProxy.sol";

import {USR_FORBIDDEN, USR_ILLEGAL_ARGUMENT, USR_NOT_FOUND} from "fvm-solidity/FVMErrors.sol";

import {MockRewardTest} from "./mocks/MockRewardTest.sol";
import {WAD} from "./mocks/FVMRewardActor.sol";
import {StreamWeightActor} from "../src/StreamWeightActor.sol";
import {IServiceRewardsActor} from "../src/interfaces/IServiceRewardsActor.sol";
import {PendingOp, Share, WeightRecord, WeightRecordUpdate} from "../src/lib/FVMRewardTypes.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";
import {FVMRewards} from "../src/lib/FVMRewards.sol";
import {SWA_TIMELOCK} from "../src/lib/FVMRewardMethod.sol";

contract StreamWeightActorTest is MockRewardTest {
    StreamWeightActor actor;
    address owner1;
    address owner2;

    uint64 constant STREAM_ID = 1;
    address constant WRITER = address(0xBEEF);

    Epoch constant TEST_QUARTER = Epoch.wrap(262980); // epochs per 365.25/4 days
    Epoch constant TEST_HOLD = Epoch.wrap(2 * 60 * 24 * 7); // epochs per 7 days

    function setUp() public override {
        super.setUp();
        owner1 = _makeSafeOwner("owner1");
        owner2 = _makeSafeOwner("owner2");

        address sra = makeAddr("sra");
        vm.mockCall(
            sra, abi.encodeWithSelector(IServiceRewardsActor.EPOCHS_PER_QUARTER.selector), abi.encode(TEST_QUARTER)
        );
        vm.mockCall(sra, abi.encodeWithSelector(IServiceRewardsActor.SRA_CANCEL_HOLD.selector), abi.encode(TEST_HOLD));

        actor = new StreamWeightActor(owner1, owner2, IServiceRewardsActor(sra));
        rewardActor().mockSwa(address(actor));
    }

    function _makeSafeOwner(string memory label) internal returns (address proxyAddr) {
        address masterCopy = makeAddr(string.concat(label, "-mastercopy"));
        vm.etch(masterCopy, new bytes(8001));

        SafeProxy real = new SafeProxy(masterCopy);
        bytes memory code = address(real).code;

        proxyAddr = makeAddr(label);
        vm.etch(proxyAddr, code);
        vm.store(proxyAddr, bytes32(0), bytes32(uint256(uint160(masterCopy))));
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _record(int256 w) internal pure returns (WeightRecord memory) {
        return WeightRecord({vStart: w, slope: 0, tStart: Epoch.wrap(0), floor: 0, cap: WAD});
    }

    function _activation() internal view returns (uint64) {
        return uint64(block.number) + SWA_TIMELOCK;
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
        vm.roll(block.number + SWA_TIMELOCK);
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

    // -------------------------------------------------------------------------
    // replaceOwner
    // -------------------------------------------------------------------------

    function test_ReplaceOwner_Success_SwapsApprovalRights() public {
        address newOwner = _makeSafeOwner("newOwner");

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
