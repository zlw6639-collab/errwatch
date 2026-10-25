# 审计：L3 采集与离线分析的**本机预演**（2026-10-22 晚）

> 背景：明天要在真机 WinRE 里验证 L3（交接待办 A-1）。动手前先在正常系统把
> 「采集 → 证据包 → 离线分析」跑一遍 —— 结果抓出 **5 个真 bug**，其中 3 个会让
> 真机实测必然失败（或得出错结论）。

## 一、发现的问题

### 1. manifest 每条记录前多一个空对象 `{}`（严重）

`L3-collect.cmd` 用 `"items": [ {}` 占位，之后每条都带前导逗号 → 产出
`[{}, {"name":...}, {"name":...}]`。分析器把空对象当条目（`@($m.items).Count` 多 1），
`missing` 里也多一条空白缺口。

**修复**：数组开头改为 `[`，三个子例程加 `!IT_SEP!` / `!CM_SEP!` / `!MS_SEP!`
（首条无逗号，之后置 `,`）。

### 2. `wevtutil epl` 自己占住自己的输出文件 → exit 32（严重）

`:run` 子例程会执行 `命令 > "%ITEMS%\同名文件" 2>&1`；而 `wevtutil epl System <同名文件> /ow`
的**输出参数**就是那个文件 —— 重定向先把它占住，`wevtutil` 再写 → 共享冲突（exit 32）。
**本机实测**：单独跑 `wevtutil epl System x.evtx /ow` 成功（19.99 MB），走 `:run` 必然失败。

**修复**：新增 `:runto` 子例程（不套重定向，命令自己写文件，检查退出码与产物），
System/Application/Setup 三条改走它。

### 3. 单文件上限 5 MB → 默认事件日志根本取不到（严重）

Windows 默认 System / Application 日志各约 **20 MB**；`:addfile` 的 5 MB 上限会直接拒绝
（只记进 large-files.txt）。WinRE 路径（`SAME_ROOT=0`）正是走 `:addfile` 拷 evtx 原件
—— 不修的话，真机实测必然"事件日志缺失"。

**修复**：上限 5 MB → **64 MB**；文案同步改。

### 4. 分析器把「事件 ID 0」当成 Perflib（严重）

`Get-EventRule` 用 `[int]$r.id` 比较，而 `events.json` 里 provider 级条目（Perflib）**没有 id**
→ `[int]$null = 0` → Application 日志里所有 EventID 0 的事件（1503 条）都被贴成
「性能计数器加载失败（Perflib）」；组内抽样再被翻成「访问违例 0xc0000005」，是彻底的误导。

**修复**：`Get-EventRule` 跳过无 `id` 的条目；关注列表 `$ids` 只收带 `id` 的条目。

### 5. 分析器不区分日志 → Application/1001 被贴成「蓝屏 878 次」（严重）

`events.json` 里**早就有 `log` 字段**（1001=System 蓝屏、1000=Application 崩溃、12=System 蓝牙），
但 `Get-EventRule` 只按 id 查。结果 Application 的 1001（WER 错误报告）显示成"蓝屏 878 次"，
Application/12 也显示成"蓝牙适配器"。

**修复**：`Get-EventRule` 增加 `$LogName` 参数；条目有 `log` 时要求一致；
关注列表按"适用于这份日志"过滤。修复后 Application/1001 不再被收录（该事件在表里没有
Application 版本的解释 —— 属**已知覆盖缺口**，见下）。

## 二、验证（本机预演）

| 项 | 结果 |
|---|---|
| 采集 | RC=0；items **12**、commands 9、missing 8，**零空元素** |
| 事件日志 | `System.evtx` 19,992,576 B、`Application.evtx` 19,992,576 B、`Setup.evtx` 1,118,208 B，`kind=eventlog`，`wevtutil` 三条 **exit=0** |
| 分析 | 读取 20000 / 20000 / 1420 条；事件组正确：Application 1000×474、1002×51、System 219×13、7031×8、2004×6、7045×29；**无"事件 0"、无"蓝屏 878 次"** |
| 非管理员降级 | diskpart / 离线注册表 / dism 均跳过并如实记入 `missing`（预期行为） |

## 三、真机 WinRE 实测（2026-10-22 20:03，本机）

用 `shutdown /r /o` 进 WinRE → 命令提示符 → 跑 `C:\ai\go.cmd`（WinRE 里盘符重排：正常 `E:` → 里面的 `C:`）。

| 项 | 结果 |
|---|---|
| 环境识别 | `environment=winre`、`systemRoot=X:/windows` ✓ |
| 目标系统盘探测 | **D:**（WinRE 里系统盘变成 D:）✓ 命中 |
| 事件日志原件 | `System.evtx` / `Application.evtx` 各 **20.9 MB**、`Setup.evtx` 1 MB，`:addfile` 直接拷成功 ✓（64 MB 上限生效） |
| 离线注册表 | `reg load` + `reg-services.txt` **67.9 KB** ✓（正常系统里做不了） |
| bcdedit | exit=0、4 KB ✓（正常系统里 exit=1） |
| 采集条目 | **17 项**（正常系统 12 项） |
| 分析器 | 读 20000/20000/1420 条；事件组正确（Application 1000×475、1002×51……），无「事件 0」、无「蓝屏 878」 |

**实测发现的 bug（已修）**：`where diskpart` / `where dism` 在 WinRE 里失效（PATH 不含 System32），
导致 `disk / diskfree / shadows / packages` 被当成"需要管理员权限"跳过，实际是"没探测到工具"。
修复：改用 `if exist %SystemRoot%\System32\xxx.exe` 探测；`env.txt` 记录 `IsAdmin/HasDiskpart/HasDism`；
缺项文案区分「非管理员（IS_ADMIN=0）」与「环境里没有该工具」。

## 四、仍然未验证

1. Ventoy 注入触发（`VentoyAutoRun.bat`）未在真机启动过。
2. `diskpart` / `dism` 的探测修复**尚未在 WinRE 复测**（正常系统已复测：`HasDiskpart=1`、文案正确）。

## 五、容忍的已知缺口

- `Application/1001`（WER 错误报告）目前**没有解释**，会从「关键事件」里消失。它是"应用崩溃的报告"，与 `Application/1000` 高度相关；补一条表项即可，未做。
- `dir` 类命令在"目录不存在"时 exit=1，会被记成"命令失败"（本机 `MEMORY.DMP`、`System32\config` 两例）。语义上应是"没有这个文件"，属噪音级问题。

## 六、教训

- **预演比实测便宜**：这 5 个 bug 如果留到 WinRE 里才暴露，等于白重启两次。
- `:run` 这种"包一层重定向"的通用封装，遇到**自己写文件的命令**（wevtutil、xcopy、robocopy）
  必然打架 —— 通用入口要留一条"不套重定向"的旁路。
- 数据表里已有的字段（`log`）没人用，等于没有；**消费端才是口径的最终定义**。
