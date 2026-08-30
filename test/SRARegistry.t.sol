// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// SRA registry tests — freeze semantics / cap rejection (D2)
//
//   - orchestrator admission/cap: 64-full rejection, Remove release, Freeze non-release (D2)
//   - registerPairs: uniqueness, admission/freeze gating, re-claimable after Remove release
//   - freeze/unfreeze: suspend/restore operation capability
//   - replace: operator identity transfer; reassignBinding: binding reassignment

import {SRATestBase} from "./SRATestBase.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {Binding, FilecoinPayVolume} from "../src/lib/SraTypes.sol";

/// @dev ERC-7201 Registry namespace slot (src/lib/SraStorage.sol) — the id allocator lives at
///      REGISTRY_SLOT + 3 (low 64 bits = nextId). The test reads it directly because the id is
///      internal to the identity model (no public getter).
bytes32 constant REGISTRY_SLOT = 0xb7fd4b054ced95f43476af93bf71636318271f9e64f7661dc52f0fb4c1a54400;

contract SRARegistryTest is SRATestBase {
    // ------------------------------------------------------------------------
    // D2 cap (strategy 5)
    // ------------------------------------------------------------------------

    /// Strategy 5/D2: once the admitted total reaches 64, the 65th admit is rejected.
    function test_Admit_AtCapacity_Reverts() public {
        for (uint256 i = 0; i < 64; i++) {
            _admit(makeAddr(string.concat("orch-", vm.toString(i))));
        }
        assertEq(sra.admittedCount(), 64);

        address orch65 = makeAddr("orch-65");
        vm.prank(owner1);
        sra.admit(orch65);
        vm.prank(owner2);
        sra.admit(orch65); // second vote: completes the full vote queue (wait); body not executed

        vm.roll(block.number + SRA_CANCEL_HOLD); // hold elapsed
        vm.expectRevert(); // cap rejection: admit is full at 64 (third permissionless call executes the body)
        sra.admit(orch65);
    }

    /// Strategy 5/D2: after Remove frees a slot, a new orchestrator can be admitted.
    function test_Admit_RemoveFreesSlot() public {
        for (uint256 i = 0; i < 64; i++) {
            _admit(makeAddr(string.concat("orch-", vm.toString(i))));
        }
        address removed = makeAddr("orch-0");
        _remove(removed);
        assertEq(sra.admittedCount(), 63);

        _admit(makeAddr("orch-new")); // slot freed, can admit
        assertEq(sra.admittedCount(), 64);
    }

    /// Strategy 5/D2: Freeze does not release a slot — the frozen orchestrator still occupies an admitted slot.
    function test_Admit_FrozenStillCountsTowardLimit() public {
        for (uint256 i = 0; i < 64; i++) {
            _admit(makeAddr(string.concat("orch-", vm.toString(i))));
        }
        // freeze one orchestrator
        address frozenOrch = makeAddr("orch-0");
        _freeze(frozenOrch);
        assertTrue(sra.isFrozen(frozenOrch));
        // freeze does not release a slot: admittedCount is still 64
        assertEq(sra.admittedCount(), 64);

        // slot not released: a new admit is still rejected (after two votes queue, rejected at body execution once hold elapses)
        address orch65 = makeAddr("orch-65");
        vm.prank(owner1);
        sra.admit(orch65);
        vm.prank(owner2);
        sra.admit(orch65); // second vote: completes the full vote queue (wait)

        vm.roll(block.number + SRA_CANCEL_HOLD); // hold elapsed
        vm.expectRevert();
        sra.admit(orch65); // third permissionless call executes the body -> cap rejection
    }

    // ------------------------------------------------------------------------
    // registerPairs (strategy 3)
    // ------------------------------------------------------------------------

    /// an admitted orchestrator can register binding pairs.
    function test_RegisterPairs_Success() public {
        address orch = makeAddr("orch");
        _admit(orch);

        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(makeAddr("payer"), makeAddr("operator"));

        _registerPairsAs(orch, pairs);
        assertEq(sra.bindingOf(makeAddr("payer"), makeAddr("operator")), orch);
    }

    /// a non-admitted address cannot registerPairs.
    function test_RegisterPairs_NotAdmitted_Reverts() public {
        address stranger = makeAddr("stranger");
        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(makeAddr("payer"), makeAddr("operator"));

        vm.prank(stranger);
        vm.expectRevert();
        sra.registerPairs(pairs);
    }

    /// a frozen orchestrator cannot registerPairs.
    function test_RegisterPairs_Frozen_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);
        _freeze(orch);

        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(makeAddr("payer"), makeAddr("operator"));

        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.Frozen.selector, orch));
        sra.registerPairs(pairs);
    }

    /// registerPairs reverts when the pair is already bound to another (uniqueness invariant).
    function test_RegisterPairs_DuplicatePair_Reverts() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB");
        _admit(orchA);
        _admit(orchB);

        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(makeAddr("payer"), makeAddr("operator"));
        _registerPairsAs(orchA, pairs);

        vm.prank(orchB);
        vm.expectRevert(); // already bound to another -> uniqueness rejection
        sra.registerPairs(pairs);
    }

    /// the same orchestrator re-registering the same pair reverts (self-duplicates also disallowed).
    function test_RegisterPairs_SameOrchDuplicatePair_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);

        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(makeAddr("payer"), makeAddr("operator"));
        _registerPairsAs(orch, pairs);

        vm.prank(orch);
        vm.expectRevert();
        sra.registerPairs(pairs);
    }

    /// C1: registerPairs with more than MAX_PAIRS (64) pairs reverts TooManyPairs (array-length bound, audit C1).
    function test_RegisterPairs_TooManyPairs_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);

        Binding[] memory pairs = new Binding[](65);
        for (uint256 i = 0; i < pairs.length; i++) {
            pairs[i] =
                _pair(makeAddr(string.concat("payer", vm.toString(i))), makeAddr(string.concat("op", vm.toString(i))));
        }

        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.TooManyPairs.selector));
        sra.registerPairs(pairs);
    }

    /// C1 control: exactly MAX_PAIRS (64) pairs is accepted (boundary value).
    function test_RegisterPairs_MaxPairs_Accepted() public {
        address orch = makeAddr("orch");
        _admit(orch);

        Binding[] memory pairs = new Binding[](64);
        for (uint256 i = 0; i < pairs.length; i++) {
            pairs[i] =
                _pair(makeAddr(string.concat("payer", vm.toString(i))), makeAddr(string.concat("op", vm.toString(i))));
        }

        _registerPairsAs(orch, pairs);
        assertEq(sra.bindingOf(makeAddr("payer0"), makeAddr("op0")), orch);
    }

    /// Remove releases all bindings; pairs return to unclaimed and can be claimed by other orchestrators.
    function test_Remove_ReleasesPairs_CanBeReclaimed() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB");
        _admit(orchA);
        _admit(orchB);

        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(makeAddr("payer"), makeAddr("operator"));
        _registerPairsAs(orchA, pairs);
        assertEq(sra.bindingOf(makeAddr("payer"), makeAddr("operator")), orchA);

        _remove(orchA);

        // original orchestrator removed; B can claim the same pair
        _registerPairsAs(orchB, pairs);
        assertEq(sra.bindingOf(makeAddr("payer"), makeAddr("operator")), orchB);
    }

    // ------------------------------------------------------------------------
    // freeze / unfreeze (strategy 3)
    // ------------------------------------------------------------------------

    /// a frozen orchestrator cannot postVolume (rejected even within the posting window).
    function test_Freeze_PreventsPostVolume() public {
        address orch = makeAddr("orch");
        _admit(orch);
        _freeze(orch);

        vm.roll(_qEnd(0) + 1); // posting period
        vm.prank(orch);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.Frozen.selector, orch));
        sra.postVolume(0, FixedU18.wrap(_fpv(100e18)));
    }

    /// correctVolume freeze symmetry: a frozen orchestrator cannot be re-admitted
    /// into a quarter via the governance correctVolume path. Freeze suspends — the mirror advance
    /// clears frozenAtPostEnd, so without this gate a freeze → correctVolume → advance sequence
    /// would give a frozen orchestrator shares in the next quarter.
    /// Unfreeze restores the governance correction path.
    function test_CorrectVolume_Frozen_Reverts_UnfreezeRestores() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        _admit(a);
        _admit(b);

        vm.roll(_qEnd(0) + 1); // posting
        _postAs(a, 0, _fpv(100e18));
        _postAs(b, 0, _fpv(200e18));
        _freeze(b); // posting window: b excluded from q0 (frozenAtPostEnd)

        // verification window: correcting a frozen orchestrator must revert Frozen —
        // the governance path must not re-admit a suspended orchestrator (unanimousNoHold:
        // vote 1 approves, vote 2 executes the body where the gate fires)
        vm.roll(_qPostEnd(0) + 1);
        vm.prank(owner1);
        sra.correctVolume(b, 0, FixedU18.wrap(_fpv(150e18))); // vote 1 (approve only)
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.Frozen.selector, b));
        vm.prank(owner2);
        sra.correctVolume(b, 0, FixedU18.wrap(_fpv(150e18))); // vote 2 executes body -> Frozen
        assertEq(FixedU18.unwrap(sra.fpvOf(0, b).usd), 200e18, "frozen b's fpv untouched");

        // unfreeze restores the governance correction path (fresh calldata -> fresh task)
        _unfreeze(b);
        _correctVolume(b, 0, _fpv(180e18));
        assertEq(FixedU18.unwrap(sra.fpvOf(0, b).usd), 180e18, "corrected after unfreeze");
    }

    /// unfreeze restores operation capability (registerPairs / postVolume).
    function test_Unfreeze_RestoresOperations() public {
        address orch = makeAddr("orch");
        _admit(orch);
        _freeze(orch);

        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(makeAddr("payer"), makeAddr("operator"));
        vm.prank(orch);
        vm.expectRevert();
        sra.registerPairs(pairs);

        _unfreeze(orch);
        assertFalse(sra.isFrozen(orch));

        _registerPairsAs(orch, pairs); // can register after restore
        vm.roll(_qEnd(0) + 1);
        _postAs(orch, 0, _fpv(100e18)); // can post after restore
        FilecoinPayVolume memory f = sra.fpvOf(0, orch);
        assertEq(FixedU18.unwrap(f.usd), 100e18);
    }

    // ------------------------------------------------------------------------
    // replace / reassignBinding
    // ------------------------------------------------------------------------

    /// replace transfers the operator identity (the new address gains admission and bindings; the old address becomes invalid).
    function test_Replace_TransfersIdentity() public {
        address oldOrch = makeAddr("oldOrch");
        address newOrch = makeAddr("newOrch");
        _admit(oldOrch);

        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(makeAddr("payer"), makeAddr("operator"));
        _registerPairsAs(oldOrch, pairs);

        // governance replace(old, new): two votes + hold
        vm.prank(owner1);
        sra.replace(oldOrch, newOrch);
        vm.prank(owner2);
        sra.replace(oldOrch, newOrch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.replace(oldOrch, newOrch);

        assertFalse(sra.isAdmitted(oldOrch));
        assertTrue(sra.isAdmitted(newOrch));
        // bindings follow the identity transfer
        assertEq(sra.bindingOf(makeAddr("payer"), makeAddr("operator")), newOrch);
    }

    /// After replace, a third party cannot grab the binding pair — registerPairs's AlreadyBound
    /// check resolves along the replace chain to the current valid orchestrator.
    function test_RegisterPairs_AfterReplace_ThirdPartyReverts() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB"); // fresh address: replace target must be unadmitted (auto-admitted on identity transfer)
        address orchC = makeAddr("orchC");
        _admit(orchA);
        _admit(orchC); // a third party must be admitted to reach the AlreadyBound check (registerPairs gating)

        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(makeAddr("payer"), makeAddr("operator"));
        _registerPairsAs(orchA, pairs);
        assertEq(sra.bindingOf(makeAddr("payer"), makeAddr("operator")), orchA);

        // governance replace(orchA -> orchB): two votes + hold elapsed + third permissionless execution
        vm.prank(owner1);
        sra.replace(orchA, orchB);
        vm.prank(owner2);
        sra.replace(orchA, orchB);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.replace(orchA, orchB);

        assertTrue(sra.isAdmitted(orchB));
        assertFalse(sra.isAdmitted(orchA));
        // bindings follow the identity transfer (id-keyed: the wallet re-point keeps the binding)
        assertEq(sra.bindingOf(makeAddr("payer"), makeAddr("operator")), orchB);

        // third party orchC tries to grab the same pair -> expect AlreadyBound revert
        vm.prank(orchC);
        vm.expectRevert();
        sra.registerPairs(pairs);
    }

    /// reassignBinding reassigns the (payer, operator) binding to another orchestrator.
    function test_ReassignBinding_ChangesBinding() public {
        address orchA = makeAddr("orchA");
        address orchB = makeAddr("orchB");
        _admit(orchA);
        _admit(orchB);

        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(makeAddr("payer"), makeAddr("operator"));
        _registerPairsAs(orchA, pairs);
        assertEq(sra.bindingOf(makeAddr("payer"), makeAddr("operator")), orchA);

        // governance reassignBinding(payer, operator, orchB)
        vm.prank(owner1);
        sra.reassignBinding(makeAddr("payer"), makeAddr("operator"), orchB);
        vm.prank(owner2);
        sra.reassignBinding(makeAddr("payer"), makeAddr("operator"), orchB);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.reassignBinding(makeAddr("payer"), makeAddr("operator"), orchB);

        assertEq(sra.bindingOf(makeAddr("payer"), makeAddr("operator")), orchB);
    }

    // ------------------------------------------------------------------------
    // G6: failure-path closure (governance operations unanimous+hold: errors thrown at the third permissionless body execution)
    // ------------------------------------------------------------------------

    /// G6: replace target already admitted (admitted=true) -> AlreadyAdmitted revert at the third execution.
    /// (The replace tests cover the target-unadmitted + binding-transfer path; this test covers the "target already admitted" reverse branch)
    function test_Replace_AlreadyAdmittedTarget_Reverts() public {
        address oldOrch = makeAddr("oldOrch");
        address newOrch = makeAddr("newOrch");
        _admit(oldOrch);
        _admit(newOrch); // target already admitted -> replace rejected

        vm.prank(owner1);
        sra.replace(oldOrch, newOrch);
        vm.prank(owner2);
        sra.replace(oldOrch, newOrch); // second vote: completes the full vote queue (wait)
        vm.roll(block.number + SRA_CANCEL_HOLD); // hold elapsed
        vm.expectRevert(); // AlreadyAdmitted(newOrch)
        sra.replace(oldOrch, newOrch); // third permissionless body execution -> revert
    }

    /// G6: reassignBinding target not admitted -> NotAdmitted revert at the third execution.
    function test_ReassignBinding_NotAdmittedTarget_Reverts() public {
        address orchA = makeAddr("orchA");
        _admit(orchA);

        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(makeAddr("payer"), makeAddr("operator"));
        _registerPairsAs(orchA, pairs);

        address stranger = makeAddr("stranger"); // unadmitted target
        vm.prank(owner1);
        sra.reassignBinding(makeAddr("payer"), makeAddr("operator"), stranger);
        vm.prank(owner2);
        sra.reassignBinding(makeAddr("payer"), makeAddr("operator"), stranger);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert(); // NotAdmitted(stranger)
        sra.reassignBinding(makeAddr("payer"), makeAddr("operator"), stranger);
    }

    /// G6: remove on a non-orchestrator (unadmitted) -> NotAdmitted revert at the third execution.
    function test_Remove_NotAdmitted_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(owner1);
        sra.remove(stranger);
        vm.prank(owner2);
        sra.remove(stranger);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert(); // NotAdmitted(stranger)
        sra.remove(stranger);
    }

    /// G6: a frozen orchestrator can be removed (the implementation does not block it; remove also clears frozen state and freeze history).
    function test_Remove_FrozenOrch_Succeeds() public {
        address orch = makeAddr("orch");
        _admit(orch);
        _freeze(orch);
        assertTrue(sra.isFrozen(orch));

        _remove(orch);
        assertFalse(sra.isAdmitted(orch));
        assertFalse(sra.isFrozen(orch));
        assertEq(sra.admittedCount(), 0);
    }

    // ------------------------------------------------------------------------
    // P2 coverage closure (CV4-CV7): governance failure branches + read-only view
    // ------------------------------------------------------------------------

    /// Strategy 5/CV4: re-admitting the same address -> AlreadyAdmitted revert at the third body execution.
    /// (G2 covered AtCapacity-full; the "same address re-admitted" branch was uncovered — coverage line 346)
    function test_Admit_AlreadyAdmitted_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);
        assertTrue(sra.isAdmitted(orch));

        vm.prank(owner1);
        sra.admit(orch);
        vm.prank(owner2);
        sra.admit(orch); // second vote: completes the full vote queue (wait)
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert(); // AlreadyAdmitted(orch)
        sra.admit(orch); // third permissionless body execution -> revert
    }

    /// Strategy 3/CV5: freeze on an unadmitted orchestrator -> NotAdmitted revert.
    /// (The freeze success path is tested; the NotAdmitted failure branch was uncovered — coverage line 371)
    function test_Freeze_NotAdmitted_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(owner1);
        sra.freeze(stranger);
        vm.prank(owner2);
        sra.freeze(stranger);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert(); // NotAdmitted(stranger)
        sra.freeze(stranger);
    }

    /// Strategy 3/CV5: freeze on an already-frozen orchestrator -> AlreadyFrozen revert.
    /// (coverage line 372 revert branch uncovered)
    function test_Freeze_AlreadyFrozen_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);
        _freeze(orch);
        assertTrue(sra.isFrozen(orch));

        vm.prank(owner1);
        sra.freeze(orch);
        vm.prank(owner2);
        sra.freeze(orch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert(); // AlreadyFrozen(orch)
        sra.freeze(orch);
    }

    /// Strategy 3/CV5: unfreeze on an unadmitted orchestrator -> NotAdmitted revert.
    /// (coverage line 381 revert branch uncovered)
    function test_Unfreeze_NotAdmitted_Reverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(owner1);
        sra.unfreeze(stranger);
        vm.prank(owner2);
        sra.unfreeze(stranger);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert(); // NotAdmitted(stranger)
        sra.unfreeze(stranger);
    }

    /// Strategy 3/CV5: unfreeze on a non-frozen orchestrator -> NotFrozen revert.
    /// (coverage line 382 revert branch uncovered)
    function test_Unfreeze_NotFrozen_Reverts() public {
        address orch = makeAddr("orch");
        _admit(orch);
        assertFalse(sra.isFrozen(orch));

        vm.prank(owner1);
        sra.unfreeze(orch);
        vm.prank(owner2);
        sra.unfreeze(orch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert(); // NotFrozen(orch)
        sra.unfreeze(orch);
    }

    /// Strategy 3/CV6: replace with an unadmitted old address -> NotAdmitted(oldOrch) revert.
    /// (G6 covered the "target already admitted" reverse branch; old unadmitted was uncovered — coverage line 396)
    function test_Replace_OldNotAdmitted_Reverts() public {
        address stranger = makeAddr("stranger"); // old address never admitted
        address newOrch = makeAddr("newOrch");

        vm.prank(owner1);
        sra.replace(stranger, newOrch);
        vm.prank(owner2);
        sra.replace(stranger, newOrch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        vm.expectRevert(); // NotAdmitted(stranger)
        sra.replace(stranger, newOrch);
    }

    /// Strategy 5/CV7: the orchestratorCount read-only view reflects admission/removal counts (consistent with admittedCount).
    /// (coverage lines 596-597 never called — the read-only view had no tests)
    function test_OrchestratorCount_ReflectsAdmissions() public {
        assertEq(sra.orchestratorCount(), 0);

        address a = makeAddr("orchA");
        address b = makeAddr("orchB");
        _admit(a);
        _admit(b);
        assertEq(sra.orchestratorCount(), 2);
        assertEq(sra.orchestratorCount(), sra.admittedCount()); // view consistency

        _remove(a);
        assertEq(sra.orchestratorCount(), 1);
    }

    // ------------------------------------------------------------------------
    // re-admit = fresh identity (clears frozen/freeze history)
    // ------------------------------------------------------------------------

    /// Re-admit allocates a fresh identity: frozen state and freeze history are cleared, so a
    /// re-admitted address operates as a normal orchestrator, not excluded by historical freezes.
    function test_ReAdmit_ResetsFrozenState() public {
        address oldOrch = makeAddr("readmit-frozen-old");
        address newOrch = makeAddr("readmit-frozen-new");
        _admit(oldOrch);
        _freeze(oldOrch); // old frozen (frozenSince recorded)

        // replace(old->new): the frozen state is copied wholesale with the struct to new (identity-transfer semantics)
        vm.prank(owner1);
        sra.replace(oldOrch, newOrch);
        vm.prank(owner2);
        sra.replace(oldOrch, newOrch);
        vm.roll(block.number + SRA_CANCEL_HOLD);
        sra.replace(oldOrch, newOrch);
        assertTrue(sra.isFrozen(newOrch), "new inherits frozen state from old");
        assertTrue(sra.isAdmitted(newOrch));
        assertFalse(sra.isAdmitted(oldOrch)); // old invalidated (alias)

        // re-admit old: fresh identity (clears frozen state)
        _admit(oldOrch);
        assertTrue(sra.isAdmitted(oldOrch));
        assertFalse(sra.isFrozen(oldOrch), "re-admit must reset frozen state");

        // after re-admission old operates as a normal orchestrator (postVolume not excluded by freeze history)
        vm.roll(_qEnd(1) + 1); // quarter 1 posting window
        _postAs(oldOrch, 1, _fpv(100e18)); // not reverting proves normal operation
        FilecoinPayVolume memory f = sra.fpvOf(1, oldOrch);
        assertEq(FixedU18.unwrap(f.usd), 100e18);
    }

    // ------------------------------------------------------------------------
    // id-keyed identity: re-admit = fresh id (structural, not a cleanup step)
    // ------------------------------------------------------------------------

    /// id-keyed identity: re-admit of a removed address allocates a fresh id — the removed identity's bindings
    /// (pair bound by the old id) and FilecoinPayVolume do not carry over. The pair stays claimable and the fresh id's quarter
    /// record is empty (the old record lives on only under the archived id, unreachable from the address).
    function test_ReAdmit_FreshIdentity_NoBindingsNoFilecoinPayVolume() public {
        address oldOrch = makeAddr("fresh-old");
        address third = makeAddr("fresh-third");
        _admit(oldOrch);
        _admit(third);

        Binding[] memory pairs = new Binding[](1);
        pairs[0] = _pair(makeAddr("payer"), makeAddr("operator"));
        _registerPairsAs(oldOrch, pairs);
        assertEq(sra.bindingOf(makeAddr("payer"), makeAddr("operator")), oldOrch);

        vm.roll(_qEnd(0) + 1); // q0 posting window
        _postAs(oldOrch, 0, _fpv(100e18));

        _remove(oldOrch);
        assertFalse(sra.isAdmitted(oldOrch));

        // re-admit the same address: fresh identity
        _admit(oldOrch);
        assertTrue(sra.isAdmitted(oldOrch));
        assertFalse(sra.isFrozen(oldOrch));

        // the removed identity's binding does not carry over: the pair is claimable by a third party
        _registerPairsAs(third, pairs); // no revert -> the old id's binding is not inherited
        assertEq(sra.bindingOf(makeAddr("payer"), makeAddr("operator")), third);

        // the removed identity's FilecoinPayVolume does not carry over: the fresh id's quarter-0 record is empty
        FilecoinPayVolume memory f = sra.fpvOf(0, oldOrch);
        assertEq(FixedU18.unwrap(f.usd), 0);
    }

    /// id allocation is monotonic and never reuses an id: 0 is the unregistered sentinel, ids start at 1 and
    /// increase strictly — remove + re-admit of the same address consumes a new id (never the archived one).
    /// Reads the ERC-7201 registry slot directly (no public getter — the id is internal to the identity model).
    function test_Admit_IdMonotonic_NeverReused() public {
        bytes32 slot = bytes32(uint256(REGISTRY_SLOT) + 3); // nextId sits alone in slot3's low 64 bits (no admittedCount packing)
        assertEq(uint64(uint256(vm.load(address(sra), slot))), 1, "nextId starts at 1 (0 = sentinel)");

        address a = makeAddr("id-a");
        _admit(a);
        assertEq(uint64(uint256(vm.load(address(sra), slot))), 2, "first admit consumes id 1");

        _remove(a);
        _admit(a); // re-admit allocates a NEW id (never reused)
        assertEq(uint64(uint256(vm.load(address(sra), slot))), 3, "re-admit allocates a fresh id");

        _admit(makeAddr("id-b"));
        assertEq(uint64(uint256(vm.load(address(sra), slot))), 4, "ids increase strictly");
    }

    // ------------------------------------------------------------------------
    // admittedIndex (O(1) removal bookkeeping) — raw ERC-7201 slot reads (no public getter)
    // ------------------------------------------------------------------------

    /// @dev admittedIds: uint64[] at REGISTRY_SLOT+4; elements packed 4 per 32B word (8B each), low-bytes first.
    bytes32 internal constant ADMITTED_IDS_SLOT = bytes32(uint256(REGISTRY_SLOT) + 4);

    function _admittedIdsLength() internal view returns (uint256 n) {
        n = uint256(vm.load(address(sra), ADMITTED_IDS_SLOT));
    }

    function _admittedIdAt(uint256 i) internal view returns (uint64 id) {
        bytes32 wordSlot = bytes32(uint256(keccak256(abi.encode(uint256(ADMITTED_IDS_SLOT)))) + i / 4);
        id = uint64(uint256(vm.load(address(sra), wordSlot)) >> ((i % 4) * 64));
    }

    /// @dev orchestrators mapping at REGISTRY_SLOT; struct word 3 = admittedIndex (added after prevFpv).
    function _admittedIndexOf(uint64 id) internal view returns (uint64 idx) {
        bytes32 base = keccak256(abi.encode(uint64(id), REGISTRY_SLOT));
        idx = uint64(uint256(vm.load(address(sra), bytes32(uint256(base) + 3))));
    }

    /// OrchestratorInfo invariant: every admitted id's admittedIndex == its position in admittedIds.
    function _assertIndexConsistent() internal view {
        uint256 n = _admittedIdsLength();
        for (uint256 i = 0; i < n; i++) {
            uint64 id = _admittedIdAt(i);
            assertEq(_admittedIndexOf(id), i, "admittedIndex must equal array position");
        }
    }

    /// O(1) removal core: removing a middle element swaps the last one into its slot — the swapped
    /// element's admittedIndex must be rewritten to the new position (swap double-write).
    function test_Remove_MiddleElement_SwapUpdatesIndex() public {
        address a = makeAddr("mid-a");
        address b = makeAddr("mid-b");
        address c = makeAddr("mid-c");
        _admit(a);
        _admit(b);
        _admit(c); // ids 1, 2, 3

        _remove(b); // remove middle (id 2): list [1, 3] — id 3 swapped into position 1

        assertEq(_admittedIdsLength(), 2);
        assertEq(_admittedIdAt(0), 1);
        assertEq(_admittedIdAt(1), 3, "last element swapped into removed slot");
        assertEq(_admittedIndexOf(3), 1, "swapped element's admittedIndex rewritten");
        assertEq(_admittedIndexOf(1), 0, "untouched element's admittedIndex intact");
        assertEq(_admittedIndexOf(2), 0, "removed id's admittedIndex cleared (dead pointer)");
        _assertIndexConsistent();
    }

    /// Removing the last element: no swap; remaining indices unchanged.
    function test_Remove_LastElement_IndexIntact() public {
        address a = makeAddr("last-a");
        address b = makeAddr("last-b");
        _admit(a);
        _admit(b); // ids 1, 2

        _remove(b); // remove last (id 2): list [1]

        assertEq(_admittedIdsLength(), 1);
        assertEq(_admittedIdAt(0), 1);
        assertEq(_admittedIndexOf(1), 0, "remaining element's index unchanged");
        assertEq(_admittedIndexOf(2), 0, "removed id's admittedIndex cleared (dead pointer)");
        _assertIndexConsistent();
    }

    /// Multiple removals in sequence: the index invariant holds after every step (head/middle/last mixed).
    function test_Remove_ConsecutiveRemoves_IndexAlwaysConsistent() public {
        address a = makeAddr("seq-a");
        address b = makeAddr("seq-b");
        address c = makeAddr("seq-c");
        address d = makeAddr("seq-d");
        _admit(a);
        _admit(b);
        _admit(c);
        _admit(d); // ids 1, 2, 3, 4

        _remove(a); // head: list [4, 2, 3]
        assertEq(_admittedIndexOf(4), 0, "head removal swaps last to front");
        assertEq(_admittedIndexOf(1), 0, "removed id's admittedIndex cleared (dead pointer)");
        _assertIndexConsistent();

        _remove(c); // middle: list [4, 2]
        assertEq(_admittedIndexOf(2), 1, "middle removal swaps last to slot 1");
        assertEq(_admittedIndexOf(3), 0, "removed id's admittedIndex cleared (dead pointer)");
        _assertIndexConsistent();

        _remove(b); // last: list [4]
        assertEq(_admittedIndexOf(2), 0, "removed id's admittedIndex cleared (dead pointer)");
        _assertIndexConsistent();

        assertEq(_admittedIdsLength(), 1);
        assertEq(_admittedIdAt(0), 4);
    }

    /// Re-admit after removal: the new id is pushed at list.length — its admittedIndex must be that position.
    /// Removes the last element (id 2): its stale admittedIndex would be 1, colliding with the new id's push
    /// position — clearing the dead pointer is what keeps the two apart.
    function test_Remove_ThenAdmit_NewAdmitGetsPushIndex() public {
        address a = makeAddr("readmit-a");
        address b = makeAddr("readmit-b");
        _admit(a);
        _admit(b); // ids 1, 2; list [1, 2]

        _remove(b); // list [1] (length 1)
        assertEq(_admittedIndexOf(2), 0, "removed id's admittedIndex cleared (dead pointer)");

        address c = makeAddr("readmit-c");
        _admit(c); // id 3 pushed at position 1

        assertEq(_admittedIdsLength(), 2);
        assertEq(_admittedIdAt(0), 1);
        assertEq(_admittedIdAt(1), 3);
        assertEq(_admittedIndexOf(3), 1, "new admit's admittedIndex == push position (list.length)");
        _assertIndexConsistent();
    }
}
