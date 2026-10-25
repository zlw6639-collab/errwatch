# 审计：第四维「诊断进度」（2026-10-24）

> 用户拍板的核心一句：**诊断会话以固定开始时间计算绝对截止期限；可恢复的提前失败允许一次受控重试，
> 但重试不得重置截止期限；达到硬时限后终止采集、保留已有证据，并将最终结果写入报告状态。**
>
> 本记录按「先写规则、再改实现」的顺序：契约 §十 先定稿，代码后跟上。

## 一、为什么它不该和报告结论混在一起

第四维回答的是「**诊断流程**走到哪一步」，不是「诊断结论是什么」。

- 结论仍由 `core\diagnose-contract.ps1` 的五态表达：`known / unknown / insufficient / conflict / collection-failed`
- `progress = complete` **只表示流程终结**（正常完成 / 超时 / 被中断 / 取证失败），**不表示诊断成功**
- 因此托盘文案里刻意**不出现「成功」**（`test-progress` H 用例直接断言这一点）

如果把这两件事混在一起，就会出现「诊断完成了」被读成「系统没问题」—— 这正是本项目反复要防的误读。

## 二、契约（`STATE-CONTRACT.md` §十）

| 项 | 值 |
|---|---|
| 维度 | `progress`：`not-started`（默认）/ `collecting` / `complete` |
| 写者 | **sentinel**（取证前后）—— 第三类受控写者（另两类：recover 写 `rescue`、保留策略清理） |
| 会话字段 | `sessionStartedAt` / `maxDurationSeconds`（默认 600）/ `attemptCount`（首次=1，上限 2） |
| 截止时刻 | `sessionStartedAt + maxDurationSeconds` |
| 心跳 | **不延长**时限 |
| 重试 | 一次；**不重置** `sessionStartedAt`，只能用剩余时间 |
| 崩溃恢复 | 过期 → `complete + reason=timeout`；未过期 → `complete + reason=interrupted` |

**两种失败分开处理**（用户特别强调的）：

- 情况 A：取证提前失败 → 硬时限内允许**一次**重试
- 情况 B：到硬时限 → **不再重试**，也不重开一个完整窗口

**崩溃后为什么选「终结」而不是「重开」**：重试的意义是「补一次失败的取证」，而会话上下文在进程里；
进程没了，事件已入队、证据已落盘，重开一个新会话不等于重试 —— 那只会把 10 分钟无限续下去。
所以未过期的残留会话直接标 `interrupted`，不假装重试。

## 三、实现

| 文件 | 改动 |
|---|---|
| `core\ack-state.ps1` | `ackDimensions` 加 `progress`；ACK 行支持可选 `meta`；聚合出 `progress` + `progressMeta`；`New-ErrwatchAckRecord -Meta`；新增 `Get-ErrwatchDiagnosisLabel` |
| `core\progress.ps1`（新） | 会话四件套：`New-ErrwatchDiagnosisSession`（新建/受控重试）、`Test-ErrwatchDiagnosisExpired`、`Get-ErrwatchDiagnosisRemaining`、`New-ErrwatchDiagnosisCompleteMeta`、`Get-ErrwatchStaleDiagnosis`（崩溃恢复） |
| `errwatch-sentinel.ps1` | 取证从「事件构造前直接做」挪到「确认要发这条事件之后」，包进会话：`collecting` → 取证（失败可重试一次）→ `complete`；**启动时**扫描残留 `collecting` 并终结 |
| `errwatch-tray.ps1` | 菜单项追加诊断后缀（`诊断中` / `诊断超时（证据已保留）` / `诊断中断（证据已保留）` / `取证失败（结论不完整）`），正常完成不出文案 |

## 四、测试（`tests\test-progress.ps1`，10 项）

| 用例 | 证明什么 |
|---|---|
| A | 新建会话：`attemptCount=1`、截止 = 开始 + 时限 |
| B | **重试不重置** `sessionStartedAt`，只拿到剩余时间 |
| C | `attemptCount` 永不超过 2 |
| D | 硬时限只看 `sessionStartedAt`（写入/重试都不能延长） |
| E | 剩余时间到 0 就不能再试 |
| F | 崩溃恢复：过期 → `timeout`；未过期 → `interrupted` |
| G | `progress` 变化**不改变** `lifecycle`（不变式 1） |
| H | `complete` 不代表成功（标签不出现「成功」） |
| I | `meta` 完整往返（写进去 → 读回来） |
| J | 哨兵真的接上了 + 契约 §十 存在 + 托盘真的显示 |

## 五、反证（测试会咬人）

| 反证 | 改了什么 | 结果 |
|---|---|---|
| 1 | 重试时把 `sessionStartedAt` 重置成当前时间 | **B 精确 FAIL**（9/10） |
| 2 | 去掉 `attemptCount` 上限 | **C 精确 FAIL**（9/10） |

## 六、真实链路（`tools\verify-retention-live.ps1`，9/9）

在真起哨兵、真杀进程的那条链路上新增两项：

```
[PASS] 真实事件写入了诊断会话（progress=complete）
[PASS] complete 带 reason（流程为什么结束，而不是诊断结论）
```

也就是说：第四维不是只活在单测里，**生产路径上真的写了**。

## 七、门禁

28/28 · 哨兵 16 · 托盘 16 · 契约 10 · 恢复机会 13 · 恢复 7 · 启动 7 · 保留策略 9 · 采集状态 11 ·
**诊断进度 10/10** · 真实链路 9/9 · 基线 **85/85** · lint FAIL 0。

## 八、剩余（诚实记录）

1. **`collecting` 的实际存活时间极短**：现在的取证就是查一次事件日志（毫秒级），
   所以肉眼几乎看不到「诊断中」。第四维的**真实价值要等出现耗时取证**（大目录扫描 / 证据包分析）时才显现 ——
   现在它是「语义与状态机先就位 + 崩溃恢复能兜住」。
2. **重试只覆盖「取证抛异常」这一种失败**。取证「返回空」是正常结果（`unknown-exit`），不重试。
3. **`interrupted` 的会话不会补证据**（事件已入队、证据已落盘，没有可重放的上下文）。
   若要支持「重放」，需要先把取证输入（事件上下文）持久化，那是另一件事。
4. 托盘的诊断标签依赖 `progressMeta` 能读回来 —— 若 acks 被外部截断只留半行，标签会退化（不显示），不会报错。
