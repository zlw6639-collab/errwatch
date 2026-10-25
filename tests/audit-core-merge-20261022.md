# 核心资产迁移 + 分叉消除（B-4 / B-5）

- 日期：2026-10-22
- 目标：把"核心能力与运行入口分离"从**逻辑上成立**推进到**物理上也成立**
- 结论：**9 个入口全部改用 core；3 个核心数据文件迁入 `core\`；全量验收通过**（回归 28/28、unknown 9/9）

---

## 一、B-4：剩余分叉清单，逐个消除

上一轮已经把 `run.ps1`、`notify.ps1` 的复制品换成 core。这一轮清掉剩下的四处：

| 文件 | 原来 | 现在 |
|---|---|---|
| `errwatch-query.ps1` | 自加载 rules.json + 自实现 `Translate` | dot-source core，新增 `Get-Hit`（按当前规则重算一条历史记录） |
| `errwatch-report.ps1` | 自加载 rules.json + 自写两层匹配循环 | dot-source core，用 `TranslateForApp` + `New-ErrwatchHay` |
| `errwatch-ui.ps1` | 两处自加载 rules.json（规则计数、重算翻译） | dot-source core；计数用 `Get-ErrwatchCoreInfo`，重算用 `TranslateForApp` |
| `tests/unknown-chain.ps1` | 自加载 rules/apps + `Match-AppLocal` / `TranslateLocal` | dot-source core；冲突计数用 `Count-RuleHits` |

**顺带修掉一个同类缺陷**：`query.ps1` 里三处调用是
`Translate "$($rec.code) $($rec.msg) $($rec.provider)"` —— 又是**空格拼接**，
code 为空时会留下前导空格、破坏行首锚点。改用 `Get-Hit`（内部走 `New-ErrwatchHay`）后消失。

**一个可见的行为变化（是改进，不是回归）**：
`query -Stats` 的"当前规则覆盖率"从「12 条里 2 条未覆盖」变成 **12/12 全覆盖**。
原因：那 2 条 Codex 事件只有来源名、没有错误码，`query` 旧逻辑把 provider 拼在**尾部**、
且自实现里没有"用来源名兜底"这一步；core 的 `TranslateForApp` 会先按消息、再按来源名匹配，
所以正确地命中了 Codex 规则。

## 二、B-5：核心数据迁入 core\

```
core\
  analyze.ps1     规则匹配 / 翻译 / 安全模式判断（唯一实现）
  rules.json   ←  从根目录迁入
  apps.json    ←  从根目录迁入
  noise.json   ←  从根目录迁入
  events.json     事件 ID → 人话
  schema\         证据包格式契约
```

迁移后根目录不再有这三个文件（已确认无残留）。

### 兼容策略（两种，各自场景不同）

| 场景 | 做法 |
|---|---|
| **依赖 core 的脚本**（errwatch.ps1 / notify / query / report / ui / run.ps1 / bundle-analyze） | 用 core 的 `Resolve-CoreAsset`：**优先 `core\`，回退根目录** |
| **独立入口**（`evidence.ps1` / `doctor.ps1` / notify 的 noise 加载，位于 core 加载之前） | 两行式：先试 `core\`，不存在再试根目录 —— **不引入对 core 的依赖** |

也就是说：**旧布局（文件在根目录）仍然能跑**，新布局才是规范布局。
这样一个迁移期里"只更新了部分文件"也不会炸。

### 其他同步修改

| 文件 | 改动 |
|---|---|
| `errwatch-doctor.ps1` | 核心文件清单改为「`core\` 或根目录」两种都认（新增 rules/apps/noise 三项检查） |
| `tests/run.ps1` | `rulesHash` 改用 `Resolve-CoreAsset`（跨版本对比的哈希仍可用） |
| `README.md` | 架构图、文件表、维护说明全部改为 `core\` 路径 |

## 三、全量验收（迁移后，9 个入口）

| # | 入口 | 结果 |
|---|---|---|
| 1 | `tests/run.ps1` 规则回归 | **28/28**，误诊 0、漏诊 0 |
| 2 | `tests/unknown-chain.ps1` | **9/9** |
| 3 | `errwatch-doctor.ps1` 核心数据检查 | rules / apps / noise 三项均 `[OK]` |
| 4 | `errwatch-evidence.ps1 -App VRChat` | 正常（apps.json 从 core 读到日志位置） |
| 5 | `errwatch-notify.ps1 -DryRun` | 正常（noise.json 从 core 读到降噪配置） |
| 6 | `errwatch-query.ps1 -Stats` | 正常，覆盖率 12/12 |
| 7 | `errwatch.ps1 -NoFile` 采集 | 正常出报告 |
| 8 | `errwatch-level.ps1` 定级 | rules=28 apps=6，L3 闭环就绪 |
| 9 | `errwatch-bundle-analyze.ps1` 离线分析 | 正常出报告 |

## 四、诚实记录

1. **两行式解析在 3 处各有一份**（`evidence` / `doctor` / `notify` 的 noise）。
   这是"独立入口不依赖 core"的代价，是刻意的取舍，不是遗漏 —— 但它们**语义相同**，若将来改路径策略要一起改。
2. **UI 只做了语法检查**：`errwatch-ui.ps1` 是 WinForms 界面，需要人点击才能验证，
   目前没有自动化测试覆盖它的两个改动点（规则计数、重算翻译）。
3. **迁移用的是 `Move-Item`（不可逆）**，但因为有回退逻辑，把文件放回根目录仍能工作。
4. **`Resolve-CoreAsset` 的"回退根目录"分支将来可以删掉**：
   等确认没有旧布局的包在外流通，这个兼容层就是多余的。
5. **`query -Stats` 覆盖率的口径变了**（12/12）：这不是本轮迁移引入的，
   而是 core 的判定比旧自实现更正确。历史对比时注意这一点，别误判成回归。

## 五、剩下的（更新后的清单）

| # | 事项 | 说明 |
|---|---|---|
| 1 | WinRE 实测 L3 采集 | 需你在电脑前，最大的未验证项 |
| 2 | 真实安全模式 / Ventoy PE 实测 | 同上，一次 U 盘启动可串起来 |
| 3 | 分析器细化 | 大日志按关键词筛、`diskpart`/`dism` 输出结构化 |
| 4 | UI 接入 L3 | 图形界面加"分析证据包"入口 |
| 5 | `0xe0000008` 措辞 | "不是标准 NTSTATUS" 可更精确 |
| 6 | 审计路线第 6 项 | 真实试用与误诊统计 |
| 7 | 历史挂账 | TOCTOU、`-Value` 边界、`-Port` 只验监听、并发未真压测 |
