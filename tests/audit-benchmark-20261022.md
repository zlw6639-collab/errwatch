# 对标社区（补充）：两个更接近的同类

- 日期：2026-10-22
- 背景：先前这一节写着"Chainsaw / Hayabusa / FRST 没抓到，不引用其细节"。
  后来发现 `ghproxy.net` 这条通道可代理 raw.githubusercontent.com，于是补上了实测。
- 抓取方式：`https://ghproxy.net/https://raw.githubusercontent.com/<owner>/<repo>/<branch>/README.md`

---

## 一、Chainsaw（WithSecure Labs）

**它是什么**：Rust 写的 Windows 取证「第一响应」工具 —— 快速在事件日志等取证产物里找威胁。

| 事实 | 出处 |
|---|---|
| 支持 **Sigma 规则**：`--sigma` 指定规则目录，`--mapping` 指定**字段映射文件** | README「Sigma Rule Matching」 |
| 支持解析：evtx 事件日志、**MFT**、**Shimcache**、**Amcache**、**SRUM**、注册表 hive、ESE 数据库 | README「Features」 |
| 输出 ASCII 表 / CSV / JSON；可跨 MacOS / Linux / Windows | README「Features」 |
| 自带一套 Chainsaw 规则（AV 告警解析、日志被清空、账户创建、远程登录、暴力破解） | README「Chainsaw Detection Rules」 |
| 它支持的字段映射覆盖：Sysmon 1/3/7/11/13、PowerShell 4104、进程创建 4688、计划任务 4698、服务创建 7045 等 | README 表格 |
| 作者判断："very few open-source, standalone tools that provide a simple and fast method of triaging Windows event logs" | README「Why Chainsaw?」 |

**⚠️ 一条实用警告**：README 专门写了一段 **EDR / AV 误报** ——
因为示例日志和 Sigma 规则里含 `mimikatz` 之类的字符串，Chainsaw 会被部分杀软判为恶意。
**这条直接印证了我们此前的判断：只该引入"系统故障类"规则，不要全套导入安全规则。**

## 二、Hayabusa（Yamato Security）

**它是什么**：Windows 事件日志的**快速取证时间线生成器** + 威胁狩猎工具。

| 事实 | 出处 |
|---|---|
| Rust 写，多线程；把单机或上千台系统的日志合成 **CSV / JSON / JSONL 时间线** | README「About」 |
| 自称 **"the only open-source tool with full Sigma support, including v2 correlation rules"** | README 顶部 |
| 可实时运行、可收集日志离线分析、可通过 Velociraptor 做企业级狩猎 | README「About」 |
| 输出可接 LibreOffice / Timeline Explorer / Elastic Stack / Timesketch | README「About」 |
| GNU AGPLv3；规则部分用 Detection Rule License 1.1 | README「Contributing & License」 |

## 三、这两份 README 给我们的三条启示

### 1. ★ `mapping` 文件才是 Sigma ↔ evtx 的正解（我们现在的做法是有损的）

我们的转换器把 Sigma 的字段条件**展平成文本正则**（"CommandLine|contains: x" → 正则 `x`），
这在原理上就丢掉了字段语义。而 Chainsaw 的做法是：
**保留 Sigma 规则原样，另配一个 mapping 文件，声明"哪个 Sigma 字段对应事件日志里的哪个真实字段"**。

差别很实在：
- 我们的做法：`service` 这种宽泛词会去匹配整条消息（实测让 1001 事件被 7000 规则命中 451 次，靠 `TextMatch` 标记才按下去）
- mapping 的做法：`param1|contains: service` 只在事件 XML 的 `param1` 字段里匹配 → 精确

**这条是下一步最有价值的技术方向**：让证据包分析器变成**字段感知**的
（evtx 的结构化字段 + 一张字段映射表），而不是继续在文本上做近似。

### 2. 只引入"系统故障类"规则 —— 有实测依据了

Chainsaw 明确说自己会被杀软误报（规则里有 `mimikatz` 等字符串）。
errwatch 是要长期在用户机器上跑的东西，**被 AV 盯上就等于废了**。
所以：从 Sigma 那 3000+ 条里**只挑系统故障相关的**（磁盘、蓝屏、服务失败、意外关机），
不导入安全检测类规则。这不只是"目标不同"，也是**工程上的必要**。

### 3. 定位差异被再次确认

| 维度 | Chainsaw / Hayabusa | errwatch |
|---|---|---|
| 受众 | 安全分析师 / 事件响应 | 遇到报错但不做技术的人 |
| 形态 | 命令行 CLI + Rust 二进制 | 双击 `.bat` + PowerShell |
| 输入 | evtx / MFT / SRUM / hive（取证产物） | 事件日志 + 直读现场（含安全模式/WinRE） |
| 输出 | 表格 / CSV / JSON / 时间线 | **人话 + 建议 + 该找谁** |
| 结论 | 命中某条检测规则 | 命中 + 边界（`unknown` 是显式状态） |

它们**功能强得多**（解析的取证产物种类、多系统、时间线、生态），这不需要回避。
但"把命中翻译成使用者能行动的结论、并说明哪些不该由工具替他决定"，仍然没人做 ——
Chainsaw 输出的是"检测到 CobaltStrike 服务安装"，errwatch 输出的是"这个报错是什么、你该怎么办"。

## 四、诚实记录

1. 这两份 README 是**通过第三方代理（ghproxy.net）**抓的，未走官方网络路径；内容可信度按原文对待。
2. 只读了 README，**没读它们的源码**，也没实际跑过它们的工具 —— 所以上面只写 README 明说的事实。
3. 依然没抓到 **FRST**（Farbar Recovery Scan Tool）的资料。
4. **没有跑过 SigmaHQ 的真实规则库**（GitHub 列目录 API 被 403，拿不到文件清单）——
   这一条仍然待解，见 `tests\audit-sigma-20261022.md` 的诚实记录。
