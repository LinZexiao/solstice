// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// SRA test common base (test-first contract anchor)
//
// This file is the SRA contract interface anchor: it pins the exact signatures, types,
// and constructor parameters the implementation must match.
//
// Test assumptions:
//   the constructor signature (9 params) is a test-side derivation
//   FilecoinPayVolume is a single USD total (FIP-0118 FIPs#1275: off-chain conversion)
//   PRICE_BAND in basis points (2000 = allows ±20% deviation); authoritative for the off-chain indexer

import {SafeProxy} from "@safe/proxies/SafeProxy.sol";

import {MockRewardTest} from "./mocks/MockRewardTest.sol";
import {WAD} from "./mocks/FVMRewardActor.sol";

import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";
import {Binding} from "../src/lib/SraTypes.sol";
import {SERVICE_ID, Share, WeightRecord} from "../src/lib/FVMRewardTypes.sol";
import {FVMRewards} from "../src/lib/FVMRewards.sol";
import {SWA_TIMELOCK} from "../src/lib/FVMRewardMethod.sol";

/// @notice Common test base: deploys the SRA, builds Safe owners, registers service stream 2, quarterly time utilities.
contract SRATestBase is MockRewardTest {
    ServiceRewardsActor internal sra;
    address internal owner1;
    address internal owner2;

    // ---- small test window constants (constructor config) ----
    // quarter 1000 epochs, posting 300, verification 400, hold 100; ACTIVATION = 100000
    // keeps quarter 0's windows far from the "SWA_TIMELOCK(20160) advance required to register stream 2".
    // POST_PERIOD(300) > 2×SRA_CANCEL_HOLD(200): guarantees two consecutive freezes within the posting
    // period (each 2 votes + 100 hold) complete before E+POST (the timing prerequisite for all-frozen -> burn).
    uint64 internal constant EPOCHS_PER_QUARTER = 1000;
    uint64 internal constant POST_PERIOD = 300;
    uint64 internal constant VERIFICATION_WINDOW = 400;
    uint64 internal constant SRA_CANCEL_HOLD = 100;
    uint64 internal constant ACTIVATION_EPOCH = 100_000;
    uint256 internal constant MIN_LOT = 100; // 100 USD (lot face value; authoritative for the off-chain indexer, FIPs#1275)
    uint256 internal constant PRICE_BAND = 2000; // 20% (basis points), test threshold

    function setUp() public virtual override {
        super.setUp();
        owner1 = _makeSafeOwner("sra-owner1");
        owner2 = _makeSafeOwner("sra-owner2");
        sra = new ServiceRewardsActor(
            owner1,
            owner2,
            Epoch.wrap(EPOCHS_PER_QUARTER),
            Epoch.wrap(POST_PERIOD),
            Epoch.wrap(VERIFICATION_WINDOW),
            Epoch.wrap(SRA_CANCEL_HOLD),
            Epoch.wrap(ACTIVATION_EPOCH),
            MIN_LOT,
            PRICE_BAND
        );
        _registerServiceStream();
    }

    /// @dev Builds a Safe proxy address (following the SWA test technique: masterCopy + SafeProxy + vm.etch + slot0).
    function _makeSafeOwner(string memory label) internal returns (address proxyAddr) {
        address masterCopy = makeAddr(string.concat(label, "-mastercopy"));
        vm.etch(masterCopy, new bytes(8001));

        SafeProxy real = new SafeProxy(masterCopy);
        bytes memory code = address(real).code;

        proxyAddr = makeAddr(label);
        vm.etch(proxyAddr, code);
        vm.store(proxyAddr, bytes32(0), bytes32(uint256(uint160(masterCopy))));
    }

    /// @dev migration pins service stream = 2, already registered with writer = SRA:
    /// the base contract temporarily acts as the swa, registers EXPLICIT stream 2 (writer = address(sra)),
    /// advances past SWA_TIMELOCK and uses one mock dispatch to trigger _settle so the stream takes effect.
    function _registerServiceStream() internal {
        rewardActor().mockSwa(address(this));

        Share[] memory initialShares = new Share[](1);
        initialShares[0] = Share({wallet: address(sra), share: FixedU18.wrap(1e18)});
        int256 exitCode = FVMRewards.tryRegisterStream(
            SERVICE_ID,
            WeightRecord({vStart: 0, slope: 0, tStart: Epoch.wrap(0), floor: 0, cap: WAD}),
            address(sra),
            initialShares,
            uint64(block.number) + SWA_TIMELOCK
        );
        require(exitCode == 0, "registerServiceStream failed");

        vm.roll(block.number + SWA_TIMELOCK);
        // trigger one dispatch: the mock's handle_filecoin_method entry runs _settle() first, applying the due registration.
        rewardActor().mockAwardBlockReward(0);
    }

    // ------------------------------------------------------------------------
    // Quarterly time utilities (Epoch = block.number, controlled by vm.roll)
    // ------------------------------------------------------------------------

    function _qEnd(uint64 q) internal pure returns (uint64) {
        return ACTIVATION_EPOCH + q * EPOCHS_PER_QUARTER;
    }

    /// @notice end epoch of the posting period: E + POST (posting window is (E, E+POST])
    function _qPostEnd(uint64 q) internal pure returns (uint64) {
        return _qEnd(q) + POST_PERIOD;
    }

    /// @notice end epoch of the verification window: E + POST + VERIFY (window is (E+POST, E+POST+VERIFY])
    function _qVerifyEnd(uint64 q) internal pure returns (uint64) {
        return _qPostEnd(q) + VERIFICATION_WINDOW;
    }

    function _rollTo(uint64 epoch) internal {
        vm.roll(epoch);
    }

    // ------------------------------------------------------------------------
    // Data construction utilities
    // ------------------------------------------------------------------------

    /// @notice single USD total for the quarter (FIP-0118 FIPs#1275: off-chain FIL→USD conversion).
    function _fpv(uint256 usd) internal pure returns (uint256) {
        return usd;
    }

    function _pair(address payer, address operator) internal pure returns (Binding memory) {
        return Binding({payer: payer, operator: operator});
    }

    // ------------------------------------------------------------------------
    // Governance operation helpers: two votes (unanimous + hold) -> roll past hold -> permissionless completion
    // ------------------------------------------------------------------------

    function _admit(address orch) internal {
        vm.prank(owner1);
        sra.admit(orch);
        vm.prank(owner2);
        sra.admit(orch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.admit(orch); // third call (permissionless) completes execution
    }

    function _freeze(address orch) internal {
        vm.prank(owner1);
        sra.freeze(orch);
        vm.prank(owner2);
        sra.freeze(orch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.freeze(orch);
    }

    function _unfreeze(address orch) internal {
        vm.prank(owner1);
        sra.unfreeze(orch);
        vm.prank(owner2);
        sra.unfreeze(orch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.unfreeze(orch);
    }

    function _remove(address orch) internal {
        vm.prank(owner1);
        sra.remove(orch);
        vm.prank(owner2);
        sra.remove(orch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.remove(orch);
    }

    /// @notice correctVolume uses unanimousNoHold: the second vote executes, no roll needed.
    /// @dev value is an 18-decimal USD figure; wrapped to FixedU18 at the contract boundary.
    function _correctVolume(address orch, uint64 q, uint256 value) internal {
        vm.prank(owner1);
        sra.correctVolume(orch, q, FixedU18.wrap(value));
        vm.prank(owner2);
        sra.correctVolume(orch, q, FixedU18.wrap(value));
    }

    /// @notice posts a single USD total as the orchestrator within quarter q's posting window.
    /// @dev fpv is an 18-decimal USD figure; wrapped to FixedU18 at the contract boundary.
    function _postAs(address orch, uint64 q, uint256 fpv) internal {
        vm.prank(orch);
        sra.postVolume(q, FixedU18.wrap(fpv));
    }

    /// @notice registers binding pairs as the orchestrator within quarter q's posting window.
    function _registerPairsAs(address orch, Binding[] memory pairs) internal {
        vm.prank(orch);
        sra.registerPairs(pairs);
    }
}
