// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// Active-quarter aggregate mirror — differential tests
//   aggregatedFilecoinPayVolume reads the O(1) mirror (totalUsd) for the active quarter; these
//   tests pin the mirror to the linear-scan semantics across post / correct /
//   replace / remove, plus the historical-quarter fallback.
//
// Time model (test base): E(Q)=100000+Q*1000; posting (E,E+300]; verification
//   (E+300,E+700]; post-binding > E+700. Governance methods execute immediately
//   (unanimousNoHold, spec §4.2).

import {SRATestBase} from "./SRATestBase.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";
import {SERVICE_ID, Share} from "../src/lib/FVMRewardTypes.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";

contract SRAggregateMirrorTest is SRATestBase {
    /// Basic: two posters — mirror == their sum.
    function test_Mirror_Basic() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1); // posting
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));

        vm.roll(_qVerifyEnd(0) + 1); // post-binding
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 300e18);
    }

    /// Unposted orchestrator never enters the mirror.
    function test_Mirror_Unposted_Excluded() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(100e18));

        vm.roll(_qVerifyEnd(0) + 1);
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 100e18);
    }

    /// CorrectVolume adjusts the mirror (up / down / clear-to-zero).
    function test_Mirror_CorrectVolume_Sync() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));

        vm.roll(_qPostEnd(0) + 1); // verification window
        _correctVolume(a, 0, _fpv(150e18)); // up
        _correctVolume(b, 0, 0); // clear

        vm.roll(_qVerifyEnd(0) + 1);
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 150e18);
    }

    /// Replacement during posting transfers identity — the old orchestrator's contribution is
    /// inherited by the new identity (aggregate unchanged; ownership moves), per the mirror design.
    function test_Mirror_ReplaceInPosting_Inherits() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        address a2 = makeAddr("a2");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));

        vm.prank(owner1);
        sra.replaceWallet(a, a2);
        vm.prank(owner2);
        sra.replaceWallet(a, a2); // second vote executes (unanimousNoHold) — still inside posting window

        vm.roll(_qVerifyEnd(0) + 1);
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 300e18); // inherited — no deduction
    }

    /// Removal after the pending quarter is submitted leaves the bound aggregate as a binding
    /// snapshot — the §3.2 guard makes any removal post-binding, so no deduction rewrites the
    /// quarter's counter (spec §2.2: the read view exposes the bound values directly).
    function test_Mirror_Remove_Deducts() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));

        vm.roll(_qVerifyEnd(0) + 1); // q0 binds
        sra.submitShares(0); // guard lifts
        _remove(a); // post-binding removal: the aggregate is a binding snapshot, not rewritten
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 300e18);
    }

    /// Mirror switches quarters; the previous quarter falls back to the linear scan.
    function test_Mirror_QuarterSwitch_HistoricalFallback() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        vm.roll(_qVerifyEnd(0) + 1);
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 100e18); // mirror for q=0

        // quarter 1: mirror re-points; q=0 becomes historical (linear fallback)
        vm.roll(_qEnd(1) + 1);
        _postAs(b, 1, _fpv(50e18));
        vm.roll(_qVerifyEnd(1) + 1);
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 100e18); // fallback scan
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(1)), 50e18); // mirror for q=1
    }

    /// Lagging SubmitShares (spec: operates on the latest bound quarter, up to one quarter of lag):
    /// after the mirror advances into q=1, submitShares(0) reads the previous-quarter mirror slot
    /// (prevFpv) — an orchestrator that posted in both quarters is picked up from its mirror value.
    function test_Mirror_SubmitShares_Lagging_ReadsPrevSlot() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));

        // advance into q=1 (a posts again — its q=0 value moves into prevFpv at the advance)
        vm.roll(_qEnd(1) + 1);
        _postAs(a, 1, _fpv(50e18));

        // q=0 is still the latest bound quarter (q=1 not bound yet): lagging submit reads prevFpv
        sra.submitShares(0);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 2, "both q0 contributors from the mirror");
        assertEq(shares[0].wallet, a, "posting order: a first (mirror of a's q0 value)");
        assertEq(_shareOf(shares, a) + _shareOf(shares, b), 1e18, "shares sum to 100%");
    }

    /// correctVolume can be the first writer of a quarter (backfill): it triggers the mirror
    /// advance, and a backfill for an unposted orchestrator keeps the already-posted ones.
    function test_Mirror_CorrectVolume_FirstWrite_Advances() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(100e18));

        // q=1: nobody posted — correctVolume backfill is the first write (advance to q=1)
        vm.roll(_qPostEnd(1) + 1);
        _correctVolume(b, 1, _fpv(200e18));

        vm.roll(_qVerifyEnd(1) + 1);
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 100e18); // q=0 snapshot intact
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(1)), 200e18); // q=1 counter

        sra.submitShares(1); // q=1 latest bound, active quarter: reads fpv (b only)
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1, "backfill only contributor of q=1");
        assertEq(shares[0].wallet, b);
        assertEq(FixedU18.unwrap(shares[0].share), 1e18);
    }

    /// correctVolume backfill advancing the quarter must not leak the previous quarter's value
    /// into the new quarter's counter: the old value is read *after* the advance,
    /// so a backfill with value < oldUsd must not underflow and value > oldUsd lands exactly.
    function test_Mirror_CorrectVolume_Advance_NoLeak() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));

        // q=1 nobody posted: correctVolume backfills are the first writes (advance to q=1).
        // a: value < oldUsd (100 -> 50) must not underflow; b: value > oldUsd (200 -> 300)
        // must land exactly — neither may carry q=0's contribution into the q=1 counter.
        vm.roll(_qPostEnd(1) + 1);
        _correctVolume(a, 1, _fpv(50e18));
        _correctVolume(b, 1, _fpv(300e18));

        vm.roll(_qVerifyEnd(1) + 1);
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(1)), 350e18); // 50 + 300, no leak from q0
    }

    /// Spec §3.2 timing guard: RemoveOrchestrator reverts while an ended quarter awaits its
    /// share map — from the end of a quarter until that quarter's SubmitShares has run. A lag-window
    /// remove (q0 bound, map not submitted, time already into q1) must revert PendingShares(1) —
    /// the guard keys on the ended quarter, so q1 itself is pending until submitted; after
    /// submitShares(0) clears the lag the same removal succeeds. This also guarantees the submitted
    /// map is always consistent with the quarter counter (no removal binds between close-of-posting
    /// and SubmitShares).
    function test_Mirror_Remove_PendingShares_Reverts() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));

        // q=1: a posts again — the mirror advances; q=0 becomes the latest bound quarter (map pending).
        vm.roll(_qEnd(1) + 1);
        _postAs(a, 1, _fpv(50e18));

        // lag window: q=0 bound, submitShares(0) not yet called -> the second vote (which executes
        // the body under unanimousNoHold) hits the guard and reverts; the first approval persists.
        vm.prank(owner1);
        sra.removeOrchestrator(b); // vote 1 (approve)
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PendingShares.selector, 1));
        vm.prank(owner2);
        sra.removeOrchestrator(b); // vote 2 executes the body: ended q1 awaits its share map -> guard reverts (vote rolls back)

        // crank the pending quarters — q0 then q1 (both ended, q1's map holds a's correction) —
        // then the same unanimous task completes on the second vote.
        sra.submitShares(0);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 2, "both q0 contributors submitted while still admitted");
        vm.roll(_qVerifyEnd(1) + 1); // q1 binds
        sra.submitShares(1); // q1 submitted (map = [a]; b's q1 fpv is zero)
        vm.prank(owner2);
        sra.removeOrchestrator(b); // second vote again: full vote now executes, guard cleared
        assertEq(sra.isAdmitted(b), false, "removed after the pending quarters are cleared");
    }

    /// Spec §3.2: the guard covers the whole window from the end of a quarter until its
    /// SubmitShares has run — posting period, verification window and any crank delay — not only
    /// the post-binding lag. With q0 submitted (nextQuarter = 1), a removal inside q1's
    /// posting/verification window (q1 ended, not yet bound) must revert PendingShares(1); once
    /// submitShares(1) clears q1 the same unanimous task completes.
    function test_Remove_InsidePostingVerificationWindow_Reverts() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        // q0 binds and submits — nextQuarter advances to 1, no pending quarter.
        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        vm.roll(_qVerifyEnd(0) + 1);
        sra.submitShares(0);

        // q1 posting window (E(1)+1): q1 has ended and awaits its share map -> the second vote
        // (body execution) reverts; the first approval persists.
        vm.roll(_qEnd(1) + 1);
        vm.prank(owner1);
        sra.removeOrchestrator(b); // vote 1 (approve)
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PendingShares.selector, 1));
        vm.prank(owner2);
        sra.removeOrchestrator(b); // vote 2 executes the body: guard reverts

        // q1 verification window (E(1)+POST+1): still before binding, still pending -> reverts again.
        vm.roll(_qPostEnd(1) + 1);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PendingShares.selector, 1));
        vm.prank(owner2);
        sra.removeOrchestrator(b); // the persisted first approval + this second vote executes: guard reverts

        // q1 binds and submits — guard lifts; the same task completes on the next second vote.
        vm.roll(_qVerifyEnd(1) + 1);
        sra.submitShares(1);
        vm.prank(owner2);
        sra.removeOrchestrator(b); // second vote again: full vote now executes, guard cleared
        assertEq(sra.isAdmitted(b), false, "removed after q1 submitted");
    }

    /// The remove guard's latest-bound determination is *time-driven* (via
    /// _quarterOf), not derived from the activeQ cache — the cache advances only on writes, so a
    /// gap quarter (bound but unwritten) would be missed: q1 bound, nobody wrote, activeQ still 0,
    /// the cache-based guard wrongly reports latest = 0 (already submitted) and lets removal pass.
    function test_Remove_PendingShares_GapWindow() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1); // Q0 posting window
        _postAs(a, 0, _fpv(100e18));
        vm.roll(_qVerifyEnd(0) + 1); // Q0 binds
        sra.submitShares(0); // lastSubmittedQ = 1

        // Q1 gap: nobody writes (activeQ stays 0). Roll past Q1 binding, before Q2 begins
        // (E(1)+701; the 100-epoch hold keeps the executing removal at E(1)+801 < E(2)).
        vm.roll(_qVerifyEnd(1) + 1);

        // Time-derived latest bound = 1 (unsubmitted) -> the second vote (body execution) reverts.
        vm.prank(owner1);
        sra.removeOrchestrator(b); // vote 1 (approve)
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PendingShares.selector, 1));
        vm.prank(owner2);
        sra.removeOrchestrator(b); // vote 2 executes the body: gap-quarter pending -> guard reverts
    }

    /// @dev share of a wallet in the map (0 if absent).
    function _shareOf(Share[] memory shares, address wallet) internal pure returns (uint256) {
        for (uint256 i = 0; i < shares.length; i++) {
            if (shares[i].wallet == wallet) return FixedU18.unwrap(shares[i].share);
        }
        return 0;
    }

    /// invariant_NonZeroTotal_ValidShareMap regression (CI seed 0x8104...): submitShares(q) with q beyond the mirror's activeQ —
    /// a quarter bound but never written (posting/verification elapsed with no contribution) —
    /// must be an all-zero no-op, not a stale prevFpv submission. The previous code treated any
    /// q != activeQ as the previous-quarter mirror (usePrev = q != activeQ), so submitting a
    /// future bound quarter collected the *older* quarter's prevFpv and overwrote the share map
    /// with a quarter-misaligned distribution (CI: share map 2 recipients > snapshot count 1).
    function test_Mirror_SubmitShares_FutureBoundQuarter_NoOp() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        // q0: both post (activeQ=0, fpv slot)
        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));

        // q1: only a is corrected (advance to q=1) — q0 backs up into prevFpv (a:100, b:200)
        vm.roll(_qPostEnd(1) + 1);
        _correctVolume(a, 1, _fpv(50e18));

        // submit q1 (latest bound, active quarter): map = [a], lastSubmittedQ = 2
        vm.roll(_qVerifyEnd(1) + 1);
        sra.submitShares(1);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1, "q1 map = a only");
        assertEq(shares[0].wallet, a);

        // q2 binds with no contribution ever (the mirror never advanced to 2): submitShares(2)
        // must be an all-zero no-op — map unchanged, the quarter still counts as submitted.
        vm.roll(_qVerifyEnd(2) + 1);
        sra.submitShares(2);
        shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1, "future bound quarter no-op leaves the map untouched");
        assertEq(shares[0].wallet, a, "map still the q1 distribution");
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(2)), 0, "q2 has no contributions");
    }

    /// spec §3.2: the posting window itself reverts — from the end of a quarter until its
    /// SubmitShares has run (posting period included), RemoveOrchestrator is not callable. The
    /// pre-E+POST exclusion (spec §2.2) is unreachable in-window by design: governance defers the
    /// removal until the quarter is submitted, and the exclusion then follows from the removed
    /// orchestrator leaving the admitted list.
    function test_Mirror_Remove_InPostingWindow_Reverts() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1); // Q0 posting window
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));

        // q0 ended and awaits its share map -> the second vote (body execution) reverts.
        vm.prank(owner1);
        sra.removeOrchestrator(b); // vote 1 (approve)
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PendingShares.selector, 0));
        vm.prank(owner2);
        sra.removeOrchestrator(b); // vote 2 executes the body: guard reverts
    }

    /// Once the verification window closes, AggregatedFilecoinPayVolume(activeQ) is a fixed binding
    /// snapshot (spec §2.2: the read view exposes the bound values directly). A removal after
    /// binding must not rewrite it — only a pre-E+POST removal excludes the contribution.
    /// FIPs#1277 §2.4.4: removal binds through an immediate map push — the removed entry is repointed
    /// to f099 (burn address), every other share is left untouched. The bound aggregate is a binding
    /// snapshot and must not drift, but the f02 map *does* change: the removed id's row becomes f099
    /// (stored stripped of f099 rows, so its share leaves the stored map). Redistribution to survivors
    /// is still deferred to the next SubmitShares.
    function test_Mirror_Remove_AfterBinding_KeepsSnapshot() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1); // Q0 posting window
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));

        vm.roll(_qVerifyEnd(0) + 1); // Q0 binds
        sra.submitShares(0);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 2, "both contributors in the bound map");
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 300e18, "bound aggregate");
        uint256 aShare = _shareOf(shares, a);
        uint256 bShare = _shareOf(shares, b);
        assertGt(aShare, 0, "a holds a share");
        assertGt(bShare, 0, "b holds a share");

        _remove(b); // post-binding removal: aggregate is a binding snapshot, must not drift
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 300e18, "bound aggregate unchanged after removal");
        shares = rewardActor().getShares(SERVICE_ID);
        // b's entry was repointed to f099 (stripped from storage): only a's share remains stored,
        // at its unchanged value; b's slice is recorded as the stripped burn.
        assertEq(shares.length, 1, "removed entry repointed to f099 leaves the stored map");
        assertEq(_shareOf(shares, a), aShare, "survivor share untouched until next SubmitShares");
        assertEq(rewardActor().strippedBurnOf(SERVICE_ID), bShare, "removed slice recorded as stripped f099 burn");
    }

    /// spec §3.2: the verification window also reverts — removal is deferred to after SubmitShares,
    /// so a misreport surfacing during verification cannot be silenced by removing the orchestrator
    /// (spec Security Considerations: a misreport surfaces during posting or verification, when
    /// removal is not yet callable). The old in-window exclusion semantics (deduct aggregate +
    /// omit map) are unreachable by design.
    function test_Mirror_Remove_InVerificationWindow_Reverts() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1); // Q0 posting window
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));

        vm.roll(_qPostEnd(0) + 1); // Q0 verification window (E+POST+1)
        vm.prank(owner1);
        sra.removeOrchestrator(b); // vote 1 (approve)
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.PendingShares.selector, 0));
        vm.prank(owner2);
        sra.removeOrchestrator(b); // vote 2 executes the body: guard reverts
    }

    /// A gap quarter (no writes, zero volume) submits as an all-zero no-op — the mirror
    /// jump keeps prevFpv = 0 for it, so submitShares reads zero and the existing map stands.
    function test_GapQuarter_SubmitShares_NoOp() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a, a);
        _admit(b, b);

        vm.roll(_qEnd(0) + 1); // Q0 posting window
        _postAs(a, 0, _fpv(100e18));
        vm.roll(_qVerifyEnd(0) + 1); // Q0 binds
        sra.submitShares(0);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1, "q0 map = a");
        assertEq(shares[0].wallet, a);

        // Q1 gap; Q2: b posts (mirror jumps 0 -> 2, prevFpv = 0 for the gap).
        vm.roll(_qEnd(2) + 1);
        _postAs(b, 2, _fpv(50e18));

        // Q1 binds with no contribution: submitShares(1) must be an all-zero no-op.
        vm.roll(_qVerifyEnd(1) + 1);
        sra.submitShares(1);
        shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1, "gap quarter no-op leaves the map untouched");
        assertEq(shares[0].wallet, a, "map still the q0 distribution");
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(1)), 0, "gap quarter has no contributions");
    }
}
