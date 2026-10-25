# errwatch — 故障看护与处置

> **第一次用？只要三步**：双击「启动报错看护.vbs」（不会弹黑框）→ 点左上角「开始扫描」→ 看表格和文件夹里最新的 `report-*.md`。
> 如果双击 vbs 被安全软件拦了，改用「启动报错看护.bat」——功能一样，只是会闪一下黑窗口。
> 下面的内容讲它是什么、边界在哪；赶时间可以跳过，直接看「快速开始」。

> **不是"修电脑的工具"**，而是：程序报错之后，让人知道发生了什么、该由谁处理、
> 以及哪些事这个工具不会替你决定。
>
> Windows 是当前平台，不是产品边界。
>
> **三条原则**：
> 1. **有证据** —— 每条结论都能追溯到规则 / SDK 定义 / 实测样本
> 2. **有边界** —— 能安全修的才修，超出能力就明确告诉你该找谁
> 3. **有路由** —— fix / agent / driver / community 四路分诊
>
> ⚠️ **使用前请读 [免责声明](免责声明.md)**：能力边界（看得见什么、看不见什么）、
> 数据行为（本地只读、不联网）、修复风险（默认演练、部分动作不可回滚）、
> 以及规则许可（Sigma 衍生规则受 DRL 1.1，样例与真实规则的 `uri` 区别）。
>
> **当前发行包的规则来源**：`core/rules.json` **34 条**为项目自编；`core/rules-sigma.json` 6 条由 `tools/sigma-samples/` 的**自编样例**转换而来。
> 本包**不含** SigmaHQ 的真实检测规则，也**不含** Hayabusa 的代码或规则。详见 [第三方声明](THIRD-PARTY-NOTICES.md)。

## 三个等级

同一套规则，按**运行环境的能力**分三级；不同等级用不同入口，但结论口径一致。

| 等级 | 什么时候 | 入口 | 重点 |
|---|---|---|---|
| **L1 正常看护** | 系统正常 | `errwatch.ps1` / `errwatch-ui.ps1` | 采集 + 翻译 + 有限修复 |
| **L2 安全模式诊断** | 能起来但组件不全 | `errwatch.ps1`（自动降级） | **取回证据**，恢复手段受限 |
| **L3 恢复环境取证** | Windows 本身起不来 | `runners\L3-collect.cmd`（纯 cmd，WinRE 可跑） | **只读取证 → 证据包 → 换台机器分析** |

- 判定与路由：`pwsh -File errwatch-level.ps1`（会告诉你现在在哪一级、该走哪个入口、这一级少了什么）
- L3 的操作步骤与「磁盘坏了怎么办」：见 [`runners/L3-操作卡.md`](runners/L3-操作卡.md)
- 想做到「开机选一下 U 盘，剩下全自动」：见 [`runners/USB-自动采集.md`](runners/USB-自动采集.md)

## 架构：核心与入口分离

errwatch 过去的诊断逻辑和采集动作缠在一起，后果是**采集环境一坏，能力全没**。
现在拆成「核心」与「入口」两层：

```
errwatch/
  core/                        核心：不依赖运行环境（纯数据 + 纯逻辑）
    analyze.ps1                  规则匹配 / 人话翻译 / 安全模式判断（全项目唯一实现）
    rules.json                   34 条通用规则（正则 → 人话 → 建议 → 坑号）
    apps.json                    6 个软件档案（匹配特征 / 日志位置 / 专属规则）
    noise.json                   降噪（ignore / quiet / 聚合窗口）
    events.json                  事件 ID → 人话（蓝屏、磁盘错误、服务失败…）
    rules-sigma.json             从 Sigma 规则转换来的规则（tools\sigma-convert.ps1 生成）
    schema/evidence-bundle.v1.md 证据包格式契约
  tools/                       构建期工具（不参与日常运行）
    sigma-convert.ps1            把 Sigma 规则转成 errwatch 规则（零依赖）
    sigma-samples/               转换器自测用的样本规则
  runners/                     入口：不同环境下的执行体
    L3-collect.cmd               纯 cmd 采集器 —— WinRE 里没有 PowerShell，也照样跑
    L3-操作卡.md                  给人看的操作步骤
  errwatch.ps1 / doctor / fix …  L1 / L2 入口：薄壳，只负责采集与呈现
  errwatch-bundle-analyze.ps1   证据包分析器：只吃证据包，可搬到另一台机器
  errwatch-level.ps1            定级与路由
```

三条约定：

1. **判断逻辑只有一份**（`core\`）—— 入口可以换、环境可以坏，规则不会分叉
2. **采集与分析分离** —— 采集器**不下结论**，只如实记录取到了什么、没取到什么；分析器**不碰原机器**
3. **证据包是唯一的跨环境接口** —— 自描述（`manifest.json`）+ 哈希 + 相对路径，搬到哪都能读

> 分发提醒：**`core\` 必须和脚本一起拷**。只拷单个 `.ps1` 会明确报错退出，不会静默降级。

## 修复状态语义

| 状态 | 含义 | 验证等级 |
|---|---|---|
| `dry-run` | 演练，未执行 | 无 |
| `written` | 动作完成，只确认"做完了" | 低 |
| `verified` | 动作完成 + 验证断言通过 | **高（附验证范围）** |
| `partial` | 部分完成（如服务起来了但端口没监听） | 中 |
| `verify-failed` | 验证失败 | — |
| `rolled-back` | 已回滚 | — |
| `refused` | 拒绝（参数/权限） | — |
| `aborted` | 急停回滚 | — |

**`verified` 不等于绝对修好**：它只说明**声明的验证范围**通过了。
例如 `restart-service -Port` 的 `verified` = 服务状态 + 端口监听，**不代表业务请求可用**。

## 快速开始

```
双击「启动报错看护.bat」     ← 图形界面
```

或者命令行：

```powershell
pwsh -File errwatch-doctor.ps1      # 先查环境能不能跑
pwsh -File errwatch.ps1             # 全量报告（最近 24 小时）
pwsh -File errwatch-notify.ps1      # 只报新错误（有错弹窗，无错静默）
```

## 如何验证下载的包

这个包是**开源**的：zip 里就是源码（全是 `.ps1` / `.json` / `.md`，没有任何编译产物）。
所以验证靠**哈希 + 可复现**，不靠代码签名证书。

| 信任来源 | 这个项目有没有 |
|---|---|
| 源码公开可审 | ✅ zip 内即完整源码，任何人可读 |
| 仓库身份 | ✅ 从 GitHub 仓库 Release 下载，信的是这个账号 + HTTPS |
| 构建可复现 | ✅ 无构建步骤，改完源码直接就能跑 |
| 哈希 / 清单 | ✅ `*.zip.sha256`（整包）+ `release.json`（逐文件）+ `*.sbom.json`（成分） |
| 代码签名证书 | ❌ **不需要** —— 原因见本节末尾 |

### 1. 校验整包 SHA-256（必做）

```powershell
$zip  = '.\errwatch-<版本>.zip'    # ← 换成你实际下载的包名，例如 errwatch-20261023-l.zip
$want = ((Get-Content "$zip.sha256") -split '\s+')[0]
$got  = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
if ($got -eq $want) { "OK：哈希一致" } else { "FAIL：包被改过，别用" }
```

### 2. 校验包内每个文件

`release.json` 记录了包内**每个文件的 SHA-256**，能定位到「具体是哪个文件被动过」。

> ⚠ **它在包外。** 2026-10-25 审计指出：原文档让人在解压目录里跑
> `Get-Content .\release.json` —— 那个位置永远是空的，照文档走第一步就卡住。
> `<zip名>.release.json` / `*.zip.sha256` / `*.sbom.json` / `*.verify.json` 都是**伴随文件**，
> 和 zip 放在**同一个下载目录**里，不在 zip 内部。
> （刻意不写进包：包内文件记录自己的哈希，一改就全对不上，等于自欺。）
>
> **每个包有自己的清单**（`errwatch-<版本>.zip.release.json`）。同目录的 `release.json` 只是
> 「最新构建」指针 —— 一个目录放多个版本时，它只代表最后打的那个，**不能用来校验旧包**。

```powershell
$zip     = '.\errwatch-<版本>.zip'
# 优先用**包级**清单；没有才回退到共享的 release.json（by 之前那批旧包只有共享的）
$relFile = if (Test-Path "$zip.release.json") { "$zip.release.json" } else { Join-Path (Split-Path -Parent $zip) 'release.json' }
if (-not (Test-Path -LiteralPath $relFile)) {
    throw "找不到发布清单 —— 它应该和 zip 在同一个目录里（不在 zip 里面）"
}
$r = Get-Content -LiteralPath $relFile -Raw | ConvertFrom-Json
Expand-Archive -LiteralPath $zip -DestinationPath .\unpacked -Force
$bad = foreach ($f in $r.files) {
    $p = Join-Path .\unpacked $f.path
    if (-not (Test-Path -LiteralPath $p)) { "缺失  $($f.path)" }
    elseif ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne $f.sha256) { "被改  $($f.path)" }
}
if ($bad) { $bad } else { "OK：$($r.files.Count) 个文件全部与 release.json 一致" }
```

### 3. 独立安装验证（推荐）

证明「陌生人拿到 zip、不依赖开发目录，也能跑起来」。
脚本在**包内**，所以要在解压出的目录里跑，`-Zip` 指回你下载的那个 zip：

```powershell
cd .\unpacked
pwsh -File tools\verify-package.ps1 -Zip ..\errwatch-<版本>.zip
```

它会解压到临时目录 → 查关键文件是否齐全、`.ps1` 是否都带 BOM → 跑 `doctor` / UI 自检 / 建议安全性测试 → 打印 PASS/FAIL。

### 4. 从源码自证（最强的一条）

解压出来就是源码，没有中间产物，所以「下载 → 自己看 → 自己跑」这条路是通的。
若维护者对 tag 做了 GPG 签名，还能顺带验证「这个 tag 确实是他打的」：

```powershell
git clone https://github.com/<账号>/errwatch.git repo
git -C repo verify-tag v2026.10.23     # 没有 GPG 签名时会提示无签名，不影响源码可审
```

包内每个文件的哈希都在 `release.json` 里，任何人可以取仓库对应 tag 的内容重算比对。

### 为什么没有代码签名证书

代码签名证书是给**闭源软件 / 商业分发**用的 —— 用户看不到源码，只能信证书。
本项目的源码已经公开，任何人都能读代码、自己运行、比对哈希，证书能提供的**额外**保证很有限。

什么时候才真的需要证书：

| 场景 | 要不要 |
|---|---|
| 开源、别人自己下载运行 | ❌ 不要 |
| 打包成独立 `.exe` 给普通用户双击（避免 SmartScreen 拦） | ⚠️ 建议 |
| 卖给企业、走商业分发 | ✅ 要 |
| 上架 Microsoft Store | ✅ 要 |

## 命令清单

| 命令 | 作用 |
|---|---|
| `errwatch.ps1 -Hours 72` | 全量报告：崩溃、安装失败、DSH 状态 |
| `errwatch-notify.ps1 -DryRun` | 只检查新错误，不弹窗 |
| `errwatch-query.ps1 -Stats` | 历史统计：按程序 / 按错误码 |
| `errwatch-query.ps1 -Query VRChat` | 搜历史 |
| `errwatch-query.ps1 -Unknown` | 规则没覆盖的（待补清单） |
| `errwatch-query.ps1 -New -Hours 24` | 历史上从未出现过的新错误 |
| `errwatch-evidence.ps1 -App VRChat` | 取证：事件日志 + WER + 应用日志 |
| `errwatch-evidence.ps1 -Open` | 直接打开证据目录 |
| `errwatch-source.ps1 -Code 0x80000003` | 从本机 SDK 查官方定义 |
| `errwatch-source.ps1 -Code 1603 -Web` | 生成社区搜索链接 |
| `errwatch-doctor.ps1` | 环境自检 |
| `errwatch-baseline.ps1 -Create` | 生成哈希基线（防篡改） |
| `errwatch-baseline.ps1` | 校验有没有被改 |
| `errwatch-level.ps1` | **定级**：现在属于 L1/L2/L3、该走哪个入口、这一级少了什么 |
| `errwatch-bundle-analyze.ps1 -Bundle <包>` | 分析证据包（可在**另一台机器**上跑） |
| `runners\L3-collect.cmd <输出目录> <目标盘>` | L3 取证采集（纯 cmd，WinRE / WinPE 可跑） |
| `errwatch-fix.ps1 -Action log-rotate -Path x.log -Commit` | 执行修复（默认演练；安全模式需 `-AllowSafeMode`） |
| `errwatch-report.ps1 -App x -Message "..."` | 主动上报不写事件日志的报错 |
| `register-watch.ps1` | 注册每 10 分钟自动检查 |

## 文件说明

| 文件 | 是什么 |
|---|---|
| `core\rules.json` | **34 条**通用规则：正则 → 人话 → 建议 → 坑号（**核心资产**） |
| `core\analyze.ps1` | **核心诊断层**：规则匹配 / 翻译 / 安全模式判断（唯一实现，被所有入口复用） |
| `core\events.json` | 事件 ID → 人话（蓝屏 1001、磁盘 7/11/51、服务 7000/7001、驱动 219…） |
| `core\rules-sigma.json` | 从 **Sigma 规则**转换来的规则（事件 ID 匹配为主，见 `tools\sigma-convert.ps1`） |
| `tools\sigma-convert.ps1` | Sigma → errwatch 转换器：**有损就说明有损，宁可不转也不转错** |
| `tools\pack.ps1` | 打包发布包：双重门禁（第三方准入 + BOM）+ 自动排除运行时残留 + 生成包外 `.sha256` |
| `tools\verify-package.ps1` | 独立安装验证：解压到临时目录证明「陌生人拿到 zip 也能跑」（发布前必跑） |
| `tools\make-release.ps1` / `make-sbom.ps1` | 生成包外 `release.json`（逐文件哈希 + 测试绑定）与 SBOM |
| `core\schema\evidence-bundle.v1.md` | 证据包格式契约（L3 的跨环境接口） |
| `runners\L3-collect.cmd` | L3 采集器：纯 cmd、只读优先、WinRE / WinPE 可跑 |
| `runners\L3-操作卡.md` | Windows 起不来 / 磁盘坏了时，人该怎么做 |
| `runners\VentoyAutoRun.bat` | **自动采集**：Ventoy 在 WinPE 启动时自动调用它（1.0.55+ 注入机制） |
| `runners\USB-自动采集.md` | 能自动到哪一步、做不到什么、三条社区路线（Ventoy / 预制 PE / SystemRescue） |
| `errwatch-bundle-analyze.ps1` | 证据包分析器：只吃证据包，可在任意机器上跑 |
| `core\apps.json` | 6 个软件档案：匹配特征、日志位置、专属规则、可用性检测 |
| `core\noise.json` | 降噪：ignore（完全忽略）/ quiet（进报告不弹窗）/ 聚合窗口 |
| `baseline.json` | 哈希基线（自动生成，别手改） |
| `history.jsonl` | 历史库（每次采集自动追加，按时间+来源+ID 去重） |
| `report-*.md` | 每次报告的快照 |

## 依赖与可移动性

**只依赖 Windows 自带的东西**：

- PowerShell（`pwsh` 优先，没有就回退 `powershell.exe` 5.1）
- 事件日志（`Get-WinEvent`，普通权限）
- Windows SDK 头文件（可选，用于查官方定义）

**实测可整体移动**：复制到任何目录都能跑，因为所有脚本用 `$PSScriptRoot` 定位，配置和数据都在同目录。
**注意**：`core\` 和 `runners\` 必须和脚本一起拷贝 —— 只拷单个 `.ps1` 会明确报错退出。

**不依赖**：DSH、网络、Python、Node、任何第三方包。

## 权限

| 能力 | 权限 |
|---|---|
| 读事件日志、写报告 | 普通用户 |
| 注册计划任务 | 普通用户 |
| 读 WER 报告内容 / Minidump | **管理员** |
| 创建还原点 / 卷影副本 | **管理员**（安全模式通常禁用） |

## 安全模式

errwatch **知道自己是否在安全模式**（2026-10-22 加入）。各处的行为：

| 位置 | 在安全模式下做什么 |
|---|---|
| `errwatch-doctor.ps1` | 报告当前模式；在安全模式下列出会失效的能力 |
| `errwatch.ps1` | 报告开头标注「运行模式」，并解释「上次成功采集停在旧时间」是预期行为 |
| `errwatch-source.ps1 -Web` | 提示安全模式通常无网络、链接打不开 |
| `errwatch-fix.ps1` | **默认拒绝执行**（演练不受限）；确需执行要加 `-AllowSafeMode`，并记审计 |

检测口径：`HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option\OptionValue`（1=最小，2=带网络）；
取不到时回退 `Win32_ComputerSystem.BootupState`。

安全模式下会失效的能力（**系统限制，不是工具坏了**）：

| 能力 | 状态 | 原因 |
|---|---|---|
| 采集 / 查询 / 取证 / 官方定义 / 分诊 / UI / baseline | ✅ 可用 | 纯本地读，不需要网络与特殊服务 |
| 计划任务 | ❌ 不运行 | 安全模式默认不启动任务计划 → 心跳会停在旧时间 |
| 系统还原 / 卷影副本 | ❌ 不可用 | 安全模式禁用 |
| 社区搜索链接 | ⚠️ 打不开 | 通常无网络 |
| 服务 / 驱动 / DISM 类修复 | ⚠️ 可能失败 | 目标组件本就没加载 |

**自测开关**：设 `ERRWATCH_SAFEMODE=1` 可让上述脚本按安全模式处理。
它**只收紧提示与权限判断，不放宽任何东西**，因此不构成后门（见 `tests/audit-safemode-20261022.md`）。

## 环境指纹（分层）

结论是有**时效**的：换了显卡、加了内存、重装系统之后，旧日志里的报错可能已经与这台机器无关。
所以每次采集都记一份指纹，下次采集时比对。

指纹分两层（2026-10-22 晚加入）：

| 层 | 包含 | 变了会怎样 |
|---|---|---|
| **核心层** | 系统版本、CPU、显卡、固定磁盘数、内存、物理网卡 | 报告里**警告**「旧结论可能已不适用」并逐项列出；历史按它**分段** |
| **外围层** | 音频端点、可移动磁盘（U 盘 / 移动硬盘） | **不提示**（与报错结论无关），只记在 `env-last.json` 里备查 |

为什么插耳机不再算「环境变了」：

- 插耳机 → `MMDevices\Audio\Render` 端点数量变化 → 过去整机指纹跟着变，报告弹警告、历史被切成两段
- 插 U 盘 → `Disk\Enum` 多一条 → 同上。现在只数**固定磁盘**（`USB` 开头的条目归外围层）

另外，**虚拟 / 共享 / 调试类设备一律不进核心层**（开个热点就"换了硬件"说不通）：
`Remote NDIS`（手机热点）、`Wintun`（WireGuard 类 VPN）、`Kernel Debug`（调试桥）、
`Virtual Display`（投屏 / 远程桌面）、`Bluetooth PAN`、`WAN Miniport`、
`Hyper-V` / `VMware` / `VirtualBox` 等。归类函数是 `Test-ErrwatchVirtualDevice`。

```powershell
pwsh -File errwatch.ps1                     # 报告顶部显示核心指纹；只有核心层变了才警告
pwsh -File errwatch-query.ps1 -CurrentEnv   # 只看当前核心环境的历史（环境未知的旧记录会保留并标注）
```

数据在 `env-last.json`（`coreHash` / `peripheralHash` / `fields`）。
回归：`tests\env-tiers.ps1`（30 项）。

## 已知边界

1. **抓不到不写事件日志的报错**（例如 Agents Anywhere 的 UI 层错误）
2. **规则是手写的**——可能错，但每条都有来源（坑号 / 官方定义 / 实测）
3. **哈希基线只能发现篡改，不能阻止**——工作区已沦陷时它救不了你
4. **安全模式下"能看不能修"**：详见上面「安全模式」一节 —— 采集照常，修复器默认拒绝执行

## 维护

**改了规则或脚本后**，记得重新生成基线：

```powershell
pwsh -File errwatch-baseline.ps1 -Create
```

**补规则**：跑 `errwatch-query.ps1 -Unknown` 看未命中清单，把反复出现的补进 `core\rules.json`。

**加软件**：改 `core\apps.json`，加一条 `id` / `match` / `logs` / `detect` / `known`。

## 许可与合规

| 项 | 文件 | 说明 |
|---|---|---|
| **代码许可** | `LICENSE` | **MIT**（SPDX: `MIT`）；覆盖全部脚本与 `core\analyze.ps1` 等程序代码 |
| **版权主体** | `LICENSE` | `Copyright (c) 2026 猫咖没有猫猫 (@zlw6639-collab)` |
| **第三方声明** | `THIRD-PARTY-NOTICES.md` | Sigma 规则（**DRL 1.1**）、Hayabusa（AGPL，**未使用其代码/规则**） |
| **规则许可分离** | `core\rules-sigma.json` | 来自 Sigma，受 **DRL 1.1**，**不属于 MIT**；每条带 `author`/`uri`/`license` |
| **免责声明** | `免责声明.md` | 能力边界 / 数据行为（**已静态验证不联网**）/ 修复风险 / 责任限制 |
| **贡献指南** | `CONTRIBUTING.md` | 规则模板、第三方材料要求、DCO 声明 |
| **发布流程** | `发布流程.md` | 权属确认 → 回归 → BOM → 打包 → 哈希 → 审计记录 |
| **开源发布清单** | `开源发布清单.md` | GitHub Release 步骤：建仓库 / 上传哪几个文件 / 正文模板 |

> ⚠️ 发布前必读 `发布流程.md` 第 0 步「权属确认」——这一条只有维护者本人能答。
> 审计与整改记录见 `tests\审计索引.md`（先看索引，再看具体报告）。
