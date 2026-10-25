# errwatch 优化备忘（第三轮审查，2026-10-22 22:10）

> 前两轮审「正确性」（两个 P0 已修复并复验通过）。本轮专查**运营期会天天咬人**的问题，
> 全部带本机实测证据。按价值排序，P1 优先。

---

## O1（P1，架构割裂）：降噪只做在弹窗通道，报告通道完全没有

**证据**：
- `noise.json` 的三层降噪（ignore / quiet / aggregate）只在 `errwatch-notify.ps1:171-199` 消费；
  `core/analyze.ps1` 全文无 noise 逻辑，`errwatch.ps1` 无任何 ignore/quiet。
- `errwatch.ps1` 的采集口径（201-240 行）：System/Application 的 **Level 1/2 全采不过滤**，
  只有 Level 3 警告按「事件表已收录」收窄。
- 实测后果（7 天窗口报告 §5）：用户在 `noise.json` 明示 ignore 的
  `CodexSandboxService ×14` 照样进报告；§4 的 Top-12 分组第一位被
  `DistributedCOM/10005 ×59`（未收录）占位。

**问题本质**：用户亲口说「别烦我」的噪音，在它几乎不看的弹窗通道被尊重，
在它真正读的报告通道被无视。且这又是一处「同一语义两份实现」——notify 的 `Test-Rule`
是本地函数，与 core 的规则翻译各玩各的（上一轮刚删掉 `Get-SystemMessageFallback`
的同类分叉，这里留了一个更大的）。

**修法**：把 noise 加载 + `Test-ErrwatchNoiseRule` 提到 `core/analyze.ps1`
（与 `Get-SystemMessageFallback` 同一模式），`errwatch.ps1` 在分组前应用：
ignore → 不进报告但计数；quiet → 进报告不计入告警。notify 改为调用 core 版。

---

## O2（P1，运营）：prune 工具存在但零调用，报告无限堆积

**证据**：
- 计划任务 10 分钟一次、`RepetitionDuration` 设了 3650 天（`register-watch.ps1:59-63`）；
- 工具目录今天已堆 **21 份 `report-*.md`**（13:09→21:55），无任何自动清理
  （notify/errwatch/doctor 全文无 prune 调用，只有文档和打包排除模式提到它）；
- `errwatch-prune.ps1` 本身设计良好（演练默认、先备份再删、历史双上限 + 报告保留 N 份），
  但「靠人记得跑」——正是两个 P0 的同款根因。

**修法**（二选一或都做）：
1. `errwatch-notify.ps1` 成功路径末尾自动跑 `errwatch-prune.ps1`（无 `-Commit`，
   超阈值才 Commit——把「记得」变成「条件触发」）；
2. `errwatch-doctor.ps1` 加水位检查：报告份数 > 30 或 history > 5000 时黄条提示。

---

## O3（P2，规则供给）：Top 事件源未收录，unknown 率约四成

**证据**（近 7 天 Error/Critical 全量实测，227 事件 / 16 分组）：

| 未收录（unknown） | 次数 | 说明 |
|---|---|---|
| DistributedCOM / 10005 | **59** | 全场第 1 位。DCOM 服务无法启动，多为权限/配置，常无害但量大 |
| CodexSandboxService / 1003 | 14 | noise 里有 ignore 规则（见 O1，修了 O1 它自动消失） |
| VSS / 8193 | 4 | 卷影意外错误（0x8007045b 正在关机） |
| .NET Runtime / 1022、1026 | 2 | 分析 API 附加失败 |
| SCM / 7043、WUClient / 20 | 各 1 | 服务启动被拒 / 更新下载失败 |

unknown ≈ **37% 事件量、44% 分组**。补录优先级：DCOM 10005 一条顶掉约 1/4 的 unknown，
且它大概率该进 `quiet`（无害但要看见）；VSS 8193 与 SCM 7043 值得人话。

**配套**：`errwatch-query.ps1 -Unknown` 已能列未知候选，但写 `core/events.json`
无任何辅助（手改 JSON）。建议 `errwatch-source.ps1` 加 `-AddEvent` 半自动落库
（抓官方定义 → 生成条目骨架 → 人补 why/do）。

---

## O4（P2，数据丢失）：历史库每次只录最新 10 条崩溃

**证据**：`errwatch.ps1:108` 的 `foreach ($c in ($crashes | Select-Object -First 10))`
把 `$histRecords +=`（115 行）包在了**打印限流循环里**。7 天窗口 48 次崩溃，
报告计数正确（48），但历史库只进 10 条——今早以前各轮扫描各自录下同样的最新 10 条，
其余 38 条永久缺席。`query -Stats / -New` 的长期崩溃统计因此少计。

**修法**：`$histRecords` 遍历全部 `$crashes`，报告打印仍限前 10（两行改动，零行为风险）。

---

## O5（P3，小项）

- 报告 unknown 分组只给「需要人工判断，或补进 core\events.json」，没给命令——
  与 O3 的 `-AddEvent` 一并解决。
- `errwatch-source.ps1 -Code` 查错误码定义已有 `-Web` 直开 Microsoft Learn，
  但报告里的「怎么验」只提示了命令、没提示可以加 `-Web` 直接看官方页。

---

## 本轮确认没问题的（避免下次重复审）

- **打包白名单**（`pack-errwatch9.ps1` 显式列举 71 项）——运行产物天然进不了包，
  比排除法稳；BOM 门禁在打包前强制。
- **prune 设计**：演练默认 + `_prune-Backup` 先备份 + 双上限。
- **history 去重**：ISO 时间统一转 `'o'` 再比 key（躲过了 JSON 反序列化 DateTime 的坑）。
- **环境指纹分层**：核心层（系统/CPU/GPU/磁盘/内存/网卡）才警告「旧结论可能不适用」，
  外围层（音频端点/可移动磁盘）只轻提示——插耳机不该把历史切成两段。
- **心跳** `last-success.json`：证明「这次采集成功完成」而非「零事件」。
- **日志完整性**：记录号缺口检测 + 「缺口也可能是轮转」的诚实说明。
- 每条翻译结论带「怎么验」与可信度字段。

---

*审查人：WorkBuddy（第三轮，运营面向），2026-10-22 22:10。所有数字为本机实测，可按命令重跑。*
