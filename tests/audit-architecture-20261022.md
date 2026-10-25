# 架构改造：分级 + 核心/入口分离 + L3 取证 — 记录与可复现测试

- 日期：2026-10-22
- 起因：需要被回答的问题 ——「不能依赖自己的运行环境；磁盘坏了怎么办？把核心诊断能力与运行入口分离？」
- 结论：**已落地 L1/L2/L3 三级 + core/runners 分离 + 证据包接口；自测与回归全绿；WinRE 实机未验证（见诚实记录）**

---

## 一、问题是什么

改造前的 errwatch 有一个结构性缺陷：**诊断逻辑与采集动作缠在一起，且整套东西寄生在自己的运行环境里**。

| 场景 | 改造前会发生什么 |
|---|---|
| Windows 起不来（引导/驱动损坏） | 脚本就在那块可能读不出来的盘上 → 什么都拿不到 |
| 磁盘出现坏道 | 脚本本身可能读不出来；反复读盘还会加重损伤 |
| 安全模式 | 能跑但能力受限，取到的证据留在本机、带不走 |
| 想在别的机器上复盘 | 做不到 —— 没有可搬运的证据形态 |

根因：**从来没有把「核心能力」和「运行入口」分开过**。规则、判断、采集、呈现全在同一个 `.ps1` 里，
而这些脚本又假设自己运行在一个健康的 Windows 上。

## 二、决策（三件事）

### 1. 分级：按**运行环境的能力**分三级，不是按功能多少

| 等级 | 判据 | 入口 | 重点 |
|---|---|---|---|
| L1 正常看护 | 系统正常 | `errwatch.ps1` | 采集 + 翻译 + 有限修复 |
| L2 安全模式诊断 | `SafeBoot\Option\OptionValue` 存在 | `errwatch.ps1`（降级） | **取回证据**，恢复受限 |
| L3 恢复环境取证 | Windows 本身起不来 | `runners\L3-collect.cmd` | 只读取证 → 证据包 → 换机器分析 |

关键认识：**L3 时 errwatch 的 PowerShell 入口本来就不可能运行**（它在那块坏盘上）。
所以 L3 的入口不能是"另一个 .ps1"，必须是**不依赖本机 Windows 的执行体** —— 纯 cmd。

### 2. 分离：核心 = 纯数据 + 纯逻辑；入口 = 薄壳

```
core/     ← 不依赖运行环境
  analyze.ps1   规则匹配 / 翻译 / 安全模式判断（唯一实现）
  events.json   事件 ID → 人话
  schema/       证据包格式契约
runners/  ← 入口
  L3-collect.cmd   纯 cmd 采集器（WinRE 可跑，不需要 PowerShell）
  L3-操作卡.md      给人看的步骤
errwatch.ps1 …     L1/L2 入口（只做采集 + 呈现）
errwatch-bundle-analyze.ps1  证据包分析器（不碰原机器）
```

实测验证了分离是真的：把 `errwatch.ps1` 单独拷到空目录运行 → 明确报"核心层缺失"并 `exit 2`，
**不会静默降级成半残状态**。

### 3. 证据包：唯一的跨环境接口（也是"磁盘坏了"的答案）

证据包 = `manifest.json`（自描述）+ `items/`（原件 + 哈希）+ `README.txt`。
四条硬规矩写在 `core/schema/evidence-bundle.v1.md`：自描述、不依赖采集环境、采集不判断、**失败也是证据**。

**磁盘坏了怎么办**（这是问题里最硬的一条）：

| 情况 | errwatch 的答案 |
|---|---|
| 逻辑损坏（引导/文件系统） | 进 WinRE，`L3-collect.cmd` 只读取证 → 换机器分析 |
| 物理损坏（坏道/异响/盘半死） | **明确不做数据恢复**。路由：先只读镜像（ddrescue / DiskGenius / 厂商工具，跳过坏道、可断点续做），再对镜像取证 |
| 盘完全读不出（主控挂） | 路由给专业数据恢复，errwatch 不假装能帮 |

原则一致：**能安全做的才做，超出的明确告诉你该找谁**。

## 三、改了什么

新增：

| 文件 | 作用 |
|---|---|
| `core/analyze.ps1` | 核心诊断层（规则匹配、翻译、安全模式判断） |
| `core/events.json` | 14 条事件 ID → 人话（蓝屏 1001、磁盘 7/11/51、服务 7000/7001、驱动 219、非正常关机 41/6008…） |
| `core/schema/evidence-bundle.v1.md` | 证据包格式契约 |
| `runners/L3-collect.cmd` | L3 采集器（约 470 行 cmd，GBK 编码） |
| `runners/L3-操作卡.md` | 人看的操作步骤（含"先镜像再分析"的顺序） |
| `errwatch-bundle-analyze.ps1` | 证据包分析器 |
| `errwatch-level.ps1` | 定级与路由 |

改动：

| 文件 | 改动 |
|---|---|
| `errwatch.ps1` | 改为薄入口：删除内联的规则加载与 4 个翻译函数，dot-source `core\analyze.ps1` |
| `errwatch-doctor.ps1` | 安全模式判断改为复用 core |
| `errwatch-fix.ps1` | 同上（3 处重复实现收敛为 1 处） |
| `README.md` | 新增「三个等级」「架构：核心与入口分离」两节 |

## 四、测试结果

| 测试 | 结果 |
|---|---|
| 语法（全部脚本） | OK |
| 安全模式自测（`_tmp/sm-test.ps1`，20 项） | **20/20 PASS**（含 L2 演练允许、L2 执行拒绝、授权后执行、审计留痕） |
| 规则回归 `tests/run.ps1` | 总数 20 / 正确 20 / 误诊 0 / 漏诊 0 |
| unknown 全链路 `tests/unknown-chain.ps1` | PASS 9 / FAIL 0 |
| 核心缺失行为 | 单独拷贝 `errwatch.ps1` → 明确报错并 `exit 2` |
| **L3 闭环实测** | `L3-collect.cmd` → 证据包 → `errwatch-bundle-analyze.ps1` → 242 行报告，退出码 0 |
| 证据包 manifest | 标准 JSON 可解析；12 items / 9 commands（失败 6）/ 8 missing 如实记录 |
| 定级脚本 | L1 与 `ERRWATCH_SAFEMODE=1`（L2）判定均正确；`-Json` 可用 |

复现：

```powershell
$root = "E:\ai\_tools\errwatch"
pwsh -File "$root\errwatch-level.ps1"                       # 定级
cmd /c "$root\runners\L3-collect.cmd E:\bundle C:"          # L3 采集（WinRE 里同样命令）
pwsh -File "$root\errwatch-bundle-analyze.ps1" -Bundle E:\bundle
```

## 五、这一轮踩到的坑（都已修，记录以免重犯）

写 cmd 采集器踩的坑比预期多，逐条记下来：

1. **UTF-8 的 .bat 会解析错乱** —— 即使开头 `chcp 65001`，cmd 仍按字节逐行读脚本，中文注释被拆字节，
   报出一堆 `'ens' is not recognized` 之类的怪错。**正解：GBK 编码 + CRLF 换行，不用 chcp 65001。**
2. **`> file ( ... )` 不是合法的块重定向** —— 正确写法是 `( ... ) > file`（重定向写在块结束括号之后）。
3. **`"%~3"` 把整条命令加了引号** —— `"dism /image:C:\ /get-packages"` 会被当成一个程序名。
   正确写法 `%~3`（不加引号）。
4. **需要提权的命令在非管理员下会「挂起」而不是失败** —— `diskpart` / `fsutil` / `vssadmin` 全都
   12 秒不退出、输出 0 字节，**把整个采集卡死**。正解：**先探测能力，再决定跑不跑**
   （探测管理员 + `where` 查命令存在性，跳过项如实记进 `missing`，并说明"WinRE 下自动满足"）。
   —— 这条是最值得记住的：**"失败"和"挂起"是两种东西，后者只有超时才能发现。**
5. **JSON 里裸反斜杠非法** —— Windows 路径 `C:\Windows` 里的 `\W` 不是合法转义，标准解析器直接报错。
   正解：采集器把 manifest 内的反斜杠统一规范化为正斜杠；分析器再做一层宽容解析兜底。
6. **`if exist config\SYSTEM` 对普通用户永远为假** —— 用它判断"目标系统可读"会把正常系统误判成不可读。
   正解：改用普通用户可读的 `ntoskrnl.exe`；hive 可读性单独用一个字段记录。
7. **cmd 写出的 manifest 是 GBK** —— 分析器若按 UTF-8 读会乱码。
   正解：分析器做编码探测（BOM → UTF-8 严格解码 → GBK 回退），不假设采集环境的编码。
8. **PowerShell 别名会静默覆盖同名函数** —— 定级脚本里我把输出助手命名为 `H`，而 `h` 是 `Get-History`
   的内置别名，**别名优先**，调用被 `$ErrorActionPreference='SilentlyContinue'` 吞掉，标题行直接消失。
   正解：函数改名为 `Say`；教训是**别用单字母函数名**，也别用 SilentlyContinue 掩盖整套逻辑。

## 六、诚实记录（未做到 / 未验证）

1. **没有在真实 WinRE 里跑过 L3 采集器**（最大未验证项）。
   本次只在**正常 Windows 的 cmd** 里跑通了同一份脚本。
   WinRE 的差异（`X:\Windows` 环境、目标盘离线、默认管理员）是**按机制推断**的，没有实测。
   验证方法：从安装 U 盘启动到修复模式，跑一次 `L3-collect.cmd`，对照 `missing` 是否清空。
2. **需要管理员的那几个采集项没有实测成功路径** —— 本机非管理员，`diskpart` / `dism /image` /
   `reg load` 全部走了"跳过 + 记 missing"的分支。它们在 WinRE 下应该可用，但**没验证过**。
3. **采集器的 `--dumps` / `--full` / `--chkdsk` 未实测**（只在解析层面通过）。
4. **`rules.json` / `apps.json` 仍在根目录**，没有迁进 `core\`。
   `Resolve-CoreAsset` 是"优先 core\、回退根目录"，所以功能正常，但**核心资产的物理位置还没统一**。
5. **UI 没有接入 L3** —— `errwatch-ui.ps1` 仍是 L1 形态，没有入口指向证据包分析。
6. **分析报告对 `setupact.log` 这类大日志只打印前 20 行**，价值有限；
   应该像 `SrtTrail.txt` 那样按关键词筛选。
7. **`diskpart` 的采集结果没有被解析**（只展示原文），没有做"卷异常/分区异常"的判断。

## 七、下一轮建议（按性价比排序）

1. 进一次 WinRE 实测采集器 —— 这是唯一能验证 L3 是否真成立的方式
2. 把 `rules.json` / `apps.json` 迁进 `core\`，让"核心资产"的物理位置也统一
3. 分析器：大日志按关键词筛、`diskpart`/`dism` 输出做结构化解析
4. 审计路线里仍未做的两项：**第 4 项（故障测试集 / 规则回归语料）**、**第 6 项（真实试用与误诊统计）**
