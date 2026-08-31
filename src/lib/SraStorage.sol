// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {FixedU18} from "./FixedU18.sol";

library SraStorage {
    struct OrchestratorInfo {
        address wallet; // current effective wallet — 20B
        bool admitted; // admitted — 1B
        // word 0: the two fields above pack into one 32B word (21B)
        FixedU18 fpv; // active quarter
        FixedU18 prevFpv; // previous quarter
        uint64 admittedIndex; // position in admittedIds
    }

    /// @custom:storage-location erc7201:Solstice.SRA.Registry
    struct SraStorageRegistry {
        mapping(uint64 id => OrchestratorInfo) orchestrators; // id is the identity (monotonic, never reused)
        mapping(address orch => uint64 id) activeIdOf; // current effective address -> id (0 = unregistered sentinel)
        mapping(bytes32 pairId => uint64 id) bindings; // pairId = keccak256(abi.encode(payer, operator))
        uint64 nextId; // id allocator
        uint64[] admittedIds; // enumerable admitted
    }

    /// @custom:storage-location erc7201:Solstice.SRA.Quarter
    struct SraStorageQuarter {
        uint64 activeQuarter;
        uint64 nextQuarter; // last submitted quarter + 1
        mapping(uint64 quarter => FixedU18) totalUsd;
    }

    /// @custom:storage-location erc7201:Solstice.SRA.LastShares
    /// @dev The f02 share map has no read-back (FVMRewardMethod has no GET_SHARES), so SRA keeps
    ///      its own snapshot of the last submitted map to drive the immediate f099 push on
    ///      removeOrchestrator / the wallet swap on replaceWallet.
    struct SraStorageLastShares {
        mapping(uint64 id => FixedU18) lastShares; // share>0 的 admitted entry 快照（不含 f099）
        uint64[] lastShareIds;
    }

    // keccak256(abi.encode(uint256(keccak256(namespace)) - 1)) & ~bytes32(uint256(0xff)) — precomputed and hardcoded
    bytes32 internal constant REGISTRY_SLOT = 0xb7fd4b054ced95f43476af93bf71636318271f9e64f7661dc52f0fb4c1a54400;
    bytes32 internal constant QUARTER_SLOT = 0x347e624280399e1e720d839edbd7cd00c80c69bf34cd8ee59e27f691732af300;
    bytes32 internal constant LAST_SHARES_SLOT = 0x8f6532fa5014c056fe83781daa76176834ccfd1ca78d78f4ea5a24128857ed00;

    function registry() internal pure returns (SraStorageRegistry storage r) {
        assembly ("memory-safe") {
            r.slot := REGISTRY_SLOT
        }
    }

    function quarter() internal pure returns (SraStorageQuarter storage q) {
        assembly ("memory-safe") {
            q.slot := QUARTER_SLOT
        }
    }

    function lastShares() internal pure returns (SraStorageLastShares storage s) {
        assembly ("memory-safe") {
            s.slot := LAST_SHARES_SLOT
        }
    }
}
