// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Epoch} from "../lib/Epoch.sol";
import {FixedU18} from "../lib/FixedU18.sol";

interface IServiceRewardsActor {
    function aggregatedFilecoinPayVolume(uint64 quarter) external view returns (FixedU18 filecoinPayVolume);
    function qEnd(uint64 quarter) external view returns (Epoch quarterEnd);
    function EPOCHS_PER_QUARTER() external view returns (Epoch oneQuarter);
    function SRA_CANCEL_HOLD() external view returns (Epoch hold);
}
