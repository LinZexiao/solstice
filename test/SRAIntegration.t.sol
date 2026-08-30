// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// SRA integration contract tests — simulate the SWA QuarterlyGateCheck consumption chain of aggregatedFilecoinPayVolume
//
// Background: FIPs#1275 moved the FIL→USD conversion off-chain — FilecoinPayVolume is a single USD total, the
// on-chain FinalizeConversion is gone, and aggregatedFilecoinPayVolume is a pure view (no finalize to trigger).
// These tests lock the contract "aggregatedFilecoinPayVolume (view) == submitShares's internal total — no divergence"
// (the property the spec's "execution order produces no diverging numbers" clause requires).

import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {SERVICE_ID, Share} from "../src/lib/FVMRewardTypes.sol";
import {SRATestBase} from "./SRATestBase.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";

contract SRAIntegrationTest is SRATestBase {
    uint256 private _salt;

    // ------------------------------------------------------------------------
    // Scenario 1 (core): the gating consumer reads aggregatedFilecoinPayVolume first -> submitShares's
    // SharesSubmitted.totalUsd strictly equals aggregatedFilecoinPayVolume (no divergence).
    // ------------------------------------------------------------------------

    /// Orchestrator a: 600e18 USD; orchestrator b: 300e18 USD. total = 900e18.
    function test_Contract_AggregatedMatchesSubmitTotal() public {
        _admitAndPost(600e18);
        _admitAndPost(300e18);

        _rollTo(_qVerifyEnd(0) + 1); // post-binding

        assertEq(
            FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)),
            900e18,
            "aggregatedFilecoinPayVolume sums the bound USD values"
        );

        // no divergence: submitShares's internal total must == aggregatedFilecoinPayVolume (expectEmit captures totalUsd)
        vm.expectEmit(true, false, false, true, address(sra));
        emit ServiceRewardsActor.SharesSubmitted(0, 2, FixedU18.wrap(900e18));
        sra.submitShares(0);
    }

    // ------------------------------------------------------------------------
    // Scenario 2: after submitShares, subsequent reads of aggregatedFilecoinPayVolume are consistent.
    // ------------------------------------------------------------------------

    function test_Contract_SubmitShares_ThenReadConsistent() public {
        address a = _admitAndPost(600e18);
        address b = _admitAndPost(300e18);

        _rollTo(_qVerifyEnd(0) + 1);

        sra.submitShares(0);

        assertEq(
            FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 900e18, "post-submit aggregated matches final value"
        );

        // shares proportional to USD: a:b = 600:300 = 2:1, Σ == 1e18 (largest-remainder tops up the larger remainder a)
        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(shares.length, 2);
        assertEq(_sumShares(shares), 1e18);
        assertEq(_walletShare(shares, a), 666_666_666_666_666_667);
        assertEq(_walletShare(shares, b), 333_333_333_333_333_333);
    }

    // ------------------------------------------------------------------------
    // Scenario 3: aggregatedFilecoinPayVolume is a pure view — it returns the complete value with no
    // state change (FIPs#1275: no on-chain finalize to trigger).
    // ------------------------------------------------------------------------

    function test_Contract_AggregatedFilecoinPayVolume_PureView() public {
        _admitAndPost(100e18);
        _rollTo(_qVerifyEnd(0) + 1); // post-binding
        assertEq(FixedU18.unwrap(sra.aggregatedFilecoinPayVolume(0)), 100e18, "view equals the bound value");
    }

    // ------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------

    /// @dev Admits and posts an orchestrator with a single USD total (within q=0's posting window).
    function _admitAndPost(uint256 usd) internal returns (address orch) {
        orch = makeAddr(string.concat("orch-", vm.toString(_salt++)));
        _admit(orch);
        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(usd));
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
}
