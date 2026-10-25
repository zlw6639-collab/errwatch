# 诊断结果契约 — 设计方案（2026-10-23）

> 对应外部终审 §三（诊断结果结构化）与 §四（UI 三层）。
> **本文件是方案。** 第 1 步（契约与判定函数）与第 2 步（报告 / UI 消费）已落地，
> 实现与验证见 `core\diagnose-contract.ps1` 与 §九「落地记录」；第 3 步未做。
> 评审通过后再提炼为 `core\schema\diagnosis-result.v1.md`（与 `evidence-bundle.v1.md` 并列）。

---

## 一、要解决什么

终审原话：

> 不能把所有无法给出明确结论的情况统统塞进 `unknown`。
> 如果这些情况混在一起，工具会出现一种非常隐蔽的产品问题：**界面看起来很诚实，实际却把不同的不确定性压扁了。**

现状核对（代码证据）：

| 检查 | 结果 |
|---|---|
| `unknown` 如何产生 | **穷尽式兜底** —— `Translate()` 返回 `$null` 即 unknown（`errwatch-triage.ps1:84`） |
| 是否有 `insufficient` | ❌ 无 |
| 是否有 `conflict` | ❌ 无（`tests\run.ps1` 里的 `conflictList` 只是**测试统计**，不进运行时结论） |
| 是否有 `collection-failed` | ❌ 无（采集失败**不会变成一条诊断结果**，而是变成"没采到东西"） |
| `Confidence` 现状 | 有字段，但取值是硬编码的 `'中'` / `'弱'`（`analyze.ps1:218/235`），语义不统一 |
| `limitations` | ❌ 无 |
| 日志缺口检测 | ✅ **已存在**：`Get-ErrwatchLogIntegrity($Events, $GapThreshold=6)`（`analyze.ps1:703`）—— 但没被用来判断结论强度 |
| 多规则命中计数 | ✅ **已存在**：`Count-RuleHits($Text)`（`analyze.ps1:293`） |
| 采集缺失清单 | ✅ **已存在**：证据包 `manifest.json` 有 `missing` 字段（L3 实操中记录过 `missing 7→3`） |

**关键结论**：五态所需的判据**基本都已经有了**，缺的是「统一定义 + 统一出口」。这使得本方案可以**不改判据、只加契约层**。

---

## 二、契约设计：诊断结果 v1

### 2.1 结构

```jsonc
{
  "schema": "errwatch-diagnosis",
  "schemaVersion": 1,

  "id": "20261023-153000-0007",        // 稳定 ID，供通知去重 / 反馈关联
  "time": "2026-10-23T15:30:00+08:00",

  "subject": {                          // 「在说谁」—— 与现有 UI 表格列对齐
    "app": "VRChat.exe",
    "code": "0xc0000005",
    "eventId": 1000,
    "module": "UnityPlayer.dll",
    "source": "Application"
  },

  "status": "known",                    // ★ 五态，见 2.2
  "confidence": "medium",               // ★ high | medium | low | none

  "explanation": {                      // 「我为什么这么说」
    "why": "……",
    "ruleId": "r-0xc0000005",
    "ruleSource": "rules.json",
    "matchBy": "appKnown"               // 承接现有 MatchBy
  },

  "evidence": [                         // 「我看到了什么」（可空数组，不能是 null）
    { "kind": "eventlog", "ref": "Application#1000@15:29:58", "note": "" }
  ],

  "limitations": [                      // ★ 「我还不知道什么」
    "本次采集截止 15:30，之后的事件未覆盖",
    "未找到对应的 WER 转储"
  ],

  "nextAction": {                       // 「现在最合适的下一步」
    "text": "……",
    "kind": "verify"                    // verify | collect | route | ignore
  },

  "route": "software",                  // software | system | self | unknown（承接现有 Route）
  "verifyHint": "……"                    // 承接现有 Verify
}
```

**兼容承诺**：新增字段全部**可选**；现有 `Translate()` 的返回（`Why/Do/Ref/Route/Verify/Confidence`）**一个都不删**，由适配层翻译。

### 2.2 `status` 五态与判定规则

| status | 含义 | 判定判据（落到现有函数） |
|---|---|---|
| `collection-failed` | **连"有没有问题"都不知道** | 采集阶段报告的缺失项命中关键集合（`manifest.missing` ∩ 关键证据表 ≠ ∅） |
| `insufficient` | 发现了异常，但**缺足以解释它的材料** | 命中规则，但 `Get-ErrwatchLogIntegrity` 报告缺口，或规则声明需要证据而当前缺失 |
| `conflict` | 多个来源给出**无法同时成立**的结论 | `Count-RuleHits > 1` **且** 命中规则的 `route` 不一致（最小判据，见开放问题 Q2） |
| `known` | 有规则、有证据 | `Translate()` 返回非 null，且无上述降级条件 |
| `unknown` | 规则库里**没有**这条 | `Translate()` 返回 `$null` |

**优先级（互斥，取最高）**：

```
collection-failed  >  insufficient  >  conflict  >  unknown  >  known
```

排序理由：按「用户还能不能相信自己的判断」排，而不是按严重度排 ——
前两者意味着**结论本身不可靠**，此时报告"已知 N 条"是误导；后两者才是"结论可靠与否"的问题。

> ⚠️ 这条优先级是需要评审拍板的第一个决策点（见 Q1）。

### 2.3 `confidence` 与 `status` 的分工

- `status` 回答「**我能不能给结论**」
- `confidence` 回答「**给了结论，我有多确定**」

两者独立：`unknown` 的 confidence 恒为 `none`；`known` 的 confidence 来自规则的 `verifyStatus`（`verified` → high，缺 verify → low）。

### 2.4 不变量（Invariants）

给测试用，每条都可写成断言：

1. `status = unknown` **不允许**带 `explanation.why` 有内容（不能编原因）
2. `status = collection-failed | insufficient` **必须**至少有一条 `limitations`
3. `status = known` **必须**至少有一条 `evidence`（否则应降级为 `insufficient`）
4. `evidence` / `limitations` 是数组，**不允许 null**（空数组才算"无"）
5. `nextAction` **必须**存在；`unknown` 的 nextAction 不能是 `ignore`
6. 五态判定**必须在单一函数里完成**，报告 / UI / 通知消费同一出口（承接现有的「判断逻辑只有一份」原则）

---

## 三、UI 三层设计

### 3.1 三层职责

| 层 | 回答 | 内容 |
|---|---|---|
| **首页** | 我现在该怎么办？ | 采集完整性 + 结论分布 + 一句话下一步 |
| **问题列表** | 有哪些事？ | 按 status 分组的行：重复次数 / 首次发生 / 影响对象 / 处理状态 |
| **专业详情** | 凭什么？ | 现有表格列 + 证据 + limitations + 怎么验 + 修复风险 + 审计记录 |

### 3.2 首页（含红线）

```
┌─ 本次扫描 ───────────────────────────────┐
│ ⚠ 采集不完整：缺 WER 转储、System 日志有 2 处缺口   │   ← 有缺口时**置顶**
│                                          │
│ 可给出结论    12 条（其中需处理 1 条）              │
│ 无法给结论     3 条 · 证据不足 2 · 规则未覆盖 1      │
│                                          │
│ 下一步：先补采 WER 转储，再重扫              │   ← 一句话
└──────────────────────────────────────────┘
```

**设计红线（终审明确要求）**：

> 不能把「没有发现问题」默认渲染成绿色。

落地规则 —— **绿色有准入门槛**：

```
首页允许显示绿色 ⇔ 采集完整（无 collection-failed）
                  ∧ 无 conflict
                  ∧ 无 insufficient
                  ∧ 无待处理的 known
否则一律用中性色 + 明确说明"本次结论只覆盖已采集的范围"
```

### 3.3 问题列表：按 status 分组，各给**不同的**下一步

这是"不把不确定性压扁"在界面上的落点 —— 四种"没结论"必须给四种不同动作：

| 分组 | 一句话动作 |
|---|---|
| ⛔ 采集失败 | **先解决采集**，不能当成"零异常" |
| 🟠 证据不足 | **补证据**（明确补什么） |
| 🔴 结论矛盾 | **核对来源、时间与上下文** |
| ⚪ 规则未覆盖 | 查官方资料 / 向社区求助 / 提交反馈 |
| 🟢 已有结论 | 按「怎么验」核对，再决定找谁 |

---

## 四、落地路径（三步，每步可独立验证）

用户已明确：**先做方案，不急着重构**。所以路径设计成"每步都能停"。

| 步 | 做什么 | 不做什么 | 可验证的产出 |
|---|---|---|---|
| **1** | 新增 `Get-ErrwatchDiagnosis`（**唯一出口**），内部仍调用现有 `Translate` / `Count-RuleHits` / `Get-ErrwatchLogIntegrity`，产出 v1 结构 | 不动任何现有调用方 | `tests\diagnosis-contract.ps1`：五态各至少 1 例 + 6 条不变量断言 |
| **2** | 报告（`errwatch.ps1`）与 UI 改为消费新结构；首页三层落地 | 不改规则库 | UI 走查：采集缺口时首页**不显示绿色** |
| **3** | 规则库逐步补 `evidence` / `limitations`；`confidence` 由 `verifyStatus` 推导 | 仍不改 `pat/why/do` 语义 | 覆盖率统计：多少条规则有可复现证据 |

**第 1 步做完即可评审**：契约本身不依赖 UI，也不改行为（新函数暂时只有测试调用它）。

---

## 五、验收用例（第 1 步的测试清单）

| # | 场景 | 期望 status | 关键断言 |
|---|---|---|---|
| 1 | 命中规则 + 有证据 | `known` | 有 evidence；confidence ≠ none |
| 2 | 完全未知的错误 | `unknown` | `explanation.why` 为空；nextAction ≠ ignore |
| 3 | 采集器报告关键证据缺失 | `collection-failed` | **优先于**其他所有态；limitations ≥ 1 |
| 4 | 命中规则但日志有缺口 | `insufficient` | limitations ≥ 1；nextAction.kind = collect |
| 5 | 同一文本命中两条 route 相反的规则 | `conflict` | nextAction.kind = verify |
| 6 | 多规则命中但 route 一致 | **不是** conflict | 防止把"规则重叠"误判成矛盾 |
| 7 | 六条不变量 | — | 逐条断言 |

> 用例 6 是**反例**：它保证 `conflict` 不会被滥用成"命中多条就算矛盾"。

---

## 六、明确不做的事

1. **不引入新依赖**（契约是纯数据结构）
2. **不改 `rules.json` 的 `pat/why/do`**（v2 格式保持兼容）
3. **不新增修复动作**（本方案只改"怎么表达结论"，不改"能做什么"）
4. **不把规则数量当进度**（终审 §七）：补规则要先补**证据**，不是补条数
5. **不重构现有入口**（第 1 步只加一个函数）

---

## 七、待评审的开放问题

| # | 问题 | 我的倾向 | 需要你定 |
|---|---|---|---|
| Q1 | 五态优先级 `collection-failed > insufficient > conflict > unknown > known` 是否认可 | 倾向"按用户还能不能相信自己的判断"排 | 是/否，或给出你的排序 |
| Q2 | `conflict` 的最小判据用「多命中且 route 不一致」是否够 | 够用作第一版；更强的语义矛盾判据留观察 | 是否接受"第二版再收紧" |
| Q3 | `insufficient` 是否只建在日志缺口上 | 先用 `Get-ErrwatchLogIntegrity` + 规则声明的证据需求 | 是否还有别的"证据不足"来源 |
| Q4 | 首页绿灯准入门槛（四条件全满足）是否过严 | 宁可严 —— 误报"没问题"比误报"有问题"代价高 | 是否放宽 |
| Q5 | 契约文档先放 `tests\` 还是直接放 `core\schema\` | 先放 `tests\`（未实现的东西不该进 schema 目录） | 认可否 |

---

## 八、与现有文档的关系

- 本方案**承接** `定位.md` 的三条原则（有证据 / 有边界 / 有路由），是它们在数据结构上的落点
- 契约风格**参照** `core\schema\evidence-bundle.v1.md`（自描述 + schemaVersion + 不变量）
- 与 `audit-external-20261023-终审.md` §三 / §四 对应，落实状态见下节
- **本文件不含任何已验证的实现结论** —— 代码尚未改动

---

## 九、落地记录（2026-10-23，第 2 步）

> 本节是**回填**，不是设计。第 1 步见 `core\diagnose-contract.ps1` 头部注释。

### 9.1 已落地

| 落点 | 做法 | 验证 |
|---|---|---|
| 报告 `errwatch.ps1` | §7 改为「五态分布 + 判定」；采集失败**置顶警示**；有结论但不完整时写「不能说没有发现异常」 | `tests\test-diagnosis-consume.ps1` |
| 采集状态 | 新增 `Invoke-EwCollect`：区分「零事件」（`Get-WinEvent` 报"找不到匹配事件"）与「采集失败」（其他异常） | 同上（`ERRWATCH_SIMULATE_COLLECT_FAIL` 注入） |
| 心跳 | `last-success.json` 新增 `diagnosis` 段（五态计数 / 采集失败源 / verdict）；`sources` 不再硬编码 `ok` | 同上 |
| UI `errwatch-ui.ps1` | 标题栏内新增**首页概览条**（采集完整性 / 结论分布 / 下一步）；详情区新增「结论状态 · 可信度 · 局限 · 下一步」 | `-Check` 自检 + 同上 |
| 共用出口 | `Get-ErrwatchDiagnosisSummary` / `Get-ErrwatchDiagnosisVerdict` / `New-ErrwatchDiagnosisHit` 在契约文件里，报告与 UI 只消费、不重算 | 契约验收 ⑧⑨⑩⑪ |

### 9.2 两个必须记录的判断

**① 绿灯门槛比 Q4 更严：`unknown` 也拦。**
Q4 的四条件是「采集完整 ∧ 无 conflict ∧ 无 insufficient ∧ 无待处理 known」。
实现时把 `unknown` 也加进拦截条件 —— 因为 `unknown` 是「**有报错但工具没解释**」，
此时显示绿色与本页内容自相矛盾。按 Q4 的取向（宁可严）执行，已在代码注释里写明。

**② `insufficient` 只认「实质缺口」。**
本机实测 24h 内 Application 有 55 处、System 有 54 处记录号缺口，绝大多数是
「同一秒内缺 1~2 条」的正常写入形态。若「有缺口 → 证据不足」，几乎所有已知结论
都会被降级（等于把常态误判成不可信）。
判据定为：**缺 ≥5 条 且 跨度 ≥10 分钟**，且事件在该缺口结束后 2 小时内。
本机当前数据下该判据命中 0 处 —— 也就是说：没有实质缺失时，不下「证据不足」的结论。

### 9.3 第 2 步抓到的真 bug（已修 + 已加回归）

`$gaps = if (...) { ... } else { @() }` 在 PowerShell 里会得到 `$null`，
而 `@($null).Count` 是 **1**。于是「没有缺口」的条目全被判成 `insufficient` ——
实测首跑 24 条结论里 23 条变「证据不足」。修复：契约层先滤掉空值再计数，
并新增用例 ⑧（空数组 / `$null` / `$null` 的 ExtraLimitations 都不得产生缺口）。

### 9.4 明确未做（留第 3 步或后续）

- **问题列表按 status 分组**（设计 §3.3）：当前列表仍是「有说明 / 没说明」两态；
  改列会影响「只看没说明的」筛选与忽略逻辑，单独一轮做。
- **报告正文逐条标注 status**：目前只有 §7 的汇总分布与「没结论的部分」分动作；
  §1/§4/§5 的明细仍沿用旧版式（人话 / 建议 / 怎么验 / 该找谁）。
- **UI 专业详情完整版**（证据 / 修复风险 / 审计记录）：只加了结论状态与下一步。
- **规则补 `evidence` / `limitations`**：`confidence` 仍来自 `verifyStatus` 的朴素映射。
- 契约文档尚未移入 `core\schema\`（按 Q5，等第 3 步稳定后再移）。

