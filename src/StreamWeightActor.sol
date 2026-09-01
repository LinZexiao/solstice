// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {IServiceRewardsActor} from "./interfaces/IServiceRewardsActor.sol";
import {Epoch} from "./lib/Epoch.sol";
import {FixedU18} from "./lib/FixedU18.sol";
import {GateParams, GateParamsLibrary} from "./lib/GateParams.sol";
import {FVMRewards} from "./lib/FVMRewards.sol";
import {PendingOp, SERVICE_ID, Share, WeightRecord, WeightRecordUpdate} from "./lib/FVMRewardTypes.sol";
import {OwnersLibrary} from "./lib/Owners.sol";
import {UnanimousGovernance} from "./lib/UnanimousGovernance.sol";

int256 constant STEP = 5e16; // 5%

/// @notice Owner-governed actor with sudo control over every f02 stream's weight schedule
/// (FIP-0118, solstice#3): registers, removes, reweights, and reassigns writers by stream id.
/// @dev Writes require unanimous owner approval, except `cancelPending`/`cancelPendingWeight`
/// (any single owner, immediate) and `quarterlyGateCheck` (fully permissionless).
contract StreamWeightActor is UnanimousGovernance {
    using OwnersLibrary for address;

    IServiceRewardsActor immutable SRA;
    Epoch immutable QUARTER;
    Epoch immutable HOLD;

    /// @notice Deploys the actor with its two initial owners, bound to a Service Rewards Actor.
    /// @param owner1 First owner.
    /// @param owner2 Second owner.
    /// @param sra Service Rewards Actor supplying QUARTER/HOLD and gating `quarterlyGateCheck`.
    constructor(address owner1, address owner2, IServiceRewardsActor sra) {
        owner1.addOwner();
        owner2.addOwner();

        SRA = sra;
        QUARTER = sra.EPOCHS_PER_QUARTER();
        HOLD = sra.SRA_CANCEL_HOLD();

        GateParamsLibrary.init();
    }

    /// @notice Queues a new implicit stream.
    /// @dev f02 resolves the recipient from protocol state; no writer or share map is stored.
    /// @param id Stream id to register.
    /// @param record Initial weight schedule.
    /// @param activationEpoch Epoch the schedule begins applying.
    function registerStream(uint64 id, WeightRecord calldata record, uint64 activationEpoch)
        external
        unanimousNoHold(keccak256(msg.data))
    {
        // hold enforced in f02
        FVMRewards.registerStream(id, record, activationEpoch);
    }

    /// @notice Queues a new explicit stream with its designated writer and initial share map.
    /// @param id Stream id to register.
    /// @param record Initial weight schedule.
    /// @param writer Address permitted to update the share map.
    /// @param shares Initial wallet-to-share map; must be valid at registration.
    /// @param activationEpoch Epoch the schedule begins applying.
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

    /// @notice Queues removal of a stream.
    /// @param id Stream id to remove.
    function removeStream(uint64 id) external unanimousNoHold(keccak256(msg.data)) {
        // hold enforced in f02
        FVMRewards.removeStream(id);
    }

    /// @notice Queues a discretionary weight-schedule write for one or more streams.
    /// @param updates Id/record pairs to write.
    function setWeightRecords(WeightRecordUpdate[] calldata updates) external unanimousNoHold(keccak256(msg.data)) {
        // hold enforced in f02
        FVMRewards.setWeightRecords(updates);
    }

    /// @notice Queues a writer change for an explicit stream.
    /// @param id Stream id whose writer changes.
    /// @param writer New designated writer.
    function setDistribution(uint64 id, address writer) external unanimousNoHold(keccak256(msg.data)) {
        // hold enforced in f02
        FVMRewards.setDistribution(id, writer);
    }

    /// @notice Cancels a queued per-stream operation (register, remove, or setDistribution).
    /// @dev Any current owner, immediate, bypassing unanimity.
    /// @param id Stream id the pending operation targets.
    /// @param op Kind of pending operation to cancel.
    function cancelPending(uint64 id, PendingOp op) external {
        // any owner can immediately cancel any pending operation
        require(msg.sender.isOwner());
        FVMRewards.cancelPending(id, op);
    }

    /// @notice Cancels a queued discretionary weight-schedule write (SetWeightRecords).
    /// @dev Any current owner, immediate. Cannot cancel a gate-originated StepWeightRecords write.
    /// @param op Weight operation to cancel.
    function cancelPendingWeight(PendingOp op) external {
        // any owner can immediately cancel any pending operation
        require(msg.sender.isOwner());
        FVMRewards.cancelPendingWeight(op);
    }

    /// @notice Replaces one of the two owners.
    /// @param prevOwner Owner being removed.
    /// @param newOwner Owner being added.
    function replaceOwner(address prevOwner, address newOwner) external unanimousNoHold(keccak256(msg.data)) {
        prevOwner.removeOwner();
        newOwner.addOwner();
    }

    /// @notice All 8 gate steps have already been taken.
    error StepsComplete();

    /// @notice Advances the quarterly gate by one quarter, stepping SERVICE_ID's weight schedule
    /// if the elapsed quarter's aggregated FilecoinPayVolume cleared the next volume threshold.
    /// @dev Permissionless; reverts via the SRA if the quarter's FilecoinPayVolume is not yet bound.
    function quarterlyGateCheck() external {
        GateParamsLibrary.GateParamsInfo storage gateParamsInfo = GateParamsLibrary.getGateParamsSlot();
        GateParams memory loaded = gateParamsInfo.params;
        require(loaded.steps < 8, StepsComplete());

        uint64 quarter = ++gateParamsInfo.lastCheckedQuarter;
        // NOTE this will enforce afterBinding()
        FixedU18 fpv = SRA.aggregatedFilecoinPayVolume(quarter);

        if (fpv >= loaded.nextThreshold()) {
            int256 next = (int256(uint256(loaded.steps)) + 3) * STEP;

            WeightRecordUpdate[] memory updates = new WeightRecordUpdate[](1);
            updates[0].id = SERVICE_ID;
            updates[0].record.floor = next;
            updates[0].record.tStart = SRA.qEnd(quarter);
            updates[0].record.vStart = next;
            updates[0].record.cap = next;
            updates[0].record.slope = 0;

            gateParamsInfo.params.steps++;
            FVMRewards.stepWeightRecords(updates);
        }
    }

    /// @notice Overwrites the quarterly gate's parameters; has a HOLD-epoch timelock after unanimity.
    /// @param params New volume target and step state.
    function setGateParams(GateParams calldata params) external unanimous(keccak256(msg.data), HOLD) {
        GateParamsLibrary.getGateParamsSlot().params = params;
    }
}
