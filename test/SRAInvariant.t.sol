// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// SRA invariant tests (P1) — random operation sequences + persistent invariant verification
//
// 3 core invariants:
//   I1 Share conservation: after any operation sequence (the most recent successful submitShares),
//      the f02 share map Σ is always == 1e18
//   I2 Binding uniqueness: any (payer, operator) pair always has at most 1 valid bound orchestrator;
//      the handler-recorded last binder (resolved along the replace chain) must == sra.bindingOf()
//      — a third-party grab after replace is exactly the kind of invariant this breaks
//   I3 Governance consistency: the approved bitmask is consistent with orchestrator state —
//      parked tasks (one vote, not executed) have a non-zero bitmask and state not landed;
//      executed tasks have a zeroed bitmask (deleted after execution); handler-expected state == sra actual
//
// Handler design:
//   - inherits SRATestBase (auto-deploys SRA + Safe owners + service stream 2)
//   - 12 random operations (fuzzer targets): admit/remove/replace/
//     reassignBinding/registerPairs/cancelBinding/postVolume/correctVolume/
//     submitShares/parkAdmit/completeParked/rollForward
//     (finalizeConversion removed by FIPs#1275)
//   - time model: governance operations execute on the second vote (unanimousNoHold, no hold window);
//     business operations explicitly roll to the target quarter window (posting/verification/post-bound)
//   - every operation's precondition check keeps the "expected success" path reachable (invalid calls return directly, no state pollution)
//
// Run: forge test --match-contract SRAInvariant (default 256 runs)

import {Test} from "forge-std/Test.sol";

import {SERVICE_ID, Share} from "../src/lib/FVMRewardTypes.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {Binding} from "../src/lib/SraTypes.sol";
import {SRATestBase} from "./SRATestBase.sol";

/// @dev ERC-7201 storage slot of PendingTask (see src/lib/PendingTask.sol: Solstice.PendingTasks).
///     Hardcoded on the test side to read the approved bitmask (invariant I3).
bytes32 constant PENDING_TASKS_SLOT = 0x635f64a8ec66823e68578973f5bc466fd4e0eadd655f760cfc91e860524aa300;

/// @dev ERC-7201 Registry namespace slot (src/lib/SraStorage.sol) — read directly because the id list and
///     the admittedIndex field are internal to the identity model (no public getter).
bytes32 constant REGISTRY_SLOT = 0xb7fd4b054ced95f43476af93bf71636318271f9e64f7661dc52f0fb4c1a54400;

/// @notice Invariant handler: encapsulates random operations and maintains "expected state" for invariant assertions.
contract SRAInvariantHandler is SRATestBase {
    uint256 internal constant ORCH_POOL = 20;
    uint256 internal constant PAYER_POOL = 5;
    uint256 internal constant OPERATOR_POOL = 5;
    uint256 internal constant MAX_Q = 2; // explores quarters 0/1/2

    // ---- orchestrator pool and handler-side expected state ----
    address[] internal _orchPool;
    mapping(address => bool) internal _admitted; // expected admitted
    /// @dev identity generation per address: incremented on every admit. The id-keyed implementation reuses an
    ///      address across successive identities (remove -> re-admit -> new id), so an address alone cannot
    ///      identify which id holds a binding; the generation disambiguates it (replace re-points the *current*
    ///      generation's pairs only).
    mapping(address => uint256) internal _idGen;
    /// @dev current payout wallet per identity (spec §3.2 ReplaceWallet: identity does not move, only the
    ///      wallet re-points). Bound records resolve through this map — bindingOf reads orchestrators[id].wallet,
    ///      so after a replace the binding still resolves to the new wallet while the identity stays put.
    mapping(address => address) internal _idWallet;
    uint256 internal _genSeq;

    // ---- pair pool and binding records ----
    address[] internal _payers;
    address[] internal _operators;

    struct PairRecord {
        address payer;
        address operator;
        address boundOrch; // handler-recorded last successful binder
        uint256 gen; // binder identity generation at binding time
    }
    PairRecord[] internal _pairs;
    mapping(bytes32 => uint256) internal _pairIdx; // pairId → _pairs index + 1

    // ---- quarterly posting records (avoid invalid AlreadyPosted calls) ----
    mapping(uint64 => mapping(address => bool)) internal _posted;

    // ---- governance task tracking (invariant I3) ----
    /// @dev taskState: 0=none 1=parked (two votes, not executed; pending across operations) 2=executed 3=cleared (reverted but deleted)
    mapping(bytes32 => uint8) internal _taskState;
    mapping(bytes32 => address) internal _parkedOrch;
    mapping(bytes32 => uint64) internal _parkedEpoch;
    bytes32[] internal _parkedTasks;
    bytes32[] internal _executedTasks;
    /// @dev set of parked governance target addresses: while parked, the target must not be pre-admitted/replaced by atomic ops (I3 consistency)
    mapping(address => bool) internal _parkedTarget;

    bool internal _everSubmitted;

    /// @dev quarter and POST-instant snapshot of the most recent successful submitShares (read by the invariants).
    bool internal _hasLastSubmit;
    uint64 internal _lastSubmitQ;
    uint256 internal _lastTotal; // Σ usdValue of active orchestrators with usdValue>0 at the POST instant
    uint256 internal _lastActiveCount; // corresponding orchestrator count

    constructor() {
        for (uint256 i = 0; i < ORCH_POOL; i++) {
            _orchPool.push(makeAddr(string.concat("inv-orch-", vm.toString(i))));
        }
        for (uint256 i = 0; i < PAYER_POOL; i++) {
            _payers.push(makeAddr(string.concat("inv-payer-", vm.toString(i))));
        }
        for (uint256 i = 0; i < OPERATOR_POOL; i++) {
            _operators.push(makeAddr(string.concat("inv-operator-", vm.toString(i))));
        }
    }

    // Governance operations (unanimous + hold three phases: owner1 vote -> owner2 vote -> roll(hold) -> third execution)
    // Precondition checks guarantee the third call succeeds (no concurrent insertion between the two votes; operation is atomic)

    /// @notice Atomic admit: two votes, the second executes immediately (unanimousNoHold).
    function admit(uint256 idx) external {
        address orch = _pickOrch(idx);
        if (sra.isAdmitted(orch) || sra.admittedCount() >= 64) return;
        if (_parkedTarget[orch]) return; // must not preempt a parked governance target (I3)
        bytes32 taskId = _taskId(sra.addOrchestrator.selector, abi.encode(orch, orch));
        vm.prank(owner1);
        sra.addOrchestrator(orch, orch);
        vm.prank(owner2);
        sra.addOrchestrator(orch, orch); // second vote executes (unanimousNoHold)
        _admitted[orch] = true;
        _genSeq++;
        _idGen[orch] = _genSeq; // fresh identity generation (re-admit = new id)
        _idWallet[orch] = orch; // a fresh identity's payout wallet is the address itself
        _recordExecuted(taskId);
    }

    /// @notice Atomic remove: releases the slot; the handler must sync its own bookkeeping (I2).
    /// @dev Spec §3.2 timing guard: remove reverts while a bound quarter awaits its share map. The handler
    ///      mirrors the spec's governance procedure — clear any pending quarter by cranking SubmitShares first
    ///      (permissionless + idempotent; quarters beyond MAX_Q are never bound here), so the guard passes.
    ///      The crank keeps the snapshot bookkeeping in sync with the contract.
    function remove(uint256 idx) external {
        address orch = _pickOrch(idx);
        if (!sra.isAdmitted(orch)) return;
        for (uint64 qq = 0; qq <= MAX_Q; qq++) {
            _crankSubmitShares(qq);
        }
        bytes32 taskId = _taskId(sra.removeOrchestrator.selector, abi.encode(orch, ""));
        vm.prank(owner1);
        sra.removeOrchestrator(orch, "");
        vm.prank(owner2);
        sra.removeOrchestrator(orch, ""); // second vote executes (unanimousNoHold)
        _admitted[orch] = false;
        _recordExecuted(taskId);
    }

    /// @notice Payout-wallet swap (spec §3.2): the orchestrator identity does not move — only the id's
    ///         wallet is re-pointed, so every current-generation pair bound to it resolves to the new
    ///         wallet (bindingOf reads orchestrators[id].wallet). _admitted / _idGen stay unchanged.
    function replace(uint256 oldIdx, uint256 newIdx) external {
        address oldOrch = _pickOrch(oldIdx);
        address newWallet = _pickOrch(newIdx);
        if (oldOrch == newWallet) return;
        // newWallet must not be an admitted orchestrator: in this handler every admitted wallet is the
        // identity itself (_admit(x, x)), so a duplicate would revert DuplicateWallet (D7).
        if (!sra.isAdmitted(oldOrch) || sra.isAdmitted(newWallet)) return;
        if (_parkedTarget[newWallet]) return; // must not preempt a parked governance target (I3)
        bytes32 taskId = _taskId(sra.replaceWallet.selector, abi.encode(oldOrch, newWallet));
        vm.prank(owner1);
        sra.replaceWallet(oldOrch, newWallet);
        vm.prank(owner2);
        sra.replaceWallet(oldOrch, newWallet); // second vote executes (unanimousNoHold)
        // wallet swap: the id keeps its identity (spec §3.2); the handler re-points the wallet map and
        // leaves every bound record's identity untouched — bindingOf resolves through _idWallet, so all
        // current-generation pairs bound to the id read the new wallet automatically.
        _idWallet[oldOrch] = newWallet;
        _recordExecuted(taskId);
    }

    /// @notice Disputed pair reassignment: the target orchestrator must be admitted.
    function reassignBinding(uint256 pairIdx, uint256 orchIdx) external {
        (address payer, address operator) = _pickPair(pairIdx);
        address orch = _pickOrch(orchIdx);
        if (!sra.isAdmitted(orch)) return;
        bytes32 taskId = _taskId(sra.reassignBinding.selector, abi.encode(payer, operator, orch, false));
        vm.prank(owner1);
        sra.reassignBinding(payer, operator, orch, false);
        vm.prank(owner2);
        sra.reassignBinding(payer, operator, orch, false); // second vote executes (unanimousNoHold)
        _setBound(payer, operator, orch);
        _recordExecuted(taskId);
    }

    /// @notice Governance release of a binding: the pair returns to unclaimed and becomes claimable
    ///         by anyone again (spec §4.2). The guard mirrors registerPairs's AlreadyBound check —
    ///         only a live binding (binder still admitted at its recorded identity) can be canceled;
    ///         a removed/superseded binder's binding already reads as unclaimed under registerPairs
    ///         semantics, so canceling it would revert PairNotBound. Claim and cancel stay mutually
    ///         exclusive: registerPairs claims exactly when cancel reverts, and vice versa.
    function cancelBinding(uint256 pairIdx) external {
        (address payer, address operator) = _pickPair(pairIdx);
        bytes32 pairId = keccak256(abi.encode(payer, operator));
        uint256 idx = _pairIdx[pairId];
        if (idx == 0) return; // never bound -> contract reverts PairNotBound; skip
        PairRecord storage p = _pairs[idx - 1];
        if (!_admitted[p.boundOrch]) return; // binder removed -> already unclaimed, cancel reverts
        if (_idGen[p.boundOrch] != p.gen) return; // binder's identity superseded -> same
        bytes32 taskId = _taskId(sra.cancelBinding.selector, abi.encode(payer, operator));
        vm.prank(owner1);
        sra.cancelBinding(payer, operator);
        vm.prank(owner2);
        sra.cancelBinding(payer, operator); // second vote executes (unanimousNoHold)
        // Sync the handler bookkeeping: binding released, pair unclaimed again — a later
        // registerPairs by any other orchestrator re-binds it (I2 stays consistent).
        p.boundOrch = address(0);
        p.gen = 0;
        _recordExecuted(taskId);
    }

    /// @notice An orchestrator declares binding pairs itself (no governance).
    function registerPairs(uint256 orchIdx, uint256 pairIdx) external {
        address orch = _pickOrch(orchIdx);
        if (!sra.isAdmitted(orch)) return;
        (address payer, address operator) = _pickPair(pairIdx);
        if (!_claimable(orch, payer, operator)) return;
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = Binding({payer: payer, operator: operator});
        vm.prank(orch);
        sra.registerPairs(pairs);
        _setBound(payer, operator, orch);
    }

    // Business operations (posting / verification / bound windows, explicit roll)

    /// @notice An orchestrator posts a pure-stablecoin FilecoinPayVolume (no FIL periods).
    function postVolume(uint256 q, uint256 orchIdx, uint256 usd) external {
        uint64 qq = uint64(bound(q, 0, MAX_Q));
        address orch = _pickOrch(orchIdx);
        if (!sra.isAdmitted(orch) || _posted[qq][orch]) return;
        // S3: bound(1, 1e30) aligns with the code-enforced MAX_STABLE_USD (postVolume rejects > 1e30) —
        // the invariant's sampling domain equals the contract's enforced input domain.
        uint256 stableUsd = bound(usd, 1, 1e30);
        uint256 target = _qEnd(qq) + 1 + uint64(bound(usd, 0, POST_PERIOD - 1));
        if (block.number < target) vm.roll(target); // monotonic: real time never rewinds (mirror activeQ assumes forward-only quarters)
        vm.prank(orch);
        sra.postVolume(qq, FixedU18.wrap(_fpv(stableUsd)));
        _posted[qq][orch] = true;
    }

    /// @notice Dual-Safe correction/backfill (unanimousNoHold: the second vote executes).
    function correctVolume(uint256 q, uint256 orchIdx, uint256 usd) external {
        uint64 qq = uint64(bound(q, 0, MAX_Q));
        address orch = _pickOrch(orchIdx);
        if (!sra.isAdmitted(orch)) return;
        // S3: bound(1, 1e30) aligns with the code-enforced MAX_FILECOIN_PAY_VOLUME_USD (correctVolume rejects > 1e30).
        uint256 stableUsd = bound(usd, 1, 1e30);
        uint256 target = _qPostEnd(qq) + 1 + uint64(bound(usd, 0, VERIFICATION_WINDOW - 1));
        if (block.number < target) vm.roll(target); // monotonic
        vm.prank(owner1);
        sra.correctVolume(orch, qq, FixedU18.wrap(stableUsd));
        vm.prank(owner2);
        sra.correctVolume(orch, qq, FixedU18.wrap(stableUsd));
        _posted[qq][orch] = true;
    }

    /// @notice Submit shares (permissionless after binding; FIPs#1275: no on-chain finalize to trigger).
    ///         Only a *successful* submit with non-zero total records the last-submit snapshot — a revert
    ///         (e.g. AlreadySubmitted) or an all-zero no-op leaves the previous snapshot valid (the map did
    ///         not change), otherwise the invariant would compare a new snapshot against the stale map.
    function submitShares(uint256 q) external {
        uint64 qq = uint64(bound(q, 0, MAX_Q));
        uint256 target = _qVerifyEnd(qq) + 1 + uint64(bound(q, 0, 50));
        if (block.number < target) vm.roll(target); // monotonic
        _crankSubmitShares(qq);
    }

    /// @dev Best-effort SubmitShares crank (permissionless + idempotent): a successful submit with a
    ///      non-zero total records the last-submit snapshot; a revert (NotBound/AlreadySubmitted)
    ///      or an all-zero no-op leaves the previous snapshot valid (the map did not change).
    function _crankSubmitShares(uint64 qq) internal {
        try sra.submitShares(qq) {
            _everSubmitted = true;
            // _snapshotPostEnd records only for non-zero-total quarters (no-op quarters return false)
            if (_snapshotPostEnd(qq)) {
                _hasLastSubmit = true;
                _lastSubmitQ = qq;
            }
        } catch {}
    }

    // Governance "slow path": parked tasks exist across operations (simulating mid-governance state, invariant I3 verification)

    /// @notice One vote (no execution): the admit task enters pending state, existing across operations.
    /// @dev unanimousNoHold executes on the second vote, so a parked task carries exactly one approval.
    function parkAdmit(uint256 idx) external {
        address orch = _pickOrch(idx);
        if (sra.isAdmitted(orch) || sra.admittedCount() >= 64) return;
        bytes32 taskId = _taskId(sra.addOrchestrator.selector, abi.encode(orch, orch));
        if (_taskState[taskId] != 0) return;
        vm.prank(owner1);
        sra.addOrchestrator(orch, orch);
        _taskState[taskId] = 1;
        _parkedOrch[taskId] = orch;
        _parkedEpoch[taskId] = uint64(block.number);
        _parkedTarget[orch] = true;
        _parkedTasks.push(taskId);
    }

    /// @notice Completes all parked tasks (the second vote executes under unanimousNoHold).
    function completeParked() external {
        if (_parkedTasks.length == 0) return;
        bytes32[] memory parked = _parkedTasks; // snapshot then clear
        delete _parkedTasks;
        for (uint256 i = 0; i < parked.length; i++) {
            bytes32 taskId = parked[i];
            if (_taskState[taskId] != 1) continue;
            address orch = _parkedOrch[taskId];
            vm.prank(owner2);
            try sra.addOrchestrator(orch, orch) {
                _admitted[orch] = true;
                _genSeq++;
                _idGen[orch] = _genSeq; // fresh identity generation
                _idWallet[orch] = orch;
                _parkedTarget[orch] = false;
                _recordExecuted(taskId);
            } catch {
                // orch was pre-admitted by an atomic admit -> AlreadyAdmitted revert; the task was already deleted
                _parkedTarget[orch] = false;
                _taskState[taskId] = 3;
            }
        }
    }

    /// @notice Small random time advance (keeps time flowing, explores different window phases).
    function rollForward(uint256 bump) external {
        vm.roll(block.number + uint64(bound(bump, 1, 500)));
    }

    // Query interface (read by the invariant test contract)

    function sraInstance() external view returns (ServiceRewardsActor) {
        return sra;
    }

    function getServiceShares() external view returns (Share[] memory) {
        return rewardActor().getShares(SERVICE_ID);
    }

    /// @dev f099 share total stripped from the last SetShares push (f02 stores no f099 rows) —
    ///      stored + stripped == 1e18 whenever the last push was valid, including after a
    ///      removeOrchestrator f099 push that repoints a removed id's entry to the burn address.
    function lastStrippedBurn() external view returns (uint256) {
        return rewardActor().strippedBurnOf(SERVICE_ID);
    }

    function everSubmitted() external view returns (bool) {
        return _everSubmitted;
    }

    function hasLastSubmit() external view returns (bool) {
        return _hasLastSubmit;
    }

    function lastSubmitQ() external view returns (uint64) {
        return _lastSubmitQ;
    }

    /// @dev A3: POST-instant aggregation of the most recent submit quarter (total / active count).
    function lastTotals() external view returns (uint256 total, uint256 count) {
        return (_lastTotal, _lastActiveCount);
    }

    function orchPoolLength() external view returns (uint256) {
        return _orchPool.length;
    }

    function orchAt(uint256 i) external view returns (address) {
        return _orchPool[i];
    }

    function expectedAdmitted(address orch) external view returns (bool) {
        return _admitted[orch];
    }

    function knownPairsLength() external view returns (uint256) {
        return _pairs.length;
    }

    function pairRecordAt(uint256 i) external view returns (address payer, address operator, address boundOrch) {
        return (_pairs[i].payer, _pairs[i].operator, _pairs[i].boundOrch);
    }

    /// @dev The wallet a live bound record resolves to (the binder identity's current wallet); address(0)
    ///      when the pair is unclaimed — binder removed or its identity superseded by a re-admit. The
    ///      identity generation distinguishes a live binding from a stale one (an address can host
    ///      successive identities), and the wallet map resolves the current payout wallet after replaces.
    function liveBoundWallet(uint256 i) external view returns (address) {
        PairRecord storage p = _pairs[i];
        if (!_admitted[p.boundOrch]) return address(0);
        if (_idGen[p.boundOrch] != p.gen) return address(0);
        return _idWallet[p.boundOrch];
    }

    function parkedCount() external view returns (uint256) {
        return _parkedTasks.length;
    }

    function parkedTaskId(uint256 i) external view returns (bytes32) {
        return _parkedTasks[i];
    }

    function parkedOrch(uint256 i) external view returns (address) {
        return _parkedOrch[_parkedTasks[i]];
    }

    function executedCount() external view returns (uint256) {
        return _executedTasks.length;
    }

    function executedTaskId(uint256 i) external view returns (bytes32) {
        return _executedTasks[i];
    }

    /// @dev Reads the PendingTask approved bitmask (PendingTask{modified:Epoch, approvals:uint160} packed into one slot;
    ///      Epoch is uint64, so approvals sits at bit offset 64).
    function approvalsOf(bytes32 taskId) external view returns (uint160) {
        bytes32 slot = keccak256(abi.encode(taskId, PENDING_TASKS_SLOT));
        return uint160(uint256(vm.load(address(sra), slot)) >> 64);
    }

    // Internal helpers

    function _pickOrch(uint256 idx) internal view returns (address) {
        return _orchPool[bound(idx, 0, ORCH_POOL - 1)];
    }

    function _pickPair(uint256 idx) internal view returns (address payer, address operator) {
        uint256 i = bound(idx, 0, PAYER_POOL * OPERATOR_POOL - 1);
        payer = _payers[i / OPERATOR_POOL];
        operator = _operators[i % OPERATOR_POOL];
    }

    function _taskId(bytes4 selector, bytes memory args) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(selector, args));
    }

    function _recordExecuted(bytes32 taskId) internal {
        _taskState[taskId] = 2;
        _executedTasks.push(taskId);
    }

    /// @dev Records the POST-instant snapshot for a successfully submitted non-zero quarter — the Σ and
    ///      count of active orchestrators with usd > 0 (consistent with the implementation's submitShares
    ///      admittedList traversal). Returns false for an all-zero quarter (benign no-op — the map did not
    ///      change, so the previous snapshot stays valid; recording a new one would mismatch the unchanged map).
    function _snapshotPostEnd(uint64 qq) internal returns (bool recorded) {
        // first pass: if the total is 0 (all-zero no-op quarter), skip recording entirely
        for (uint256 i = 0; i < _orchPool.length; i++) {
            address orch = _orchPool[i];
            if (!sra.isAdmitted(orch)) continue;
            if (FixedU18.unwrap(sra.fpvOf(qq, orch).usd) > 0) {
                // non-zero total exists -> record the full snapshot
                _lastTotal = 0;
                _lastActiveCount = 0;
                for (uint256 j = 0; j < _orchPool.length; j++) {
                    address o = _orchPool[j];
                    if (!sra.isAdmitted(o)) continue;
                    uint256 usd = FixedU18.unwrap(sra.fpvOf(qq, o).usd); // bound USD value — same field submitShares reads (FIPs#1275)
                    if (usd > 0) {
                        _lastTotal += usd;
                        _lastActiveCount++;
                    }
                }
                return true;
            }
        }
        return false;
    }

    /// @dev Whether a pair is claimable: unbound, or its binder's identity has ended. The id-keyed implementation
    ///      treats a pair as unclaimed iff the bound id is not admitted; since an address can host successive
    ///      identities (remove -> re-admit), the handler tracks the binder's identity generation: the pair is
    ///      claimable iff the recorded binder is no longer admitted or its identity was superseded by a re-admit.
    function _claimable(address, address payer, address operator) internal view returns (bool) {
        bytes32 pairId = keccak256(abi.encode(payer, operator));
        uint256 idx = _pairIdx[pairId];
        if (idx == 0) return true; // never bound
        PairRecord storage p = _pairs[idx - 1];
        if (!_admitted[p.boundOrch]) return true; // binder removed -> unclaimed
        if (_idGen[p.boundOrch] != p.gen) return true; // binder's identity superseded (re-admitted) -> unclaimed
        return false; // binder's current identity still holds the pair (self or third party -> AlreadyBound)
    }

    function _setBound(address payer, address operator, address orch) internal {
        bytes32 pairId = keccak256(abi.encode(payer, operator));
        uint256 idx = _pairIdx[pairId];
        if (idx == 0) {
            _pairs.push(PairRecord({payer: payer, operator: operator, boundOrch: orch, gen: _idGen[orch]}));
            _pairIdx[pairId] = _pairs.length;
        } else {
            _pairs[idx - 1].boundOrch = orch;
            _pairs[idx - 1].gen = _idGen[orch];
        }
    }
}

/// @notice Invariant test entry: targetContract(handler), 3 core invariants.
contract SRAInvariantTest is Test {
    SRAInvariantHandler internal handler;

    function setUp() public {
        handler = new SRAInvariantHandler();
        handler.setUp(); // deploy SRA + Safe owners + service stream 2
        targetContract(address(handler));
        // explicitly limit the handler's operation function set — excluding setUp() (public; otherwise the fuzzer would
        // treat it as a target and randomly call it, resetting the sra instance and diverging the handler's expected state
        // from reality)
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = SRAInvariantHandler.admit.selector;
        selectors[1] = SRAInvariantHandler.remove.selector;
        selectors[2] = SRAInvariantHandler.replace.selector;
        selectors[3] = SRAInvariantHandler.reassignBinding.selector;
        selectors[4] = SRAInvariantHandler.registerPairs.selector;
        selectors[5] = SRAInvariantHandler.cancelBinding.selector;
        selectors[6] = SRAInvariantHandler.postVolume.selector;
        selectors[7] = SRAInvariantHandler.correctVolume.selector;
        selectors[8] = SRAInvariantHandler.submitShares.selector;
        selectors[9] = SRAInvariantHandler.parkAdmit.selector;
        selectors[10] = SRAInvariantHandler.completeParked.selector;
        selectors[11] = SRAInvariantHandler.rollForward.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// I1 Share conservation: after any operation sequence, the share Σ written by the most recent successful submitShares is always == 1e18.
    /// Catches: wrong share top-up direction causing Σ≠1e18, recipient omission, all-zero no-op path breakage.
    function invariant_SumShares_IsShareTotal() public view {
        if (!handler.everSubmitted()) return; // never successfully submitted; no shares to query
        Share[] memory shares = handler.getServiceShares();
        uint256 sum;
        for (uint256 i = 0; i < shares.length; i++) {
            sum += FixedU18.unwrap(shares[i].share);
        }
        // f02 stores the map with f099 rows removed (spec §2.4.4); a removeOrchestrator f099 push
        // repoints the removed id's entry to BURN_ADDRESS, so stored sum alone drops below 1e18.
        // The invariant holds on the full map: stored + stripped (the f099 burn slice) == 1e18.
        assertEq(sum + handler.lastStrippedBurn(), 1e18, "I1: sum of shares must equal SHARE_TOTAL");
    }

    /// I2 Binding uniqueness: every live pair's bindingOf must == the handler-recorded binder's current
    /// wallet (resolved through the identity's wallet map — bindingOf reads orchestrators[id].wallet, so
    /// a replace re-points the resolved wallet while the identity stays put).
    /// Catches: a third-party grab of the same pair after replace (overwriting the binding),
    ///        registerPairs bypassing the uniqueness check, reassignBinding writes inconsistent with the record.
    /// Unclaimed pairs (binder removed or identity superseded) are skipped: bindingOf returns 0 for a
    /// removed id (admitted=false) and the record tracks a superseded identity's pairs as unclaimed,
    /// so the resolved value is address(0) on both sides of the comparison.
    function invariant_OneBindingPerPair() public view {
        uint256 n = handler.knownPairsLength();
        for (uint256 i = 0; i < n; i++) {
            (address payer, address operator,) = handler.pairRecordAt(i);
            address expected = handler.liveBoundWallet(i);
            if (expected == address(0)) continue; // unclaimed pair — skip
            assertEq(
                handler.sraInstance().bindingOf(payer, operator),
                expected,
                "I2: bindingOf must match handler-recorded binder"
            );
        }
    }

    /// I3 Governance consistency:
    ///   a) parked tasks (two votes, not executed) have a non-zero bitmask, and the orchestrator state has not landed (task not executed);
    ///   b) executed tasks have a zeroed bitmask (taskInfo.task deleted after execution);
    ///   c) handler-expected orchestrator state == sra actual (governance task execution results land correctly).
    /// Catches: un-cleared state after governance task execution (bitmask residue), function-body state changes
    ///        diverging from the governance flow, replace/remove identity-transfer state not synchronized.
    function invariant_GovernanceTasks_Consistent() public view {
        // a) parked tasks
        uint256 p = handler.parkedCount();
        for (uint256 i = 0; i < p; i++) {
            bytes32 taskId = handler.parkedTaskId(i);
            uint160 approvals = handler.approvalsOf(taskId);
            assertTrue(approvals != 0, "I3a: parked task approvals must be non-zero");
            // task not executed -> orchestrator state not landed
            address orch = handler.parkedOrch(i);
            assertFalse(handler.sraInstance().isAdmitted(orch), "I3a: parked admit must not be applied");
        }
        // b) executed tasks bitmask cleared
        uint256 e = handler.executedCount();
        for (uint256 i = 0; i < e; i++) {
            bytes32 taskId = handler.executedTaskId(i);
            assertEq(handler.approvalsOf(taskId), 0, "I3b: executed task approvals must be cleared");
        }
        // c) handler expected state == sra actual
        uint256 n = handler.orchPoolLength();
        for (uint256 i = 0; i < n; i++) {
            address orch = handler.orchAt(i);
            assertEq(
                handler.sraInstance().isAdmitted(orch), handler.expectedAdmitted(orch), "I3c: admitted state mismatch"
            );
        }
    }

    /// A3 All-zero no-op (FIP-0118 FIPs#1275): in the most recent submit quarter,
    /// if the Σ of active with usd>0 at the POST instant is 0 -> submitShares is a benign no-op:
    /// SplitRule is not evaluated and the existing share map stands (covered by the SRAShares unit
    /// tests; here the invariant only needs to assert the map stays valid for the Σ>0 branch).
    /// If Σ>0 -> the map is a non-empty subset of the active orchestrators (zero-share entries trimmed),
    /// all entries non-zero, size <= active count.
    /// Catches: usd aggregation omission (a poster miscounted causing a false total-zero determination),
    ///        trimmed-map corruption.
    function invariant_NonZeroTotal_ValidShareMap() public view {
        if (!handler.hasLastSubmit()) return;
        Share[] memory shares = handler.getServiceShares();
        (uint256 total, uint256 count) = handler.lastTotals();
        if (total > 0) {
            // The implementation trims zero-share entries (largest-remainder can floor a tiny
            // usd to 0 when the residue top-up round count is smaller than the active count),
            // so the map holds a non-empty subset of the active orchestrators, all non-zero —
            // unless a later removeOrchestrator f099 push burned every stored entry (f099 rows are
            // stripped from storage, spec §2.4.4); then the stripped total carries the shares.
            if (shares.length == 0) {
                assertGt(handler.lastStrippedBurn(), 0, "A3: all shares burned must be recorded as stripped f099");
                return;
            }
            assertLe(shares.length, count, "A3: share count must not exceed active orchestrator count");
            for (uint256 i = 0; i < shares.length; i++) {
                assertGt(FixedU18.unwrap(shares[i].share), 0, "A3: trimmed map must contain only non-zero shares");
            }
        }
    }

    /// I6 admittedIndex ↔ array position: every id in admittedIds has its orchestrators[id].admittedIndex ==
    /// its position (the O(1) removal bookkeeping invariant). Reads raw ERC-7201 slots:
    ///   admittedIds (uint64[] at REGISTRY_SLOT+4) elements are packed 4 per 32B word, low-bytes first;
    ///   orchestrators[id] at keccak256(abi.encode(id, REGISTRY_SLOT)), admittedIndex = struct word 4
    ///   (the admit-time orchestrator field heads the struct, shifting admittedIndex past fpv/prevFpv).
    /// Catches: swap double-write omission (a swapped id keeps its stale index), wrong index write on
    ///        remove/admit, index drift under repeated remove + re-admit.
    function invariant_AdmittedIndex_MatchesArrayPosition() public view {
        ServiceRewardsActor sra = handler.sraInstance();
        bytes32 lenSlot = bytes32(uint256(REGISTRY_SLOT) + 4);
        uint256 n = uint256(vm.load(address(sra), lenSlot));
        bytes32 elemBase = keccak256(abi.encode(uint256(REGISTRY_SLOT) + 4));
        for (uint256 i = 0; i < n; i++) {
            bytes32 wordSlot = bytes32(uint256(elemBase) + i / 4);
            uint256 word = uint256(vm.load(address(sra), wordSlot));
            uint64 id = uint64(word >> ((i % 4) * 64));
            bytes32 base = keccak256(abi.encode(uint64(id), REGISTRY_SLOT));
            uint64 idx = uint64(uint256(vm.load(address(sra), bytes32(uint256(base) + 4))));
            assertEq(idx, i, "I6: admittedIndex must equal array position");
        }
    }
}
