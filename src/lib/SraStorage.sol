// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {Epoch} from "./Epoch.sol";
import {FixedU18} from "./FixedU18.sol";

// ----------------------------------------------------------------------------
// SRA ERC-7201 storage layout (4 namespaces) + precomputed slots, in a shared
// library so the #5 proxy refactor can use the exact same namespace definitions
// between proxy and implementation — a single source of truth for the storage layout.
//
// Identity model: a uint64 id is the orchestrator identity; an address is only the
// current effective wallet mapping (activeIdOf). bindings/fpv/freeze history all
// key on the id, so replace is an O(1) wallet re-point and historical quarter data
// survives an operator-address change without migration. ids are allocated
// monotonically and never reused (0 is the unregistered sentinel), so a removed
// id stays resolvable — a released binding pair is "unclaimed" iff the bound id's
// admitted flag is false.
// ----------------------------------------------------------------------------

library SraStorage {
    struct OrchestratorInfo {
        address wallet; // current effective wallet (replace updates this; the share map writes this) — 20B
        bool admitted; // admitted — 1B
        // Frozen-at-E+POST flag: exactly "was this orchestrator frozen at the close of the
        // posting period of the active quarter" — the fpv-effectiveness test. It changes only
        // before E+POST (freeze/unfreeze in the posting window set/clear it); from the
        // verification window onward it is fixed. Contrast frozenSince, which tracks the
        // current freeze state (0 = not frozen) for admission checks and freeze/unfreeze symmetry.
        bool frozenAtPostEnd; // 1B
        Epoch frozenSince; // current freeze state: 0 = not frozen; > 0 = frozen since this epoch — 8B
        // 4 fields pack into one 32B word (30B)
        // Contribution slots (mirror): fpv = active-quarter contribution (0 = not posted),
        // prevFpv = previous-quarter contribution mirror, exclusion-fixed at mirror advance
        // (prevFpv <- frozenAtPostEnd ? 0 : fpv; fpv = 0). submitShares reads fpv for the
        // active quarter (q == activeQ) and prevFpv for the previous one (q == activeQ - 1).
        FixedU18 fpv; // word 1
        FixedU18 prevFpv; // word 2
    }

    /// @custom:storage-location erc7201:Solstice.SRA.Registry
    struct SraStorageRegistry {
        mapping(uint64 id => OrchestratorInfo) orchestrators; // id is the identity (monotonic, never reused)
        mapping(address orch => uint64 id) activeIdOf; // current effective address -> id (0 = unregistered sentinel)
        mapping(bytes32 pairId => uint64 id) bindings; // pairId = keccak256(abi.encode(payer, operator))
        uint64 nextId; // id allocator (constructor sets 1; 0 is the unregistered sentinel)
        uint64[] admittedIds; // enumerable admitted (incl. frozen); length doubles as the count
    }

    /// @custom:storage-location erc7201:Solstice.SRA.AdmittedLists
    struct SraStorageLists {
        mapping(address => bool) stablecoins; // admitted stablecoins (valued at face USD)
        mapping(address => bool) filecoinPayContracts; // admitted Filecoin Pay contracts
        address[] stablecoinList; // needed for exclusive updates (design-gap completion)
        address[] filecoinPayList;
    }

    /// @custom:storage-location erc7201:Solstice.SRA.Quarter
    struct SraStorageQuarter {
        // activeQ: the quarter the mirror has advanced to (postVolume/correctVolume set it on
        // the first write of a new quarter — the advance trigger). The previous quarter's
        // per-orchestrator contributions live in prevFpv (exclusion-fixed at the advance);
        // only these two quarters retain per-orchestrator values (spec: CorrectVolume is
        // bounded by the verification window, so no historical corrections exist).
        uint64 activeQ;
        uint64 lastSubmittedQ; // anti-replay: last submitted quarter + 1 (0 = none; q+1 encoding so quarter 0 does not collide with the sentinel; monotonic, no reset)
        // Quarter counter array: per-quarter USD aggregate (aggregatedFPV O(1) for every
        // quarter, fixed once the mirror advances — spec determinism: the registry is constant
        // within a quarter, so the aggregate cannot drift with later remove/replace).
        mapping(uint64 Q => FixedU18) totalUsd;
    }

    /// @custom:storage-location erc7201:Solstice.SRA.Params
    struct SraStorageParams {
        uint256 minLot; // MIN_LOT (FIP §2.3: governs the off-chain conversion, not an on-chain computation)
        uint256 priceBand; // PRICE_BAND (basis points; same — authoritative parameter for the off-chain indexer)
    }

    // keccak256(abi.encode(uint256(keccak256(namespace)) - 1)) & ~bytes32(uint256(0xff)) — precomputed and hardcoded
    bytes32 internal constant REGISTRY_SLOT = 0xb7fd4b054ced95f43476af93bf71636318271f9e64f7661dc52f0fb4c1a54400;
    bytes32 internal constant LISTS_SLOT = 0x6b063b99e710dc539d819b661c65b9a94a4c91adbbbff20449f292eda97f9300;
    bytes32 internal constant QUARTER_SLOT = 0x347e624280399e1e720d839edbd7cd00c80c69bf34cd8ee59e27f691732af300;
    bytes32 internal constant PARAMS_SLOT = 0xe21afbd697880784c3da970abdca3a316f22b4c4fc74f2fceb073d8e55bcad00;

    function registry() internal pure returns (SraStorageRegistry storage r) {
        assembly ("memory-safe") {
            r.slot := REGISTRY_SLOT
        }
    }

    function lists() internal pure returns (SraStorageLists storage l) {
        assembly ("memory-safe") {
            l.slot := LISTS_SLOT
        }
    }

    function quarter() internal pure returns (SraStorageQuarter storage q) {
        assembly ("memory-safe") {
            q.slot := QUARTER_SLOT
        }
    }

    function params() internal pure returns (SraStorageParams storage p) {
        assembly ("memory-safe") {
            p.slot := PARAMS_SLOT
        }
    }
}
