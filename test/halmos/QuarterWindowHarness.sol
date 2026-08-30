// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {ServiceRewardsActor} from "../../src/ServiceRewardsActor.sol";
import {Epoch} from "../../src/lib/Epoch.sol";

/// @dev Halmos symbolic-verification harness: inherits ServiceRewardsActor, exposing the internal quarter-window
///      determination functions via public wrappers (_qEnd/_inPostingWindow/_inVerificationWindow/_afterBinding).
///      The harness only forwards internal calls; it does not copy window logic — what is verified is the
///      implementation itself.
///      Constructor parameters match the production config in test/SRATestBase.sol (Q=1000/P=300/V=400/
///      ACTIVATION=100000), verifying the window semantics under the production config.
///      Deployment: the check contract directly inherits this harness; when running
///      halmos with --no-test-constructor the constructor is skipped — note: after skipping the constructor the
///      immutable window constants (Q/P/V/ACTIVATION) get symbolized by halmos as free variables (no concrete
///      values), so the propositions verified by this harness are all "parameter-independent properties"
///      (mathematical properties holding under any window config); absolute boundary membership depending on
///      concrete parameter values is covered by dynamic tests.
///      The E+POST exclusion is a stored flag (frozenAtPostEnd) — there is no per-epoch
///      interval-search function to verify; the E+POST semantics is covered by dynamic tests.
contract QuarterWindowHarness is ServiceRewardsActor {
    constructor(address owner1, address owner2)
        ServiceRewardsActor(
            owner1,
            owner2,
            Epoch.wrap(1000), // epochsPerQuarter
            Epoch.wrap(300), // postPeriod
            Epoch.wrap(400), // verificationWindow
            Epoch.wrap(100), // cancelHold
            Epoch.wrap(100_000), // activationEpoch
            1e18, // minLot
            2000 // priceBand (20%, basis points)
        )
    {}

    /// @dev posting window (E, E+POST].
    function inPostingWindow(uint64 q) external view returns (bool) {
        return _inPostingWindow(q);
    }

    /// @dev verification window (E+POST, E+POST+VERIFY].
    function inVerificationWindow(uint64 q) external view returns (bool) {
        return _inVerificationWindow(q);
    }

    /// @dev post-binding: now > E+POST+VERIFY.
    function afterBinding(uint64 q) external view returns (bool) {
        return _afterBinding(q);
    }
}
