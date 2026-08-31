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

    // keccak256(abi.encode(uint256(keccak256(namespace)) - 1)) & ~bytes32(uint256(0xff)) — precomputed and hardcoded
    bytes32 internal constant REGISTRY_SLOT = 0xb7fd4b054ced95f43476af93bf71636318271f9e64f7661dc52f0fb4c1a54400;
    bytes32 internal constant QUARTER_SLOT = 0x347e624280399e1e720d839edbd7cd00c80c69bf34cd8ee59e27f691732af300;

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
}
