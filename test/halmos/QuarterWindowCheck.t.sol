// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {Epoch} from "../../src/lib/Epoch.sol";
import {QuarterWindowHarness} from "./QuarterWindowHarness.sol";

/// @dev Halmos symbolic verification of the quarter state-machine window determination.
///      Deployment mode: this contract directly inherits QuarterWindowHarness; when
///      running halmos with --no-test-constructor the constructor is skipped — but the window constants
///      (EPOCHS_PER_QUARTER/POST_PERIOD/VERIFICATION_WINDOW/ACTIVATION_EPOCH) are immutable, and after skipping
///      the constructor they get symbolized by halmos as free variables. Therefore this verification focuses on
///      **parameter-independent properties** (mathematical properties holding under any window parameters).
///      Halmos 0.1.13 limits: vm.warp does not work on symbolic parameters, so block.number cannot be
///      symbolized — window determination relying on currentEpoch() is covered by dynamic tests instead
///      (SRAQuarter.t.sol window-boundary cases, SRARegistry freeze/unfreeze in both directions, and the
///      invariant suite's random freeze-history exclusion); storage array element reads after push return
///      symbolic elements, so freeze-history interval search is also dynamic-test-covered.
contract QuarterWindowCheck is QuarterWindowHarness, Test {
    // forge-lint: disable-start(mixed-case-function) — halmos runs only check_-prefixed property functions (tool convention)
    /// @dev owner params arbitrary (halmos executes with --no-test-constructor, skipping the constructor; the compiler layer still needs explicit args).
    constructor() QuarterWindowHarness(address(0xCAFE), address(0xBEEF)) {}

    uint64 private constant Q = 1000;
    uint64 private constant P = 300;
    uint64 private constant V = 400;
    uint64 private constant ACTIVATION = 100_000;
    /// @dev nowE upper bound (covers the full window lifecycle of q ≤ 3, matching the production config; only constrains the SMT domain).
    uint256 private constant MAX_NOW = ACTIVATION + 4 * Q + P + V + 1;

    // ------------------------------------------------------------------------
    // T2a: quarter-boundary epoch semantics (parameter-independent boundary property)
    // ------------------------------------------------------------------------

    /// @dev T2a: at now = E_q, ¬posting — the quarter-boundary epoch E_q is not in the new quarter's posting
    ///      window (posting is left-open (E, E+P]). E_q itself is the last epoch of the previous quarter's
    ///      binding tail. This is the most critical off-by-one boundary, independent of concrete window parameter values.
    function check_T2a_QuarterEndNotInPosting(uint64 q) public {
        vm.assume(q <= 3);
        uint64 E = uint64(Epoch.unwrap(_qEnd(q)));
        vm.warp(E);
        assert(!_inPostingWindow(q));
    }

    // ------------------------------------------------------------------------
    // T3: constant quarter-progression interval (arithmetic correctness + cross-quarter continuity, parameter-independent)
    // ------------------------------------------------------------------------

    /// @dev T3: any consecutive quarter interval is constant: qEnd(q+1) - qEnd(q) == qEnd(1) - qEnd(0).
    ///      I.e. quarter progression is equidistant (the gap is always EPOCHS_PER_QUARTER, independent of
    ///      ACTIVATION/specific config), with no cross-quarter gaps or overlaps. The gap is derived from the
    ///      implementation itself (not depending on concrete parameter values that cannot be read).
    function check_T3_QuarterProgression(uint64 q) public view {
        vm.assume(q <= 3);
        uint256 gap = Epoch.unwrap(_qEnd(q + 1)) - Epoch.unwrap(_qEnd(q));
        uint256 gap0 = Epoch.unwrap(_qEnd(1)) - Epoch.unwrap(_qEnd(0));
        assert(gap == gap0);
    }
    // forge-lint: disable-end(mixed-case-function)
}
