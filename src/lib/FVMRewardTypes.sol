// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Epoch} from "./Epoch.sol";
import {FixedU18} from "./FixedU18.sol";

// f02's service stream fixed id — the f02 migration pins consensus = 1 and service = 2.
uint64 constant SERVICE_ID = 2;

/// @notice A stream's Distribution kind (FIP-0118 Section 2.4).
/// @dev IMPLICIT streams store no writer (f02 resolves the recipient from protocol state).
///      EXPLICIT streams are paid out per a wallet-to-share map written by their designated writer.
enum DistributionKind {
    IMPLICIT,
    EXPLICIT
}

/// @notice A stream's weight schedule: clamp(vStart + slope * (epoch - tStart), floor, cap).
/// @dev WAD-scaled (1e18 == 1.0 == 100%); fields must fit int64 to be wire-encodable.
struct WeightRecord {
    int256 vStart;
    int256 slope;
    Epoch tStart;
    int256 floor;
    int256 cap;
}

/// @notice One entry in a SetWeightRecords/StepWeightRecords batch.
/// @dev Bundling the id with its record makes a batch's two lengths structurally equal -- there
/// is no encoding for a mismatch, so none needs to be checked for.
struct WeightRecordUpdate {
    uint64 id;
    WeightRecord record;
}

/// @notice One entry in an EXPLICIT stream's wallet-to-share map.
/// @dev Shares across a stream's map must sum to SHARE_TOTAL (1e18); a single share must
///      therefore fit uint64.
struct Share {
    address wallet;
    FixedU18 share;
}

/// @notice The kinds of queueable SWA discretionary writes a pending slot may hold.
enum PendingOp {
    SET_WEIGHT,
    STEP_WEIGHT,
    REGISTER,
    REMOVE,
    SET_DISTRIBUTION
}
