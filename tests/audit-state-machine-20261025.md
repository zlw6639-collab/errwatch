# 状态机与结果语义盘点（审计方向 01）2026-10-25

> 外部审计的「下一阶段优化清单」01 项要求：
> 检查非法状态跳转、错误关闭、错误恢复；区分 `PASS/FAIL/SKIP/NOT_RUN`；
> 区分「已执行 / 已处理 / 已核验」；检查历史记录中的状态与实际结果是否一致。
>
> **本文档只做盘点，不改代码。** 每条发现都带代码位置、可复现的验证方式、以及判定。
> 判定口径用审计给的那套：`CONFIRMED` / `CLEARED` / `UNVERIFIED` / `NOT_APPLICABLE`。
> 「没发现问题」不写成「问题不存在」；「没验过」一律写 `UNVERIFIED`。

## 一、方法

1. 读权威定义：`STATE-CONTRACT.md`（四维度、终态唯一判据、7 条不变式）。
2. 读唯一实现：`core\ack-state.ps1`（聚合与终态判定）。
3. 用 `grep` 把**所有写入点**列出来，不靠印象。
4. 归纳一个**可复现脚本**验证每个可疑点（下文的「复现」都是实跑过的）。

## 二、状态全景（4 维度）

| 维度 | 取值 | 默认 | 写者（代码位置） |
|---|---|---|---|
| `lifecycle` | `acknowledged` / `expired` | `open` | 托盘：`errwatch-tray.ps1:572`（用户点「不需要处理」）、`:815`（30 分钟超时） |
| `notify` | `attempted` / `failed` / `suppressed` | `eligible` | 托盘：`:875` / `:877` / `:820,:830` |
| `rescue` | `launching` / `launched` / `launch-failed` / `user-confirmed` / `verified` | `not-started` | 托盘：`:561,:563`；`errwatch-recover.ps1:280` |
| `progress` | `collecting` / `complete` | `not-started` | 哨兵：`:1162` / `:1229,:1504` |

**终态唯一判据**：`lifecycle ∈ {acknowledged, expired}`（`core\ack-state.ps1:18`）。

## 三、发现

### F1 · `CONFIRMED`（P0）用户核验完成后，事件**不会**离开待处理

**契约怎么写的**（`STATE-CONTRACT.md` §四 不变式 2）：
> 任何 `rescue` 变化都不改变 `lifecycle`（**除了用户明确确认时显式写 `acknowledged`**）

**代码怎么做的**：`errwatch-recover.ps1:276-283` 在用户逐项勾完自检后只写 `rescue`：

```powershell
$val = if ($okN -eq $r.verify.Count) { 'verified' } else { 'user-confirmed' }
(New-ErrwatchAckRecord -Id $EventId -Dimension 'rescue' -Value $val) | Add-Content ...
```

`errwatch-recover.ps1` 全文**没有任何一处**写 `acknowledged`（实测 grep 零命中）。

**复现**（实跑）：

```
写入 e1: rescue=launching → launched → verified
  rescue   = verified     （用户已逐项核验）
  lifecycle= open
  是终态吗 = False
  → 仍然留在待处理（用户还得再点一次「不需要处理」）
补充 acknowledged 之后（场景 2）：lifecycle=acknowledged，是终态=True
```

**影响**：用户在救援窗口里做完了最有价值的那一步（确认文件救回来了），托盘却还挂着这条。
对用户来说这就是「我明明处理了，它还说没处理」—— 正是审计要查的「状态与实际结果不一致」。

**判定**：`CONFIRMED`。→ **已修（2026-10-25）**：`errwatch-recover.ps1` 在用户确认后补写
`lifecycle=acknowledged`；契约 `STATE-CONTRACT.md` 新增 §八.1 把这条写成不变式 8。
守卫 `test-recover` U，**反证过**（把那一行删掉 → U 立刻 FAIL）。

### F2 · `CONFIRMED`（P1）`verified` 一个词，三种意思

| 语境 | 位置 | 含义 |
|---|---|---|
| **rescue 维度值** | `core\ack-state.ps1:148` | 用户逐项核对过（自检） |
| **规则库 verifyStatus** | `core\diagnose-contract.ps1:105` | 这条**规则**已核验 → `confidence=high` |
| **修复动作结果** | `errwatch-fix.ps1:395,503,581,694` | 动作完成 **且** 验证断言通过 |

三者都叫 `verified`，写在同一批日志/状态目录里。看日志时无法从字面判断是「用户核对过」「规则被核验过」还是「修复被断言验证过」。

**判定**：`CONFIRMED`（grep 可复现）。

### F3 · `CONFIRMED`（P1）`user-confirmed` 与 `verified` 语义**倒置**，且两者都被算成「恢复成功」

**写入判据**（`errwatch-recover.ps1:277`）：
```powershell
$val = if ($okN -eq $r.verify.Count) { 'verified' } else { 'user-confirmed' }
```
- 全部项通过 → `verified`
- **部分**项通过 → `user-confirmed`

**界面文案**（`core\ack-state.ps1:145,148`）：
- `user-confirmed` → 「你自己确认救回了」
- `verified` → 「你逐项核对过」

「确认救回了」读起来比「逐项核对过」**更强**，却给了**部分成功**的那一档。

**统计口径**（`core\metrics.ps1:160,163`）：
```powershell
$rescueReached = ... -in @('launched', 'user-confirmed', 'verified')
$rescueOk      = ... -in @('user-confirmed', 'verified')
```
部分通过被算进「恢复成功」。这正是审计 05 项警告的同一类错误：**把部分成功说成成功，成功率因此虚高**。

**判定**：`CONFIRMED`。→ **已修（2026-10-25）**：判据改三档 ——「一项都没确认」**不写**
`rescue` 终态值（原来 `$okN=0` 也会落进 `user-confirmed`，等于 0 项确认被记成「确认救回了」）。
契约 §八.1 新增不变式 9。

> **F3 里最严重的那一档是查代码时顺手发现的**：`if ($okN -eq $r.verify.Count) { 'verified' } else { 'user-confirmed' }`
> 只有两档，所以「用户全按 N」也会写 `user-confirmed`。metrics 再把 `user-confirmed` 算进
> `rescueOk`，于是**完全没救回来的一次也会给恢复成功率 +1**。

### F4 · `CONFIRMED`（P1）「已执行 / 已处理 / 已核验」三个概念散在三个维度，没有统一表达

| 概念 | 现在藏在哪 | 契约怎么说 |
|---|---|---|
| 已执行（通知投递过） | `notify = attempted` | §二：不是终态（投递 ≠ 用户看见） |
| 已处理（诊断流程结束） | `progress = complete` | §二：不是终态，**也不表示诊断成功** |
| 已核验（用户逐项确认） | `rescue = verified` | §一：救援走到哪一步 |

单看任何一个值都推不出「这条事件现在到底走到哪一步」。用户要同时看三个维度才能拼出来，而界面上目前是按维度分片展示的。

**判定**：`CONFIRMED`（属设计层面缺口，不是实现错误）。

### F5 · `CONFIRMED`（P2）终态**之后**写的记录，会在终态满期时被连带清掉

`core\ack-state.ps1:93` 只挡住「`lifecycle` 终态后回退」，**其他三个维度在终态后仍可写**（实测接受 `notify=attempted` 写在 `acknowledged` 之后）。

而保留策略按**进入终态的时间**清（`core\retention.ps1`，用户明确要求的口径）。于是：

**复现**（实跑）：`lifecycle=acknowledged` 写在 7.2 天前，`notify=attempted` 写在 1.2 天前 →
清理后 **两行都没了**（`acksRemoved=2`）。那条 `notify` 只有 1.2 天，却因为事件在 7.2 天前进的终态而被一起清掉。

**影响**：`metrics` 按窗口统计时会少算这些「终态后发生的动作」。因为是整个事件一起过期，用户侧不可感知，但**观测口径**会偏。

**判定**：`CONFIRMED`（优先级低于 F1）。

### F6 · `CONFIRMED`（P2）`expired` 是系统超时写的，却和「用户处理了」一起被算成「决策」

- `expired` 的来源：`core\fallback.ps1:67` —— 事件超过 `DeadlineMinutes`（默认 30）且非终态 → 托盘在 `errwatch-tray.ps1:815` 写 `lifecycle=expired`。
- `core\metrics.ps1:140,143` 把 `acknowledged` 与 `expired` **同等**当作终态，用来算「决策延迟」。

于是「决策延迟」指标里混进了「用户根本没处理、系统 30 分钟后自动关掉」的样本 —— 而 metrics 自己的注释（行 226）还写着「用户一直不处理就没有样本」。**这句话现在不成立**。

**判定**：`CONFIRMED`。→ **已修（2026-10-25）**：决策延迟只算 `acknowledged`（用户真的处理过），
超时自动关闭的单独报 `expiredAuto`。**实测代价**：决策中位从「28.8 分钟」变成「6.8 分钟」
（另有 14 条是系统自动关闭的）—— 原来虚高 4.2 倍，因为一半样本是 30 分钟超时的产物。
守卫 `test-metrics` K，**反证过**（把 expired 混回去 → 样本变 2、中位被拉到 960 秒，立刻 FAIL）。

## 四、已审但**没有**发现问题的项（`CLEARED`）

| 项 | 怎么验的 | 结论 |
|---|---|---|
| 不变式 3：`lifecycle` 终态后不回 `open` | 实跑：写 `acknowledged` 后再写 `open`，聚合结果仍是 `acknowledged` | `CLEARED` |
| 终态判据唯一 | 全仓 `Test-ErrwatchAckTerminal` 只有 `core\ack-state.ps1:112` 一处实现，托盘与哨兵都调它 | `CLEARED` |
| 旧格式（无 `dimension`）兼容 | `core\ack-state.ps1:21-30` 有映射表；`test-ack-state` 有用例 | `CLEARED`（已有测试覆盖） |

## 五、尚未验证的项（`UNVERIFIED`）

- **不变式 5**：「一个事件从 `open` 到终态，至少经过一次用户操作或过期」—— 没有反例测试证明**不存在**其他进入终态的路径（目前只知道两个写点，但没跑过「如果没有这两个写点会怎样」的对照）。
- **乱序 / 延迟事件**对 rescue 最终值的影响：`metrics.ps1` 用 `Sort-Object at` 取最后一个 rescue 值，但**没有测过** `at` 相同或时钟回拨时会取到哪个。
- **`progress` 的 `failed` 缺失**：`progress` 只有 `collecting`/`complete`，失败信息藏在 `meta.reason` 里（`timeout`/`interrupted`/`evidence-failed`）。这是「没有独立失败态」还是「有意用 reason 表达」，没找到设计说明 —— **`UNVERIFIED`**。

## 六、建议的修复顺序（本文档不实施）

1. **F1** 先修：契约与实现不一致，且用户可感知。修法二选一 ——
   (a) `recover.ps1` 在用户确认后同时写 `lifecycle=acknowledged`（照契约）；
   (b) 改契约，明确「核验完仍需用户单独关闭」。
   **必须先选一个再改代码**，否则又是两份真相。
2. **F3 + F6** 一起修：都是「统计口径把弱信号当强信号」，同一批 metrics 改动。
3. **F2** 改名（`rescue` 维度值换成 `user-checked` 之类），并给规则库/修复动作那两处也换成不歧义的名字。改名涉及历史数据兼容，要单独设计迁移。
4. **F4** 属产品表达，最后做。
5. **F5** 影响最小，可与 retention 一起调。

## 七、环境

```
机器      WZL · Windows 10.0.26200
PowerShell 7.6.6（测试）/ 5.1（发布件也要过）
项目      E:\ai\_tools\errwatch
基线      errwatch-20261024-bq（112 个文件）
本文档基于 bq 的代码，未做任何修改
```
