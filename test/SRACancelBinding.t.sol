// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// SRA cancelBinding tests — governance-level release of a single binding (issue #34)
//
// cancelBinding is a spec-external governance method (unanimousNoHold, immediate — the same
// governance level as reassignBinding, spec §4.2): it deletes bindings[pairId] so the pair
// returns to unclaimed and becomes claimable again.
//
// Guard semantics: cancel requires a *live* binding — boundId != 0 AND the bound id is still
// admitted. A removed orchestrator's binding is already equivalent-unclaimed under registerPairs
// semantics (any admitted orchestrator can claim it), so canceling it would be a no-op and reverts
// PairNotBound. This guard is the exact mirror of registerPairs's AlreadyBound check, which keeps
// claim and cancel mutually exclusive on every pair: registerPairs claims exactly when cancel
// reverts, and vice versa.
//
// The event carries the released orchestrator identity (three indexed args, like BindingDeclared/
// BindingReassigned): after the delete, bindingOf returns 0, so without the identity field an
// off-chain indexer could not tell who lost the binding. The identity is the admit-time
// orchestrator (the OrchestratorInfo reverse index, written once at addOrchestrator) — it does
// not move with replaceWallet: cancel releases the binding right of that identity, not of its
// replaceable payout wallet.

import {SRATestBase} from "./SRATestBase.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {Binding} from "../src/lib/SraTypes.sol";
import {UnanimousGovernance} from "../src/lib/UnanimousGovernance.sol";

contract SRACancelBindingTest is SRATestBase {
    /// pairId = keccak256(abi.encode(payer, operator)) — mirrors the contract's _pairId helper
    /// (the assembly version is byte-identical to abi.encode; asserted in the PairNotBound checks).
    function _pairId(address payer, address operator) internal pure returns (bytes32) {
        return keccak256(abi.encode(payer, operator));
    }

    /// governance release: two Safe approvals, the second executes immediately (unanimousNoHold).
    function _cancelBinding(address payer, address operator) internal {
        vm.prank(owner1);
        sra.cancelBinding(payer, operator);
        vm.prank(owner2);
        sra.cancelBinding(payer, operator);
    }

    // ------------------------------------------------------------------------
    // Happy path
    // ------------------------------------------------------------------------

    /// a live binding is released: after governance cancel, bindingOf returns address(0) (unclaimed).
    function test_CancelBinding_Success_UnbindsPair() public {
        address orch = makeAddr("orch");
        _admit(orch, orch);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orch, pairs);
        assertEq(sra.bindingOf(payer, operator), orch);

        _cancelBinding(payer, operator);

        assertEq(sra.bindingOf(payer, operator), address(0));
    }

    /// released pairs return to unclaimed: another admitted orchestrator can claim the same pair
    /// (consistent with registerPairs's removed-as-unclaimed semantics, spec §4.2).
    function test_CancelBinding_PairReclaimable_ByOtherOrch() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB");
        _admit(orchA, orchA);
        _admit(orchB, orchB);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orchA, pairs);

        _cancelBinding(payer, operator);
        assertEq(sra.bindingOf(payer, operator), address(0));

        _registerPairsAs(orchB, pairs); // claimable after release
        assertEq(sra.bindingOf(payer, operator), orchB);
    }

    /// the release emits BindingCanceled(payer, operator, admitIdentity) at the execution call
    /// (here admitIdentity == orch == wallet; the distinct-wallet case is covered below).
    function test_CancelBinding_EmitsBindingCanceled() public {
        address orch = makeAddr("orch");
        _admit(orch, orch);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orch, pairs);

        vm.prank(owner1);
        sra.cancelBinding(payer, operator);
        vm.expectEmit(true, true, true, false, address(sra));
        emit ServiceRewardsActor.BindingCanceled(payer, operator, orch);
        vm.prank(owner2); // second approval executes immediately
        sra.cancelBinding(payer, operator);
    }

    /// the third event arg is the *admit-time orchestrator identity*, not the payout wallet: a bound
    /// pair whose orchestrator admitted a distinct wallet still emits the orchestrator at cancel —
    /// releasing the binding releases the identity's binding right, and the wallet is only the
    /// replaceable payout address.
    function test_CancelBinding_EmitsIdentity_WhenWalletDiffersFromOrch() public {
        address orch = makeAddr("orch");
        address distinctWallet = makeAddr("distinct-wallet");
        _admit(orch, distinctWallet);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orch, pairs);

        vm.prank(owner1);
        sra.cancelBinding(payer, operator);
        vm.expectEmit(true, true, true, false, address(sra));
        emit ServiceRewardsActor.BindingCanceled(payer, operator, orch);
        vm.prank(owner2); // second approval executes immediately
        sra.cancelBinding(payer, operator);
    }

    /// the identity does not move with the payout wallet (spec §3.2): after replaceWallet re-points
    /// the wallet, cancel still emits the *admit-time* orchestrator — the binding right stays with
    /// the identity, not with whichever wallet currently receives payouts.
    function test_CancelBinding_EmitsAdmitIdentity_AfterReplaceWallet() public {
        address orch = makeAddr("orch");
        address origWallet = makeAddr("orig-wallet");
        address newWallet = makeAddr("new-wallet");
        _admit(orch, origWallet);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orch, pairs);

        // governance wallet swap: identity and binding stay put, only the wallet field re-points
        vm.prank(owner1);
        sra.replaceWallet(orch, newWallet, "");
        vm.prank(owner2);
        sra.replaceWallet(orch, newWallet, ""); // second approval executes immediately

        vm.prank(owner1);
        sra.cancelBinding(payer, operator);
        vm.expectEmit(true, true, true, false, address(sra));
        emit ServiceRewardsActor.BindingCanceled(payer, operator, orch); // admit-time identity, not newWallet
        vm.prank(owner2); // second approval executes immediately
        sra.cancelBinding(payer, operator);
    }

    // ------------------------------------------------------------------------
    // Failure paths (guard + governance)
    // ------------------------------------------------------------------------

    /// canceling a pair that was never bound reverts PairNotBound(pairId) at body execution.
    function test_CancelBinding_NotBound_Reverts() public {
        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        bytes32 pairId = _pairId(payer, operator);

        vm.prank(owner1);
        sra.cancelBinding(payer, operator);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PairNotBound.selector, pairId));
        vm.prank(owner2); // second approval executes immediately and reverts at the guard
        sra.cancelBinding(payer, operator);
    }

    /// cancel is not idempotent: after a release the pair is unbound, and a second cancel reverts
    /// PairNotBound — releasing an already-unclaimed pair is a no-op and is rejected.
    function test_CancelBinding_DoubleCancel_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch, orch);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orch, pairs);
        _cancelBinding(payer, operator);

        bytes32 pairId = _pairId(payer, operator);
        vm.prank(owner1);
        sra.cancelBinding(payer, operator);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PairNotBound.selector, pairId));
        vm.prank(owner2); // second approval executes immediately and reverts at the guard
        sra.cancelBinding(payer, operator);
    }

    /// a removed orchestrator's binding is equivalent-unclaimed under registerPairs semantics
    /// (any admitted orchestrator can claim it); canceling it would be a no-op, so it reverts
    /// PairNotBound. The pair stays claimable — the removed binding is left for the next claim.
    function test_CancelBinding_RemovedOrch_Reverts() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB");
        _admit(orchA, orchA);
        _admit(orchB, orchB);

        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(payer, operator);
        _registerPairsAs(orchA, pairs);
        _crankQuarter0(); // lift the §3.2 remove guard (q0 bound + submitted)
        _remove(orchA, ""); // binding stays in storage but reads as unclaimed (spec §4.2)

        bytes32 pairId = _pairId(payer, operator);
        vm.prank(owner1);
        sra.cancelBinding(payer, operator);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PairNotBound.selector, pairId));
        vm.prank(owner2); // second approval executes immediately and reverts at the guard
        sra.cancelBinding(payer, operator);

        // the pair stays claimable by another orchestrator (registerPairs sees it as unclaimed)
        _registerPairsAs(orchB, pairs);
        assertEq(sra.bindingOf(payer, operator), orchB);
    }

    /// governance gate: a non-Safe caller is rejected at the approval step (NotOwner).
    function test_CancelBinding_NonOwner_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UnanimousGovernance.NotOwner.selector, stranger));
        sra.cancelBinding(makeAddr("payer"), makeAddr("operator"));
    }
}
