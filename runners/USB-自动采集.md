# 插上 U 盘就能用吗？—— 自动采集 U 盘的做法与边界

> 直接回答三个问题：
> **能自动采集吗？** 开机从 U 盘启动之后可以做到**全自动**（有现成机制，见路线 A）。
> **能自动存储吗？** 能 —— 采集器本来就是把证据包写到 U 盘（自描述 + 哈希）。
> **能自动分析吗？** **不能**。没有能执行分析器的系统，就没有执行者。分析要么在带 PowerShell 的 PE 里做，要么搬到另一台机器。

---

## 一、先把"自动"拆成三段，这段段不一样

| 阶段 | 能不能自动 | 为什么 |
|---|---|---|
| **1. 从 U 盘启动** | ⚠️ 要人动一次手 | "从哪启动"由主板固件决定（BIOS/UEFI 启动顺序），**不是 U 盘能决定的**。至少要在开机时按一次启动菜单键（F12 / F11 / Esc / F8，视品牌）选 U 盘。 |
| **2. 启动之后采集** | ✅ **可以全自动** | PE 启动后会执行注入的脚本 —— 见下面路线 A / C 的现成机制。 |
| **3. 分析证据** | ❌ 黑屏那台做不到 | 分析器需要一个能跑 PowerShell 的系统。选择只有两个：带 PowerShell 的 PE（Hiren's / Medicat 这类），或者另一台电脑。 |

**所以"插上 U 盘，黑屏的机器自己就把故障分析出来了"这种情况不存在。**
但"开机选一下 U 盘，剩下的全自动跑完、结果写到 U 盘"是**完全可以做到**的。

> 唯一能省掉第 1 步的办法是把 U 盘设成固件里的第一启动项。
> 这是**修改固件设置**，属于持久改动，也可能影响你正常开机 —— errwatch 不建议默认这么干。

---

## 二、三条路线（都借用成熟社区方案，不重造）

### 路线 A：Ventoy + 自动执行脚本（最接近"全自动"）

[Ventoy](https://www.ventoy.net/) 是一个"把 ISO 文件丢进去就能启动"的 U 盘方案。
它从 **1.0.55** 起支持：只要给 ISO **注入**一个 `X:\VentoyAutoRun.bat`，Ventoy 就会在
`winpeshl.exe`（标准 Windows / WinPE ISO）或 `PECMD.EXE`（多数 WinPE）**运行之前自动执行它**，
并把 bat 的输出存到 `X:\VentoyAutoRun.log`。

它还会传两个参数给这个 bat，正好够我们定位文件：

| 参数 | 含义 | 我们怎么用 |
|---|---|---|
| `%1` | ISO 文件的绝对路径（如 `E:\ISO\Win11.iso`） | 从中取出 **U 盘数据分区的盘符** |
| `%2` | ISO 的挂载盘符（如 `F`） | 备选查找路径 |

配套模板已经写好：**[`VentoyAutoRun.bat`](VentoyAutoRun.bat)**。它会：
自动定位 U 盘上的 errwatch → 自动探测目标系统盘 → 调用 `L3-collect.cmd` → 把证据包写回 U 盘 → 全程记日志。

用法：

1. 用 Ventoy 把 U 盘做成启动盘
2. 把 Windows 安装 ISO（或任意 WinPE ISO）放进 U 盘
3. 把 `errwatch\` 整个目录拷到 U 盘根目录
4. 按 Ventoy 的 [Injection Plugin](https://www.ventoy.net/en/plugin_injection.html) 说明，
   把 `VentoyAutoRun.bat` 打包成 `windows_injection.7z` 注入到那个 ISO
5. 之后：**开机 → 选 U 盘 → 进 PE → 脚本自动跑完 → 证据包已经在 U 盘上**

局限：需要一次性的定制动作（打包注入包）；部分特殊 WinPE 不支持这个机制（Ventoy 文档自己标注了）。

### 路线 B：直接借用预制救援盘（最省事，不需要定制）

如果不想定制，用现成的救援盘，进去后**手动双击一次**采集器：

| 方案 | 是什么 | 备注 |
|---|---|---|
| [Hiren's BootCD PE](https://www.hirensbootcd.org/) | 基于 Windows 11 PE x64 的救援盘，含一批免费工具，支持 UEFI | 官方页面写明需 ≥4 GB 内存；不含盗版软件 |
| [Medicat USB](https://medicatusb.com/) | 多启动的诊断/恢复工具合集（含分区、备份、数据恢复工具） | 体积大，工具最全 |
| Windows 安装 U 盘自带的修复模式 | 微软官方介质，进去就是 WinRE | 最"干净"、最稳，但工具少；按本目录的 [`L3-操作卡.md`](L3-操作卡.md) 操作 |

这类 PE 通常**自带 PowerShell**，所以连分析也能当场做（见第四节）。

### 路线 C：SystemRescue（Linux 侧，专治坏盘）

[SystemRescue](https://www.system-rescue.org/) 是一个 Linux 救援盘，自带：

- `ddrescue` —— 从**有硬件错误**的盘上做镜像（跳过坏块，可断点续做）
- `testdisk` —— 分区表/文件恢复
- `memtest` —— 内存测试
- `ntfs3g` —— 读写 NTFS
- 以及 **autorun** 机制（官方文档：*Run your own scripts at start-up with autorun*）

它还有一篇专门讲 **从起不来的 Windows 电脑里备份数据** 的文档。
**盘有物理损坏时，走这条路线**：先用 ddrescue 做只读镜像，再对镜像取证。

---

## 三、为什么"纯插上就自动"做不到（说清楚，不糊弄）

1. **U 盘不能让自己被启动** —— 启动顺序在固件里，不在 U 盘上。
2. **没有系统就没有执行者** —— Windows 起不来时，机器上没有任何组件会自动运行你的 U 盘里的程序。
   现在的采集器能在 WinRE 里跑，是因为 **WinRE 本身是一个操作系统**。
3. **固件层面的"自动运行"不存在通用机制** —— 能持久化改变启动顺序，但那已经是改机器设置，不是 U 盘的能力。
4. **分析必须有算力** —— 黑屏状态下没有可用的执行环境；PE 里的分析能力取决于那个 PE 是否带 PowerShell。

诚实结论：**"自动"能省掉的是第 2 步的全部人工，第 1 步至少要按一次启动键。**

---

## 四、分析放在哪做

| 选项 | 说明 |
|---|---|
| **带 PowerShell 的 PE**（Hiren's / Medicat / 定制 PE） | 在 PE 里直接 `pwsh -File errwatch-bundle-analyze.ps1 -Bundle <盘>:\bundle` —— 当场出报告 |
| **另一台电脑** | 把 U 盘插过去，同样一行命令。这是最稳的做法（分析器不依赖原机器） |
| Windows 安装盘自带的 WinRE | **通常没有 PowerShell**，只能用 cmd 采集，分析要换地方 |

标准 WinPE 默认不带 PowerShell，需要额外加组件包；预制救援盘一般都带 —— 这是选路线 B 的一个实际理由。

---

## 五、边界与风险（必须知道）

1. **errwatch 不改你的机器设置** —— 不会自动把 U 盘设成第一启动项，那属于固件改动，请你自己决定。
2. **只读优先**：`L3-collect.cmd` 默认不改动被检查的系统；`--chkdsk` 也只是 `/scan`（只读）。
3. **盘有物理损坏时不要反复采集** —— 先按路线 C 做镜像，再对镜像取证。
   在坏盘上反复读取会加重损伤，这一点比"采集到全不全"重要得多。
4. **证据包会变大**：默认不拷贝 >5MB 的单文件、不拷内存转储。
   需要全量再加 `--dumps` / `--full`，并留够 U 盘空间。
5. **模板里的目标盘探测是启发式的**（找 `\Windows\System32\ntoskrnl.exe`）——
   多系统、隐藏分区、BitLocker 等情况下可能选错。日志里会写明它选了哪个盘，
   不对就手动跑一次并显式指定盘符。

---

## 六、实测记录（是证据，不是承诺）

| 被测 | 结果 |
|---|---|
| `VentoyAutoRun.bat` 在**正常 Windows 的 cmd** 里端到端 | ✅ 定位 errwatch → 探测目标盘 → 调用 L3 采集 → 证据包写出（manifest 合法：12 items / 9 commands / 8 missing） |
| 目标盘探测在正常 Windows 下 | ✅ 行为正确：`%SystemDrive%`（C:）被排除 → 探测不到 → 警告并退回 C:。**在 PE 里 SystemDrive=X:，C: 不会被排除** —— 别把这条警告当 bug |
| 证据包内容（中文与结构） | ✅ `manifest.json` 可被标准解析器读、`README.txt` 中文正常 |
| **真实 Ventoy + WinPE 环境** | ❌ **没有验证过**。模板按 Ventoy 官方文档的机制写，但没在真机上启动过一次 |

一个排查提示：如果你用 PowerShell 中转 cmd 的输出来看日志，中文会显示成乱码 ——
那是「GBK 输出被 PowerShell 按 UTF-8 解码」的**显示**问题，证据包本身正常（已单独验证）。
真实场景里 Ventoy 直接写 `X:\VentoyAutoRun.log`，不经过 PowerShell。

## 七、来源

- Ventoy 的自动执行机制：[About VentoyAutoRun.bat](https://www.ventoy.net/en/doc_inject_autorun.html)、[Injection Plugin](https://www.ventoy.net/en/plugin_injection.html)
- Hiren's BootCD PE：[hirensbootcd.org](https://www.hirensbootcd.org/)（Win11 PE x64、UEFI、≥4GB 内存）
- Medicat USB：[medicatusb.com](https://medicatusb.com/)（诊断与恢复工具合集）
- SystemRescue：[system-rescue.org](https://www.system-rescue.org/)（ddrescue / testdisk / memtest / ntfs3g / autorun）
