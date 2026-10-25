# 字段感知匹配（mapping）：把"借来的规则"变成"能用的规则"

- 日期：2026-10-22
- 起因：Sigma 转换器把字段条件**展平成文本正则**，丢掉了字段语义 ——
  实测后果：`param1 contains service` 变成在整条消息里找 "service"，
  让 **1001 事件被 7000 的服务规则命中了 451 次**。
- 思路来源：**Chainsaw 的 `--mapping`** —— 规则保持原样，另配一张「字段名 → 日志字段」映射表。
- 结果：字段级匹配已跑通，端到端验证 `MatchBy=field`；回归仍 28/28 + 9/9。

---

## 一、改了什么

| 位置 | 改动 |
|---|---|
| `core\field-mapping.json`（新） | 声明「Sigma 字段名 → 事件 XML 位置」：System 段（EventID/Provider/Channel/…）+ 别名表 + 已知限制 |
| `core\analyze.ps1` | 新增 `ConvertTo-ErrwatchFieldMap`（事件 → 字段字典）、`Test-ErrwatchFieldConditions`、`TranslateEventRecord`（事件级总入口） |
| `tools\sigma-convert.ps1` | 转换时**保留字段条件原文** `fieldConditions`（展平出的正则降级为"纯文本场景"的兜底） |
| `errwatch-bundle-analyze.ps1` | 事件处理从 `TranslateEvent(id, provider, msg)` 改为 `TranslateEventRecord($e)` |

**三条匹配路径的优先级**（`TranslateEventRecord`）：

1. **字段级精确匹配** — 规则带 `fieldConditions`，事件能解析出字段 → `MatchBy='field'`，可信度**高**
2. **事件 ID + 文本** — 退回原有的 `TranslateEvent`
3. **通用匹配** — 最后退回 `TranslateForApp`

## 二、实测

| 项 | 结果 |
|---|---|
| 样本规则转换 | 6 条中 4 条带 `fieldConditions`（Provider_Name / Data\|re / param1\|contains / ClassName） |
| **真实库 1638 条** | **1561 条带字段条件**（其余是关键词类规则） |
| 事件字段解析 | 一条真实 7000 事件解析出 8 个字段：`EventID=7000`、`Provider_Name=Service Control Manager`、`param1=PICO Streaming Service`… |
| 字段条件判定 | `param1 contains 'service'` → **✅ 命中**（因为 param1 真是 "PICO Streaming Service"） |
| 整条路径 | `TranslateEventRecord` → **`MatchBy=field`** ✅ |

## 三、过程中修掉的一个 bug

`EventID` 最初从 XML 取：`[string]$xml.Event.System.EventID` → 得到的却是字符串
**`System.Xml.XmlElement`**（因为 XML 里 EventID 是带属性的节点，`[string]` 转换拿的是类型名）。
修法：改用记录自身的 `$EventRecord.Id`（本来就在用），回退时才取 `.InnerText`。

## 四、这套做法的关键性质（为什么它比展平好）

1. **字段名不匹配 → 不命中**（保守）。
   展平法的失败模式是"**误命中**"（service 到处乱命中）；字段法的失败模式是"**不命中**"（字段名对不上就静默放过）。
   对 errwatch 来说，**漏比误好**——误报会让人不再信任工具。
2. **可信度天然是「高」**：字段级判定靠结构化数据，不靠文本猜。
3. **近似点变少了**：`note` 里不再需要写"字段名已忽略"。

## 五、诚实记录

1. **真实库里那 1561 条字段规则，绝大多数与我们无关**（它们是安全检测：进程创建、注册表、网络）。
   目前 core 里只有**样本的 4 条**字段规则在用。要真正受益，需要按「系统故障类」筛一遍再启用。
2. **UserData 段暂不解析**：少数事件（如 Windows Update 相关）把数据放在 `UserData` 下，
   这类规则会退回事件 ID + 文本匹配，精度下降。
3. **字段名依赖"Sigma 与 Windows 事件同名"**：Sysmon 与 Windows 审计事件基本同名，
   但少数字段（如某些别名）会落空 → 那种规则表现为"不命中"。别名表目前只收了几条**有依据**的。
4. **没做**：字段值的类型转换（如把 `0x1` 与 `1` 视为相等）、`|cidr` / `|base64offset` 等修饰符仍是跳过。

## 六、下一步

- 把真实库里「`windows/system` + `windows/application`」且带字段条件的规则筛出来，人工过一遍，挑出真正"故障类"的启用
- UserData 段解析（让 Windows Update 类事件也能字段匹配）
