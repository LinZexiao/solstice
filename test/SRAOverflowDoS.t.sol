// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// Overflow DoS regression tests — 3 overflow-DoS vulnerabilities sharing one root cause:
// the FilecoinPayVolume input fields had no business-domain upper-bound validation.
//
//   Anchor pollution → network-wide permanent DoS: obsolete after FIPs#1275
//        (the PRICE_BAND anchor/_checkPriceBand are gone — FIL→USD conversion is
//        off-chain, so no on-chain band arithmetic exists).
//   finalizeConversion overflow → quarterly settlement stuck: obsolete after
//        FIPs#1275 (no on-chain FIL→USD conversion; _finalizeConversion removed).
//   Huge USD total → _computeShares overflow → quarterly settlement stuck:
//        still applicable — the single USD total feeds usds[i] * SHARE_TOTAL in
//        _computeShares; the fix is the MAX_FILECOIN_PAY_VOLUME_USD business-domain bound enforced
//        at postVolume/correctVolume.
//
// Expected fix behavior (locked by these tests):
//   - a USD total beyond the business bound is rejected at the entry; a normal
//     total must let submitShares settle (system stays operational).

import {SERVICE_ID, Share} from "../src/lib/FVMRewardTypes.sol";
import {SRATestBase} from "./SRATestBase.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";

contract SRAOverflowDoS is SRATestBase {
    uint256 private constant EXTREME = type(uint256).max; // V3: poison USD total

    // ------------------------------------------------------------------------
    // V3 — huge USD total → _computeShares overflow → quarterly settlement stuck
    // ------------------------------------------------------------------------

    /// V3 regression (operational): a huge USD total must not wedge submitShares;
    /// the quarter must still settle.
    function test_V3_HugeUsd_SystemStaysOperational() public {
        address attacker = makeAddr("v3-attacker");
        address victim = makeAddr("v3-victim");
        _admit(attacker);
        _admit(victim);

        vm.roll(_qEnd(0) + 1);
        vm.prank(attacker);
        try sra.postVolume(0, FixedU18.wrap(EXTREME)) {} catch {}

        vm.prank(victim);
        sra.postVolume(0, FixedU18.wrap(100e18));

        vm.roll(_qVerifyEnd(0) + 1);
        sra.submitShares(0); // must not overflow

        Share[] memory shares = rewardActor().getShares(SERVICE_ID);
        assertEq(_sumShares(shares), 1e18);
    }

    /// V3 regression (reject-at-post): the huge total must be rejected by postVolume
    /// (expected fix: business-domain upper bound MAX_FILECOIN_PAY_VOLUME_USD on the single USD total).
    function test_V3_HugeUsd_RejectedByPostVolume() public {
        address attacker = makeAddr("v3-reject");
        _admit(attacker);

        vm.roll(_qEnd(0) + 1);
        vm.prank(attacker);
        vm.expectRevert();
        sra.postVolume(0, FixedU18.wrap(EXTREME));
    }

    // ------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------

    function _sumShares(Share[] memory shares) internal pure returns (uint256 sum) {
        for (uint256 i = 0; i < shares.length; i++) {
            sum += FixedU18.unwrap(shares[i].share);
        }
    }
}
