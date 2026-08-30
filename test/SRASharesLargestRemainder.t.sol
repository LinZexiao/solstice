// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// Largest-remainder top-up semantics — direct _computeShares unit tests.
//
// The differential suite (test/differential/DifferentialShares.t.sol) locks
// bit-identical output against the Python reference model on random inputs;
// these cases pin the *ordering* of top-up picks that the differential inputs
// only exercise implicitly:
//   - tie-break: equal remainders are topped up in input order (index ascending)
//   - remainder boundary: the max remainder at the first / last index
//   - size edges: n = 1 / 2 / 64 (MAX_ORCHESTRATORS protocol boundary)

import {Share} from "../src/lib/FVMRewardTypes.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";
import {SRATestBase} from "./SRATestBase.sol";
import {DifferentialSharesHarness} from "./differential/DifferentialSharesHarness.sol";

contract SRASharesLargestRemainderTest is SRATestBase {
    DifferentialSharesHarness internal harness;

    function setUp() public virtual override {
        super.setUp();
        harness = new DifferentialSharesHarness(
            owner1,
            owner2,
            EPOCHS_PER_QUARTER,
            POST_PERIOD,
            VERIFICATION_WINDOW,
            SRA_CANCEL_HOLD,
            ACTIVATION_EPOCH,
            MIN_LOT,
            PRICE_BAND
        );
    }

    // ------------------------------------------------------------------------
    // Tie-break stability: equal remainders -> index ascending (input order)
    // ------------------------------------------------------------------------

    /// Three equal usd values split 3 ways: all remainders equal (1), residue 1
    /// -> the single top-up goes to the lowest index.
    function test_TieBreak_EqualRemainders_LowestIndex() public view {
        uint256[] memory usds = new uint256[](3);
        usds[0] = 1;
        usds[1] = 1;
        usds[2] = 1;
        Share[] memory shares = _compute(usds, 3);
        assertEq(_share(shares, 0), 333_333_333_333_333_334, "lowest index tops up");
        assertEq(_share(shares, 1), 333_333_333_333_333_333);
        assertEq(_share(shares, 2), 333_333_333_333_333_333);
    }

    /// Two equal max remainders (index 0, 1), residue 2 -> both top up, in index
    /// ascending order (not descending, not the later index first).
    function test_TieBreak_MultiRound_IndexAscending() public view {
        uint256[] memory usds = new uint256[](3);
        usds[0] = 1;
        usds[1] = 1;
        usds[2] = 4;
        Share[] memory shares = _compute(usds, 6);
        assertEq(_share(shares, 0), 166_666_666_666_666_667, "index 0 tops up");
        assertEq(_share(shares, 1), 166_666_666_666_666_667, "index 1 tops up");
        assertEq(_share(shares, 2), 666_666_666_666_666_666, "later index untouched");
    }

    // ------------------------------------------------------------------------
    // Remainder boundary: max remainder at the first / last index
    // ------------------------------------------------------------------------

    /// Max remainder at the last index -> the last index receives the top-up.
    function test_MaxRemainder_LastIndex() public view {
        uint256[] memory usds = new uint256[](3);
        usds[0] = 1;
        usds[1] = 2;
        usds[2] = 4;
        Share[] memory shares = _compute(usds, 7);
        assertEq(_share(shares, 0), 142_857_142_857_142_857);
        assertEq(_share(shares, 1), 285_714_285_714_285_714);
        assertEq(_share(shares, 2), 571_428_571_428_571_429, "last index has max remainder");
    }

    /// Max remainder at the first index -> the first index receives the top-up.
    function test_MaxRemainder_FirstIndex() public view {
        uint256[] memory usds = new uint256[](3);
        usds[0] = 4;
        usds[1] = 1;
        usds[2] = 2;
        Share[] memory shares = _compute(usds, 7);
        assertEq(_share(shares, 0), 571_428_571_428_571_429, "first index has max remainder");
        assertEq(_share(shares, 1), 142_857_142_857_142_857);
        assertEq(_share(shares, 2), 285_714_285_714_285_714);
    }

    // ------------------------------------------------------------------------
    // Size edges: n = 1 / 2 / 64
    // ------------------------------------------------------------------------

    /// n = 1: single orchestrator takes the whole share, no top-up.
    function test_SingleOrchestrator_NoTopUp() public view {
        uint256[] memory usds = new uint256[](1);
        usds[0] = 5;
        Share[] memory shares = _compute(usds, 5);
        assertEq(_share(shares, 0), 1e18);
    }

    /// n = 2: top-up goes to the larger remainder (index 1).
    function test_TwoOrchestrators() public view {
        uint256[] memory usds = new uint256[](2);
        usds[0] = 1;
        usds[1] = 2;
        Share[] memory shares = _compute(usds, 3);
        assertEq(_share(shares, 0), 333_333_333_333_333_333);
        assertEq(_share(shares, 1), 666_666_666_666_666_667);
    }

    /// n = 64 (MAX_ORCHESTRATORS): 63 equal usds (remainder 40) + 1 double
    /// (remainder 15), residue 39 -> 39 top-ups land on the 39 lowest indices.
    function test_SixtyFour_ProtocolBoundary_TopUpsInOrder() public view {
        uint256[] memory usds = new uint256[](64);
        for (uint256 i = 0; i < 63; i++) {
            usds[i] = 1;
        }
        usds[63] = 2;
        Share[] memory shares = _compute(usds, 65);
        for (uint256 i = 0; i < 39; i++) {
            assertEq(_share(shares, i), 15_384_615_384_615_385, "top-up index");
        }
        for (uint256 i = 39; i < 63; i++) {
            assertEq(_share(shares, i), 15_384_615_384_615_384, "floor-only index");
        }
        assertEq(_share(shares, 63), 30_769_230_769_230_769, "larger usd, smaller remainder");
    }

    // ------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------

    function _compute(uint256[] memory usds, uint256 total) internal view returns (Share[] memory) {
        uint256 n = usds.length;
        address[] memory wallets = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            wallets[i] = address(uint160(i + 1)); // non-zero; share assertions only inspect values
        }
        return harness.computeShares(wallets, usds, n, total);
    }

    function _share(Share[] memory shares, uint256 i) internal pure returns (uint256) {
        return FixedU18.unwrap(shares[i].share);
    }
}
