# errwatch-20261025-bu.zip 兼容性专项审计（2026-10-25）

范围：`E:\ai\_tools\_dist\errwatch-20261025-bu.zip` 的解压副本 `C:\Users\17586\AppData\Local\Temp\bu`。  
重点：**Windows PowerShell 5.1 / PowerShell 7 双运行时、Windows 桌面环境、进程宿主假设、编码假设、发行材料定位**。  
本机环境：Windows 11 26200；PS 5.1.26100.8875（Desktop）；PS 7.6.6（Core）。

---

## 1. 总体结论

**核心运行时兼容性良好：没有发现 PS7-only 语法，关键 API 在 5.1/7 都可用，主要入口在 PS7 下实跑退出码均为 0。**  
真正需要修的是三类“跨版本/跨包”假设：

| 级别 | 问题 | 是否影响崩溃救援主链 |
|---|---|---|
| P2 | `release.json` 不是包级材料，多个发行包同目录会互相覆盖，旧包默认校验失败 | 影响发布可信度，不影响运行 |
| P3 | `register-watch.ps1` 生成 VBS 的编码随 PowerShell 宿主变化：5.1 写 ANSI，7 写 UTF-8 无 BOM | 中文安装路径下有启动风险 |
| P3 | 托盘/界面进程检测按 PowerShell 宿主名猜，且不锚定当前安装目录 | 会误报“托盘没跑”或漏杀重复界面 |
| P3 | 设置窗“启动看护”在没有启动项且没有默认 PS7 路径时会启动失败 | 只影响手动启动入口 |
| P3 | doctor 对启动文件夹只查文件存在，不校验指向 | 会把旧安装的启动项报告成 OK |
| P3/低 | 部分 `Get-Content` 依赖隐式 BOM 侦测；当前 WER 文件有 BOM 所以安全，但格式变化会分叉 | 潜在 |

---

## 2. 已验证通过的部分

### 2.1 双运行时 API 矩阵

同一探针脚本分别在 PS 5.1 与 PS 7 下运行，结果均为 OK：

| 能力 | PS 5.1 | PS 7 | 说明 |
|---|---:|---:|---|
| `System.Windows.Forms` / `System.Drawing` | OK | OK | UI 主链路可用 |
| `System.IO.Compression.FileSystem` / `ZipFile` | OK | OK | 打包/解包/材料校验可用 |
| `Set-Clipboard` | OK | OK | UI 复制可用 |
| `Get-WinEvent -FilterHashtable` | OK | OK | 事件采集可用 |
| `Get-CimInstance Win32_OperatingSystem` | OK | OK | WMI/CIM 可用 |
| `New-Object -ComObject Shell.Application` | OK | OK | COM 互操作在 PS7 Windows 版可用 |
| `System32\WindowsPowerShell\v1.0\powershell.exe` 存在 | True | True | 5.1 回退路径可用 |

### 2.2 语法与静态扫描

- PS 5.1 语法模拟：**0 错**（复用了既有门禁结论）。
- PS 7 解析器复测全部 `*.ps1`：**0 错**。
- 未发现 PS7-only 语法/用法：`??`、`?.`、`ForEach-Object -Parallel`、`ConvertFrom-Json -AsHashtable`、`-replace` scriptblock 均无命中。
- 运行时 `Set-Content` / `Out-File` 未显式声明编码的行：**0 条**。

### 2.3 PS7 下主要入口实跑

| 入口 | 结果 |
|---|---|
| `errwatch-doctor.ps1` | exit 0 |
| `errwatch-tray.ps1 -Check` | exit 0，菜单/队列自检正常 |
| `errwatch-settings-ui.ps1 -Check` | exit 0 |
| `errwatch-settings-ui.ps1 -CheckBuild` | exit 0，界面可真实构建 |
| `errwatch-ui.ps1 -Check` | exit 0，布局/右键/详情自检正常 |
| `errwatch-sentinel.ps1 -Once -Json` | exit 0 |
| `errwatch-metrics.ps1 -Json` | exit 0 |

---

## 3. 发现的问题

### P2-1：`release.json` 不是包级材料，多个发行包同目录会互相覆盖

现象：对 `-bu` 包跑默认材料绑定校验，PS 5.1 与 PS 7 **结果相同，都 FAIL**：

```text
release.sha256 一致：BBA0B2413A7E4105… vs 82590FFE8FF20B69…
release.entries 与 ZIP 条目数一致：release=137 zip=193
release.files 逐文件一致：★ 先看我.txt 大小 3148≠754； 等 106 项
SBOM 声明的 ZIP 就是本 ZIP（名称）：sbom=errwatch-20261025-bx.zip
这组材料不能作为候选发行件。
```

根因：

- `tools\make-release.ps1:39` 默认输出到 `Join-Path $zipDir 'release.json'`，不是 `<zip名>.release.json`。
- `tools\check-release-identity.ps1:34` 默认也读同一个 `release.json`。
- 但 `.sha256` / `.sbom.json` / `.verify.json` 都是包级命名。现在 `_tools\_dist` 已有 `bu/bv/bw/bx` 四个包，`release.json` 已指向最新的 `bx`。

影响：**任何一个旧候选包，在新包构建后都无法用默认命令自证身份**；审阅者按 README 跑校验会得到“材料不能作为候选发行件”，即使 ZIP/SBOM/verify 三个包级材料是对的。

建议修法：

1. `make-release.ps1` 默认输出改为 `<zip文件名>.release.json`，或打包流程显式传 `-Out`。
2. `check-release-identity.ps1` 优先找 `<zip文件名>.release.json`，再回退 `release.json`。
3. 发布说明明确：四个材料必须同目录、同包名保留。

---

### P3-1：`register-watch.ps1` 生成 VBS 的编码会随 PowerShell 宿主变化

代码注释明确说：

```powershell
# VBS 必须用系统 ANSI 编码（带 BOM 的 UTF-8 会被 wscript 判为语法错误）
Set-Content ... -Encoding Default
```

但实测 `Default` 在 5.1 和 7 里不是同一种编码：

| 宿主 | 写入 `x-中文` 的前几字节 | 实际编码 |
|---|---|---|
| PS 5.1 | `78 2D D6 ...` | 系统 ANSI/GBK |
| PS 7 | `78 2D E4 ...` | UTF-8 无 BOM |

而 `wscript.exe` 读 `.vbs` 按 ANSI 解释。因此：

- 安装路径纯 ASCII 时，通常还能跑，但中文注释会变乱码；
- 安装路径含中文时，PS7 生成的 VBS 里路径字节是 UTF-8，wscript 按 GBK/ANSI 读成另一条路径，**登录启动可能静默失效**。

相关位置：`register-watch.ps1:136-148`，读取侧 `register-watch.ps1:223`。

建议修法：不要让 VBS 内容依赖宿主默认编码。要么只生成 ASCII VBS，要么用 .NET 显式按系统 ANSI 代码页写字节；中文说明放进 README，不要写进 VBS。

---

### P3-2：托盘/界面进程检测按 PowerShell 宿主名猜，而且不锚定当前安装目录

三处检测口径不一致：

| 位置 | 当前查询 | 问题 |
|---|---|---|
| `errwatch-doctor.ps1:353-355` | `Name='pwsh.exe'` + CommandLine 含 `errwatch-tray.ps1` | 托盘回退到 5.1 运行时误报“没在跑” |
| `errwatch-settings-ui.ps1:671-673` | 同上 | 看护健康面板同样误报 |
| `errwatch-ui.ps1:60-61` | `Name='powershell.exe'` + CommandLine 含 `errwatch-ui.ps1` | 界面由 PS7 启动时，单实例守卫找不到另一个界面 |

另外，这些匹配只匹配脚本名，不匹配当前安装根目录。本机复现：在临时解压目录跑 doctor，它把**真实安装目录** `E:\ai\_tools\errwatch` 的托盘判成“这个临时包”的托盘 alive。

`errwatch-restart.ps1` 反而做对了，查询的是：

```text
Name='pwsh.exe' OR Name='powershell.exe'
```

建议修法：统一用“两个宿主名 + CommandLine 包含当前 `$root\errwatch-xxx.ps1`”的判定，避免跨安装目录串台。

---

### P3-3：设置窗“启动看护”在无启动项且无默认 PS7 路径时会失败

`errwatch-settings-ui.ps1:854-858`：

```powershell
if (Test-Path -LiteralPath $vbsS) { ... }
else { Start-Process -FilePath 'C:\Program Files\PowerShell\7\pwsh.exe' ... }
```

如果没有登录启动项，并且机器上没有 `C:\Program Files\PowerShell\7\pwsh.exe`（例如只有 5.1，或 PS7 是 Store 版），这里会直接尝试启动一个不存在的路径，用户点“启动看护”得到操作失败。

同文件 `errwatch-settings-ui.ps1:275-276` 的救援按钮反而做了正确回退：先试默认 PS7 路径，不存在就用 `powershell.exe`。

建议修法：抽一个 `Get-PsExe` 帮助函数，设置窗、救援按钮、注册脚本共用；启动项缺失时优先用帮助函数选出的 PowerShell。

---

### P3-4：doctor 对启动文件夹只查存在，不校验指向

`register-watch.ps1 -Status` 能正确发现启动项指向旧目录：

```text
[启动文件夹] errwatch-sentinel.vbs
      → 指向旧目录！当前目录的代码不会生效
      指向: E:\ai\_tools\errwatch\errwatch-sentinel.ps1
      当前: C:\Users\17586\AppData\Local\Temp\bu\errwatch-sentinel.ps1
```

但 `errwatch-doctor.ps1:328` 只做：

```powershell
Test-Path -LiteralPath (Join-Path $startupDir ("$($it.Name).vbs"))
```

所以 doctor 对同一个临时包报告 `errwatch-sentinel（启动文件夹）` OK。用户 migrate/换目录解压后，doctor 可能说“装好了”，实际登录启动的是旧代码。

建议修法：doctor 复用 register-watch 的 `Test-StartupTarget` 判据，或至少解析 VBS 内路径并和当前目录比较。

---

### P3-5：部分文本读取依赖隐式 BOM，建议显式声明编码

实测：

- UTF-8 无 BOM 文件，`Get-Content` 不带 `-Encoding`：PS7 读对，PS5.1 按 GBK 读成乱码。
- UTF-16LE 带 BOM 文件：5.1/7 都能靠 BOM 读对。

当前 `errwatch-evidence.ps1:68` 读 `Report.wer` 不带编码，但本机 WER `Report.wer` 是 UTF-16LE+BOM，所以暂时安全。`errwatch-tray.ps1:405` 读 `ui.pid` 是 ASCII，也安全。`errwatch-source.ps1:150` 读 SDK 头文件通常是 ASCII。

这不算当前必现 bug，但是隐性跨版本依赖。建议把所有读取改成显式 `-Encoding UTF8`/`Unicode`，不要依赖默认值和 BOM 侦测。

---

## 4. 建议修复顺序

1. **P2-1 发行材料包级化**：`make-release.ps1` / `check-release-identity.ps1` 改成 `<zip>.release.json` 优先。这个修完，旧候选包才能继续自证。
2. **P3-2 进程检测统一**：托盘、看护健康、UI 单实例都改成“pwsh/powershell 双宿主 + 当前根目录锚定”。
3. **P3-3 设置窗启动回退**：抽 `Get-PsExe`，替换硬编码 `C:\Program Files\PowerShell\7\pwsh.exe`。
4. **P3-1 VBS 编码**：生成 ASCII VBS 或显式 ANSI 字节写盘。
5. **P3-4 doctor 启动项校验**：复用 stale-target 判据。
6. **P3-5 显式编码**：作为 robustness 清理，不阻塞发布。

---

## 5. 复现方式

```powershell
# 双运行时 API/语法探针
pwsh -NoProfile -File C:\Users\17586\AppData\Local\Temp\compat-probe.ps1
powershell -NoProfile -File C:\Users\17586\AppData\Local\Temp\compat-probe.ps1

# PS7 解析器复测
pwsh -NoProfile -File C:\Users\17586\AppData\Local\Temp\compat-parse.ps1

# 旧包材料绑定（默认命令，预期当前 FAIL）
pwsh -NoProfile -File tools\check-release-identity.ps1 -Zip E:\ai\_tools\_dist\errwatch-20261025-bu.zip
powershell -NoProfile -File tools\check-release-identity.ps1 -Zip E:\ai\_tools\_dist\errwatch-20261025-bu.zip
```

结论：**runtime 可以在 PS5.1/PS7 双栈跑；发布前建议至少修掉 P2-1 和 P3-2/P3-3，因为它们会让“旧包校验”和“托盘/界面状态显示”在陌生机器上给出错误结论。**
