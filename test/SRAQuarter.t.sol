// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// SRA quarter state machine + FilecoinPayVolume + FIL pricing tests
//   window boundaries / CorrectVolume / AggregatedFilecoinPayVolume
//   FIP-0118 (FIPs#1275): FilecoinPayVolume is a single USD total — PRICE_BAND / FinalizeConversion
//   tests are obsolete after FIPs#1275 (off-chain conversion).
//
// Time model: Epoch = block.number; windows:
//   posting:      E < now <= E+POST
//   verification: E+POST < now <= E+POST+VERIFY
//   post-binding: now > E+POST+VERIFY

import {SRATestBase} from "./SRATestBase.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {FilecoinPayVolume} from "../src/lib/SraTypes.sol";

contract SRAQuarterTest is SRATestBase {
    // ------------------------------------------------------------------------
    // postVolume window boundaries
    // ------------------------------------------------------------------------

    /// posting within the window (E < now <= E+POST) succeeds.
    function test_PostVolume_PostingWindow_Success() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1); // E+1
        _postAs(orch, 0, _fpv(100e18));
        FilecoinPayVolume memory f = sra.fpvOf(0, orch);
        assertEq(FixedU18.unwrap(f.usd), 100e18);
    }

    /// E itself is not in the posting window (E < now, strictly less).
    function test_PostVolume_AtQuarterEnd_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0)); // now == E: posting not yet open
        vm.prank(orch);
        vm.expectRevert();
        sra.postVolume(0, FixedU18.wrap(_fpv(100e18)));
    }

    /// the posting window's right boundary is inclusive of E+POST (<=).
    function test_PostVolume_AtPostEnd_Inclusive() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qPostEnd(0)); // now == E+POST: allowed
        _postAs(orch, 0, _fpv(100e18));
        assertEq(FixedU18.unwrap(sra.fpvOf(0, orch).usd), 100e18);
    }

    /// E+POST+1 enters verification; posting is rejected.
    function test_PostVolume_AfterPostingWindow_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qPostEnd(0) + 1);
        vm.prank(orch);
        vm.expectRevert();
        sra.postVolume(0, FixedU18.wrap(_fpv(100e18)));
    }

    /// at most once per quarter — the second posting reverts (posted flag).
    function test_PostVolume_SecondPosting_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        vm.prank(orch);
        vm.expectRevert();
        sra.postVolume(0, FixedU18.wrap(_fpv(200e18)));
    }

    /// #7: zero posting is rejected — a zero total is equivalent to not posting, so
    ///     `usd == 0` unambiguously means "not posted" (postVolume requires > 0).
    function test_PostVolume_Zero_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        vm.prank(orch);
        vm.expectRevert(); // InvalidParameter — zero total rejected
        sra.postVolume(0, FixedU18.wrap(0));
    }

    /// #7: CorrectVolume(0) clears a posted value (equivalent to not posted) —
    ///     the orchestrator is excluded from the aggregate.
    function test_CorrectVolume_Zero_Clears() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qPostEnd(0) + 1); // verification window
        _correctVolume(orch, 0, 0); // clear to zero

        vm.roll(_qVerifyEnd(0) + 1); // post-binding
        assertEq(FixedU18.unwrap(sra.fpvOf(0, orch).usd), 0);
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 0);
    }

    // ------------------------------------------------------------------------
    // CorrectVolume (within the verification window)
    // ------------------------------------------------------------------------

    /// an upward correction within the verification window succeeds.
    function test_CorrectVolume_VerificationWindow_Upward() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qPostEnd(0) + 1); // verification window
        _correctVolume(orch, 0, _fpv(250e18));
        assertEq(FixedU18.unwrap(sra.fpvOf(0, orch).usd), 250e18);
    }

    /// bidirectional correction — downward succeeds.
    function test_CorrectVolume_Downward_Corrects() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qPostEnd(0) + 1);
        _correctVolume(orch, 0, _fpv(40e18));
        assertEq(FixedU18.unwrap(sra.fpvOf(0, orch).usd), 40e18);
    }

    /// multiple corrections within the window; the last one wins (whole replacement).
    function test_CorrectVolume_MultipleCorrections_LastWins() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qPostEnd(0) + 1);
        _correctVolume(orch, 0, _fpv(200e18));
        _correctVolume(orch, 0, _fpv(300e18));
        assertEq(FixedU18.unwrap(sra.fpvOf(0, orch).usd), 300e18);
    }

    /// an unposted orchestrator can be backfilled within the verification window (posted=false -> written).
    function test_CorrectVolume_BackfillUnposted() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qPostEnd(0) + 1); // unposted, straight into verification
        _correctVolume(orch, 0, _fpv(150e18));
        assertEq(FixedU18.unwrap(sra.fpvOf(0, orch).usd), 150e18);
    }

    /// the verification window's right boundary is inclusive of E+POST+VERIFY.
    function test_CorrectVolume_AtVerifyEnd_Inclusive() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1); // E+1: post within the posting window (E, E+POST]
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qVerifyEnd(0)); // now == E+POST+VERIFY: allowed
        _correctVolume(orch, 0, _fpv(200e18));
        assertEq(FixedU18.unwrap(sra.fpvOf(0, orch).usd), 200e18);
    }

    /// after the window closes (E+POST+VERIFY+1) CorrectVolume is rejected (value bound).
    function test_CorrectVolume_AfterVerificationWindow_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);

        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qVerifyEnd(0) + 1); // post-binding
        vm.prank(owner1);
        sra.correctVolume(orch, 0, FixedU18.wrap(_fpv(200e18)));
        vm.prank(owner2);
        vm.expectRevert(); // window closed
        sra.correctVolume(orch, 0, FixedU18.wrap(_fpv(200e18)));
    }

    // ------------------------------------------------------------------------
    // AggregatedFilecoinPayVolume (read-only bound value)
    // ------------------------------------------------------------------------

    /// aggregatedFilecoinPayVolume reverts NotBound before the window closes (distinguishable from zero declared volume).
    function test_AggregatedFilecoinPayVolume_BeforeBinding_RevertsNotBound() public {
        address orch = makeAddr("orch");
        _admit(orch);
        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        // Revert NotBound during posting/verification (not bound) — the SWA can distinguish this from a zero-volume quarter
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotBound.selector, 0));
        sra.aggregatedFilecoinPayVolume(0);
        vm.roll(_qVerifyEnd(0));
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotBound.selector, 0));
        sra.aggregatedFilecoinPayVolume(0);
    }

    /// after binding aggregatedFilecoinPayVolume = Σ each orchestrator's bound USD value (pure view, FIPs#1275).
    function test_AggregatedFilecoinPayVolume_AfterBinding_SumOfValues() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB");
        _admit(orchA);
        _admit(orchB);

        vm.roll(_qEnd(0) + 1);
        _postAs(orchA, 0, _fpv(100e18));
        _postAs(orchB, 0, _fpv(250e18));

        vm.roll(_qVerifyEnd(0) + 1);
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 350e18);
    }

    /// a frozen orchestrator's (frozen at the E+POST instant) FilecoinPayVolume is excluded from the aggregate.
    function test_AggregatedFilecoinPayVolume_FrozenExcluded() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB");
        _admit(orchA);
        _admit(orchB);

        vm.roll(_qEnd(0) + 1);
        _postAs(orchA, 0, _fpv(100e18));
        _postAs(orchB, 0, _fpv(250e18));

        // freeze B during posting (affects the quarter: B frozen at the E+POST instant)
        _freeze(orchB);

        vm.roll(_qVerifyEnd(0) + 1);
        // B excluded: the aggregate contains only A
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 100e18);
    }

    /// Strategy 11/CV7: some orchestrators did not post -> aggregatedFilecoinPayVolume skips them (usd==0 continue).
    function test_AggregatedFilecoinPayVolume_UnpostedOrch_Excluded() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB"); // B admitted but does not post
        _admit(orchA);
        _admit(orchB);

        vm.roll(_qEnd(0) + 1);
        _postAs(orchA, 0, _fpv(100e18));

        vm.roll(_qVerifyEnd(0) + 1); // post-binding
        // B unposted (posted=false) -> skipped; only A aggregated
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 100e18);
    }

    // ------------------------------------------------------------------------
    // G1: setPricingParams / getPricingParams
    //   Governance: unanimous + hold (two votes + permissionless body execution after hold elapses)
    //   FIPs#1275: MIN_LOT/PRICE_BAND are authoritative for the off-chain indexer, not an on-chain computation
    // ------------------------------------------------------------------------

    /// G1: governance updates the params minLot/priceBand; getPricingParams returns the new values.
    function test_SetPricingParams_UpdatesParams_GetReturns() public {
        vm.prank(owner1);
        sra.setPricingParams(2e18, 1500);
        vm.prank(owner2);
        sra.setPricingParams(2e18, 1500);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.setPricingParams(2e18, 1500); // third call: permissionless execution

        (uint256 minLot, uint256 priceBand) = sra.getPricingParams();
        assertEq(minLot, 2e18);
        assertEq(priceBand, 1500); // 15%
    }

    /// G1: a non-owner (third party) calling setPricingParams -> rejected on the first vote (NotOwner).
    function test_SetPricingParams_NonOwner_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert();
        sra.setPricingParams(2e18, 1500);
    }

    /// G1: invalid params (priceBand > 10000) -> InvalidParameter at the third body execution.
    function test_SetPricingParams_InvalidParams_Reverts() public {
        // priceBand > BASIS_POINTS(10000) is invalid
        vm.prank(owner1);
        sra.setPricingParams(MIN_LOT, 10001);
        vm.prank(owner2);
        sra.setPricingParams(MIN_LOT, 10001);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert();
        sra.setPricingParams(MIN_LOT, 10001);
    }

    // ------------------------------------------------------------------------
    // Permission checks
    // ------------------------------------------------------------------------

    function test_PostVolume_NotAdmitted_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.roll(_qEnd(0) + 1); // posting window
        vm.prank(stranger);
        vm.expectRevert(); // NotAdmitted(stranger)
        sra.postVolume(0, FixedU18.wrap(_fpv(100e18)));
    }

    /// correctVolume's target not admitted -> NotAdmitted revert at the second vote's body execution.
    function test_CorrectVolume_NotAdmitted_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.roll(_qPostEnd(0) + 1); // verification window
        vm.prank(owner1);
        sra.correctVolume(stranger, 0, FixedU18.wrap(100e18)); // first vote approve
        vm.prank(owner2);
        vm.expectRevert(); // second vote executes the body -> NotAdmitted(stranger)
        sra.correctVolume(stranger, 0, FixedU18.wrap(100e18));
    }
}
