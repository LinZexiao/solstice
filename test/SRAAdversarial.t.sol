// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// Adversarial input matrix for the external write surface (S1, QA system fix)
//
// Background: the V1/V2/V3 overflow audit exposed a
// structural QA gap — every verification layer (deterministic/fuzz/invariant/
// differential) exercised inputs inside the "business domain" and none probed
// malicious extreme inputs. This suite is the adversarial layer (S1): for each
// external write function it enumerates the boundary values of every numeric /
// address / array parameter and asserts the exact revert (or acceptance) —
// locking the code-enforced input domain as executable behavior.
//
// Principles:
//   * every revert assertion uses an exact error selector (no bare expectRevert)
//   * existing coverage is NOT duplicated: V1/V2/V3 max-value rejects live in
//     SRAOverflowDoS.t.sol; B1 minLot upper bound in SRAQuarter; C1/F2 array
//     length bounds in SRARegistry/SRAGovernance; E1/E2 in SRAGovernance.
//     This file adds: q-parameter window boundaries, fpv exact-limit accept /
//     limit+1 reject, zero-address probes, setPricingParams full boundary grid,
//     empty-array semantics, and the multi-orchestrator aggregate bound.

import {SERVICE_ID, Share} from "../src/lib/FVMRewardTypes.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {Binding} from "../src/lib/SraTypes.sol";
import {IsASafe} from "../src/lib/IsASafe.sol";
import {SRATestBase} from "./SRATestBase.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";

contract SRAAdversarial is SRATestBase {
    // ------------------------------------------------------------------------
    // 1. q-parameter window boundaries (exact selectors)
    // ------------------------------------------------------------------------

    /// q = a future quarter: posting window not yet open -> NotInPostingWindow(q).
    function test_PostVolume_FutureQuarter_NotInPostingWindow() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1); // inside Q0's posting window
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotInPostingWindow.selector, uint64(10)));
        sra.postVolume(10, FixedU18.wrap(_fpv(100e18)));
    }

    /// q = uint64.max: with Epoch now uint64 (cherry-picked 8c3eff9), uint64.max × 1000 ≈ 2^83 > 2^64,
    /// so the _qEnd range guard fires -> InvalidParameter (this is the guard becoming the rejection
    /// path for MaxQuarter probes; the huge-EPOCHS_PER_QUARTER simulation below remains as an extra
    /// direct guard test).
    function test_PostVolume_MaxQuarter_RangeGuard_InvalidParameter() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        sra.postVolume(type(uint64).max, FixedU18.wrap(_fpv(100e18)));
    }

    /// correctVolume on a future quarter: verification window not open -> NotInVerificationWindow(q)
    /// (unanimousNoHold: the second approval executes the body and reverts).
    function test_CorrectVolume_FutureQuarter_NotInVerificationWindow() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qVerifyEnd(0)); // inside Q0's verification window
        vm.prank(owner1);
        sra.correctVolume(orch, 10, FixedU18.wrap(_fpv(100e18)));
        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotInVerificationWindow.selector, uint64(10)));
        sra.correctVolume(orch, 10, FixedU18.wrap(_fpv(100e18)));
    }

    /// q = uint64.max on correctVolume -> _qEnd range guard fires (uint64 width) -> InvalidParameter.
    function test_CorrectVolume_MaxQuarter_RangeGuard_InvalidParameter() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qVerifyEnd(0));
        vm.prank(owner1);
        sra.correctVolume(orch, type(uint64).max, FixedU18.wrap(_fpv(100e18)));
        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        sra.correctVolume(orch, type(uint64).max, FixedU18.wrap(_fpv(100e18)));
    }

    /// aggregatedFilecoinPayVolume on a future quarter (before its binding) -> NotBound(q).
    function test_AggregatedFilecoinPayVolume_FutureQuarter_NotBound() public {
        vm.roll(_qVerifyEnd(0) + 1); // Q0 binding complete
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotBound.selector, uint64(10)));
        sra.aggregatedFilecoinPayVolume(10);
    }

    /// q = uint64.max on qEnd -> _qEnd range guard fires (uint64 width) -> InvalidParameter.
    function test_QEnd_MaxQuarter_RangeGuard_InvalidParameter() public {
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        sra.qEnd(type(uint64).max);
    }

    /// q = uint64.max on submitShares -> _afterBinding calls _qEnd, guard fires (uint64 width) -> InvalidParameter.
    function test_SubmitShares_MaxQuarter_RangeGuard_InvalidParameter() public {
        vm.roll(_qVerifyEnd(0) + 1);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        sra.submitShares(type(uint64).max);
    }

    /// The _qEnd range guard itself, exercised directly: with EPOCHS_PER_QUARTER = 2^40,
    /// uint64.max × 2^40 ≈ 2^104 > 2^64 -> end beyond type(uint64).max -> InvalidParameter
    /// (same rejection path as the MaxQuarter probes above, but with a config-amplified q).
    function test_QEnd_HugeQuarter_RangeGuard_InvalidParameter() public {
        ServiceRewardsActor big = new ServiceRewardsActor(
            owner1,
            owner2,
            Epoch.wrap(1 << 40), // EPOCHS_PER_QUARTER: uint64.max × 2^40 ≈ 2^104 > 2^64
            Epoch.wrap(POST_PERIOD),
            Epoch.wrap(VERIFICATION_WINDOW),
            Epoch.wrap(SRA_CANCEL_HOLD),
            Epoch.wrap(ACTIVATION_EPOCH),
            MIN_LOT,
            PRICE_BAND
        );
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        big.qEnd(type(uint64).max);
    }

    // ------------------------------------------------------------------------
    // 2. FilecoinPayVolume single-USD-total exact-limit boundaries (accept at limit / reject limit+1)
    //    (FIP-0118 FIPs#1275: FilecoinPayVolume is a single USD total; MAX_FILECOIN_PAY_VOLUME_USD = 1e30 domain bound)
    // ------------------------------------------------------------------------

    /// usd == MAX_FILECOIN_PAY_VOLUME_USD(1e30) is accepted (domain boundary).
    function test_Fpv_Usd_AtMax_Accepted() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(1e30));
        assertEq(FixedU18.unwrap(sra.fpvOf(0, orch).usd), 1e30);
    }

    /// usd == MAX_FILECOIN_PAY_VOLUME_USD + 1 is rejected with InvalidParameter.
    function test_Fpv_Usd_OverMax_Rejected() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        sra.postVolume(0, FixedU18.wrap(_fpv(1e30 + 1)));
    }

    // ------------------------------------------------------------------------
    // 3. Zero-address probes (address-parameter adversarial cases)
    // ------------------------------------------------------------------------

    /// Governance may admit the zero address (no zero-address guard in admit);
    /// it becomes an admitted orchestrator that can never post (no caller can be 0).
    function test_Admit_ZeroAddress_Accepted() public {
        vm.prank(owner1);
        sra.admit(address(0));
        vm.prank(owner2);
        sra.admit(address(0));
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.admit(address(0));
        assertTrue(sra.isAdmitted(address(0)));
    }

    /// freeze(0) on a never-admitted zero address -> NotAdmitted(0) at body execution.
    function test_Freeze_ZeroAddress_NotAdmitted() public {
        vm.prank(owner1);
        sra.freeze(address(0));
        vm.prank(owner2);
        sra.freeze(address(0));
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotAdmitted.selector, address(0)));
        sra.freeze(address(0));
    }

    /// A zero payer address is a legal binding pair (pairId = keccak(0, operator));
    /// no zero-address guard exists — the behavior is locked as accepted.
    function test_RegisterPairs_ZeroPayer_Accepted() public {
        address orch = makeAddr("orch");
        address operator = makeAddr("op");
        _admit(orch);

        Binding[] memory pairs = new Binding[](1);
        pairs[0] = Binding({payer: address(0), operator: operator});
        _registerPairsAs(orch, pairs);
        assertEq(sra.bindingOf(address(0), operator), orch);
    }

    /// replaceOwner with the zero address as newOwner -> NotSafeProxy(0) (EXTCODESIZE(0) = 0 <= 56).
    function test_ReplaceOwner_ZeroNewOwner_NotSafeProxy() public {
        vm.prank(owner1);
        sra.replaceOwner(owner1, address(0));
        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(IsASafe.NotSafeProxy.selector, address(0)));
        sra.replaceOwner(owner1, address(0));
    }

    /// reassignBinding to the zero address -> NotAdmitted(0) at body execution.
    function test_ReassignBinding_ZeroTarget_NotAdmitted() public {
        address payer = makeAddr("payer");
        address operator = makeAddr("operator");
        vm.prank(owner1);
        sra.reassignBinding(payer, operator, address(0));
        vm.prank(owner2);
        sra.reassignBinding(payer, operator, address(0));
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotAdmitted.selector, address(0)));
        sra.reassignBinding(payer, operator, address(0));
    }

    // ------------------------------------------------------------------------
    // 4. setPricingParams full parameter boundary grid
    //    (B1 already covers minLot = MAX_LOT_USD + 1 rejection; this adds the
    //     remaining accept edges of each parameter)
    // ------------------------------------------------------------------------

    function _setPricingParams(uint256 minLot, uint256 priceBand) internal {
        vm.prank(owner1);
        sra.setPricingParams(minLot, priceBand);
        vm.prank(owner2);
        sra.setPricingParams(minLot, priceBand);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.setPricingParams(minLot, priceBand);
    }

    /// priceBand = 0 (tightest band) is a valid parameter — accepted.
    function test_SetPricingParams_PriceBandZero_Accepted() public {
        _setPricingParams(MIN_LOT, 0);
        (uint256 minLot, uint256 priceBand) = sra.getPricingParams();
        assertEq(minLot, MIN_LOT);
        assertEq(priceBand, 0);
    }

    /// priceBand = BASIS_POINTS (100%) is a valid parameter — accepted.
    function test_SetPricingParams_PriceBandFull_Accepted() public {
        _setPricingParams(MIN_LOT, 10_000);
        (, uint256 priceBand) = sra.getPricingParams();
        assertEq(priceBand, 10_000);
    }

    /// minLot = 1e30 (large) is accepted (governance-trusted parameter for the off-chain indexer).
    function test_SetPricingParams_MinLotLarge_Accepted() public {
        _setPricingParams(1e30, PRICE_BAND);
        (uint256 minLot,) = sra.getPricingParams();
        assertEq(minLot, 1e30);
    }

    /// minLot = 0 (no floor) is accepted.
    function test_SetPricingParams_MinLotZero_Accepted() public {
        _setPricingParams(0, PRICE_BAND);
        (uint256 minLot,) = sra.getPricingParams();
        assertEq(minLot, 0);
    }

    // ------------------------------------------------------------------------
    // 5. Array-parameter edges (empty arrays)
    //    (C1/F2 already cover the over-long side; the empty side locks the
    //     no-op / clear semantics)
    // ------------------------------------------------------------------------

    /// registerPairs with an empty array is a no-op and succeeds.
    function test_RegisterPairs_EmptyArray_Accepted() public {
        address orch = makeAddr("orch");
        _admit(orch);

        Binding[] memory empty = new Binding[](0);
        _registerPairsAs(orch, empty);
        assertEq(sra.admittedCount(), 1); // state unchanged
    }

    /// setAdmittedLists is event-only (snapshot semantics): the executed call emits
    /// AdmittedListsUpdated carrying the full arrays; empty arrays emit an empty snapshot.
    function test_SetAdmittedLists_EmitsFullArrays() public {
        address token = makeAddr("usdc");
        address payContract = makeAddr("pay");

        // populate
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        address[] memory payContracts = new address[](1);
        payContracts[0] = payContract;
        vm.prank(owner1);
        sra.setAdmittedLists(tokens, payContracts);
        vm.prank(owner2);
        sra.setAdmittedLists(tokens, payContracts);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectEmit(false, false, false, true, address(sra));
        emit ServiceRewardsActor.AdmittedListsUpdated(tokens, payContracts);
        sra.setAdmittedLists(tokens, payContracts);

        // clear with empty arrays (the Filecoin Pay side has no public query;
        // the stablecoin side is observable and the two clears share one path)
        address[] memory empty = new address[](0);
        vm.prank(owner1);
        sra.setAdmittedLists(empty, empty);
        vm.prank(owner2);
        sra.setAdmittedLists(empty, empty);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectEmit(false, false, false, true, address(sra));
        emit ServiceRewardsActor.AdmittedListsUpdated(empty, empty);
        sra.setAdmittedLists(empty, empty);
    }

    // ------------------------------------------------------------------------
    // 6. Multi-orchestrator aggregate boundary
    // ------------------------------------------------------------------------

    /// Two orchestrators each posting MAX_STABLE_USD: total = 2e30 stays far below
    /// 2^256 and _computeShares' usds[i] * 1e18 = 1e48 does not overflow — shares
    /// still sum to exactly 1e18 (multi-party V3 variant stays safe).
    function test_MultiOrchestrator_AtMaxStableUsd_ConservesShares() public {
        address a = makeAddr("agg-a");
        address b = makeAddr("agg-b");
        _admit(a);
        _admit(b);

        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(1e30));
        _postAs(b, 0, _fpv(1e30));

        vm.roll(_qVerifyEnd(0) + 1);
        sra.submitShares(0);

        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(_sumShares(shares), 1e18);
    }

    // ------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------

    // ------------------------------------------------------------------------
    // Mirror-advance direction guard + window-overlap constructor constraint
    // ------------------------------------------------------------------------

    /// Constructor rejects window overlap: a quarter's verification window must close before the
    /// next quarter begins (POST + VERIFY <= EPOCHS), otherwise a governance CorrectVolume could
    /// target an already-advanced quarter and rewind the mirror.
    function test_Ctor_WindowOverlap_Rejected() public {
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        new ServiceRewardsActor(
            owner1,
            owner2,
            Epoch.wrap(500), // EPOCHS
            Epoch.wrap(300), // POST
            Epoch.wrap(400), // VERIFY: 300 + 400 = 700 > 500 -> overlap
            Epoch.wrap(SRA_CANCEL_HOLD),
            Epoch.wrap(ACTIVATION_EPOCH),
            MIN_LOT,
            PRICE_BAND
        );
    }

    /// Constructor rejects when the uint64 window sum wraps: POST + VERIFY = 2^63 + 2^63 = 2^64, which
    /// wraps to 0 in the uint64 domain — a uint64-only check would pass (0 < EPOCHS = 2^64 - 1) and
    /// admit an overlapping window. The uint256 sum (2^64) against EPOCHS must reject.
    function test_Ctor_WindowSum_Uint64Wrap_Rejected() public {
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        new ServiceRewardsActor(
            owner1,
            owner2,
            Epoch.wrap(type(uint64).max), // EPOCHS: 2^64 - 1
            Epoch.wrap(uint64(2 ** 63)), // POST
            Epoch.wrap(uint64(2 ** 63)), // VERIFY: uint64 sum wraps to 0; uint256 sum = 2^64 > EPOCHS -> rejected
            Epoch.wrap(SRA_CANCEL_HOLD),
            Epoch.wrap(ACTIVATION_EPOCH),
            MIN_LOT,
            PRICE_BAND
        );
    }

    /// Constructor rejects the exact boundary: POST + VERIFY == EPOCHS leaves the window's last
    /// epoch inside the next quarter's mirror window — _inVerificationWindow allows the write
    /// while _assertMirrorWindow rejects it (off-by-one dead zone), so the constraint is strict.
    function test_Ctor_WindowBoundary_Rejected() public {
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        new ServiceRewardsActor(
            owner1,
            owner2,
            Epoch.wrap(700), // EPOCHS
            Epoch.wrap(300), // POST
            Epoch.wrap(400), // VERIFY: 300 + 400 = 700 == EPOCHS -> rejected (strict)
            Epoch.wrap(SRA_CANCEL_HOLD),
            Epoch.wrap(ACTIVATION_EPOCH),
            MIN_LOT,
            PRICE_BAND
        );
    }

    /// A write must target the active or the next quarter: skipping a quarter (q > activeQ + 1)
    /// would misalign the prevFpv mirror (it can only hold activeQ - 1's data) — rejected by the
    /// mirror-window guard.
    /// A write may skip a gap quarter (a quarter with no volume is necessarily
    /// unwritten — postVolume rejects zero). The mirror jumps in one step, keeping prevFpv =
    /// activeQ-1's data (0 for a gap).
    function test_PostVolume_SkipsGapQuarter() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(2) + 1); // Q2 posting window; Q1 is a gap (no writes)
        _postAs(orch, 2, _fpv(100e18));
        assertEq(FixedU18.unwrap(sra.fpvOf(2, orch).usd), 100e18, "gap-skipped write lands in the active slot");
        assertEq(FixedU18.unwrap(sra.fpvOf(1, orch).usd), 0, "gap quarter has no contribution (prevFpv = 0)");
    }

    /// The governance path skips gap quarters the same way (CorrectVolume in Q2's
    /// verification window succeeds; Q1 was unwritten).
    function test_CorrectVolume_SkipsGapQuarter() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(2) + POST_PERIOD + 1); // Q2 verification window; activeQ still 0
        _correctVolume(orch, 2, _fpv(100e18));
        assertEq(FixedU18.unwrap(sra.fpvOf(2, orch).usd), 100e18, "governance write skips the gap quarter");
    }

    /// A no-volume quarter must not deadlock the system — q0 has volume,
    /// q1 is a gap, q2 must still accept writes.
    function test_GapQuarter_NoDeadlock() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a);
        _admit(b);

        vm.roll(_qEnd(0) + 1); // Q0 posting window
        _postAs(a, 0, _fpv(100e18));

        // Q1: nobody writes (all SPs have zero volume) — the gap.
        vm.roll(_qEnd(2) + 1); // Q2 posting window
        _postAs(b, 2, _fpv(50e18)); // must succeed
        assertEq(FixedU18.unwrap(sra.fpvOf(2, b).usd), 50e18, "post-gap write succeeds");
        assertEq(FixedU18.unwrap(sra.fpvOf(1, a).usd), 0, "gap quarter: prevFpv zero for q0's contributor");
        assertEq(FixedU18.unwrap(sra.fpvOf(1, b).usd), 0, "gap quarter: prevFpv zero for the new writer too");
    }

    function _sumShares(Share[] memory shares) internal pure returns (uint256 sum) {
        for (uint256 i = 0; i < shares.length; i++) {
            sum += FixedU18.unwrap(shares[i].share);
        }
    }
}
