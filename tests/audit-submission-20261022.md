# errwatch 送审包审计（2026-10-22 晚，第三方复核）

> 审计对象：`E:\ai\_dist\errwatch-20261022-送审包.zip`（194 KB，58 条目，SHA256 `102d4abf…75d389`）
> 审计方式：解包核对 + 哈希基线验证 + 静态代码审查 + **关键问题均在本机实测复现**（非推断）
> 结论先行：**声明体系基本可信、架构质量高，但两个 P0 缺陷带病出场**——均为"真机实测之后又改代码、改完没重跑回归/没重跑 BOM 检查"造成。修复成本低。

---

## 一、P0：两处实测复现的缺陷

### P0-1 主入口 `errwatch.ps1` 无 BOM → PowerShell 5.1 下语法崩

**证据（实测）**：
- 21 个 `.ps1` 中 20 个有 BOM，唯独 `errwatch.ps1` 没有。
- 把该文件按 GBK（= PS 5.1 对无 BOM 文件的解码方式）解码后送语法解析器：**12 处语法错误**（第 71/150/151/211/284 行等，`}` 与 `else` 意外标记——正是中文吃引号的症状）。
- 包内文件与 `E:\ai\_tools\errwatch\errwatch.ps1` **字节一致**，即源目录同样带病。

**影响**：README 明文「没有 pwsh 就回退 powershell.exe 5.1」。安全模式恰恰只有 5.1（HANDOFF 自己写的：商店版 pwsh 在安全模式不可用）→ **主入口（全量 7 节报告）在安全模式下必崩**。UI / 计划任务兜底启动的都是带 BOM 的脚本（evidence / source / query / notify），所以雷只限手动跑 `errwatch.ps1` 的场景——但这正是 HANDOFF「怎么继续」的第一条命令。

**为什么没被抓到（机制性根因）**：
- 文件时间线：`errwatch.ps1` 20:23 修改，晚于 20:19 的安全模式真机实测 → **实测结论不适用于当前文件**。
- `ensure-bom.ps1` 是工作流第 8 条原则里的**手动步骤**，20:23 改动后没人重跑（ensure-bom 本身 20:10 未再动过）。
- `errwatch-doctor.ps1` **不做 BOM 自检**（grep 无 bom 字样）→ 全工具链没有任何自动防线。

**修复**：`pwsh -File tools\ensure-bom.ps1` 一条命令 + 把 BOM 校验纳入打包脚本（缺 BOM 拒绝打包，见建议 R1）。

### P0-2 `runners/L3-collect.cmd` 第 5 节磁盘采集已坏（缺开括号）

**证据（实测）**：第 5 节结构为：

```
if "!HAS_DISKPART!"=="0" goto skip_disk
    echo list disk          ← 不在括号块内
    …
) > "%TMPITEMS%\dp.txt"     ← 没有配对的开括号
```

用同结构最小用例在 cmd 实测：echo 内容**全部打到控制台**，`) > file` 被静默忽略，**dp.txt 根本不会创建**。后果：`diskpart /s 不存在的文件` → disk.txt 只会装着错误信息，而 manifest 仍会把它登记为 kind=disk 的条目（fail open——违背「失败也要如实记录」原则的第 6 条自己）。

**时间线（同样是被实测甩在身后）**：文件 20:59 修改，第二次 WinRE 实测是 20:53 → **「21 条目、disk/packages 全部采到」的声明针对的是修改前的版本**。20:59 那笔改动（修 `select disk` 顺手的）把开括号弄丢了。

**修复**：`if ... goto skip_disk` 之后补 `( ` 开括号（或改为 `(` 起始的显式块），改完必须在 WinRE 重测或至少本机 cmd 预演。

---

## 二、P1：流程与依赖

### P1-1 回归声明过期（违反自己的原则 8）

- `tests/last-run.json` 时间戳 **19:21**（28/28）。
- 之后修改的文件：`errwatch.ps1`（20:23）、`L3-collect.cmd`（20:59）、`errwatch-level.ps1` 相关改动等。
- 送审说明 21:02 写「验证结果可复跑」并列出 28/28、30/30、WinRE 21 条目——**这些都是旧代码的结果**。基线 21:00 重建没问题（40/40 哈希实测全对），但基线只证明「没改文件」，不证明「代码正确」。

### P1-2 `config-fix` 在送审包内不可用 + 5.1 兜底不可达

- `$wg = $root\..\WriteGuard\wg.ps1` —— **WriteGuard 不在包内**，审阅者机器上必 Fail「找不到 WriteGuard」。送审说明第七节列了不含什么，但没列这个依赖。
- `& pwsh @wgArgs` 硬编码 pwsh —— 5.1 兜底场景（无 pwsh）下此动作必挂，与整包「5.1 可跑」的目标冲突。

---

## 三、P2：隐私与文档精度（送审外发场景）

1. **证据包敏感度未警示**：L3 证据包含整份 System/Application evtx（含用户名、IP、崩溃路径等）；`--dumps` 会拷 **MEMORY.DMP 全内存转储**（内含密码、浏览数据、内存中的密钥）。是 opt-in 没错，但 README / 证据包 README.txt 应显式写「证据包勿随手外发、含 PII」。
2. **Ventoy 自动采集无确认**：`VentoyAutoRun.bat` 自动探测目标盘 → 采集 → 写 U 盘，全程无提示。用于自己的机器没问题；**用于他人机器构成未同意采集**。建议在 USB-自动采集.md 头部加一句使用边界。
3. **脱敏正则覆盖面**：`errwatch-report.ps1` 覆盖 `sk-` / `Bearer` / `password=` 族 / `cxt_`，不含 `AKIA` / `ghp_` / JWT（`eyJ`）。MVP 可接受，建议扩充。
4. **小误差**：送审说明称审计报告「共 11 份」，实际 `tests/audit-*.md` 为 **12 份**。（无伤大雅，但送审说明应以准确为先。）

---

## 四、核实通过的部分（声明 vs 实物，全对）

| 声明 | 实测 |
|---|---|
| baseline 40 文件全一致 | ✅ 40/40 哈希逐一对上，包内无缺无多 |
| 回归 28/28、误诊 0 漏诊 0 | ✅ last-run.json 一致（但时间早于最后改动，见 P1-1） |
| fix 5 个执行点全部 `-Critical`（fail closed） | ✅ 逐个数了：log-rotate/config-fix/rescan/restart-service/restart-process |
| `-Name` 通配符拒绝 | ✅ 两处 `[*?]` 检查在位 |
| 安全模式闸门（默认拒绝、`-AllowSafeMode` 记审计） | ✅ 代码与文档一致 |
| 8 态状态语义 / 7 种 fix 动作 | ✅ ValidateSet 7 个、注释 8 态 |
| report 脱敏 / 4000 上限 / 10 分钟去重 / source 仅声明 | ✅ 全在 |
| 核心层唯一实现（SafeMode / hay） | ✅ doctor/采集/修复/定级共 core\analyze.ps1 |
| hay 拼接修复 + x02 回归样本 | ✅ New-ErrwatchHay 实现正确，cases.jsonl 有 x02 |
| bundle-analyze 编码宽容（BOM→UTF-8→GBK） | ✅ Read-TextSmart 三段式实现正确 |
| 敏感信息扫描 | ✅ 全包无用户名/SID/令牌/真实 IP/个人路径（cases.jsonl 仅含程序名与版本号） |
| 包内不含运行时数据 | ✅ history.jsonl / env-last.json 等确实不在 |

**值得肯定的机制**：诚实挂账文化（HANDOFF「未验证」清单与实物相符）、急停 STOP 文件、审计 jsonl 不可删接口、每条结论带可信度与推翻方法——这些在同类个人工具里少见。

---

## 五、建议（按优先级）

- **R1（机制性，防复发）**：把 BOM 校验加进 `errwatch-doctor.ps1`（所有 ps1 必须有 BOM，缺了报红）+ 打包脚本里缺 BOM **拒绝打包**。原则 8 的手动步骤已被证明会被跳过，必须自动化。
- **R2**：打包前强制串跑：回归 → ensure-bom → WinRE 预演（L3-collect 至少在本机 cmd 完整走一遍第 5 节）→ 重建基线 → 打包。任何一步不过不出包。
- **R3**：修 P0-2 括号后，用 `tests/onsite-20261022.md` 的步骤重做一次 WinRE 实测，把「21 条目」的声明刷新到新版本。
- **R4**：`config-fix` 要么把 WriteGuard 最小集打进包，要么在送审说明第七节明示外部依赖与 5.1 限制。
- **R5**：证据包 README.txt 加 PII 警示；USB-自动采集.md 加「仅限自己机器」边界声明。

---

## 六、复现命令（全部可重跑）

```powershell
# P0-1：验证 errwatch.ps1 无 BOM（返回 False 即中招）
$b=[IO.File]::ReadAllBytes('E:\ai\_tools\errwatch\errwatch.ps1'); ($b[0]-eq0xEF -and $b[1]-eq0xBB -and $b[2]-eq0xBF)

# P0-2：同结构最小复现（echo 打到控制台、paren-out.txt 不生成）
#   见本审计所用最小用例：@echo off / echo hello / echo line1 / ) > out.txt

# 基线核对
$pkg='<解包目录>'; $b=Get-Content "$pkg\baseline.json"-Raw|ConvertFrom-Json
($b.files.PSObject.Properties|ForEach-Object{ (Get-FileHash (Join-Path $pkg $_.Name)).Hash -eq $_.Value }) -contains $false   # 应为空
```

---

## 七、复检（2026-10-22 21:52，整改后独立复验）

整改后的新送审包（21:50，217.8 KB，71 条目）按本报告第一~六节同一口径复检，全部通过：

| 检查项 | 结果 |
|---|---|
| P0-1 BOM | ✅ 71 文件中全部 `.ps1` 带 BOM；GBK 模拟解码 0 语法错误 |
| P0-2 L3 括号 | ✅ 第 175 行开括号在位 |
| P1 config-fix | ✅ WriteGuard 多候选（包内/同级/环境变量）+ `Get-PowerShellExe` 不再硬编码 pwsh |
| P1 回归时效 | ✅ last-run 21:41:55（晚于全部代码改动）；本人 21:52 又独立重跑：**28/28 + 冒烟双 PASS · unknown 9/9 · env-tiers 30/30** |
| 基线 | ✅ 21:42:05 重建，40/40 哈希对上包内文件 |
| 防复发机制 | ✅ run.ps1 冒烟（真跑主入口 + 5.1 Parser 解析 21 个 ps1）；doctor BOM/计划任务自检；打包门禁拒绝无 BOM |
| 许可合规 | ✅ MIT + THIRD-PARTY-NOTICES + Sigma DRL 字段（author/uri/license） |
| 新增文档敏感扫描 | ✅ 无用户名/SID/个人路径 |

**实测附证**：`errwatch-notify.ps1 -DryRun` 已能扫到 System 日志的 `Service Control Manager`（PICO Streaming Service 启动失败 ×9）——旧版只扫 Application，对此全盲。这也顺带给了待办 B-3 一条新线索。

**复检后仍未闭环（需人）**：WinRE 重测（括号修复目前只在正常系统验证过，见送审说明 §七）。

### 7.1 终版复验（2026-10-22 21:57，针对 21:54 重打的包）

21:50 的包之后又重打过一次（21:54，226,381 B，SHA256 `31ac8ca5…`）——与 21:50 版逐字节 diff，**仅两份文档变动**（`tests/审计索引.md`、`发布流程.md`：权属三项确认勾选），无代码变动，故基线（21:42:05）仍 40/40 对上。对 21:54 终版按同一口径重验：

| 检查项 | 结果 |
|---|---|
| 条目 / BOM / GBK 解析 | ✅ 71 条目；no-BOM 0；5.1 模拟解码 0 语法错误 |
| P0-2 L3 括号 | ✅ 第 174 行 `(` 在位 |
| 基线 | ✅ 40/40 哈希全对 |
| notify 失败语义 | ✅ 区分「窗口无事件」与「读取失败」；失败不推进时间窗、写 lastExit=2、exit 2 |
| notify 日志覆盖 | ✅ `@('Application','System')` |
| 重复函数 | ✅ notify 本地副本已删，仅存 core 版 |
| 弹窗兜底 | ✅ 非交互上下文跳过 MessageBox（`-not UserInteractive`） |
| doctor | ✅ 核心文件清单 17 项（含 core/、fix/、runners/）；BOM 自检 FAIL 即报；计划任务注册 + LastTaskResult 十六进制展示 |
| 回归冒烟 | ✅ run.ps1 真跑主入口 + 5.1 Parser 验全部 ps1（P0-1 永久变成回归项） |

**残留低风险项（不阻塞送审）**：① `errwatch-report.ps1` 脱敏正则未覆盖 `AKIA`/`ghp_`/`eyJ` 形态（本地报错文本场景风险低）；② L3 manifest `note` 字段不转义双引号（有 `ConvertFrom-JsonLenient` 兜底）；③ 包内 `audit-submission-20261022.md` 为 21:20 版（不含第七节），如需审阅者看到复检结论需随下次打包同步。

---

*审计人：WorkBuddy（对送审包的独立复核，2026-10-22 21:12 起；21:52、21:57 两轮复检）。所有「实测」字样均为本机执行结果，可按第六节复现。*
