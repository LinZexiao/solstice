// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {EMPTY_SET, FULL_SET, OwnerSet} from "./OwnerSet.sol";

library OwnersLibrary {
    struct OwnerInfo {
        uint8 bitId; // [0, 160]
    }

    /// @custom:storage-location erc7201:Solstice.Owners
    struct Owners {
        mapping(address => OwnerInfo) ownerInfo;
        uint8 nextBitCursor; // [0, 160)
        OwnerSet allOwners;
    }

    // keccak256(abi.encode(uint256(keccak256("Solstice.Owners")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant OWNERS_SLOT = 0x7d2e7f914625694dd929b468ac404d7943373f4d24421c78ac93b57cc8efb500;

    function getOwnersSlot() internal pure returns (Owners storage owners) {
        assembly ("memory-safe") {
            owners.slot := OWNERS_SLOT
        }
    }

    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);

    function isOwner(address someone) internal view returns (bool) {
        return getOwnersSlot().ownerInfo[someone].bitId != 0;
    }

    /// @dev Returns EMPTY_SET if `owner` is not a current owner.
    function asOwnerSet(address owner) internal view returns (OwnerSet mask) {
        uint8 ownerBit = getOwnersSlot().ownerInfo[owner].bitId;
        assembly ("memory-safe") {
            mask := shl(sub(ownerBit, 1), 1)
        }
    }

    function getAllOwners() internal view returns (OwnerSet) {
        return getOwnersSlot().allOwners;
    }

    // Proposed owner is already an owner
    error AlreadyOwner(address owner);
    // Unsupported ownership count (> 160)
    error MaximumOwnersReached();

    /// @param owner The address to grant ownership to
    function addOwner(address owner) internal {
        require(!isOwner(owner), AlreadyOwner(owner));

        Owners storage owners = getOwnersSlot();
        uint8 ownerBit = owners.nextBitCursor;
        OwnerSet allOwners = owners.allOwners;

        require(allOwners != FULL_SET, MaximumOwnersReached());

        OwnerSet ownerSet = EMPTY_SET;

        // assign next free bit
        while (true) {
            assembly ("memory-safe") {
                ownerSet := shl(ownerBit, 1)
                ownerBit := add(1, ownerBit)
            }
            if (ownerSet & allOwners == EMPTY_SET) {
                break;
            } else {
                ownerBit %= 160;
            }
        }

        owners.ownerInfo[owner].bitId = ownerBit;
        owners.allOwners = allOwners | ownerSet;
        owners.nextBitCursor = ownerBit % 160;

        emit OwnerAdded(owner);
    }

    // Address to remove is not a current owner
    error NotOwner(address owner);
    error CannotRemoveLastOwner();

    /// @param owner The address to revoke ownership from
    /// @dev A removed owner's bit may be recycled to a future owner by addOwner.
    /// @dev Does not veto pending tasks; callers must veto stale PendingTasks before removing an
    ///      owner, or the freed bit recycles to a future owner carrying the old approvals.
    function removeOwner(address owner) internal {
        require(isOwner(owner), NotOwner(owner));

        Owners storage owners = getOwnersSlot();
        OwnerSet mask = asOwnerSet(owner);

        OwnerSet nextOwners = owners.allOwners ^ mask;
        require(nextOwners != EMPTY_SET, CannotRemoveLastOwner());

        owners.allOwners = nextOwners;

        delete owners.ownerInfo[owner];

        emit OwnerRemoved(owner);
    }
}
