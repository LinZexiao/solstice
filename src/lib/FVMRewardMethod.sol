// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// FRC-0042 method numbers for the f02 (Reward actor) stream-splitting methods specified by
// FIP-0118 (https://github.com/filecoin-project/FIPs/blob/master/FIPS/fip-0118.md) and implemented in
// filecoin-project/builtin-actors#1764. Each is the FRC-0042 hash of the method's name. Defined
// here so FVMRewards and its mock cannot disagree.
uint64 constant REGISTER_STREAM = 386660827;
uint64 constant REMOVE_STREAM = 1623858416;
uint64 constant SET_WEIGHT_RECORDS = 3362570548;
uint64 constant STEP_WEIGHT_RECORDS = 3951753085;
uint64 constant SET_DISTRIBUTION = 3872725033;
uint64 constant CANCEL_PENDING = 187585191;
uint64 constant SET_SHARES = 2414422607;
uint64 constant CLAIM = 4045527845;
