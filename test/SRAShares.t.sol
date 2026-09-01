// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// SRA share computation tests — share rounding /
//   all-zero benign no-op (FIPs#1275) / SetShares encoding / f02 mock driving
//
// Verification means: after submitShares, read the mock's getShares(2) (the f02 service stream's share map).
// Mock validation: stream exists/EXPLICIT/writer permission/≤64 recipients/Σ==1e18 (see FVMRewardActor._setShares).

import {SERVICE_ID, Share} from "../src/lib/FVMRewardTypes.sol";
import {FVMRewards} from "../src/lib/FVMRewards.sol";
import {USR_FORBIDDEN} from "fvm-solidity/FVMErrors.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {SRATestBase} from "./SRATestBase.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";

contract SRASharesTest is SRATestBase {
    // block.number is not stable across helper calls (vm.roll), so it cannot seed unique
    // addresses; an increasing counter guarantees unique makeAddr salts.
    uint256 private _orchSalt;

    // ------------------------------------------------------------------------
    // share rounding (largest-remainder) — Σ shares exactly == 1e18
    // ------------------------------------------------------------------------

    /// 3-way split (1e18 % 3 = 1) -> one share +1, Σ exact.
    function test_SubmitShares_ThreeWayEqual_ExactSum() public {
        address a = _admitAndPost(100e18);
        address b = _admitAndPost(100e18);
        address c = _admitAndPost(100e18);

        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);

        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 3);
        assertEq(_sumShares(shares), 1e18);
        // split fairness: each share ∈ {333333333333333333, 333333333333333334}
        for (uint256 i = 0; i < shares.length; i++) {
            assertGe(FixedU18.unwrap(shares[i].share), 333_333_333_333_333_333);
            assertLe(FixedU18.unwrap(shares[i].share), 333_333_333_333_333_334);
        }
        assertEq(_walletShare(shares, a) + _walletShare(shares, b) + _walletShare(shares, c), 1e18);
    }

    /// 7-way split (1e18 % 7 = 1) -> Σ exact.
    function test_SubmitShares_SevenWayEqual_ExactSum() public {
        address[] memory orchs = new address[](7);
        for (uint256 i = 0; i < 7; i++) {
            orchs[i] = _admitAndPost(100e18);
        }

        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);

        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 7);
        assertEq(_sumShares(shares), 1e18);
        for (uint256 i = 0; i < shares.length; i++) {
            assertGe(FixedU18.unwrap(shares[i].share), 142_857_142_857_142_857);
            assertLe(FixedU18.unwrap(shares[i].share), 142_857_142_857_142_858);
        }
    }

    /// 17-way split (1e18 % 17 = 15) -> Σ exact.
    function test_SubmitShares_SeventeenWayEqual_ExactSum() public {
        for (uint256 i = 0; i < 17; i++) {
            _admitAndPost(100e18);
        }

        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);

        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 17);
        assertEq(_sumShares(shares), 1e18);
        for (uint256 i = 0; i < shares.length; i++) {
            // 58823529411764705 * 17 = 999999999999999985, remainder 15 -> 15 shares +1
            assertGe(FixedU18.unwrap(shares[i].share), 58_823_529_411_764_705);
            assertLe(FixedU18.unwrap(shares[i].share), 58_823_529_411_764_706);
        }
    }

    /// uneven split (30/70) -> proportional allocation, Σ exact.
    function test_SubmitShares_UnevenSplit_Proportional() public {
        address a = _admitAndPost(30e18);
        address b = _admitAndPost(70e18);

        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);

        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 2);
        assertEq(_walletShare(shares, a), 300_000_000_000_000_000); // 0.3e18
        assertEq(_walletShare(shares, b), 700_000_000_000_000_000); // 0.7e18
        assertEq(_sumShares(shares), 1e18);
    }

    // ------------------------------------------------------------------------
    // all-zero quarter is a benign no-op (FIP-0118 FIPs#1275)
    // ------------------------------------------------------------------------

    /// nobody posted (total=0) -> submitShares is a benign no-op: no SetShares call,
    /// the existing share map stands (FIP: "SplitRule is not evaluated and the existing share map stands").
    function test_SubmitShares_AllZero_NoOp_KeepsMap() public {
        // two orchestrators admitted but nobody posted
        _admit(makeAddr("orchA"), makeAddr("orchA"));
        _admit(makeAddr("orchB"), makeAddr("orchB"));

        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);

        // no SetShares happened: the stream map is still the registration-time initial map (writer = SRA)
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1);
        assertEq(shares[0].wallet, address(sra)); // initial map unchanged
        assertEq(FixedU18.unwrap(shares[0].share), 1e18);
    }

    // ------------------------------------------------------------------------
    // SetShares encoding (Σ=1e18, recipient resolution, map ≤ 64)
    // ------------------------------------------------------------------------

    /// share map size = number of active orchestrators (≤ 64); each wallet resolves to an orch address.
    function test_SubmitShares_MapSize_EqualsActiveOrchestrators() public {
        address a = _admitAndPost(100e18);
        address b = _admitAndPost(200e18);
        address c = _admitAndPost(300e18);

        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);

        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 3);
        assertEq(_walletShare(shares, a) + _walletShare(shares, b) + _walletShare(shares, c), 1e18);
        assertTrue(_hasWallet(shares, a));
        assertTrue(_hasWallet(shares, b));
        assertTrue(_hasWallet(shares, c));
    }

    /// Strategy 10/12: submitShares with a post of USD value from the off-chain conversion (FIPs#1275).
    function test_SubmitShares_PostedUsd_Proportional() public {
        address a = makeAddr("orchA");
        _admit(a, a);
        // orchestrator a posts a single USD total (off-chain conversion folded the FIL contribution in)
        vm.roll(_qEnd(0) + 1);
        vm.prank(a);
        sra.postVolume(0, FixedU18.wrap(1000e18)); // = 500e18 stable + 500e18 converted FIL

        // orchestrator b pure stablecoin 500e18 -> a:b = 2:1
        address b = _admitAndPost(500e18);

        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);

        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 2);
        // a: 1000e18; b: 500e18; total 1500e18 -> a 2/3, b 1/3
        assertEq(_walletShare(shares, a), 666_666_666_666_666_667);
        assertEq(_walletShare(shares, b), 333_333_333_333_333_333);
        assertEq(_sumShares(shares), 1e18);
    }

    // ------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------

    /// @dev Admits and (in the current posting window) posts a pure-stablecoin FilecoinPayVolume; returns the orchestrator address.
    function _admitAndPost(uint256 stableUsd) internal returns (address orch) {
        orch = makeAddr(string.concat("orch-", vm.toString(_orchSalt++))); // T5: increasing salt for unique addresses
        _admit(orch, orch);
        vm.roll(_qEnd(0) + 1); // posting window
        _postAs(orch, 0, _fpv(stableUsd));
    }

    function _sumShares(Share[] memory shares) internal pure returns (uint256 sum) {
        for (uint256 i = 0; i < shares.length; i++) {
            sum += FixedU18.unwrap(shares[i].share);
        }
    }

    function _walletShare(Share[] memory shares, address wallet) internal pure returns (uint256) {
        for (uint256 i = 0; i < shares.length; i++) {
            if (shares[i].wallet == wallet) return FixedU18.unwrap(shares[i].share);
        }
        return 0;
    }

    function _hasWallet(Share[] memory shares, address wallet) internal pure returns (bool) {
        for (uint256 i = 0; i < shares.length; i++) {
            if (shares[i].wallet == wallet) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------------
    // G2: 64-full + submitShares combination (mock MAX_RECIPIENTS boundary + map traversal cap)
    // ------------------------------------------------------------------------

    /// G2: all 64 posted -> submitShares share map has exactly 64 recipients (mock boundary), Σ exact.
    /// The 64-way split divides evenly (1e18 % 64 == 0) -> each share exactly == 1e18/64, no remainder top-up.
    function test_SubmitShares_AtFullCapacity_SixtyFourRecipients() public {
        for (uint256 i = 0; i < 64; i++) {
            _admitAndPost(100e18);
        }
        assertEq(sra.admittedCount(), 64);

        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);

        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 64); // mock MAX_RECIPIENTS boundary: exactly 64 accepted
        assertEq(_sumShares(shares), 1e18);
        for (uint256 i = 0; i < shares.length; i++) {
            assertEq(FixedU18.unwrap(shares[i].share), 1e18 / 64); // 15625000000000000, divides evenly
        }
    }

    // ------------------------------------------------------------------------
    // G5: multi-quarter share map isolation
    // ------------------------------------------------------------------------

    /// G5: quarter 0 posts A/B -> quarter 1 only C posts -> quarter 1's share map contains only C (no residue from quarter-0 orchestrators).
    function test_SubmitShares_MultiQuarter_Isolated() public {
        // Quarter 0: A (100e18), B (200e18)
        address a = makeAddr("orchA-q0");
        address b = makeAddr("orchB-q0");
        _admit(a, a);
        _admit(b, b);
        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));

        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);
        Share[] memory q0 = rewardActor().getShares(SERVICE_ID);
        assertEq(q0.length, 2);
        // largest-remainder (remainder descending): A remainder = (1e38 % 3e20) = 1e20 < B remainder = (2e38 % 3e20) = 2e20
        // -> the larger-remainder B tops up +1: A=1/3, B=2/3+1wei
        assertEq(_walletShare(q0, a), 333_333_333_333_333_333);
        assertEq(_walletShare(q0, b), 666_666_666_666_666_667);
        assertEq(_sumShares(q0), 1e18);

        // Quarter 1: only C posts
        address c = makeAddr("orchC-q1");
        _admit(c, c);
        vm.roll(_qEnd(1) + 1);
        _postAs(c, 1, _fpv(100e18));

        _rollTo(_qVerifyEnd(1) + 1);
        sra.submitShares(1);
        Share[] memory q1 = rewardActor().getShares(SERVICE_ID);
        // quarter 1's share map is independent: A/B did not post in quarter 1 (usdValue=0 filtered) -> no residue
        assertEq(q1.length, 1);
        assertEq(q1[0].wallet, c);
        assertEq(FixedU18.unwrap(q1[0].share), 1e18);
    }

    // ------------------------------------------------------------------------
    // FIP-0118 §4.2 latest-quarter constraint: an older quarter's shares can never overwrite a newer quarter's
    // ------------------------------------------------------------------------

    /// FIP-0118 §4.2: SubmitShares operates on the **latest** bound quarter. Q0 already submitted, Q1 bound
    /// (latest) -> submitting Q0 must revert NotLatestQuarter (the map stands — no late overwrite of a newer
    /// quarter's shares); submitting the latest bound quarter still succeeds.
    function test_SubmitShares_NotLatestQuarter_Reverts() public {
        // Q0: A posts 100e18, submit after Q0 binding
        address a = _admitAndPost(100e18);
        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);
        Share[] memory q0 = rewardActor().getShares(SERVICE_ID);
        assertEq(q0.length, 1);
        assertEq(q0[0].wallet, a);

        // Q1: B posts, bind Q1 (becomes the latest bound quarter)
        address b = makeAddr("orchB-q1");
        _admit(b, b);
        vm.roll(_qEnd(1) + 1);
        _postAs(b, 1, _fpv(200e18));
        _rollTo(_qVerifyEnd(1) + 1);

        // Q0 is superseded -> submitting it reverts NotLatestQuarter (never overwrites Q1's newer map)
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotLatestQuarter.selector, uint64(0)));
        sra.submitShares(0);

        // submitting the latest bound quarter (Q1) still succeeds
        sra.submitShares(1);
        Share[] memory q1 = rewardActor().getShares(SERVICE_ID);
        assertEq(q1.length, 1);
        assertEq(q1[0].wallet, b);
        assertEq(FixedU18.unwrap(q1[0].share), 1e18);
    }

    // ------------------------------------------------------------------------
    // G7: fuzz — arbitrary share combinations always have Σ exactly == SHARE_TOTAL
    // ------------------------------------------------------------------------

    /// G7: core invariant of share computation with 3 random usdValues: Σ shares always exactly == 1e18.
    /// Sampling domain (0, 1e30) aligns with the code-enforced MAX_STABLE_USD (audit V1/V2/V3 fix):
    /// _validateFpvBounds rejects stableUSD > 1e30 at postVolume, so this fuzz domain equals the
    /// contract's enforced input domain — not a test-side shrink to dodge overflow (S3 evidence-condition fix).
    function test_SubmitShares_Fuzz_SumAlwaysExact(uint256 v1, uint256 v2, uint256 v3) public {
        vm.assume(v1 > 0 && v1 < 1e30);
        vm.assume(v2 > 0 && v2 < 1e30);
        vm.assume(v3 > 0 && v3 < 1e30);

        _admitAndPost(v1);
        _admitAndPost(v2);
        _admitAndPost(v3);

        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);

        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertGt(shares.length, 0);
        assertEq(_sumShares(shares), 1e18); // largest-remainder: floor + remainder-descending top-up, Σ always exact
        for (uint256 i = 0; i < shares.length; i++) {
            assertGt(FixedU18.unwrap(shares[i].share), 0); // zero-share entries are trimmed before setShares
        }
    }

    // ------------------------------------------------------------------------
    // P2 coverage closure (CV3): submitShares NotBound before binding
    // ------------------------------------------------------------------------

    /// Strategy 10/CV3: submitShares before binding (verification window right boundary inclusive) -> NotBound revert.
    /// (finalizeConversion's NotBound was already tested; submitShares's own first-line require
    /// was uncovered — coverage line 508's revert branch missing)
    function test_SubmitShares_BeforeBinding_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch, orch);
        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qVerifyEnd(0)); // now == E+POST+VERIFY: not yet bound (strictly after)
        vm.expectRevert(); // NotBound(0)
        sra.submitShares(0);
    }

    // ------------------------------------------------------------------------
    // A1: system-call failure injection (SetSharesFailed) — the SRA's only external interaction point with f02
    // ------------------------------------------------------------------------

    /// A1: the mock injects a setShares failure (failSetShares flag -> USR_FORBIDDEN exit code) ->
    /// the whole submitShares path reverts SetSharesFailed (an f02 failure must roll back the quarter's shares, no half-state residue).
    /// Control: with the injection off, a normal submit in the same quarter succeeds (proving the failure comes only from injection, SRA state not polluted).
    function test_SubmitShares_SetSharesFailed_Reverts() public {
        address orch = _admitAndPost(100e18);
        _rollTo(_qVerifyEnd(0) + 1);

        rewardActor().mockFailSetShares(true);
        vm.expectRevert(abi.encodeWithSelector(FVMRewards.SetSharesFailed.selector, int256(uint256(USR_FORBIDDEN))));
        sra.submitShares(0);

        // Control: with the injection off, the normal path succeeds; shares written identically to the no-injection case
        rewardActor().mockFailSetShares(false);
        sra.submitShares(0);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1);
        assertEq(shares[0].wallet, orch);
        assertEq(FixedU18.unwrap(shares[0].share), 1e18);
    }

    // ------------------------------------------------------------------------
    // id-keyed identity: replaceWallet = O(1) payout-wallet re-point (spec §3.2: identity does not move)
    // ------------------------------------------------------------------------

    /// id-keyed identity: replaceWallet re-points the payout wallet only — the identity (id) does not
    /// move, so historical quarter FilecoinPayVolume stays aggregated under the same orchestrator.
    function test_Replace_HistoricalQuarterFilecoinPayVolume_Kept() public {
        address oldOrch = makeAddr("hist-old");
        address newOrch = makeAddr("hist-new");
        _admit(oldOrch, oldOrch);
        vm.roll(_qEnd(0) + 1); // q0 posting window
        _postAs(oldOrch, 0, _fpv(100e18));

        // governance replaceWallet(old -> newWallet) inside q0's verification window (before binding)
        vm.roll(_qPostEnd(0) + 1);
        vm.prank(owner1);
        sra.replaceWallet(oldOrch, newOrch, "");
        vm.prank(owner2);
        sra.replaceWallet(oldOrch, newOrch, ""); // second vote executes (unanimousNoHold)

        // submit q0 after binding: the posted FilecoinPayVolume is still aggregated under the same identity
        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1);
        assertEq(
            _walletShare(shares, newOrch),
            1e18,
            "historical FilecoinPayVolume stays with the identity; the share map pays the new wallet"
        );
        assertEq(_sumShares(shares), 1e18);

        // aggregatedFilecoinPayVolume agrees: the historical quarter's volume is not lost
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 100e18);
    }

    /// The share map is always written to the *current* wallet — after replace, newOrch receives the shares and
    /// the replaced address receives nothing.
    function test_Replace_ShareMap_WritesNewWallet() public {
        address oldOrch = makeAddr("wallet-old");
        address newOrch = makeAddr("wallet-new");
        _admit(oldOrch, oldOrch);
        vm.roll(_qEnd(0) + 1); // q0 posting window
        _postAs(oldOrch, 0, _fpv(50e18));
        _admitAndPost(50e18); // second orchestrator keeps the split non-trivial

        // replace(old -> new) inside the verification window
        vm.roll(_qPostEnd(0) + 1);
        vm.prank(owner1);
        sra.replaceWallet(oldOrch, newOrch, "");
        vm.prank(owner2);
        sra.replaceWallet(oldOrch, newOrch, ""); // second vote executes (unanimousNoHold)

        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(_walletShare(shares, newOrch), 5e17, "share map wallet = the current (replaced-to) wallet");
        assertEq(_walletShare(shares, oldOrch), 0, "the replaced address receives nothing");
        assertEq(_sumShares(shares), 1e18);
    }

    /// After replaceWallet, correctVolume still addresses the *unchanged* identity (spec §3.2: the
    /// orchestrator identity does not move) — a verification-window correction of the historical
    /// quarter hits the right FilecoinPayVolume record.
    function test_ReplaceWallet_CorrectVolume_IdentityUnchanged_CorrectsHistoricalQuarter() public {
        address oldOrch = makeAddr("cv-old");
        address newOrch = makeAddr("cv-new");
        _admit(oldOrch, oldOrch);
        vm.roll(_qEnd(0) + 1); // q0 posting window
        _postAs(oldOrch, 0, _fpv(100e18));

        // replaceWallet within the verification window, then correct via the unchanged identity
        vm.roll(_qPostEnd(0) + 1);
        vm.prank(owner1);
        sra.replaceWallet(oldOrch, newOrch, "");
        vm.prank(owner2);
        sra.replaceWallet(oldOrch, newOrch, ""); // second vote executes (unanimousNoHold)

        _correctVolume(oldOrch, 0, 200e18); // correction via the identity (which did not move)

        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 1);
        assertEq(_walletShare(shares, newOrch), 1e18);
        // the corrected value (200), not the original post (100), is aggregated
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 200e18);
    }

    // ------------------------------------------------------------------------
    // immediate f099 map push (FIPs#1277 §2.4.4) — removeOrchestrator / replaceWallet
    // after a submit re-push the f02 map at once; the LastShares snapshot drives it.
    // The spec §3.2 guard makes remove callable only outside an ended-quarter window, so all
    // remove-push scenarios are constructed after SubmitShares has run.
    // ------------------------------------------------------------------------

    /// Remove after submit pushes the removed id's entry to f099 immediately: the stored map drops the
    /// removed wallet (f099 rows are stripped from storage), survivors keep their shares unchanged, and
    /// the removed slice is recorded as the stripped burn (Σ stored + stripped == 1e18).
    function test_Remove_AfterSubmit_PushesF099Burn() public {
        address a = makeAddr("push-a");
        address b = makeAddr("push-b");
        _admit(a, a);
        _admit(b, b);
        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));
        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);

        Share[] memory before = rewardActor().getShares(SERVICE_ID);
        assertEq(before.length, 2, "both contributors in the bound map");
        uint256 bShare = _walletShare(before, b);

        _remove(b, "misreport"); // post-submit removal binds immediately

        Share[] memory afterMap = rewardActor().getShares(SERVICE_ID);
        assertEq(afterMap.length, 1, "removed entry repointed to f099 leaves the stored map");
        assertFalse(_hasWallet(afterMap, b), "removed wallet absent from stored map");
        assertEq(_walletShare(afterMap, a), _walletShare(before, a), "survivor share unchanged until next SubmitShares");
        assertEq(rewardActor().strippedBurnOf(SERVICE_ID), bShare, "removed slice = stripped f099 burn");
        assertEq(
            _sumShares(afterMap) + rewardActor().strippedBurnOf(SERVICE_ID), 1e18, "sum conserved (stored + stripped)"
        );
    }

    /// Multiple removes keep pushing f099 rows (f099 may appear more than once in a map, spec §2.4.4):
    /// each removed slice is stripped in turn, stored shares shrink, Σ(stored + stripped) stays 1e18.
    function test_Remove_Repeated_PushesF099Repeatedly() public {
        address a = makeAddr("push-a");
        address b = makeAddr("push-b");
        address c = makeAddr("push-c");
        _admit(a, a);
        _admit(b, b);
        _admit(c, c);
        vm.roll(_qEnd(0) + 1);
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));
        _postAs(c, 0, _fpv(300e18));
        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);

        Share[] memory before = rewardActor().getShares(SERVICE_ID);
        assertEq(before.length, 3);
        uint256 bShare = _walletShare(before, b);
        uint256 cShare = _walletShare(before, c);

        _remove(b, "");
        Share[] memory after1 = rewardActor().getShares(SERVICE_ID);
        assertEq(after1.length, 2, "b removed -> two stored entries");
        assertEq(rewardActor().strippedBurnOf(SERVICE_ID), bShare, "first remove strips b's share");

        _remove(c, "");
        Share[] memory after2 = rewardActor().getShares(SERVICE_ID);
        assertEq(after2.length, 1, "c removed -> one stored entry");
        assertEq(rewardActor().strippedBurnOf(SERVICE_ID), bShare + cShare, "stripped burn accumulates across removes");
        assertEq(_walletShare(after2, a), _walletShare(before, a), "survivor a untouched through both removes");
        assertEq(
            _sumShares(after2) + rewardActor().strippedBurnOf(SERVICE_ID),
            1e18,
            "sum conserved through repeated removes"
        );
    }

    /// Remove with no prior submit (snapshot empty) must not push: the f02 map stays as-is (the
    /// registered initial map), so an orchestrator removed before any SubmitShares leaves no stale
    /// entry to repoint. Guard-clean: crank a zero-volume quarter so remove is callable, then remove
    /// a never-shared id.
    function test_Remove_NoPriorSubmit_NoPush() public {
        address a = makeAddr("noop-a");
        address b = makeAddr("noop-b");
        _admit(a, a);
        _admit(b, b);
        // No volume at all: submitShares(0) is a benign no-op (nextQuarter advances, no SetShares),
        // so the registered initial map (address(sra): 1e18, set up in _registerServiceStream) stands.
        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);
        Share[] memory initial = rewardActor().getShares(SERVICE_ID);
        assertEq(initial.length, 1, "no-op submit leaves the initial map");

        _remove(b, "");
        Share[] memory afterRemove = rewardActor().getShares(SERVICE_ID);
        assertEq(afterRemove.length, 1, "remove without snapshot does not push");
        assertEq(_walletShare(afterRemove, address(sra)), 1e18, "initial map untouched");
        assertEq(rewardActor().strippedBurnOf(SERVICE_ID), 0, "no stripped burn without a map");
    }

    /// Replace after submit pushes the wallet swap immediately: the id's share stays (prospective —
    /// identity and accrued do not move), only the map's wallet for that id is replaced; Σ unchanged.
    function test_Replace_AfterSubmit_PushesWalletSwap() public {
        address oldOrch = makeAddr("swap-old");
        address newOrch = makeAddr("swap-new");
        _admit(oldOrch, oldOrch);
        vm.roll(_qEnd(0) + 1);
        _postAs(oldOrch, 0, _fpv(100e18));
        _admitAndPost(100e18); // second contributor keeps the split non-trivial
        _rollTo(_qVerifyEnd(0) + 1);
        sra.submitShares(0);

        Share[] memory before = rewardActor().getShares(SERVICE_ID);
        uint256 oldShare = _walletShare(before, oldOrch);
        assertGt(oldShare, 0, "old wallet holds a share before swap");

        // replace after submit (no guard): swap old -> new in the live map
        vm.prank(owner1);
        sra.replaceWallet(oldOrch, newOrch, "rotation");
        vm.prank(owner2);
        sra.replaceWallet(oldOrch, newOrch, "rotation");

        Share[] memory afterMap = rewardActor().getShares(SERVICE_ID);
        assertEq(_walletShare(afterMap, newOrch), oldShare, "share moved to the new wallet at the same value");
        assertEq(_walletShare(afterMap, oldOrch), 0, "old wallet no longer receives");
        assertEq(_sumShares(afterMap), 1e18, "sum unchanged by the wallet swap");
        assertEq(rewardActor().strippedBurnOf(SERVICE_ID), 0, "wallet swap strips nothing");
    }
}
