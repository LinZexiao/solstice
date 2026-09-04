// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

// SRA spec-alignment tests (FIPs#1277 stage 2): the six real differences the diff matrix
// confirmed against the current implementation — TDD red-phase specifications.
//
//   D1 [spec外] reassignBindings batch — per-item single-path semantics, atomic, MAX_PAIRS cap
//   D2 [spec内] setPricingParams + registration_cutoff (spec 8e495ca: event carries all values)
//   D3 [spec外] VolumeCorrected carries the corrected volume (VolumePosted symmetry)
//   D7 [spec内] wallet uniqueness across admitted orchestrators (removed wallets reusable)
//   D8 [spec内] SRA upgrade-hold duration: SRA state, fixed at deployment (spec 95eb9e0 §4.2)

import {SRATestBase} from "./SRATestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {FixedU18} from "../src/lib/FixedU18.sol";
import {ServiceRewardsActor} from "../src/ServiceRewardsActor.sol";
import {Epoch} from "../src/lib/Epoch.sol";
import {Binding, Reassignment} from "../src/lib/SraTypes.sol";

contract SRASpecAlignmentTest is SRATestBase {
    // ------------------------------------------------------------------------
    // D1 [spec外] reassignBindings batch — per-item single-path semantics, atomic
    // ------------------------------------------------------------------------

    /// 批量 reassign：每条复用单条校验与事件路径；全部成功后所有 binding 更新到目标 orchestrator。
    function test_ReassignBindings_Batch_AllReassigned() public {
        address a = makeAddr("d1-a");
        address b = makeAddr("d1-b");
        _admit(a, a);
        _admit(b, b);

        Binding[] memory pairs = new Binding[](2);
        pairs[0] = _pair(makeAddr("d1-payer-0"), makeAddr("d1-op-0"));
        pairs[1] = _pair(makeAddr("d1-payer-1"), makeAddr("d1-op-1"));
        _registerPairsAs(a, pairs);
        assertEq(sra.bindingOf(pairs[0].payer, pairs[0].operator), a);
        assertEq(sra.bindingOf(pairs[1].payer, pairs[1].operator), a);

        Reassignment[] memory rs = new Reassignment[](2);
        rs[0] = Reassignment({payer: pairs[0].payer, operator: pairs[0].operator, orch: b, inherit: true});
        rs[1] = Reassignment({payer: pairs[1].payer, operator: pairs[1].operator, orch: b, inherit: false});

        vm.prank(owner1);
        sra.reassignBindings(rs);
        vm.prank(owner2);
        sra.reassignBindings(rs); // second vote executes (unanimousNoHold)

        assertEq(sra.bindingOf(pairs[0].payer, pairs[0].operator), b);
        assertEq(sra.bindingOf(pairs[1].payer, pairs[1].operator), b);
    }

    /// 原子性：批量中一条 target 未 admitted（复用单条 NotAdmitted 校验）→ 整体 revert，
    /// 前面已校验通过的 reassign 也不生效（回滚）。
    function test_ReassignBindings_PartialInvalid_AllRolledBack() public {
        address a = makeAddr("d1-rb-a");
        address b = makeAddr("d1-rb-b");
        address stranger = makeAddr("d1-rb-stranger");
        _admit(a, a);
        _admit(b, b);

        Binding[] memory pairs = new Binding[](2);
        pairs[0] = _pair(makeAddr("d1-rb-payer-0"), makeAddr("d1-rb-op-0"));
        pairs[1] = _pair(makeAddr("d1-rb-payer-1"), makeAddr("d1-rb-op-1"));
        _registerPairsAs(a, pairs);

        Reassignment[] memory rs = new Reassignment[](2);
        rs[0] = Reassignment({payer: pairs[0].payer, operator: pairs[0].operator, orch: b, inherit: true}); // valid
        rs[1] = Reassignment({payer: pairs[1].payer, operator: pairs[1].operator, orch: stranger, inherit: false}); // invalid target

        vm.prank(owner1);
        sra.reassignBindings(rs);
        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.NotAdmitted.selector, stranger));
        sra.reassignBindings(rs); // second vote executes the body -> revert (atomic)

        assertEq(sra.bindingOf(pairs[0].payer, pairs[0].operator), a, "valid item rolled back");
        assertEq(sra.bindingOf(pairs[1].payer, pairs[1].operator), a, "invalid item left untouched");
    }

    /// 批量条数 > MAX_PAIRS (64) → TooManyPairs（与 registerPairs 同一容量上限）。
    function test_ReassignBindings_TooMany_Reverts() public {
        address a = makeAddr("d1-cap-a");
        _admit(a, a);

        Reassignment[] memory rs = new Reassignment[](65);
        for (uint256 i = 0; i < rs.length; i++) {
            rs[i] = Reassignment({
                payer: makeAddr(string.concat("d1-cap-p", vm.toString(i))),
                operator: makeAddr(string.concat("d1-cap-o", vm.toString(i))),
                orch: a,
                inherit: false
            });
        }

        vm.prank(owner1);
        sra.reassignBindings(rs);
        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.TooManyPairs.selector));
        sra.reassignBindings(rs);
    }

    /// 恰好 MAX_PAIRS (64) 条 → 接受（容量边界）。
    function test_ReassignBindings_Max64_Accepted() public {
        address a = makeAddr("d1-max-a");
        address b = makeAddr("d1-max-b");
        _admit(a, a);
        _admit(b, b);

        Binding[] memory pairs = new Binding[](64);
        for (uint256 i = 0; i < pairs.length; i++) {
            pairs[i] = _pair(
                makeAddr(string.concat("d1-max-p", vm.toString(i))), makeAddr(string.concat("d1-max-o", vm.toString(i)))
            );
        }
        _registerPairsAs(a, pairs);

        Reassignment[] memory rs = new Reassignment[](64);
        for (uint256 i = 0; i < rs.length; i++) {
            rs[i] = Reassignment({payer: pairs[i].payer, operator: pairs[i].operator, orch: b, inherit: false});
        }

        vm.prank(owner1);
        sra.reassignBindings(rs);
        vm.prank(owner2);
        sra.reassignBindings(rs);

        assertEq(sra.bindingOf(pairs[0].payer, pairs[0].operator), b);
        assertEq(sra.bindingOf(pairs[63].payer, pairs[63].operator), b);
    }

    /// 事件逐条发射：批量长度 == BindingReassigned 事件数（每条带各自的 inherit 值）。
    function test_ReassignBindings_EmitsOneEventPerItem() public {
        address a = makeAddr("d1-ev-a");
        address b = makeAddr("d1-ev-b");
        _admit(a, a);
        _admit(b, b);

        Binding[] memory pairs = new Binding[](3);
        for (uint256 i = 0; i < pairs.length; i++) {
            pairs[i] = _pair(
                makeAddr(string.concat("d1-ev-p", vm.toString(i))), makeAddr(string.concat("d1-ev-o", vm.toString(i)))
            );
        }
        _registerPairsAs(a, pairs);

        Reassignment[] memory rs = new Reassignment[](3);
        for (uint256 i = 0; i < rs.length; i++) {
            rs[i] = Reassignment({payer: pairs[i].payer, operator: pairs[i].operator, orch: b, inherit: i % 2 == 0});
        }

        vm.recordLogs();
        vm.prank(owner1);
        sra.reassignBindings(rs);
        vm.prank(owner2);
        sra.reassignBindings(rs);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 hits;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != ServiceRewardsActor.BindingReassigned.selector) continue;
            hits++;
        }
        assertEq(hits, 3, "one BindingReassigned per batch item");
    }

    /// 与单条等价：批量 reassign 的结果（binding 指向）与逐条 reassignBinding 一致。
    function test_ReassignBindings_EquivalentToSingles() public {
        address a = makeAddr("d1-eq-a");
        address b = makeAddr("d1-eq-b");
        _admit(a, a);
        _admit(b, b);

        Binding[] memory pairs = new Binding[](2);
        pairs[0] = _pair(makeAddr("d1-eq-p0"), makeAddr("d1-eq-o0"));
        pairs[1] = _pair(makeAddr("d1-eq-p1"), makeAddr("d1-eq-o1"));
        _registerPairsAs(a, pairs);

        // batch path: pair0 -> b
        Reassignment[] memory rs = new Reassignment[](1);
        rs[0] = Reassignment({payer: pairs[0].payer, operator: pairs[0].operator, orch: b, inherit: true});
        vm.prank(owner1);
        sra.reassignBindings(rs);
        vm.prank(owner2);
        sra.reassignBindings(rs);

        // single path: pair1 -> b (same semantics, same event shape)
        vm.prank(owner1);
        sra.reassignBinding(pairs[1].payer, pairs[1].operator, b, true);
        vm.prank(owner2);
        sra.reassignBinding(pairs[1].payer, pairs[1].operator, b, true);

        assertEq(sra.bindingOf(pairs[0].payer, pairs[0].operator), b);
        assertEq(sra.bindingOf(pairs[1].payer, pairs[1].operator), b);
    }

    // ------------------------------------------------------------------------
    // D2 [spec内] setPricingParams + registration_cutoff
    //    spec 8e495ca: SetPricingParams(min_lot_floor, min_lot_alpha, price_band,
    //    registration_cutoff) — MIN_LOT_ALPHA is a rational (num+den), so the event
    //    carries five values; REGISTRATION_CUTOFF parameterizes the off-chain
    //    late-claim guard (spec §2.2) as a duration in epochs (initial 7 days),
    //    stored nowhere (event-only, like the pricing parameters).
    // ------------------------------------------------------------------------

    /// @dev Two-vote setPricingParams asserting PricingParamsUpdated carries exactly the
    ///      five given values. The unanimousNoHold modifier also emits Submitted/Approved
    ///      (governance vote records), so the parameter event is extracted from recorded logs.
    function _setPricingParams(uint256 floor, uint256 alphaNum, uint256 alphaDen, uint256 band, uint256 cutoff)
        internal
    {
        vm.recordLogs();
        vm.prank(owner1);
        sra.setPricingParams(floor, alphaNum, alphaDen, band, cutoff);
        vm.prank(owner2);
        sra.setPricingParams(floor, alphaNum, alphaDen, band, cutoff);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = ServiceRewardsActor.PricingParamsUpdated.selector;
        uint256 hits;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != topic) continue;
            hits++;
            (uint256 f, uint256 an, uint256 ad, uint256 b, uint256 c) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            assertEq(f, floor);
            assertEq(an, alphaNum);
            assertEq(ad, alphaDen);
            assertEq(b, band);
            assertEq(c, cutoff);
        }
        assertEq(hits, 1, "PricingParamsUpdated emitted once");
    }

    /// registrationCutoff 传递 + 事件携带全部 5 值（cutoff = 20160 epochs = 7 days at 30s block time，spec 初始值语义）。
    function test_SetPricingParams_Cutoff_EmitsAllFive() public {
        _setPricingParams(5e17, 1, 400, 3000, 20160);
    }

    /// cutoff = 0（无注册截止）是合法参数——事件-only 参数，无存储语义，零值合法。
    function test_SetPricingParams_CutoffZero_Accepted() public {
        _setPricingParams(5e17, 1, 400, 3000, 0);
    }

    /// cutoff 大值合法（uint256 域内，参数化 off-chain 测量，spec §2.2——合约不读取）。
    function test_SetPricingParams_CutoffLarge_Accepted() public {
        _setPricingParams(5e17, 1, 400, 3000, type(uint256).max);
    }

    /// alphaDen = 0（rational 分母）仍被拒——新增 cutoff 参数不削弱既有校验。
    function test_SetPricingParams_AlphaDenZero_StillReverts() public {
        vm.prank(owner1);
        sra.setPricingParams(5e17, 1, 0, 3000, 20160);
        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        sra.setPricingParams(5e17, 1, 0, 3000, 20160);
    }

    /// band > BASIS_POINTS 仍被拒——既有边界校验保持。
    function test_SetPricingParams_BandOverMax_StillReverts() public {
        vm.prank(owner1);
        sra.setPricingParams(5e17, 1, 400, 10_001, 20160);
        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSelector(ServiceRewardsActor.InvalidParameter.selector));
        sra.setPricingParams(5e17, 1, 400, 10_001, 20160);
    }

    // ------------------------------------------------------------------------
    // D3 [spec外] VolumeCorrected carries the corrected volume (VolumePosted symmetry)
    // ------------------------------------------------------------------------

    /// 治理纠正后，VolumeCorrected 携带 corrected 值（与 VolumePosted 对称）。
    /// @dev expectEmit cannot be used here: correctVolume runs the unanimousNoHold two-vote path,
    ///      so the function-body event is preceded by Submitted/Approved; recordLogs + topic filter
    ///      (as in _setPricingParams) extracts VolumeCorrected from the full stream.
    function test_CorrectVolume_EmitsVolume() public {
        address orch = makeAddr("d3-orch");
        _admit(orch, orch);

        vm.roll(_qEnd(0) + 1); // posting window
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qPostEnd(0) + 1); // verification window
        vm.recordLogs();
        _correctVolume(orch, 0, 250e18);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 hits;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != ServiceRewardsActor.VolumeCorrected.selector) continue;
            hits++;
            assertEq(uint64(uint256(logs[i].topics[1])), 0, "indexed quarter");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), orch, "indexed orchestrator");
            assertEq(FixedU18.unwrap(abi.decode(logs[i].data, (FixedU18))), 250e18, "corrected volume");
        }
        assertEq(hits, 1, "VolumeCorrected emitted once");
    }

    /// correctVolume(0)（清除，等效未发布）也携带 0 值。
    function test_CorrectVolume_Zero_EmitsZeroVolume() public {
        address orch = makeAddr("d3-zero");
        _admit(orch, orch);

        vm.roll(_qEnd(0) + 1); // posting window
        _postAs(orch, 0, _fpv(100e18));

        vm.roll(_qPostEnd(0) + 1); // verification window
        vm.recordLogs();
        _correctVolume(orch, 0, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 hits;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != ServiceRewardsActor.VolumeCorrected.selector) continue;
            hits++;
            assertEq(uint64(uint256(logs[i].topics[1])), 0, "indexed quarter");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), orch, "indexed orchestrator");
            assertEq(FixedU18.unwrap(abi.decode(logs[i].data, (FixedU18))), 0, "cleared volume");
        }
        assertEq(hits, 1, "VolumeCorrected emitted once");
    }

    // ------------------------------------------------------------------------
    // D7 [spec内] wallet uniqueness across admitted orchestrators
    //    addOrchestrator / replaceWallet reject a wallet already held by any
    //    admitted orchestrator; removed orchestrators' wallets are reusable.
    //    (Revert selector is implementation-defined — the tests assert rejection.)
    // ------------------------------------------------------------------------

    /// admit 撞唯一 admitted orchestrator 的 wallet → 拒绝。
    function test_Admit_DuplicateWallet_Reverts() public {
        address w = makeAddr("d7-wallet");
        address a = makeAddr("d7-a");
        address b = makeAddr("d7-b");
        _admit(a, w);

        vm.prank(owner1);
        sra.addOrchestrator(b, w); // vote 1 (approve)
        vm.prank(owner2);
        vm.expectRevert(); // vote 2 executes the body -> wallet conflict
        sra.addOrchestrator(b, w);

        assertFalse(sra.isAdmitted(b));
    }

    /// admit 撞中间某个 admitted orchestrator 的 wallet（多个已 admit 中遍历检出）→ 拒绝。
    function test_Admit_DuplicateWallet_AmongMany_Reverts() public {
        address w = makeAddr("d7-many-w");
        _admit(makeAddr("d7-many-a"), makeAddr("d7-many-wa"));
        _admit(makeAddr("d7-many-b"), w); // this orchestrator holds w
        _admit(makeAddr("d7-many-c"), makeAddr("d7-many-wc"));

        address d = makeAddr("d7-many-d");
        vm.prank(owner1);
        sra.addOrchestrator(d, w); // vote 1 (approve)
        vm.prank(owner2);
        vm.expectRevert(); // vote 2 executes the body -> wallet conflict with b
        sra.addOrchestrator(d, w);

        assertFalse(sra.isAdmitted(d));
    }

    /// replaceWallet 的新 wallet 撞其他 admitted orchestrator 的 wallet → 拒绝。
    /// 构造：B 的 wallet 是独立地址 wB（≠ B），wB 未作为 orch 被 admit → 只有 D7 校验能拒绝。
    function test_ReplaceWallet_ConflictingWallet_Reverts() public {
        address a = makeAddr("d7-rw-a");
        address b = makeAddr("d7-rw-b");
        address wB = makeAddr("d7-rw-wb");
        _admit(a, a);
        _admit(b, wB); // B's wallet is the distinct address wB

        vm.prank(owner1);
        sra.replaceWallet(a, wB); // vote 1 (approve)
        vm.prank(owner2);
        vm.expectRevert(); // vote 2 executes the body -> wB conflicts with B's wallet
        sra.replaceWallet(a, wB);

        assertTrue(sra.isAdmitted(a), "A unchanged");
        assertTrue(sra.isAdmitted(b), "B unchanged");
    }

    /// replaceWallet 的新 wallet 未被任何 admitted orchestrator 占用 → 成功；spec §3.2 身份不动：
    /// a 保持 admitted，wNew 只是新 payout wallet（不进入身份命名空间）。
    function test_ReplaceWallet_NonConflicting_Succeeds() public {
        address a = makeAddr("d7-nc-a");
        address b = makeAddr("d7-nc-b");
        address wNew = makeAddr("d7-nc-wnew");
        _admit(a, a);
        _admit(b, b);

        vm.prank(owner1);
        sra.replaceWallet(a, wNew);
        vm.prank(owner2);
        sra.replaceWallet(a, wNew); // second vote executes -> no conflict

        assertTrue(sra.isAdmitted(a), "identity does not move (spec 3.2)");
        assertFalse(sra.isAdmitted(wNew), "the new wallet is not an orchestrator identity");
    }

    /// removed orchestrator 的 wallet 可复用（唯一性只约束 admitted orchestrators）。
    function test_Admit_RemovedWallet_Reusable() public {
        address w = makeAddr("d7-reuse-w");
        address a = makeAddr("d7-reuse-a");
        address c = makeAddr("d7-reuse-c");
        _admit(a, w);

        _crankQuarter0(); // lift the §3.2 remove guard (q0 bound + submitted)
        _remove(a);

        _admit(c, w); // removed orchestrator's wallet is reusable
        assertTrue(sra.isAdmitted(c));
    }

    /// 接近容量时 wallet 校验仍工作：64 满 → remove 1（容量 63）→ admit 撞剩余 wallet → 拒绝。
    /// （容量未满，触发的是 wallet 冲突而非 AtCapacity，证明遍历未被容量短路。）
    function test_Admit_WalletCheckAtHighCapacity() public {
        for (uint256 i = 0; i < 64; i++) {
            _admit(
                makeAddr(string.concat("d7-cap-", vm.toString(i))), makeAddr(string.concat("d7-cap-", vm.toString(i)))
            );
        }
        _crankQuarter0(); // lift the §3.2 remove guard (q0 bound + submitted)
        _remove(makeAddr("d7-cap-0"));
        assertEq(sra.admittedCount(), 63);

        address d = makeAddr("d7-cap-new");
        vm.prank(owner1);
        sra.addOrchestrator(d, makeAddr("d7-cap-1")); // wallet still held by admitted orch-1
        vm.prank(owner2);
        vm.expectRevert(); // vote 2 executes the body -> wallet conflict (capacity 63 < 64)
        sra.addOrchestrator(d, makeAddr("d7-cap-1"));

        assertFalse(sra.isAdmitted(d));
    }

    // ------------------------------------------------------------------------
    // D8 [spec内] SRA upgrade-hold duration: SRA state, fixed at deployment
    //    spec 95eb9e0 §4.2: "the SRA's upgrade hold is the one hold the SRA itself
    //    keeps, and its duration is SRA state, fixed at deployment"; §3.2: the SRA
    //    code upgrade alone waits in a public queue before binding. Minimal surface:
    //    constructor param -> immutable, getter exposed on the interface.
    // ------------------------------------------------------------------------

    /// getter 返回部署时固定的 hold duration（基类部署值）。
    function test_UpgradeHold_Getter_ReturnsDeploymentValue() public view {
        assertEq(Epoch.unwrap(sra.SRA_UPGRADE_HOLD()), SRA_UPGRADE_HOLD);
    }

    /// 部署固定（per-instance）：第二个实例用不同 hold 值，各自 getter 返回各自部署值（非全局常量）。
    function test_UpgradeHold_DeploymentFixed_PerInstance() public {
        ServiceRewardsActor s2 = new ServiceRewardsActor(
            owner1,
            owner2,
            Epoch.wrap(EPOCHS_PER_QUARTER),
            Epoch.wrap(POST_PERIOD),
            Epoch.wrap(VERIFICATION_WINDOW),
            Epoch.wrap(ACTIVATION_EPOCH),
            Epoch.wrap(SRA_UPGRADE_HOLD + 1)
        );

        assertEq(Epoch.unwrap(sra.SRA_UPGRADE_HOLD()), SRA_UPGRADE_HOLD);
        assertEq(Epoch.unwrap(s2.SRA_UPGRADE_HOLD()), SRA_UPGRADE_HOLD + 1);
    }
}
