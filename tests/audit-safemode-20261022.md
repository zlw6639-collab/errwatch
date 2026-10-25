# 安全模式支持 — 改动与可复现测试记录

- 日期：2026-10-22
- 对象：`errwatch-doctor.ps1`、`errwatch.ps1`、`errwatch-fix.ps1`、`errwatch-source.ps1`
- 起因：上一轮审计结论 —— errwatch 原先**没有任何安全模式检测**，在安全模式下会按正常模式的假设执行，属于「长期运行可信度」的缺口
- 结论：**4 个脚本已接入检测，20/20 自测通过；未在真实安全模式中实测（见「诚实记录」）**

---

## 一、改了什么

| # | 文件 | 改动 |
|---|---|---|
| 1 | `errwatch-doctor.ps1` | 新增「安全模式」自检节：报告当前模式与判据；在安全模式下列出会失效的能力 |
| 2 | `errwatch.ps1` | 报告开头标注「运行模式」；安全模式时追加提示块，解释「计划任务不运行 → 心跳停在旧时间」是预期行为 |
| 3 | `errwatch-fix.ps1` | 新增 `-AllowSafeMode` 开关 + **安全模式闸门**：安全模式下 `-Commit` 默认拒绝（演练不受限），授权执行会写 `safemode-override` 审计 |
| 4 | `errwatch-source.ps1` | `-Web` 在安全模式下提示「通常无网络、链接打不开」 |

检测口径（4 个脚本一致）：

1. `HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option\OptionValue` —— `1` = 最小安全模式，`2` = 带网络的安全模式
2. 取不到时回退 `Win32_ComputerSystem.BootupState`（非 `Normal` 即视为安全模式）

## 二、怎么测的（不进入真安全模式）

安全模式无法在正常运行时进入，因此引入**只收紧、不放宽**的模拟开关：

```powershell
$env:ERRWATCH_SAFEMODE = '1'   # 让脚本按安全模式处理
```

该开关**只影响判断方向**：它让脚本提示更多、拒绝更多，不会放宽权限、不会跳过任何检查，
因此不构成可用于提权的后门。真实检测路径（注册表 / CIM）在每次运行时仍然生效。

测试脚本：`E:\ai\_tmp\sm-test.ps1`（临时件，未纳入包）。

## 三、自测结果：20 / 20

| 组 | 检查点 | 结果 |
|---|---|---|
| 语法 | 4 个脚本 `Parser::ParseFile` 无错 | ✅ 4/4 |
| doctor | 正常模式显示 `[OK] 正常模式`；不出现安全模式告警 | ✅ 2/2 |
| doctor | 模拟安全模式显示 `[安全模式]`、提示计划任务不运行、提示 `-AllowSafeMode` | ✅ 3/3 |
| 采集 | 正常模式报告无「运行模式」行 | ✅ |
| 采集 | 模拟安全模式：标注运行模式 + 计划任务解释 + 还原点/网络提示 | ✅ 3/3 |
| 修复 | 正常模式演练 = `dry-run` | ✅ |
| 修复 | 正常模式执行 = `verified` | ✅ |
| 修复 | **安全模式演练仍允许** = `dry-run`（只读不该被拦） | ✅ |
| 修复 | **安全模式执行被拒绝** = `refused`，退出码非 0，**文件字节数未变** | ✅ 3/3 |
| 修复 | 拒绝信息指向 `-AllowSafeMode` | ✅ |
| 修复 | 显式 `-AllowSafeMode` 后执行 = `verified`，文件确实被清空 | ✅ 2/2 |
| 修复 | 审计库里出现 `safemode-override` 记录 | ✅ |
| 未被误伤 | `list-problem-devices`（只读动作）返回正常 | ✅ |

回归未受影响：

| 套件 | 结果 |
|---|---|
| `tests/run.ps1`（规则回归） | 总数 20 / 正确 20 / 误诊 0 / 漏诊 0 |
| `tests/unknown-chain.ps1`（unknown 全链路） | PASS 9 / FAIL 0 |

## 四、复现方式（可直接跑）

```powershell
$root = "E:\ai\_tools\errwatch"

# 1. 正常模式 vs 模拟安全模式的 doctor 对比
pwsh -File "$root\errwatch-doctor.ps1"
$env:ERRWATCH_SAFEMODE='1'; pwsh -File "$root\errwatch-doctor.ps1"; Remove-Item Env:ERRWATCH_SAFEMODE

# 2. 采集报告的模式标注（-NoFile 只输出不落盘）
$env:ERRWATCH_SAFEMODE='1'; pwsh -File "$root\errwatch.ps1" -NoFile; Remove-Item Env:ERRWATCH_SAFEMODE

# 3. 修复闸门：演练允许，执行拒绝，授权后执行
"x"*2000 | Set-Content "$env:TEMP\sm.log" -NoNewline
$env:ERRWATCH_SAFEMODE='1'
pwsh -File "$root\errwatch-fix.ps1" -Action log-rotate -Path "$env:TEMP\sm.log"                  # dry-run（允许）
pwsh -File "$root\errwatch-fix.ps1" -Action log-rotate -Path "$env:TEMP\sm.log" -Commit          # refused（拒绝）
pwsh -File "$root\errwatch-fix.ps1" -Action log-rotate -Path "$env:TEMP\sm.log" -Commit -AllowSafeMode  # verified（授权）
Remove-Item Env:ERRWATCH_SAFEMODE
```

## 五、诚实记录（未做到 / 未验证的部分）

1. **没有在真实安全模式中实测**。本机当前是正常模式，`SafeBoot\Option\OptionValue` 不存在。
   上表验证的是「检测被正确接线 + 判断分支行为正确」，**不等于「开机进安全模式后一定正确」**。
   回到电脑前重启进一次安全模式跑 `errwatch-doctor.ps1`，是唯一能闭环的验证。
2. **模拟开关只覆盖代码分支**，不覆盖安全模式下的真实系统差异（服务不在、无网络、卷影不可用）。
   报告里对失效能力的描述是**基于系统机制的推断**，已在措辞中标注为预期行为。
3. **闸门只管住 `errwatch-fix.ps1` 自己**。如果有人绕过这个脚本直接改系统，它与 errwatch 无关 ——
   工具不假装自己是安全边界。
4. `notify` / `ui` / `query` / `evidence` / `baseline` / `prune` / `report` 未加标注：
   它们在安全模式下的行为不需要区分（本地读写），加了反而是噪音。

## 六、下一轮建议

- 回到正常模式后，把上面「四、复现方式」跑一遍留档，补齐真实模式下的实测缺口
- 若要继续做审计路线：还剩**第 4 项（故障测试集 / 规则回归语料）**与**第 6 项（真实试用与误诊统计）**
