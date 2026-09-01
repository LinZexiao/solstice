// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {StreamWeightActorTest} from "./StreamWeightActor.t.sol";
import {StreamWeightActor} from "../src/StreamWeightActor.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {IServiceRewardsActor} from "../src/interfaces/IServiceRewardsActor.sol";
import {SERVICE_ID} from "../src/lib/FVMRewardTypes.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";
import {GateParams, VolumeTarget} from "../src/lib/GateParams.sol";
import {UnanimousGovernance} from "../src/lib/UnanimousGovernance.sol";
import {SWA_TIMELOCK} from "../src/lib/FVMRewardMethod.sol";

/// @dev ERC-7201 storage slot of GateParamsInfo (src/lib/GateParams.sol: Solstice.GateParams).
///     GateParamsInfo layout: {uint64 lastCheckedQuarter; GateParams params;}, where params is
///     {VolumeTarget target; uint64 steps;} and VolumeTarget is {FixedU18 base; FixedU18 stepRatio;}
///     — so lastCheckedQuarter lives at the slot, target.base at slot+1, stepRatio at slot+2,
///     and steps at slot+3 (each FixedU18 is a full 32-byte word; steps is a uint64 in the low bits).
bytes32 constant GATE_PARAMS_SLOT = 0xf9abab00248d945495524c8caf6be2b837274c1becd1964fb3775f62fd6e4600;

/// @notice StreamWeightActor quarterly-gate tests: `setGateParams` (the only system-wide governance
///         method retaining a HOLD-epoch timelock after the W2 change) and its `quarterlyGateCheck`
///         counterpart. Covers the timelock's effective boundary (== vs < HOLD epochs), the
///         permissionless execution path, and the gate state machine (quarter advance, threshold
///         comparison, StepsComplete terminal state, not-yet-bound quarter).
contract StreamWeightGateTest is StreamWeightActorTest {
    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _gateParams(uint256 base, uint256 stepRatio, uint64 steps)
        internal
        pure
        returns (GateParams memory params)
    {
        params.target = VolumeTarget({base: FixedU18.wrap(base), stepRatio: FixedU18.wrap(stepRatio)});
        params.steps = steps;
    }

    function _sraMock() internal returns (IServiceRewardsActor sra) {
        sra = IServiceRewardsActor(makeAddr("sra")); // same label the parent setUp used to mock EPOCHS_PER_QUARTER
    }

    function _mockFpv(IServiceRewardsActor sra, uint64 quarter, uint256 value) internal {
        vm.mockCall(
            address(sra),
            abi.encodeWithSelector(IServiceRewardsActor.aggregatedFilecoinPayVolume.selector, quarter),
            abi.encode(FixedU18.wrap(value))
        );
    }

    function _mockQEnd(IServiceRewardsActor sra, uint64 quarter, uint64 end) internal {
        vm.mockCall(
            address(sra),
            abi.encodeWithSelector(IServiceRewardsActor.qEnd.selector, quarter),
            abi.encode(Epoch.wrap(end))
        );
    }

    /// @dev Both owners submit the same params: unanimous approval reached, execution deferred by HOLD.
    function _submitGateParams(GateParams memory params) internal {
        vm.prank(owner1);
        actor.setGateParams(params);
        vm.prank(owner2);
        actor.setGateParams(params);
    }

    /// @dev Reads the ERC-7201 GateParamsInfo slot the SWA's own GateParamsLibrary writes.
    function _storedGateParams()
        internal
        view
        returns (uint256 base, uint256 stepRatio, uint64 steps, uint64 lastCheckedQuarter)
    {
        base = uint256(vm.load(address(actor), bytes32(uint256(GATE_PARAMS_SLOT) + 1)));
        stepRatio = uint256(vm.load(address(actor), bytes32(uint256(GATE_PARAMS_SLOT) + 2)));
        steps = uint64(uint256(vm.load(address(actor), bytes32(uint256(GATE_PARAMS_SLOT) + 3))));
        lastCheckedQuarter = uint64(uint256(vm.load(address(actor), GATE_PARAMS_SLOT)));
    }

    // -------------------------------------------------------------------------
    // setGateParams — access control and the HOLD-epoch timelock (W2 core semantics)
    // -------------------------------------------------------------------------

    function test_SetGateParams_NotOwner_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.NotOwner.selector, stranger));
        actor.setGateParams(_gateParams(4000 ether, 2.7 ether, 0));
    }

    function test_SetGateParams_EmitsSubmittedAndApproved() public {
        GateParams memory params = _gateParams(4000 ether, 2.7 ether, 1);
        bytes32 taskId = keccak256(abi.encodePacked(StreamWeightActor.setGateParams.selector, abi.encode(params)));

        vm.expectEmit(true, true, true, true);
        emit UnanimousGovernance.Submitted(taskId);
        vm.prank(owner1);
        actor.setGateParams(params);

        vm.expectEmit(true, true, true, true);
        emit UnanimousGovernance.Approved(taskId, owner2);
        vm.prank(owner2);
        actor.setGateParams(params);
    }

    /// @dev The W2 timelock contract: after unanimous approval the old params stay effective through
    ///      the whole HOLD window (submission writes nothing), permissionless completion is blocked
    ///      one epoch before the hold elapses, and the new params land exactly at epoch == HOLD.
    function test_SetGateParams_OwnerSubmit_ParamsDeferred_UntilTimelock() public {
        GateParams memory params = _gateParams(4000 ether, 2.7 ether, 1);
        _submitGateParams(params);
        uint64 modified = uint64(block.number); // second vote's epoch — the hold starts counting here

        // Old (init) params still effective: 3500 ether / 2.7 / 0 steps, untouched by the submission.
        (uint256 base, uint256 stepRatio, uint64 steps,) = _storedGateParams();
        assertEq(base, 3500 ether);
        assertEq(stepRatio, 2.7 ether);
        assertEq(steps, 0);

        // < HOLD: permissionless execution still gated.
        vm.roll(modified + SWA_TIMELOCK - 1);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(
            abi.encodeWithSelector(UnanimousGovernance.HoldUntil.selector, Epoch.wrap(modified + SWA_TIMELOCK))
        );
        actor.setGateParams(params);

        // == HOLD (exact boundary): execution becomes permissionless and the new params land.
        vm.roll(modified + SWA_TIMELOCK);
        vm.prank(makeAddr("stranger"));
        actor.setGateParams(params);

        (base, stepRatio, steps,) = _storedGateParams();
        assertEq(base, 4000 ether);
        assertEq(stepRatio, 2.7 ether);
        assertEq(steps, 1);
    }

    /// @dev An approval not yet unanimous keeps the task in owner-only territory: a stranger cannot
    ///      trigger completion because the permissionless branch requires a full approval set.
    function test_SetGateParams_SingleOwnerVote_StrangerCannotComplete() public {
        GateParams memory params = _gateParams(4000 ether, 2.7 ether, 0);
        vm.prank(owner1);
        actor.setGateParams(params); // only one vote

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.NotOwner.selector, makeAddr("stranger")));
        actor.setGateParams(params);
    }

    // -------------------------------------------------------------------------
    // quarterlyGateCheck — gate state machine
    // -------------------------------------------------------------------------

    /// @dev fpv == threshold (3500 * 2.7^0): the boundary equality clears the gate, steps the
    ///      SERVICE_ID schedule once, and advances the checked quarter.
    function test_QuarterlyGateCheck_ThresholdCleared_StepsAndLandsWeight() public {
        _registerAndActivate(SERVICE_ID);
        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3500 ether);
        _mockQEnd(sra, 2, 1000);

        actor.quarterlyGateCheck(); // permissionless

        (uint256 base, uint256 stepRatio, uint64 steps, uint64 lastChecked) = _storedGateParams();
        assertEq(base, 3500 ether);
        assertEq(stepRatio, 2.7 ether);
        assertEq(steps, 1, "threshold cleared -> one step taken");
        assertEq(lastChecked, 2, "quarter advances past the init lastCheckedQuarter=1");

        // The step is queued to f02 as an uncancellable STEP_WEIGHT write and lands once the
        // mock's own timelock elapses: floor/vStart/cap = (0+3) * STEP, tStart = qEnd(2).
        vm.roll(block.number + SWA_TIMELOCK);
        rewardActor().mockSettle();
        (uint256 b, uint256 r, uint64 s,) = _storedGateParams();
        assertEq(b, 3500 ether);
        assertEq(r, 2.7 ether);
        assertEq(s, 1);
    }

    /// @dev fpv < threshold: no step, but the quarter still advances (each quarter is checked once).
    function test_QuarterlyGateCheck_BelowThreshold_NoStep_QuarterAdvances() public {
        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3499 ether);

        actor.quarterlyGateCheck();

        (,, uint64 steps, uint64 lastChecked) = _storedGateParams();
        assertEq(steps, 0, "below threshold -> no step");
        assertEq(lastChecked, 2);
    }

    /// @dev Successive checks advance one quarter each, independent of the threshold outcome.
    function test_QuarterlyGateCheck_QuarterAdvancesMonotonically() public {
        _registerAndActivate(SERVICE_ID);
        IServiceRewardsActor sra = _sraMock();
        _mockFpv(sra, 2, 3499 ether); // below
        _mockFpv(sra, 3, 3500 ether); // cleared (threshold for steps=0 is still 3500)
        _mockQEnd(sra, 3, 2000);

        actor.quarterlyGateCheck();
        actor.quarterlyGateCheck();

        (,, uint64 steps, uint64 lastChecked) = _storedGateParams();
        assertEq(lastChecked, 3);
        assertEq(steps, 1);
    }

    /// @dev Terminal state: with all 8 steps taken the gate is complete and rejects further checks.
    ///      The steps are driven to 8 through the governance path, re-exercising the setGateParams
    ///      timelock execution from the earlier tests.
    function test_QuarterlyGateCheck_StepsComplete_Reverts() public {
        GateParams memory done = _gateParams(3500 ether, 2.7 ether, 8);
        _submitGateParams(done);
        vm.roll(block.number + SWA_TIMELOCK);
        actor.setGateParams(done);

        (,, uint64 steps,) = _storedGateParams();
        assertEq(steps, 8);

        vm.expectRevert(StreamWeightActor.StepsComplete.selector);
        actor.quarterlyGateCheck();
    }

    /// @dev A quarter whose FilecoinPayVolume is not yet bound reverts through the SRA — the SWA
    ///      does not mask the NotBound guard (call too early), only the zero-volume case returns 0.
    function test_QuarterlyGateCheck_QuarterNotBound_Reverts() public {
        IServiceRewardsActor sra = _sraMock();
        vm.mockCallRevert(
            address(sra),
            abi.encodeWithSelector(IServiceRewardsActor.aggregatedFilecoinPayVolume.selector, uint64(2)),
            abi.encodeWithSelector(ServiceRewardsActor.NotBound.selector, uint64(2))
        );

        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotBound.selector, uint64(2)));
        actor.quarterlyGateCheck();
    }
}
