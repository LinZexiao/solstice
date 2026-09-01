// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// SRA governance flow tests
//
//   - two votes + permissionless execution after SRA_CANCEL_HOLD elapses
//   - not executable within the hold (HoldUntil revert)
//   - single vote does not execute; non-owner rejected
//   - veto (cancelPending) discards a queued change
//   - NO_HOLD (correctVolume) full-vote immediate execution
//   - taskId = keccak256(msg.data): different array parameter order -> different taskId -> no merge (I2 risk)

import {SRATestBase} from "./SRATestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {FilecoinPayVolume} from "../src/lib/SraTypes.sol";
import {UnanimousGovernance} from "../src/lib/UnanimousGovernance.sol";

contract SRAGovernanceTest is SRATestBase {
    // ------------------------------------------------------------------------
    // Two votes + hold flow
    // ------------------------------------------------------------------------

    /// after two votes + hold elapses, any keeper can trigger execution (admit takes effect).
    function test_Admit_TwoApprovalsPlusHold_Executes() public {
        address orch = makeAddr("orch");
        assertFalse(sra.isAdmitted(orch));

        vm.prank(owner1);
        sra.admit(orch);
        vm.prank(owner2);
        sra.admit(orch);
        // after the second approval the hold has not elapsed; admit not yet effective
        assertFalse(sra.isAdmitted(orch));

        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.admit(orch); // permissionless completion

        assertTrue(sra.isAdmitted(orch));
        assertEq(sra.admittedCount(), 1);
    }

    /// a third call (execution attempt) within the hold reverts HoldUntil.
    function test_Admit_HoldNotElapsed_ExecutionReverts() public {
        address orch = makeAddr("orch");

        vm.prank(owner1);
        sra.admit(orch);
        vm.prank(owner2);
        sra.admit(orch);

        // hold not elapsed: the third call must revert (HoldUntil, until = second approval + hold)
        vm.roll(block.number + SRA_CANCEL_HOLD - 1);
        vm.expectRevert();
        sra.admit(orch);
        assertFalse(sra.isAdmitted(orch));
    }

    /// a single vote (only owner1) does not execute.
    function test_Admit_SingleApproval_NotExecuted() public {
        address orch = makeAddr("orch");

        vm.prank(owner1);
        sra.admit(orch);

        assertFalse(sra.isAdmitted(orch));
        vm.roll(block.number + SRA_CANCEL_HOLD + 1);
        // third call: approvals not full, owner1 already approved -> AlreadyApproved (owner1 cannot vote again)
        // here we call again as owner1 to verify "the same task cannot be approved twice"
        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.AlreadyApproved.selector));
        sra.admit(orch);
    }

    /// a non-owner calling a governance method reverts NotOwner.
    function test_Admit_NonOwner_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.NotOwner.selector, stranger));
        sra.admit(makeAddr("orch"));
    }

    /// after both Safes call the same governance method, the taskId record is identical (keccak256(msg.data)).
    function test_Admit_TaskIdIsKeccakOfCalldata() public {
        address orch = makeAddr("orch");
        bytes32 expectedTaskId = keccak256(abi.encodeWithSignature("admit(address)", orch));

        // after owner1 approves: task exists (single vote); after owner2 approves the same calldata: full vote and queued
        vm.prank(owner1);
        sra.admit(orch);
        vm.prank(owner2);
        sra.admit(orch);

        // if the taskIds match, the same calldata call after the hold can complete execution
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.admit(orch);
        assertTrue(sra.isAdmitted(orch));
        // expectedTaskId itself is not directly queryable (internal state); "execution completes" is the indirect proof
        assertTrue(expectedTaskId != bytes32(0));
    }

    // ------------------------------------------------------------------------
    // Veto (cancelPending)
    // ------------------------------------------------------------------------

    /// either Safe can veto to discard a queued change; after the veto the flow restarts.
    function test_Veto_CancelsPendingAdmit() public {
        address orch = makeAddr("orch");

        vm.prank(owner1);
        sra.admit(orch);
        vm.prank(owner2);
        sra.admit(orch);

        // owner1 changes their mind: cancelPending discards the task
        bytes32 taskId = keccak256(abi.encodeWithSignature("admit(address)", orch));
        vm.prank(owner1);
        sra.cancelPending(taskId);

        vm.roll(block.number + SRA_CANCEL_HOLD);
        // the original task was deleted: the third call is a fresh submission (first vote), not an execution
        // resubmission must be initiated by an owner (the governance library's approve branch requires isOwner)
        vm.prank(owner1);
        sra.admit(orch);
        assertFalse(sra.isAdmitted(orch));
    }

    /// a non-owner cannot veto.
    function test_Veto_NonOwner_Reverts() public {
        bytes32 taskId = keccak256("whatever");
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.NotOwner.selector, makeAddr("stranger")));
        sra.cancelPending(taskId);
    }

    // ------------------------------------------------------------------------
    // NO_HOLD: correctVolume full-vote immediate execution
    // ------------------------------------------------------------------------

    /// the unanimousNoHold path — the second vote executes immediately (correctVolume takes effect within the verification window).
    function test_CorrectVolume_NoHold_SecondApprovalExecutesImmediately() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1); // posting period
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qPostEnd(0) + 1); // verification window
        vm.prank(owner1);
        sra.correctVolume(orch, 0, FixedU18.wrap(250e18));
        // after the first vote not effective (not full vote): the value is still the posted value
        FilecoinPayVolume memory f1 = sra.fpvOf(0, orch);
        assertEq(FixedU18.unwrap(f1.usd), 100e18);

        vm.prank(owner2);
        sra.correctVolume(orch, 0, FixedU18.wrap(250e18)); // second vote executes immediately

        FilecoinPayVolume memory f2 = sra.fpvOf(0, orch);
        assertEq(FixedU18.unwrap(f2.usd), 250e18);
    }

    /// before correctVolume's second vote (not a full vote), a repeat vote reverts AlreadyApproved.
    function test_CorrectVolume_SameOwnerTwice_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);
        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));
        vm.roll(_qPostEnd(0) + 1);

        vm.prank(owner1);
        sra.correctVolume(orch, 0, FixedU18.wrap(_fpv(200e18)));
        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.AlreadyApproved.selector));
        sra.correctVolume(orch, 0, FixedU18.wrap(_fpv(200e18)));
    }

    // ------------------------------------------------------------------------
    // taskId consistency: array parameter normalization (I2 risk)
    // ------------------------------------------------------------------------

    /// Strategy 6/I2: different setAdmittedLists array orders -> different calldata -> different taskIds
    /// -> the two Safes approve different tasks, each with only one vote; the change does not take effect
    /// (task deadlock risk). With the allowlist event-only, "not taking effect" = no AdmittedListsUpdated emitted.
    function test_TaskId_DifferentArrayOrder_DoesNotMerge() public {
        address usdc = makeAddr("usdc");
        address usdt = makeAddr("usdt");

        vm.recordLogs();
        vm.prank(owner1);
        sra.setAdmittedLists(_asArray(usdc, usdt), _asArray(address(0), address(0)));
        vm.prank(owner2);
        // owner2 submits the reverse order: different calldata -> different taskId -> no merge
        sra.setAdmittedLists(_asArray(usdt, usdc), _asArray(address(0), address(0)));

        // the two votes are spread across two different tasks, each unable to reach a full vote -> the change never takes effect (I2 deadlock)
        vm.roll(block.number + SRA_CANCEL_HOLD + 1000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != ServiceRewardsActor.AdmittedListsUpdated.selector,
                "no AdmittedListsUpdated emitted"
            );
        }
    }

    /// Strategy 6/I2 control: same order (same calldata) -> two votes + hold -> execution takes effect.
    function test_TaskId_SameArrayOrder_Executes() public {
        address usdc = makeAddr("usdc");
        address[] memory stablecoins = _asArray(usdc, address(0));

        vm.prank(owner1);
        sra.setAdmittedLists(stablecoins, _asArray(address(0), address(0)));
        vm.prank(owner2);
        sra.setAdmittedLists(stablecoins, _asArray(address(0), address(0)));

        vm.roll(block.number + SRA_CANCEL_HOLD);
        // execution succeeded: the executing call emits the full-array snapshot (event-only allowlist,
        // exclusive update — the emitted arrays are the authoritative new allowlist).
        vm.expectEmit(false, false, false, true, address(sra));
        emit ServiceRewardsActor.AdmittedListsUpdated(stablecoins, _asArray(address(0), address(0)));
        sra.setAdmittedLists(stablecoins, _asArray(address(0), address(0)));
    }

    // ------------------------------------------------------------------------
    // E1: replaceOwner (owner rotation, unanimousNoHold path — aligned with upstream SWA)
    // ------------------------------------------------------------------------

    /// E1: replaceOwner uses unanimousNoHold — the second approval executes immediately,
    ///     revoking the old owner and adding the new one; the old owner can no longer vote,
    ///     the new owner can (behavioral ownership assertion, matching SWA which exposes no isOwner view).
    function test_ReplaceOwner_SecondApproval_ExecutesImmediately() public {
        address newOwner = makeAddr("sra-owner3");

        vm.prank(owner1);
        sra.replaceOwner(owner1, newOwner); // first vote only: not a full vote, ownership unchanged
        vm.prank(owner2);
        sra.replaceOwner(owner1, newOwner); // second vote executes immediately (unanimousNoHold)

        // old owner revoked: owner1 can no longer vote on a fresh governance task
        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.NotOwner.selector, owner1));
        sra.admit(makeAddr("orch-after-rotation"));

        // new owner active: newOwner's first vote on a fresh task succeeds
        vm.prank(newOwner);
        sra.admit(makeAddr("orch-new-owner-vote")); // no revert => newOwner is an owner
    }

    /// Any address type is accepted, so unanimity is the only gate on who becomes an owner.
    function test_ReplaceOwner_EoaNewOwner_Accepted() public {
        address eoaOwner = makeAddr("eoa-owner");

        vm.prank(owner1);
        sra.replaceOwner(owner1, eoaOwner); // first vote only: approve, body not executed
        vm.prank(owner2);
        sra.replaceOwner(owner1, eoaOwner); // second vote executes immediately

        // old owner revoked
        vm.prank(owner1);
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.NotOwner.selector, owner1));
        sra.admit(makeAddr("orch-after-eoa-rotation"));

        // the EOA is a full owner
        vm.prank(eoaOwner);
        sra.admit(makeAddr("orch-eoa-vote")); // no revert => eoaOwner is an owner
    }

    /// E1: a non-owner calling replaceOwner is rejected on the first vote (NotOwner).
    function test_ReplaceOwner_NonOwner_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.NotOwner.selector, stranger));
        sra.replaceOwner(owner1, makeAddr("new-owner"));
    }

    // ------------------------------------------------------------------------
    // E2: constructor parameter validation (deployment-time bounds, aligned with setPricingParams)
    // ------------------------------------------------------------------------

    /// E2: the constructor rejects invalid configuration — priceBand > BASIS_POINTS /
    ///     epochsPerQuarter=0 (each reverts InvalidParameter at deploy).
    function test_Constructor_InvalidParams_Reverts() public {
        // priceBand > BASIS_POINTS
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        new ServiceRewardsActor(
            owner1,
            owner2,
            Epoch.wrap(EPOCHS_PER_QUARTER),
            Epoch.wrap(POST_PERIOD),
            Epoch.wrap(VERIFICATION_WINDOW),
            Epoch.wrap(SRA_CANCEL_HOLD),
            Epoch.wrap(ACTIVATION_EPOCH),
            MIN_LOT,
            10001
        );

        // epochsPerQuarter == 0
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        new ServiceRewardsActor(
            owner1,
            owner2,
            Epoch.wrap(0),
            Epoch.wrap(POST_PERIOD),
            Epoch.wrap(VERIFICATION_WINDOW),
            Epoch.wrap(SRA_CANCEL_HOLD),
            Epoch.wrap(ACTIVATION_EPOCH),
            MIN_LOT,
            PRICE_BAND
        );
    }

    // ------------------------------------------------------------------------
    // F2: setAdmittedLists allowlist array-length bound
    // ------------------------------------------------------------------------

    /// F2: setAdmittedLists with an allowlist array above MAX_ALLOWLIST (64) reverts InvalidParameter at body execution.
    function test_SetAdmittedLists_TooManyEntries_Reverts() public {
        address[] memory stablecoins = new address[](65);
        for (uint256 i = 0; i < stablecoins.length; i++) {
            stablecoins[i] = makeAddr(string.concat("coin", vm.toString(i)));
        }

        vm.prank(owner1);
        sra.setAdmittedLists(stablecoins, new address[](0));
        vm.prank(owner2);
        sra.setAdmittedLists(stablecoins, new address[](0));
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        sra.setAdmittedLists(stablecoins, new address[](0));
    }

    // ------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------

    function _asArray(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
