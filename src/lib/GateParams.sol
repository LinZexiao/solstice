// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {FixedU18} from "./FixedU18.sol";

FixedU18 constant VOL_TARGET_ENTRY = FixedU18.wrap(3500 ether);
FixedU18 constant VOL_TARGET_RATIO = FixedU18.wrap(2.7 ether);

struct VolumeTarget {
    FixedU18 base;
    FixedU18 stepRatio;
}

struct GateParams {
    VolumeTarget target;
    uint64 steps;
}

using GateParamsLibrary for GateParams global;

library GateParamsLibrary {
    /// @dev Maximum gate steps the params may carry: (W2_CAP - W2_BASE) / W2_STEP = (0.50 - 0.10) / 0.05
    ///      = 8 (FIP-0118 §3.1.1 setGateParams bounds). Steps at the cap land w2 on W2_CAP and are legal.
    uint64 internal constant GATE_STEPS = 8;

    /// @custom:storage-location erc7201:Solstice.GateParams
    struct GateParamsInfo {
        uint64 lastCheckedQuarter;
        GateParams params;
    }

    // keccak256(abi.encode(uint256(keccak256("Solstice.GateParams")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant GATE_PARAMS_SLOT = 0xf9abab00248d945495524c8caf6be2b837274c1becd1964fb3775f62fd6e4600;

    function getGateParamsSlot() internal pure returns (GateParamsInfo storage slot) {
        assembly ("memory-safe") {
            slot.slot := GATE_PARAMS_SLOT
        }
    }

    function nextThreshold(GateParams memory params) internal pure returns (FixedU18 fpvThreshold) {
        return params.target.base * params.target.stepRatio.exp(params.steps);
    }

    function init() internal {
        GateParamsInfo storage slot = GateParamsLibrary.getGateParamsSlot();
        slot.lastCheckedQuarter = 1;
        slot.params.target.base = VOL_TARGET_ENTRY;
        slot.params.target.stepRatio = VOL_TARGET_RATIO;
    }
}
