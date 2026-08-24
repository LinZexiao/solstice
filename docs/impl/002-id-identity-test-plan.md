# id 身份模型测试计划（基线 sra@b521e61）

> 配套方案文档：`docs/impl/001-d1-id-identity-on-mirror.md`（存储布局 / 方法改造 / 风险）。
> 本计划是测试侧的执行规格：哪些保留、哪些适配、哪些新增，具体到文件/函数/断言。

## 1. 基线状态（实测）

- 非 invariant 套件：**314 passed**（16 suites，`forge test --no-match-contract SRAInvariant` 实测）
- invariant 套件：SRAInvariant 5 个 invariant（I1/I2/I3/A2/A3）
- **合计 314 tests**，全绿起点（含全部 review 修复：A3/B1/S1/时间驱动化）

## 2. 测试用例全景分类

| 类别 | 范围 | 处理 |
|---|---|---|
| **保留不动** | halmos（QuarterWindowCheck，纯窗口函数，与身份无关）；differential（仅走公开接口 aggregatedFPV 差分）；SRAggregateMirror / SRAQuarter / SRAGovernance / SRAIntegration / SRAOverflowDoS / FixedU18 / Owners / OwnerSet / StreamWeightActor / UnanimousGovernance | 零改动 |
| **仅注释更新** | SRAShares T10 回归（`test_ReAdmit_AfterReplace_FrozenSuccessor_NoShares`）、SRARegistry replace 系列 3 个测试（TransfersIdentity / AfterReplace_ThirdPartyReverts / ReAdmit_ResetsFrozenState） | 断言不变，注释去 successor 链描述 |
| **断言/构造适配** | SRARegistry `test_Admit_IdMonotonic_NeverReused`（slot 读取改低 64 位，无 admittedCount 打包） | 见 §4.2 |
| **新增（移植早期实现）** | 5 个行为锁定测试（3 个 SRAShares + 2 个 SRARegistry） | 见 §4.1 |
| **invariant handler 改造** | SRAInvariant handler 的 `_successor` → generation 代际机制（4 处 + resolveHandled 删除 + I2 断言简化） | 见 §5 |

**预期：314 → 319 tests**（+5 新增，其余既有测试适配后全绿）。

## 3. 关键 slot / 常量（测试侧需要）

```solidity
// REGISTRY_SLOT：src/lib/SraStorage.sol 已有，值 0xb7fd4b054ced95f43476af93bf71636318271f9e64f7661dc52f0fb4c1a54400（namespace 不变）
// 但新基线 test/ 下无此常量（早期实现 在 SRARegistry.t.sol 定义）——新增测试需自行定义：
bytes32 internal constant REGISTRY_SLOT = 0xb7fd4b054ced95f43476af93bf71636318271f9e64f7661dc52f0fb4c1a54400;
```

**id 单调性测试的 slot 计算（与早期实现 的关键差异）**：
- 旧布局 slot3 = `admittedCount(uint64) + nextId(uint64)` 打包 → 早期实现 读 `>> 64`（高 64 位）取 nextId
- **新布局 slot3 = 仅 `uint64 nextId`（admittedCount 删除，admittedIds.length 派生）** → 读**低 64 位**（不 shift）：
  ```solidity
  bytes32 slot = bytes32(uint256(REGISTRY_SLOT) + 3); // nextId 独占 slot3 低 64 位
  assertEq(uint64(uint256(vm.load(address(sra), slot))), 1, "nextId starts at 1 (0 = sentinel)");
  ```

## 4. 新增 5 个行为锁定测试（移植早期实现）

helper 全部复用新基线 `SRATestBase.sol`（`_admit/_postAs/_rollTo/_qEnd/_qPostEnd/_qVerifyEnd/_correctVolume/_fpv/_pair/_registerPairsAs`）+ `SRAShares.t.sol` 内部（`SRAShares::_admitAndPost`、`SRAShares::_walletShare`、`SRAShares::_sumShares`）。早期实现 测试几乎原样可移植。

### 4.1 新增测试清单

| # | 测试函数 | 文件（插入位置） | 断言要点 | mirror 适配 |
|---|---|---|---|---|
| 1 | `test_Replace_HistoricalQuarterFPV_Kept` | SRAShares（T10 之后） | post q0 100e18 → replace → submit q0：`_walletShare(shares, newOrch)==1e18`、`_walletShare(shares, oldOrch)==0`、`_sumShares==1e18`、`aggregatedFPV(0)==100e18` | 直接成立（fpv 按 id 存，submitShares(0) usePrev=false 读 fpv） |
| 2 | `test_Replace_ShareMap_WritesNewWallet` | SRAShares | `_admitAndPost(50e18)`（旧）+ 另一 orch 50 → replace → `_walletShare(shares, newOrch)==5e17`、`oldOrch==0`、`_sumShares==1e18` | 直接成立 |
| 3 | `test_Replace_CorrectVolume_NewAddress_CorrectsHistoricalQuarter` | SRAShares | post 100 → replace → `_correctVolume(newOrch, 0, 200e18)` → submit：`_walletShare(shares, newOrch)==1e18`、`aggregatedFPV(0)==200e18`（**200 生效非 100**） | 成立（activeQ==0 不 advance，`o.fpv=200; totalUsd[0]=+200-100`） |
| 4 | `test_ReAdmit_FreshIdentity_NoBindingsNoFPV` | SRARegistry（ReAdmit_ResetsFrozenState 之后） | remove → re-admit：pair 可被第三方认领（`bindingOf==third`）、`fpvOf(0, oldOrch).usd==0` | **删 `assertFalse(f.posted)`**（新 FPV 仅 usd 字段，FIPs#1275） |
| 5 | `test_Admit_IdMonotonic_NeverReused` | SRARegistry（末尾） | nextId 从 1；admit a → 2；remove+re-admit a → 3（新 id 不重用）；admit b → 4 | **slot 读取改低 64 位**（见 §3） |

### 4.2 新增测试源（早期实现 原样，含需适配的行标注）

```solidity
// ============ SRAShares.t.sol 新增（插入在 test_ReAdmit_AfterReplace_FrozenSuccessor_NoShares 之后、文件末尾之前） ============

/// id-keyed identity: replace re-points the wallet — historical quarter FPV follows the identity
/// (the previous address-keyed implementation lost it from the traversal after replace; here it survives by construction).
function test_Replace_HistoricalQuarterFPV_Kept() public {
    address oldOrch = makeAddr("hist-old");
    address newOrch = makeAddr("hist-new");
    _admit(oldOrch);
    vm.roll(_qEnd(0) + 1);
    _postAs(oldOrch, 0, _fpv(100e18));

    // governance replace(old -> new) inside q0's verification window (before binding)
    vm.roll(_qPostEnd(0) + 1);
    vm.prank(owner1);
    sra.replace(oldOrch, newOrch);
    vm.prank(owner2);
    sra.replace(oldOrch, newOrch);
    vm.roll(block.number + SRA_CANCEL_HOLD);
    sra.replace(oldOrch, newOrch);

    _rollTo(_qVerifyEnd(0) + 1);
    sra.submitShares(0);
    Share[] memory shares = rewardActor().getShares(SERVICE_STREAM_ID);
    assertEq(shares.length, 1);
    assertEq(_walletShare(shares, newOrch), 1e18, "historical FPV follows the identity to the new wallet");
    assertEq(_sumShares(shares), 1e18);
    assertEq(FixedU18.unwrap(sra.aggregatedFPV(0)), 100e18);
}

/// The share map is always written to the *current* wallet — after replace, newOrch receives the shares.
function test_Replace_ShareMap_WritesNewWallet() public {
    address oldOrch = makeAddr("wallet-old");
    address newOrch = makeAddr("wallet-new");
    _admit(oldOrch);
    vm.roll(_qEnd(0) + 1);
    _postAs(oldOrch, 0, _fpv(50e18));
    _admitAndPost(50e18); // second orchestrator keeps the split non-trivial

    vm.roll(_qPostEnd(0) + 1);
    vm.prank(owner1);
    sra.replace(oldOrch, newOrch);
    vm.prank(owner2);
    sra.replace(oldOrch, newOrch);
    vm.roll(block.number + SRA_CANCEL_HOLD);
    sra.replace(oldOrch, newOrch);

    _rollTo(_qVerifyEnd(0) + 1);
    sra.submitShares(0);
    Share[] memory shares = rewardActor().getShares(SERVICE_STREAM_ID);
    assertEq(_walletShare(shares, newOrch), 5e17, "share map wallet = the current (replaced-to) wallet");
    assertEq(_walletShare(shares, oldOrch), 0, "the replaced address receives nothing");
    assertEq(_sumShares(shares), 1e18);
}

/// After replace, governance correctVolume must address the *new* wallet — the id-keyed model routes it
/// to the same identity, so a verification-window correction of the historical quarter hits the right FPV record.
function test_Replace_CorrectVolume_NewAddress_CorrectsHistoricalQuarter() public {
    address oldOrch = makeAddr("cv-old");
    address newOrch = makeAddr("cv-new");
    _admit(oldOrch);
    vm.roll(_qEnd(0) + 1);
    _postAs(oldOrch, 0, _fpv(100e18));

    vm.roll(_qPostEnd(0) + 1);
    vm.prank(owner1);
    sra.replace(oldOrch, newOrch);
    vm.prank(owner2);
    sra.replace(oldOrch, newOrch);
    vm.roll(block.number + SRA_CANCEL_HOLD);
    sra.replace(oldOrch, newOrch);

    _correctVolume(newOrch, 0, _fpv(200e18)); // correction via the new wallet hits the same identity

    _rollTo(_qVerifyEnd(0) + 1);
    sra.submitShares(0);
    Share[] memory shares = rewardActor().getShares(SERVICE_STREAM_ID);
    assertEq(shares.length, 1);
    assertEq(_walletShare(shares, newOrch), 1e18);
    assertEq(FixedU18.unwrap(sra.aggregatedFPV(0)), 200e18); // the corrected value (200), not the original post (100)
}

// ============ SRARegistry.t.sol 新增（插入在 test_ReAdmit_ResetsFrozenState 之后） ============

/// id-keyed identity: re-admit of a removed address allocates a fresh id — the removed identity's bindings
/// (pair bound by the old id) and FPV do not carry over. The pair stays claimable and the fresh id's quarter
/// record is empty (the old record lives on only under the archived id, unreachable from the address).
function test_ReAdmit_FreshIdentity_NoBindingsNoFPV() public {
    address oldOrch = makeAddr("fresh-old");
    address third = makeAddr("fresh-third");
    _admit(oldOrch);
    _admit(third);

    Pair[] memory pairs = new Pair[](1);
    pairs[0] = _pair(makeAddr("payer"), makeAddr("operator"));
    _registerPairsAs(oldOrch, pairs);
    assertEq(sra.bindingOf(makeAddr("payer"), makeAddr("operator")), oldOrch);

    vm.roll(_qEnd(0) + 1);
    _postAs(oldOrch, 0, _fpv(100e18));

    _remove(oldOrch);
    assertFalse(sra.isAdmitted(oldOrch));

    _admit(oldOrch); // re-admit the same address: fresh identity
    assertTrue(sra.isAdmitted(oldOrch));
    assertFalse(sra.isFrozen(oldOrch));

    // the removed identity's binding does not carry over: the pair is claimable by a third party
    _registerPairsAs(third, pairs); // no revert -> the old id's binding is not inherited
    assertEq(sra.bindingOf(makeAddr("payer"), makeAddr("operator")), third);

    // the removed identity's FPV does not carry over: the fresh id's quarter-0 record is empty
    FPV memory f = sra.fpvOf(0, oldOrch);
    assertEq(FixedU18.unwrap(f.usd), 0);
    // ⚠️ 适配：删除早期实现 的 assertFalse(f.posted)（新 FPV 仅 usd 字段，FIPs#1275 移除 posted）
}

/// id allocation is monotonic and never reuses an id: 0 is the unregistered sentinel, ids start at 1 and
/// increase strictly — remove + re-admit of the same address consumes a new id (never the archived one).
function test_Admit_IdMonotonic_NeverReused() public {
    bytes32 slot = bytes32(uint256(REGISTRY_SLOT) + 3); // ⚠️ 适配：nextId 独占 slot3 低 64 位（无 admittedCount 打包）
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
```

## 5. invariant handler 改造（SRAInvariant.t.sol）

新基线 handler 用 `_successor` 模拟 replace 链（**4 处使用 + resolveHandled**），id identity 融合后改为 **generation 代际机制**（早期实现已验证，移植）。逐点：

| 位置 | 现状 | 改法 |
|---|---|---|
| L53 声明 | `mapping(address => address) internal _successor;` | 删 → 加 `mapping(address => uint256) internal _idGen;` + `uint256 internal _genSeq;` |
| PairRecord | `address boundOrch;` | 加 `uint256 gen;`（绑定时代际） |
| admit（L125-128） | `_successor[orch] = address(0);` | 改 `_genSeq++; _idGen[orch] = _genSeq;` |
| remove（L154） | `_successor[orch] = address(0); // implementation remove: ...successor = 0` | **删行**（id 方案无链可清） |
| replace（L207-208） | `_successor[oldOrch] = newOrch; _successor[newOrch] = address(0);` | 改 `_idGen[newOrch] = _idGen[oldOrch];`（同代际转移）；pairs 迁移**仅当前代际**（`boundOrch==oldOrch && gen==_idGen[oldOrch]` → `boundOrch=newOrch`）；`_frozen[newOrch]=_frozen[oldOrch]` 与冻结历史迁移（`_freezeAt/_unfreezeAt`）**保留**（业务语义与 id 无关） |
| completeParked（L356） | `_successor[orch] = address(0);` | 改 `_genSeq++; _idGen[orch] = _genSeq;` |
| `_claimable`（L549-553） | 链上查询版：`sra.bindingOf` + `!sra.isAdmitted(cur)` 判定 | **必须重构为基于 handler 自身 PairRecord 的代际判定**（见下方说明）——不能沿用链上查询 |
| `_setBound`（L562-576） | 写 boundOrch | 同步记录 `gen: _idGen[orch]` |
| `resolveHandled`（L427-432） | 沿链解析 | **删除**（id 模型无链） |
| I2 invariant（L616-619） | `expected = handler.resolveHandled(boundOrch)` | 改 `expected = boundOrch` 直接相等（handler replace 已把当前代际 pair 的 boundOrch 同步到新 wallet，与链上 `bindingOf` 一致） |
| `_snapshotPostEnd` / `_isFrozenAtHandled` / `_claimable` 读链上接口的部分 | — | **不需要改**（经 `sra.fpvOf/bindingOf/isAdmitted` 读值，天然适配 id 模型） |

**验证**：`forge test --match-contract SRAInvariant` → I1/I2/I3/A2/A3 全绿。generation 机制解决的是早期实现 验证过的 re-admit 后 replace 的 pair 同步歧义（归档身份的 pair 不迁移到新代际）。

> **⚠️ `_claimable` 重构要点（reviewer 修订）**：新基线 `_claimable(orch, payer, operator)` 是**链上查询版**——`sra.bindingOf(payer, operator)` 取当前绑定地址、`!sra.isAdmitted(cur)` 判可认领。该实现**不能沿用**：re-admit 场景下，归档 binding 的 boundOrch = 旧地址，re-admit 后 `sra.isAdmitted(旧地址)` 返回 **true**（activeIdOf 已指向新 id）→ 误判不可认领 → handler 漏掉合法 registerPairs 路径。**必须重构为基于 handler 自身 PairRecord 的代际判定**：经 `_pairIdx[pairId]` 取 PairRecord 的 `boundOrch + gen`，判定 `!_admitted[p.boundOrch] || _idGen[p.boundOrch] != p.gen` → claimable（即早期实现 的实现）。

## 6. 既有测试适配清单（断言不变，仅注释/内部构造）

| 文件 | 测试 | 断言 | 处理 |
|---|---|---|---|
| SRAShares | `test_ReAdmit_AfterReplace_FrozenSuccessor_NoShares`（L463-503） | newOrch 0、oldOrch 1e18、Σ 1e18 | **断言不变**；L466-471 注释"admit identity reset (clears successor/frozen/freeze history)" → 更新为"re-admit = 新 id fresh identity（无链可解析）" |
| SRARegistry | `test_Replace_TransfersIdentity`（L245-260） | `!isAdmitted(old)`、`isAdmitted(new)`、`bindingOf==newOrch` | 断言不变（id 模型 bindingOf 返回 wallet=newOrch）；注释"bindings follow the identity transfer"可保留 |
| SRARegistry | `test_RegisterPairs_AfterReplace_ThirdPartyReverts`（L299-324） | `bindingOf==orchB`、第三方 registerPairs revert | **断言不变**（id 模型 registerPairs 唯一性检查 `boundId != 0 && orchestrators[boundId].admitted` 直读，无 _resolve）；L323 注释"(_resolve chain resolution)" → 更新为"bindingOf 直接返回当前 wallet" |
| SRARegistry | `test_ReAdmit_ResetsFrozenState`（L534-568） | `isFrozen(newOrch)==true`（继承）、re-admit 后 `isFrozen(oldOrch)==false` | **断言不变**（id 模型 replace 后 frozenSince 跟随 id 实体 → isFrozen(newOrch) 仍 true；re-admit 新 id → fresh）；L536 注释"replace only touches admitted/successor"、L554 "copied wholesale with the struct" → 更新为 id 语义（frozenSince 跟随 id，不复制） |
| SRARegistry | `test_Remove_FrozenOrch_Succeeds`（L400-409） | `!isAdmitted`、`!isFrozen`、`admittedCount()==0` | 断言不变（remove 后 activeIdOf[orch]=0 → isFrozen 返 false；admittedCount=admittedIds.length=0） |
| SRARegistry | `test_Remove_ReleasesPairs_CanBeReclaimed`（L179-196） | remove 后 B 可认领同一 pair | 断言不变（id 模型 remove 惰性清理 bindings：认领时查 `orchestrators[id].admitted==false` 允许） |
| SRAAdversarial | `test_RegisterPairs_ZeroPayer_Accepted`（L191） | `bindingOf(address(0), operator)==orch` | 断言不变（pairId=keccak(0,op)，bindingOf 返回 wallet） |

**注意**：上述测试大多**不需要改代码**（断言全部成立），仅注释需同步。tester 建议 coder 只改注释、不动断言——若某测试在实现后失败，先确认是"迁移引入"还是"断言假设了旧语义"，不要顺手改断言掩盖问题。

## 7. 保留不动（明确零改动）

- `test/halmos/*`：QuarterWindowHarness 只验证窗口纯函数（`_qEnd/_inPostingWindow/_inVerificationWindow/_afterBinding`），mirror 重构已删除冻结区间判定函数 → **零改动**。验证：halmos 跑 QuarterWindowCheck 应保持全绿
- `test/differential/*`：DifferentialSharesHarness 仅通过公开接口（aggregatedFPV）差分 → 零改动
- SRAggregateMirror / SRAQuarter / SRAGovernance / SRAIntegration / SRAOverflowDoS：grep 确认无 successor/_resolve/alias 引用 → 零改动

## 8. 测试先行策略（供 coder 跑红→绿）

以下测试**可在 coder 实现前先行编写**，跑 Red 验证规格有效性：

1. **5 个新增行为锁定测试**（§4.1）——实现前全部 Red（replace 无重映射 / id 单调性无 nextId / re-admit 非 fresh）
2. **invariant handler 改造**（§5）——handler 改 generation 后，在旧实现上 I2 应失败（resolveHandled 删除后无链可解析，期望值 boundOrch 与链上 bindingOf 不一致），实现后恢复绿

> ⚠️ Red 验证注意：新基线存在**全零季度 bug**（他人并行修复中）——若某个 Red 失败来自该 bug 而非身份模型（如 submitShares 相关），标注清楚，**不要**在本重构里顺手修复（边界已划：本重构不修该 bug）。

## 9. 验收命令

```bash
forge build --sizes                              # 编译干净 + 记录 runtime 体积（EIP-170 余量检查）
forge test                                       # 全绿：303 基线 + 5 新增 = 308
forge test --match-contract SRAInvariant         # I1/I2/I3/A2/A3 全绿（handler generation 改造后）
halmos                                           # QuarterWindowCheck 全绿（零改动保持通过）
forge fmt --check && forge lint --deny notes     # 格式与 lint
```
