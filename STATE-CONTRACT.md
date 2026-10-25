# 事件状态契约（STATE-CONTRACT）

> 2026-10-23 定稿。**先定语义，再改存储。**
> 起因：原来的 `tray-acks.jsonl` 是「一个事件一个 status」，`launched / acknowledged / expired`
> 混在同一个终态集合里，后写覆盖前写。于是「救援启动了」「用户确认了」「过期了」互相踩，
> 通知投递状态也会被当成事件处理状态。
>
> 一句话：**通知尝试过 ≠ 用户看见 ≠ 事件处理完 ≠ 救援启动 ≠ 恢复成功。**

## 一、三个维度（互不覆盖）

| 维度 | 取值 | 谁写 | 决定什么 |
|---|---|---|---|
| `lifecycle` | `open`（默认）/ `acknowledged` / `expired` | tray（用户操作 / 过期） | **事件是否还需要处理** |
| `notify` | `eligible`（默认）/ `attempted` / `failed` / `suppressed` | tray（通知循环） | 是否还要再弹；不决定事件去留 |
| `rescue` | `not-started`（默认）/ `launching` / `launched` / `launch-failed` / `user-confirmed` / `verified` / **`auto-recovered`** | tray（启动）+ recover（核验回写）+ **sentinel（自动归位）** | 救援走到哪一步；**`launched` 不等于恢复成功**；`auto-recovered` = 程序自己恢复运行了（我们**没做**救援） |
| `progress` | `not-started`（默认）/ `collecting` / `complete` | sentinel（取证时） | **诊断流程**走到哪一步；`complete` 只表示流程终结，**不代表诊断成功**（见 §十） |

## 二、终态定义（唯一的）

**只有 `lifecycle ∈ {acknowledged, expired}` 是终态。**

`progress = complete` **不是**事件终态，只是「这次诊断流程结束了」—— 事件仍需用户处理（见 §十）。

- `notify = attempted` 不是终态（通知投递过 ≠ 用户看见）
- `notify = suppressed` 不是终态（全屏/静默，退出全屏后还能补）
- `rescue = launched` **不是**终态（窗口起来了，内容还没核验）
- `rescue = launch-failed` 不是终态（更要留在待处理里）
- `rescue = auto-recovered` **必须伴随** `lifecycle = acknowledged`（见 §八.1 的不变式）—— 它自己不是终态，真正让事件离开待处理的是 lifecycle

> **`auto-recovered` 的语义（2026-10-25，用户提出）**：程序崩溃后**自己又恢复运行了**
> （崩后新起的实例活够 60 秒，或崩后新实例以退出码 0 正常关闭）。
> 它证明的是「程序能用了」，**不证明**「崩溃原因查清了」—— 所以它是归位信号，不是诊断结论。
> 多实例应用（崩溃时还有兄弟实例在跑）与 `unknown-exit`（可能是被强杀）**不**自动归位。

> 这条是本次改造的核心：`launched` 以前被当成终态，导致「点了救援但没救回来」的事件直接消失。

## 三、存储格式（JSONL，append-only）

```json
{"id":"<事件ID>","dimension":"lifecycle|notify|rescue","value":"<取值>","at":"<ISO 时间>"}
```

- 同一 `id` + 同一 `dimension`，**后写覆盖前写**（读的时候按顺序聚合）
- 不同维度之间**永不互相覆盖**
- 文件只追加，不重写；**例外：保留策略清理时整文件原子重写**（见 §九）

## 四、旧数据映射（兼容）

改造前写入的行没有 `dimension` 字段。读取时按下面的映射解释，**不做文件迁移**：

| 旧 `status` | 解释为 |
|---|---|
| `acknowledged` | `lifecycle = acknowledged`（终态） |
| `expired` | `lifecycle = expired`（终态） |
| `attempted` / `failed` / `suppressed` | `notify = 同名值` |
| `launching` / `launched` / `launch-failed` | `rescue = 同名值` |

⚠️ **行为变化**：旧数据里 `launched` 的事件，现在会**重新出现在待处理里**（因为它不再是终态）。
这是有意的 —— 那些事件其实没有核验过。若嫌吵，让它们按 `expired` 自然淘汰（30 分钟）。

## 五、重建规则（pending 是投影）

1. 事实来源：`sentinel-events.jsonl`（事件本身）
2. 状态来源：`tray-acks.jsonl`（四维度聚合后的最新值）
3. `pending = 所有事件 − lifecycle 终态的事件`（**不按事件发生时间丢弃**；终态事件由 §九 的保留策略在「进入终态满 7 天」后清理。超过 7 天仍待处理的事件只记 `integrity.staleOpen` 供观测，见 §九）
4. 损坏的 pending 文件：先备份成 `.corrupt-<时间戳>`，再从 1+2 重建
5. `events.jsonl` 里的坏行：跳过并计数（`integrity.droppedLines`），不阻断整体
6. 同一程序 24 小时内重复的 `unknown-exit`（正常关闭也会产生）在投影里**只留一条**，折叠数记 `integrity.droppedQuiet`；事件事实仍全留在 `events.jsonl`（2026-10-24 外部审查后加入）

## 六、谁来写（单一写者）

| 文件 | 唯一写者 |
|---|---|
| `sentinel-events.jsonl` / `sentinel-pending.json` / `sentinel-coverage.json` / `opportunity.json` | `errwatch-sentinel.ps1` |
| `tray-acks.jsonl` | `errwatch-tray.ps1`（recover 通过托盘转交，不直接写） |
| `tray-acks.jsonl` 的 `rescue` 维度 | 例外：`recover.ps1` 在用户核验后可追加（带 `-EventId`）；**sentinel 在自动归位时写 `rescue = auto-recovered` + `lifecycle = acknowledged`**（它只需要看进程，不需要用户参与） |

> recover 直接写 acks 是**受控的例外**：只在「有 `-EventId` + 非交互核验」时写，且只写 `rescue` 维度。

## 七、不变式（测试要盯的）

1. 任何 `notify` 变化都不改变 `lifecycle`
2. 任何 `rescue` 变化都不改变 `lifecycle`（除了两处显式例外：用户明确确认时、以及 **sentinel 自动归位时**同时写 `acknowledged`）
3. `lifecycle` 一旦终态，不会再回到 `open`（读的时候忽略后续的同维度写入）
4. 同 `id` 的三维度可以同时存在，互不覆盖
5. 一个事件从 `open` 到终态，**至少**经过一次用户操作或过期，不会因为通知失败/救援启动而消失
6. 通知失败（`notify=failed`）的事件仍然可以进入救援
7. `progress` 的任何变化都不改变 `lifecycle`，也不表示诊断成功
8. 重试**不重置** `sessionStartedAt`（绝对时限不变），`attemptCount` 永不超过 2
9. 达到硬时限后，同一个 id 不再出现新的 `collecting`

## 八、已知取舍

- **不做数据库**：JSONL + 内存聚合足够，且可审计（能看见每一次状态变化）
- **不做状态回滚**：只追加不删；错写只能靠后续写入覆盖
- **不做跨事件事务**：一次只保证一个事件内部一致
- **`verified` 只由 recover 写**：托盘不替用户判断「恢复成功」

### §八.1 救援自检的三档判定（2026-10-25 定稿）

> 补这一节的原因：状态机盘点（`tests\audit-state-machine-20261025.md` S1 / S3）查出
> 契约说「用户明确确认时显式写 `acknowledged`」，而 `errwatch-recover.ps1` **一处都没写** ——
> 表现是用户核验完、事件还挂在待处理里；同时判据只有两档，
> **一项都没确认**也会被记成 `user-confirmed`（「你自己确认救回了」）。

用户做完救援后逐项勾自检（`recover` 的 `verify` 列表），判定**三档**：

| `$okN`（确认项数） | 写什么 `rescue` | 写 `lifecycle` 吗 | 用户看到的说法 |
|---|---|---|---|
| `0`（一项都没确认） | **不写** | **不写** | 什么都不说 —— 用户没确认救回，不能替他判断 |
| `1 .. n-1`（部分） | `user-confirmed` | **写 `acknowledged`** | 你自己确认救回了（部分项） |
| `n`（全部） | `verified` | **写 `acknowledged`** | 你逐项核对过 |

两条不变式随之收紧：

8. **`rescue ∈ {user-confirmed, verified}` 必须同时伴随 `lifecycle = acknowledged`**：
   用户明确确认了，这条对他就结束了。否则「确认过」和「还在待处理」同时成立 —— 自相矛盾。
9. **`$okN = 0` 不得写任何 `rescue` 终态值**：0 项确认 ≠ 确认救回。

> 注意 `expired` 是**系统超时**写的（30 分钟），不是用户操作 —— 它和 `acknowledged`
> 在「事件是否结束」上等价，但在**统计口径**上不等价（见盘点 S6）。

### §八.2 「verified」有三种含义（2026-10-25 定稿，S2）

> 状态机盘点把这条标成「一词三义」。**不改任何值**（改历史数据要迁移，风险远大于收益），
> 而是在每个语境给一句带限定的说法（唯一实现：`Get-ErrwatchVerifiedMeaning`）。

| 出现在哪 | 含义 | 说法 |
|---|---|---|
| `rescue = verified` | 用户在救援窗口里**逐项核对过**恢复文件 | 你逐项核对过恢复文件（rescue=verified） |
| `verifyStatus = verified` | **规则**被人工核验过（决定结论可信度=high） | 这条规则被人工核验过（verifyStatus=verified） |
| `fix 动作 = verified` | 修复动作完成且**断言验证通过**（带验证范围） | 修复动作完成且验证断言通过（fix=verified，附验证范围） |

三者**不共享字段**，所以数据层不会混淆；混淆只发生在「人读输出」时 —— 所以约束是：
**输出里出现 verified 时必须带语境限定**，禁止只写一个裸 `verified`。

## 九、保留策略（2026-10-24 定稿）


> 这一节补的是**契约早就承诺、代码一直没做**的那件事（原文写「按 7 天滚动」，实际两套口径：
> pending 按**事件发生时间**丢、acks 从不清理）。
> 计时起点：**事件进入终态的时间**（`lifecycle` 变成 `acknowledged` / `expired` 那一刻），
> **但如果终态之后还有人写**（notify 补发、rescue 补记），则改按**最后一次写入**计时（2026-10-25 修 S5）。
> 理由：那些"终态后发生的动作"确实发生过，按终态时间删会把它们一起抹掉，metrics 的窗口统计就缺样本。
> 终态后没人再写时两者完全相同 —— 所以这条改动**不会推迟**正常情况的清理。

| 场景 | 规则 |
|---|---|
| 已结束的事件 | 终态进入时间超过 7 天 → 清理事件记录及其**全部** ACK |
| 终态后还有写入 | 按**最后一次写入**计时（不是终态时间）—— 那些动作确实发生过 |'
| 仍待处理的事件 | **不清**，无论发生多久 —— 宁可留一条老事件，也不提前抹掉 |
| 同一事件的多条 ACK | 按 id **整组**清理，不能只删部分状态导致重建结果改变 |
| pending 重建 | 用保留后的事件与状态重建，已处理事件不会复活 |
| 日志损坏 | 单行坏只跳过并计数（`badEventLines` / `badAckLines`），不阻断整次清理 |
| 旧数据（终态行没有 `at`） | 不清（无法证明它够老，保守） |
| 没有 ACK 的事件 | 不清（没人处置过 = 还需要人看） |

**实现**：判定 `Get-ErrwatchRetentionPlan`、执行 `Invoke-ErrwatchRetention`，都在 `core\retention.ps1`（唯一实现）。

**谁执行**：`errwatch-sentinel.ps1` 每 **6 小时**最多清一次。

- 这是 `tray-acks.jsonl` 的**受控第二写者**：整文件读 → 过滤 → 写 `.tmp` → `Move` 替换，只在「确有终态超期」时发生。
- 并发保护：清理前后各取一次文件签名（长度 + 修改时间），托盘在清理期间追加 → **跳过本次** ACK 清理，下次再来。
- 每次清理的结果逐条追加到 `sentinel-retention.jsonl`（删了哪些 id、几行、是否跳过、坏行数），可审计。

**对 pending 的影响**：它不再是「7 天窗口」，而是「所有非终态事件」的投影。
超过 7 天仍待处理的事件记在 `integrity.staleOpen` 里**供观测，但不丢弃**。

**已知取舍（诚实记录）**：pending 投影仍保留「最多最近 100 条」的数量上限（防托盘菜单/气泡被撑爆）。
超出时最旧的事件退出**投影**，但它的记录与 ACK 仍在 jsonl 里，可从事实记录重建 —— 这与「因太旧而删除」是两回事。

## 十、诊断进度（第四维，2026-10-24）

> 它回答「对这个事件的**诊断流程**做到哪一步」，**不回答诊断结论**。
> 结论仍由 `core\diagnose-contract.ps1` 的五态表达（known / unknown / insufficient / conflict / collection-failed），
> 第四维**不重复承担结果判定**。

| 维度 | 取值 | 谁写 | 决定什么 |
|---|---|---|---|
| `progress` | `not-started`（默认）/ `collecting` / `complete` | sentinel（取证时） | 诊断流程走到哪一步 |

**`complete` 只表示本次诊断流程终结**（正常完成 / 超时 / 被中断 / 取证失败），
**不表示诊断成功**，也不写入任何结论字段。

### 会话字段（写在同一条 ACK 的 `meta` 里）

```json
{"id":"<事件ID>","dimension":"progress","value":"collecting","at":"<ISO 时间>",
 "meta":{"sessionStartedAt":"<ISO 时间>","maxDurationSeconds":600,"attemptCount":1}}
```

- `sessionStartedAt`：本次诊断会话的**固定**开始时间（重试不变、进程重启后恢复原值）
- `maxDurationSeconds`：绝对时限长度（默认 600 秒）
- `attemptCount`：已开始的尝试次数（首次 = 1，最多 2）

### 绝对时限（用户 2026-10-24 拍板）

- 截止时刻 = `sessionStartedAt + maxDurationSeconds`
- **心跳不能延长它**：心跳只说明进程活着，不说明诊断在推进
- **重试不重置 `sessionStartedAt`**：重试只能用**剩余时间**，不能重新获得完整 10 分钟
- `attemptCount` 最多 2（首次 + 一次受控重试）

### 两种失败必须分开

| 情况 | 规则 |
|---|---|
| **A 提前异常退出**（取证调用抛异常/返回失败） | 在硬时限内允许**一次**受控重试（`attemptCount` → 2），仍受**原**时限约束 |
| **B 达到硬时限** | 立即终结：写 `complete` + `meta.reason = timeout`，**不再重试**，不重开完整窗口 |

### 崩溃恢复（进程在 `collecting` 时被杀）

重启后按 `sessionStartedAt` 判断：

- 已过绝对时限 → 写 `complete` + `reason = timeout`（保留已有证据）
- 未过时限 → 写 `complete` + `reason = interrupted`
  （事件已进事实记录、证据已落盘，**没有可重放的上下文**，所以不假装重试）

> 这里选「终结」而不是「重开一个 10 分钟」，因为重试的全部意义是「补一次失败的取证」；
> 诊断会话的上下文在进程里，进程没了，重开一个新的会话不等于重试。

### 谁写

`errwatch-sentinel.ps1` 在**取证前后**写：`collecting`（带会话）→ `complete`（带 `reason`）。
这是 `tray-acks.jsonl` 的第三类受控写者（前两类：recover 写 `rescue`、sentinel 保留策略清理）。

### 不变式（测试要盯的）

1. `progress` 的任何变化都不改变 `lifecycle`
2. 重试不改变 `sessionStartedAt`
3. `progress = complete` 不代表成功（不写结论字段）
4. `attemptCount` 永不超过 2
5. 达到硬时限后，同一 id 不再出现新的 `collecting`

## 十一、有限自动兜底（2026-10-24）

> 一句话：**超时不等于授权。** 用户没回应时，系统只做「让它更显眼」和「留下记录」，
> 不做任何会改变文件或进程状态的动作。

| 项 | 规则 |
|---|---|
| 决策时限 | `deadlineMinutes`（默认 30；可在 `settings.json` 改，范围 5–1440） |
| 计时起点 | 事件**被发现的时间**（`event.time`），不是用户上次看到的时间 |
| 到期允许的动作 | `notify-only`（升级提示）/ `open-ui`（打开主窗口） |
| 到期**禁止**的动作 | 删除 / 覆盖 / 移动文件、强制结束进程、重启系统、改系统设置 —— **任何情况下都不自动做** |
| 审计 | 每次升级写一条 `tray-fallback.jsonl`（事件 id、app、已过分钟、动作、原因） |
| 去重 | 同一事件只升级一次；用户处理后（lifecycle 终态）不再升级 |

**为什么把「配置也开不了」写死**：§二 的边界是「超时不能变成无限授权」。
如果允许用户在配置里打开「到期自动结束进程」，这条边界就成了一句空话 ——
一旦误判（进程只是暂时无响应、或用户其实在别的桌面工作），损失不可撤销。
所以本版把**动作白名单写进代码**，配置只能选「提示方式」，不能扩大动作范围。

**升级提示长什么样**：
- 托盘菜单该事件加标记「⏰ 已超时 N 分钟未处理」
- 发一次气泡（受全屏/静默策略约束）
- 审计一行

**与第四维的区别**：第四维管「诊断流程跑到哪」，本节管「用户多久没回应」。两者互不覆盖。

**不变式**：
1. 到期动作只能是白名单内的（`notify-only` / `open-ui`）
2. 同一事件不会因为「再过一段时间」而获得更强动作
3. 用户处理后（`lifecycle` 终态）不再升级
4. 每条升级都有审计记录（可按 id 查）
