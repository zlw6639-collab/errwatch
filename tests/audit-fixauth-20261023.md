# 修复器授权链审计（2026-10-23）

> 来源：外部终审 §五.P0.1「修复器与建议之间的授权一致性」
> 性质：**审计**（读代码找绕过），**不是建设** —— 本文件不提出新机制，只记录核对结果与发现
> 方法：**静态核对**（全文读 + grep 交叉验证）。**未做动态验证**的项目在文末逐条声明。

---

## 一、授权链全貌

```
UI 双击行（errwatch-ui.ps1）
 ├─ 「复制命令」→ 剪贴板两行：
 │     & check.ps1  -App <程序> -Code <错误码>
 │     & repair.ps1 -App <程序> -Code <错误码>
 └─ 「生成一键检查.cmd」→ 写一个 .cmd（GBK 编码）：
       powershell.exe(5.1) … -File check.ps1  -App <程序> -Code <错误码>
       echo === 下面进入修复（会先问你，只做可逆动作）===
       powershell.exe(5.1) … -File repair.ps1 -App <程序> -Code <错误码>
       pause
                ↓
errwatch-repair.ps1 -App <程序> -Code <错误码>
  ① 打印规则建议（Why / Do，原文照抄）
  ② Match-App → apps.json 的 logs → 展开环境变量
       · 是目录 → 取该目录下最大的 **3 个**日志（.log/.txt/.jsonl/.out/.err）
       · 是文件 → 直接看
  ③ > ThresholdMB（默认 50）的列为「可修」，打印**实际文件路径** + 风险文案
  ④ Read-Host y/N（`-Yes` 可跳过）
                ↓
errwatch-fix.ps1 -Action log-rotate -Path <上一步的文件> -Commit
  Mutex → -Force 动作闸门 → 安全模式闸门 → Plan → 高风险确认 → switch 分支
```

**UI 唯一能触发的写操作是 `log-rotate`**：repair 明确不自动重启服务（第 142 行注释、第 157 行只打印提示）。

---

## 二、四项核对结论

### ① UI 中确认的目标 vs 实际执行目标

| 维度 | 结论 |
|---|---|
| 目标来源 | repair 从 `apps.json` 的 `logs` 推导，**不是** UI 显示的那个错误 |
| 用户可见性 | ✅ **好**：执行前把**实际文件全路径**逐条打印（repair 106–110 行），再要 y/N |
| 数量 | 目录情况下一批最多 3 个文件，可能全部轮转 |
| 口径 | ⚠️ UI 窗口标题是「修复方案」，正文讲的是**某个错误码**的原因/建议 —— 用户容易理解成"这是在修那个错误"，实际动作是"该程序日志目录里超过 50MB 的日志轮转" |

> 判定：**目标本身没有错位**（用户能在 y/N 之前看到确切路径），但**表达口径不一致**（见 P2-2）。

### ② 生成的 `.cmd` 是否保留必要参数与风险提示

| 检查项 | 结论 |
|---|---|
| 风险提示 | ✅ rem 段写明「前三步只读」「修复阶段先问、先备份、可回滚」「用完可删」 |
| 交互确认 | ✅ 不带 `-Yes`，repair 会 `Read-Host` 问一次 |
| 解释器选择 | ✅ 用系统自带 `powershell.exe` 5.1（规避 pwsh 缺失；BOM 门禁已保证兼容） |
| 参数完整性 | ✅ `-App` / `-Code` 均传入；`-ThresholdMB` 用默认 50MB（合理） |
| 编码 | ✅ 用 GBK(936) 写 .cmd，中文注释不乱码 |
| **转义** | ❗ 程序名 / 错误码**直接字符串拼接**，无转义 —— 见 P1-2 |

### ③ `-Force` / `-Commit` / `-IUnderstandRisk` 组合绕过

**未发现绕过。** 逐项：

| 检查 | 位置 | 结论 |
|---|---|---|
| `-Force` 是否通用绕过开关 | fix.ps1:162 | ✅ 非 `log-rotate` 直接 `Fail` |
| `-Force` 是否绕过 `-Commit` | fix.ps1:261-267 | ✅ 只绕**扩展名白名单**，仍需 `-Commit` 才执行 |
| `-IUnderstandRisk` 是否被当成万能钥匙 | fix.ps1:244 | ✅ 仅在 `Risk=high` **且** `-Commit` 时被要求，不构成放行 |
| `-AllowSafeMode` 是否可无 `-Commit` 生效 | fix.ps1:170 | ✅ 仅 `-Commit` 时检查；演练不受限（合理） |
| 执行前审计是否 fail-closed | 175/248/315/386/444/499/613 | ✅ 均为 `-Critical`，审计写不进去即拒绝执行 |
| `-Force` 是否留痕 | fix.ps1:266 | ✅ 记 `force-override`（但未加 `-Critical`，见 P2-4） |

### ④ STOP / 审计失败 / 执行前环境变化的覆盖

| 动作 | STOP 急停 | 审计失败 fail-closed | 执行前 Revalidate |
|---|---|---|---|
| `log-rotate` | ✅ 329（清空前） | ✅ 315 `-Critical` | ✅ 304 |
| `config-fix` | ❌ **无** | ✅ 386 `-Critical` | ✅ 384 |
| `rescan-devices` | ❌ **无** | ✅ 444 `-Critical` | ⚠️ 调用了，但 `Test-Revalidate` 的 `default` 分支返回 `null`（实为空转） |
| `restart-service` | ❌ **无** | ✅ 499 `-Critical` | ✅ 497 |
| `restart-process` | ❌ **无** | ✅ 613 `-Critical` | ✅ 609 + 逐目标复验 619（防 PID 复用） |

---

## 三、发现

### P0-1 · STOP 急停只覆盖 1/5 个动作（**确定**）

`Test-Stop` 定义在 fix.ps1:112，**全文唯一调用点是 329 行**（log-rotate 第 2 步、清空前）。

grep 证据：

```
Line 112: function Test-Stop {
Line 329:         try { Test-Stop } catch {
```

→ `config-fix` / `rescan-devices` / `restart-service` / `restart-process` **没有任何急停检查点**。

**影响**：`restart-process` 在循环里逐个结束进程（616–624 行），中途放入 STOP 文件**不会中断**，会继续把快照里的目标全部杀完；`restart-service` 的停→起之间同样无法中断。

**与承诺不符**（这不是"没做"，是"说了没做到"）：

| 位置 | 原文 |
|---|---|
| README.md:83 | `aborted` = 「急停回滚」 |
| 定位.md:16 | 「必须替他挡危险（演练优先 / fail-closed / **急停**）」 |
| 定位.md:28 | 「危险动作默认不许。演练优先、审计写不进去就拒绝执行、**STOP 急停**」 |
| fix.ps1:111 | 注释「急停：创建 STOP 文件即可中断（**在步骤之间检查**）」 |
| 前次审计 | `audit-submission-20261022.md:87` 把「急停 STOP 文件」列为**值得肯定的机制** |

**证据等级**：静态确定（调用点缺失是客观事实）。**未做动态验证**（需真杀进程/真重启服务）。

### P1-1 · 审计只记「开始执行」，不记「执行结果」（**确定**）

`fix-audit.jsonl` 中 `result` 字段的全部取值：

```
safemode-override · risk-acknowledged · force-override · execute
```

`Done()`（fix.ps1:100）与 `Fail()`（fix.ps1:92）**只 `Write-Host` + `exit`**，都不写审计。

→ 事后查 `fix-audit.jsonl`，**无法回答"那次到底修成了没有"**：`verified` / `partial` / `verify-failed` / `rolled-back` / `aborted` 这些终态一个都没落盘。

**影响**：审计记录的证明力打了折扣 —— 记录了"动过手"，没记录"手动的结果如何"。

### P1-2 · UI 生成命令时未转义（**静态核对，未动态验证**）

| 位置 | 代码 |
|---|---|
| ui.ps1:748-749 | `'… -App "' + $row.程序 + '" -Code "' + $row.错误码 + '"'`（剪贴板） |
| ui.ps1:792 | 同上，写入 `.cmd` |
| ui.ps1:798 | 同上，写入 `.cmd` |

`$row.程序` / `$row.错误码` 直接拼进 PowerShell 命令行与 `.cmd` 文本，**无任何转义**。

- 含 `"` → 引号配对被破坏，参数可能被截断或注入
- 含 `%` → **`.cmd` 里会被 cmd 做变量展开**（如 `%PATH%`）
- 含 `&` / `|` → 在引号内相对安全，但引号一旦被破坏即失守

**数据来源**：程序名来自事件日志/上报（`errwatch-report.ps1 -App` 也可由人写入任意字符串）。正常情况下形如 `VRChat.exe`，风险低但不为零。

**证据等级**：静态核对确定的**代码事实**；**未动态验证**注入是否真能触发（需伪造事件日志或主动上报恶意 App 名）。

### P2-1 · repair 的风险文案是硬编码，会与 ActionContract 漂移

repair.ps1:108-109 自己写着「处理方式：轮转…」「风险：低（可逆，备份不删）」，
而 fix.ps1 的契约（fix.ps1:184）把 `log-rotate` 标为 **`Risk = 'medium'`**。

→ 同一动作，**repair 说"低"，fix 的契约说"medium"**。两处文案独立维护，迟早分叉。

### P2-2 · UI 文案口径与 repair 实际动作范围不一致

UI 窗口叫「修复方案」，正文是**某个错误码**的【原因】【建议】；repair 实际做的是**该程序日志目录**里超 50MB 的日志轮转。用户点「修复」时的心理预期是"修这个错误"。

### P2-3 · `rescan-devices` 的执行前复验是空转

fix.ps1:442 调用了 `Test-Revalidate 'rescan-devices'`，但该函数（209–239）的 `default` 分支直接 `return $null` —— 即**没有实际复验**。该动作风险 `low`，可接受，但代码读起来像"已经复验过了"，属于**语义误导**。

### P2-4 · `force-override` 审计未加 `-Critical`

fix.ps1:266 的 `Write-Audit … 'force-override'` 没有 `-Critical`，审计写失败只警告。
考虑到它发生在**演练也可能走到**的路径上，可接受；但它记录的是"用户绕过了白名单"这一事实，是否该 fail-closed 值得再想。

---

## 四、已核对、未发现问题的项（正面清单）

| 机制 | 位置 | 核对结果 |
|---|---|---|
| 并发锁 | 148-157（命名 Mutex） | ✅ 内核互斥，进程退出自动释放；全脚本体在 `try/finally` 内 |
| `-Force` 范围限制 | 162 | ✅ 非 log-rotate 一律拒绝 |
| 扩展名白名单 | 259-267 | ✅ 只放行日志类扩展名 |
| 安全模式闸门 | 169-176 | ✅ 默认拒绝执行，覆盖需显式 `-AllowSafeMode` 且记审计 |
| 高风险强制确认 | 244-249 | ✅ `Risk=high` + `-Commit` 必须带 `-IUnderstandRisk` |
| 执行前复验 | 209-239 / 304/384/497/609 | ✅ 4 个写操作均有；`restart-process` 另加逐目标 `StartTime` 复验防 PID 复用 |
| 会话隔离 | 592-598 | ✅ 拒绝操作非当前会话的进程 |
| 通配符拒绝 | 473（服务）/ 549（进程） | ✅ `-Name` 不支持 `*?` |
| 多实例保护 | 560-576 | ✅ 同名多实例默认拒绝，推荐 `-ProcId` |
| 启动命令校验 | 551-556 | ✅ `-Path` 仅允许 `.exe/.bat/.cmd/.ps1` |
| 备份先于清空 + SHA-256 校验 | 303-326 | ✅ 校验失败则**不清空**并删掉坏备份 |
| 回滚区分成败 | 293-301 等 | ✅ 区分「已恢复 / 恢复失败」，不笼统报"已回滚" |
| WriteGuard 缺失处理 | 368-370 | ✅ fail closed，且明确说明"其余动作不受影响" |

---

## 五、未做的验证（边界声明）

本文结论**基于静态核对**。以下项目**没有**动态验证，不得当作已验证：

1. **STOP 在新动作下确实无效** —— 需真跑 `restart-process` / `restart-service` 并中途放 STOP 文件；本机未做（代价与风险都高）。
2. **命令注入是否真能触发** —— 需伪造事件日志或 `-App` 上报恶意字符串。
3. **安全模式 / 非管理员 / 5.1 环境下的实际行为** —— 均未实跑。
4. **`config-fix` 全链路** —— WriteGuard 不随包分发，本机无该组件，未验证委托行为。
5. 本文**未改动任何代码**，只记录核对结果与发现。

> 与前两份审计的关系：本文是「修复器授权链」专项，与 `audit-external-20261023-终审.md`（整体终审）、`audit-submission-20261022.md`（首份送审包）互相独立，结论不替代。

---

## 六、整改记录（2026-10-23 晚）

| 发现 | 状态 | 做法 | 验证 |
|---|---|---|---|
| **P0-1 STOP 只覆盖 1/5** | ✅ 已修 | 新增 `Test-StopRequested`（不抛异常版）。5 个写动作全部埋点：`config-fix`（执行前）、`rescan-devices`（扫描前）、`restart-service`（停止前 + 启动前；**已停时先启动回去再报告**，不让服务停在半路）、`restart-process`（逐个目标之间，并报告"已结束几个、还剩几个没动"） | `tests\test-fixauth.ps1` ④ 静态断言 ≥5 处 |
| **P1-1 审计不记终态** | ✅ 已修 | `Done()` / `Fail()` 都调 `Write-Audit`（非 Critical，写失败不改变结果），落盘 `verified / partial / verify-failed / rolled-back / aborted / refused`；`ERRWATCH_AUDIT_PATH` 供测试重定向，不污染真实 `fix-audit.jsonl` | `test-fixauth.ps1` ③ 实测拒绝路径落盘 `result=refused` |
| **P1-2 UI 未转义** | ✅ 已修 | 新增 `ConvertTo-ErrwatchPsArg`（**单引号** + `''` 双写，单引号内 PS 不展开 `$`/`` ` ``）。`.cmd` 无法可靠转义（cmd 只认双引号）→ 新增 `Test-ErrwatchCmdUnsafe`，含 `" % & \| < > ^ 换行` 时**拒绝生成**并提示改用「复制命令」（fail closed，而不是字符串替换假装安全） | `test-fixauth.ps1` ①②⑤ |
| P2-1 repair 风险文案与契约漂移 | ✅ 已修 | 契约移到 `core\action-contract.ps1`（**唯一实现**），repair 与 fix 都从 `Get-ErrwatchRiskText` 取文案；repair 不再硬编码「低」 | `test-fixauth.ps1` ⑥ |
| P2-2 UI 文案口径 | ✅ 已修 |「修复方案」窗口开头加三行边界说明：只做「查 + 生成方案」；能自动处理的只有日志轮转；其它按建议人工处理 | UI 文案 |
| P2-3 rescan 复验空转 | ✅ 已修 | `Test-Revalidate` 增加 `rescan-devices` 分支：检查 `pnputil` 是否可用，缺失则拒绝 —— 不再走 `default` 假装复验过 | `test-fixauth.ps1` ⑦ |
| P2-4 `force-override` 未 `-Critical` | ✅ 已修 | 加 `-Critical`：绕过白名单这件事写不进审计就拒绝执行 | `test-fixauth.ps1` ⑧ |

**仍未做动态验证**（与原审计边界一致，不得当作已验证）：
1. STOP 在**真杀进程 / 真重启服务**下是否真的中断 —— 需真机执行，代价与风险都高。
2. 命令注入是否真能触发 —— 需伪造事件日志或恶意 `-App` 上报。
3. 代码层已 fail closed，但"没真跑过"这件事仍要写在明面上。

