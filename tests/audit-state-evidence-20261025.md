# errwatch-20261025-bu：证据关联与状态判定专项审计

- 审计对象：`E:\ai\_tools\_dist\errwatch-20261025-bu.zip`（干净解压副本）
- 审计时间：2026-10-25
- 范围：WER/快照/RecordId 证据关联；sentinel → events.jsonl → pending/tray/UI 的状态传播；退出意图与归位；ACK 读窗口与保留策略
- 方法：逐行审查 + 直接调用包内真实函数做受控故障注入；未修改送审包源码
- 结论：发现 **2 个 P2、3 个 P3，另附 1 个同源 UI 展示问题**。其中 4 项已用真实函数复现，1 项为静态代码路径与类型边界实测。

## 结果总览

| 编号 | 级别 | 问题 | 验证 |
|---|---|---|---|
| SE-1 | P2 | 3 分钟 WER 证据窗会把同程序**前一次崩溃**配给后来的退出；退出码 0 也无法纠正 | 真实 `Get-ExitEvidence` + `Get-ErrwatchExitIntent` 复现 |
| SE-2 | P2 | UI 对同 id 事件采用“先见者胜”，行与详情停在旧 verdict/旧 Raw，后补崩溃与归位状态被遮住 | 真实 `Get-SentinelRows` 复现 |
| SE-3 | P3 | 批量归位只对最新事件检查 24 小时上限，却把所有未终态崩溃一起归位 | 真实 `Select-ErrwatchRecoveryBatch` 复现 |
| SE-4 | P3 | ACK 只读末尾 4000 行，保留策略又只清读得到的 id；高吞吐时产生复活与永久僵尸数据风险 | 4001 行 ACK + 真实保留函数复现 |
| SE-5 | P3 | Windows `EventRecordID` 是 Int64，关联链却按 Int32 转换；大 ID 会让取证直接抛错 | 类型检查 + 真实 `Get-ExitEvidence` 复现 |
| SE-2a | 同源 | 哨兵详情标题硬编码“进程消失”，即使行 verdict 是 crash-suspected/recovered | 静态确认 |

---

## SE-1（P2）：旧 WER 记录可劫持新退出的判定

### 代码路径

1. `errwatch-sentinel.ps1:1324`：退出后用 `Get-ExitEvidence app ($now.AddMinutes(-3))` 查最近 3 分钟日志。
2. `errwatch-sentinel.ps1:527-538`：只按消息中是否包含 app 名筛选，再按“1000 优先、离现在最近”选证据。
   - 没有要求证据时间接近**本次退出**；
   - 没有排除已被前一条哨兵事件使用的 `RecordId`；
   - app 名是普通子串匹配，没有 exe 名称边界。
3. `errwatch-sentinel.ps1:1335`：只要匹配到记录就先置 `crash-suspected`。
4. `core/exit-intent.ps1:42-50`：`crash-suspected` 优先级最高，后续即使 `ExitCode=0` 也不许覆盖。

代码已经意识到“1001 不能配给别次崩溃”，并在 `errwatch-sentinel.ps1:547-552` 给 1001 加了 ±120 秒限制；但 **1000 本体的初次关联没有同等防护**。

### 可复现场景

- 12:00：实例 A 崩溃，WER 写入 1000；哨兵生成事件 A。
- 12:01：用户重开程序。
- 12:01:30：新实例 B 被用户以前台方式正常关闭，退出码 0，没有自己的 WER 记录。
- B 的取证仍能看到 90 秒前 A 的 1000，于是 B 被判成崩溃，且 A/B 共用同一个 `evidenceRecordId`。

### 实测

用真实 `Get-ExitEvidence` 注入一条 90 秒前的 gcad.exe 1000 记录，再把匹配结果交给真实退出意图函数：

```text
queryOk=True; matchedRecordId=41001
exitCode=0 + foreground + old evidence => final verdict=crash-suspected; quiet=False
```

这证明“旧证据 + 正常退出硬信号”最终仍会得到崩溃判定。

### 影响

- 正常关闭被误报成崩溃，托盘多弹一次；
- 恢复机会被记成 LOST；
- 同一 RecordId 被多条事件消费，后续追溯看似“强关联”，实际源头已经配错；
- 对“崩后马上重开、又很快关闭”的救援主流程而言，这个窗口并不罕见。

### 修复建议

- 证据时间应围绕**本次退出**约束，而不是只落在“现在前 3 分钟”：优先使用 `lastSeenAt/detectedAt` 限定前后小窗，并保留 WER 异步写盘的补偿机制。
- 近期事件若已消费同一 `RecordId`，不得无说明地再次作为另一次退出的崩溃证据。
- 有 `ExitCode=0` 且证据仅来自时间窗时，应降级为“不确定/弱关联”，不能套用“任何信号都不许覆盖”。
- app 匹配增加 exe 名称边界；能读结构化字段时优先结构化字段。
- 增加反向测试：前次崩溃 1000 + 后次退出码 0，后次不得判 crash-suspected。

---

## SE-2（P2）：UI 的“先见者胜”与事实记录的“后写覆盖”冲突

### 数据事实

同一事件 id 在 `sentinel-events.jsonl` 中可能依次出现：

```text
diagnosing → 最终 verdict → dump 回填/verdict 升级 → recovered
```

- sentinel 的 `Sync-Pending` 在 `errwatch-sentinel.ps1:849-857` 按 id 后写覆盖，使用最新记录，正确。
- UI 的 `Get-SentinelRows` 在 `errwatch-ui.ps1:236-256` 却对首个非 diagnosing 记录写入 `$seen`，后续同 id 记录全部跳过。

### 实测

直接调用包内真实 `Get-SentinelRows`，输入上述四条同 id 记录：

```text
rows=1
UI row Raw.verdict=unknown-exit; Raw.dumpPath=
latest appended fact verdict=recovered
```

即：事实已经归位，UI 行仍是最初的 `unknown-exit`；行的 `Raw` 也不含后补的 `dumpPath`。

### 影响

- `Update-DumpLinks` 已把“进程消失”升级成“崩溃”，主列表仍可能显示“进程消失”。
- `Invoke-RecoveryCheck` 已追加 `recovered`，主列表仍显示原来的“崩溃/进程消失”。
- `Get-SentinelStateLabel` 和 `Get-SentinelHuman` 虽写了 `recovered` 文案，但在这条去重路径上很难真正显示出来。
- `Render-DetailForRow` 在 `errwatch-ui.ps1:1772` 直接消费该旧 `Raw`，详情里的证据、dump 路径、快照解析也受影响。

### 同源展示问题 SE-2a

`errwatch-ui.ps1:1775-1777` 对所有哨兵行统一写：

```text
进程消失（哨兵观测）
```

即使 verdict 已是 `crash-suspected` 或 `recovered`，详情标题仍不变。修 SE-2 时应一并改成按最新 verdict 生成标题。

### 修复建议

- 先按 id 合并全部原始记录（后写覆盖），再由最新记录生成行与 Raw；`diagnosing` 只在没有任何最终记录时按超时规则处理。
- 保留现有 `SentinelRaw` 全量收集，用于快照桥接与反复崩溃计数。
- 详情标题复用同一个状态标签实现，禁止再写死“进程消失”。
- 增加 UI 数据层测试：`unknown-exit → crash-suspected → recovered`，最终行必须显示 recovered，Raw 必须含 dumpPath。

---

## SE-3（P3）：批量归位绕过单事件的 24 小时年龄限制

`core/recovery.ps1:80-88` 明确规定：事件超过 `MaxAgeHours`（默认 24 小时）不自动归位。

但 `Select-ErrwatchRecoveryBatch`：

- `core/recovery.ps1:227-236` 收集同 app 所有未终态崩溃，只选最新一条做判定；
- `core/recovery.ps1:246-248` 只对这条最新事件调用年龄检查；
- `core/recovery.ps1:250-253` 一旦最新事件可恢复，却把 `$open` 中所有 id 放进 `EventIds`。

### 实测

输入：48 小时前崩溃 `old48h`、1 小时前崩溃 `new1h`，以及一个已稳定运行 10 分钟的新实例：

```text
batches=1; EventIds=old48h,new1h; Code=recovered
```

48 小时旧事件随最新事件一起被归位，与“更早的不自动处理”不符。

### 修复建议

- 在组成 `open` 或 `EventIds` 前逐条执行 `MaxAgeHours` 过滤；或
- 明确把契约改为“同 app 最新恢复可批量关闭历史崩溃”，并删除单事件 24 小时承诺。
- 推荐前者：保留老事件让人工处理，避免自动动作扩大范围。

---

## SE-4（P3）：ACK 读窗口与保留策略存在自指缺口

`core/ack-state.ps1:65-74` 默认只读 ACK 文件末尾 4000 行。哨兵与托盘使用同一窗口，这是一致性上的优点。

但保留策略的输入也是这个截断后的 map：

- `core/retention.ps1:40-83` 只能为 map 中可见的 id 制定清理计划；
- 文件清理虽然扫描全部行，却只删除计划中的 id；
- 因而一旦某事件的 ACK 已滚出 4000 行窗口，它的终态既读不到，也无法因“终态超期”被纳入清理。

### 实测

构造 4001 行 ACK：第一行是 8 天前已进入 acknowledged 的事件，后接 4000 行其他记录：

```text
old id visible in read map=False; retention DropIds=0
eventsRemoved=0; acksRemoved=0; events remain=True
```

### 影响（有吞吐前提，不是默认必现）

- 对应事件若仍在 events 读取范围内，可能因终态不可见而重新进入 pending；
- 事件与 ACK 都可能长期留在文件中，成为清理不到的僵尸数据；
- 保留策略头注释称已解决“读窗口溢出导致复活”，实际只在 4000 行吞吐以内成立。

### 修复建议

- 保留计划不能只依赖截断视图：至少对 events 中仍存在的 id 做全量/索引化 ACK 查询。
- 给 `Get-ErrwatchAckState` 增加 `truncated` 标志，doctor 在接近窗口时预警。
- 更稳妥的长期方案是定期压缩 ACK：每个 id 只保留各维度最新行及必要审计信息。

---

## SE-5（P3）：RecordId 关联链按 Int32 处理，但系统类型是 Int64

实测 .NET 类型：

```text
System.Diagnostics.Eventing.Reader.EventRecord.RecordId
= System.Nullable<System.Int64>
```

当前链路却使用 `[int]`：

- `errwatch-sentinel.ps1:569`：`RecordId = [int]$best.RecordId`
- `errwatch-sentinel.ps1:1341-1343`：事件字段再次按 int 写入
- `core/dump-link.ps1:161-162,195-198,216-218`：强关联比较也按 int TryParse

### 实测

给真实 `Get-ExitEvidence` 注入合法 Int64 值 3000000000：

```text
high RecordId error: 无法将值“3000000000”转换为类型“System.Int32”。
错误:“值对于 Int32 太大或太小。”
```

在哨兵调用路径中，这类异常会被当成取证失败处理，最终可能丢失本可使用的崩溃证据。大 ID 在当前机器上不常见，所以定 P3；但它是强关联主键，类型不应依赖“通常没那么大”。

### 修复建议

- RecordId 全链统一 `[long]` / `[int64]`，TryParse 同步改 Int64。
- 老数据是字符串时继续兼容，不做时间窗猜测。
- 增加 `3000000000` 边界单测。

---

## 本轮排除的疑似问题

1. **`[ordered]` 字典上的 Add-Member**：`errwatch-sentinel.ps1:1363` 注释称其会静默不生效，但 1395-1397 又使用它写 exitCode/exitIntent/quiet。纯 PS 5.1 实测这些字段能写入、序列化并从 JSON 读回，**不是 bug**；注释的机制描述可修正。
2. **dump-parse 时间换算**：本轮未重复报告；此前已实测 5.1 与 7 的结果一致。
3. **dump 快照关联**：`core/dump-link.ps1` 的 app+pid+时间窗、RecordId 强关联、dump 内 pid 交叉验证、weak 明示与不一致丢弃，整体逻辑严谨，未发现新的错配路径。

## 建议补的 5 个回归用例

1. 前次同 app 的 WER 1000 + 后次 `ExitCode=0` 正常退出 → 后次不得被判 crash-suspected。
2. 同 id 依次写 diagnosing/final/dump-upgrade/recovered → UI 行与详情必须使用最新记录。
3. 48h 旧崩溃 + 1h 新崩溃 + 健康新实例 → 批量归位不得包含 48h 旧事件。
4. ACK 超过 4000 行且最老终态已超保留期 → 不复活、可清理，并报告截断状态。
5. RecordId = 3000000000 → 证据仍可关联，dump 强匹配不抛错。

## 总结

本轮问题不是“单个函数不会工作”，而是两类边界：

- **证据的身份边界**：时间窗近似关联被赋予了过强的结论优先级；
- **状态的版本边界**：事实记录已经追加新状态，UI 却继续读旧版本；批量动作与保留策略则没有逐条遵守自己的边界。

建议优先修 **SE-1、SE-2**：前者会制造假崩溃，后者会把已经修正/归位的事实继续显示成旧状态。修完再补上述反向用例，现有“全绿”才能覆盖这条数据流。
