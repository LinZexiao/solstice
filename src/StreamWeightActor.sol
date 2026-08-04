// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {FVMRewards} from "./lib/FVMRewards.sol";
import {PendingOp, Share, WeightRecord, WeightRecordUpdate} from "./lib/FVMRewardTypes.sol";
import {OwnersLibrary} from "./lib/Owners.sol";
import {UnanimousGovernance} from "./lib/UnanimousGovernance.sol";
import {IsASafe} from "./lib/IsASafe.sol";

contract StreamWeightActor is UnanimousGovernance {
    using IsASafe for address;
    using OwnersLibrary for address;

    constructor(address owner1, address owner2) {
        owner1.isProbablyASafe();
        owner2.isProbablyASafe();

        owner1.addOwner();
        owner2.addOwner();
    }

    function registerStream(uint64 id, WeightRecord calldata record, uint64 activationEpoch)
        external
        unanimousNoHold(keccak256(msg.data))
    {
        // hold enforced in f02
        FVMRewards.registerStream(id, record, activationEpoch);
    }

    function registerStream(
        uint64 id,
        WeightRecord calldata record,
        address writer,
        Share[] calldata shares,
        uint64 activationEpoch
    ) external unanimousNoHold(keccak256(msg.data)) {
        // hold enforced in f02
        FVMRewards.registerStream(id, record, writer, shares, activationEpoch);
    }

    function removeStream(uint64 id) external unanimousNoHold(keccak256(msg.data)) {
        // hold enforced in f02
        FVMRewards.removeStream(id);
    }

    function setWeightRecords(WeightRecordUpdate[] calldata updates) external unanimousNoHold(keccak256(msg.data)) {
        // hold enforced in f02
        FVMRewards.setWeightRecords(updates);
    }

    function setDistribution(uint64 id, address writer) external unanimousNoHold(keccak256(msg.data)) {
        // hold enforced in f02
        FVMRewards.setDistribution(id, writer);
    }

    function cancelPending(uint64 id, PendingOp op) external {
        // any owner can immediately cancel any pending operation
        require(msg.sender.isOwner());
        FVMRewards.cancelPending(id, op);
    }

    function cancelPendingWeight(PendingOp op) external {
        // any owner can immediately cancel any pending operation
        require(msg.sender.isOwner());
        FVMRewards.cancelPendingWeight(op);
    }

    function replaceOwner(address prevOwner, address newOwner) external unanimousNoHold(keccak256(msg.data)) {
        newOwner.isProbablyASafe();
        prevOwner.removeOwner();
        newOwner.addOwner();
    }
}
