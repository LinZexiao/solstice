// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {FixedU18} from "./FixedU18.sol";


struct Binding {
    address payer;
    address operator;
}

// forge-lint: disable-next-item(pascal-case-struct) — FPV is the FIP-0118 spec term (public ABI-facing type)
/// @notice Quarterly FPV: a single USD-denominated total (FIP-0118 §2.3, FIPs#1275: FIL→USD conversion moved
///         off-chain, so the SRA no longer stores pricing periods). `usd` is the face-USD stablecoin volume plus
///         the off-chain-converted FIL volume; `usd == 0` means not posted
///         (PostVolume rejects zero, CorrectVolume(0) clears).
/// @dev FixedU18: 18-decimal fixed-point USD (1 USD = 1e18 integer). Adopted per the SWA interface
///      (IServiceRewardsActor.aggregatedFPV returns FixedU18) so every USD-consuming computation is
///      type-safe against integer/fixed-point mixing (1 vs 1e18 magnitude errors). MAX_FPV_USD(1e30)
///      keeps the downstream product usd × 1e18 ≤ 1e48 < uint256.max — no overflow in the share math. One storage slot.
struct FPV {
    FixedU18 usd; // single USD total for the quarter (FPV_i(Q)), 18-decimal fixed point; 0 = not posted
}
