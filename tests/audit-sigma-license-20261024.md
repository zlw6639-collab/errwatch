# 审计：Sigma 规则来源与许可归属（ISSUES.md A1 结案）

- 日期：2026-10-24
- 触发：`ISSUES.md` A 类 A1 —— 「只有作者能定」的许可证归属
- 结论：**自编样例**。已按 `origin=original / license=MIT / source=errwatch` 落地，并把判据锁进门禁。

## 一、判决依据（不是猜，是可核对的证据）

| 证据 | 内容 |
|---|---|
| 署名 | 9 个 `tools/sigma-samples/*.yml` 全部 `author: errwatch sample` |
| 日期 | 全部 `date: 2026-10-22`（本项目开发当天），非 SigmaHQ 规则的提交历史 |
| UUID | `1a111111-1111-4111-8111-111111111111` / `2b222222-…` —— 占位规律编号，不是随机 UUID |
| 引用 | `references` 指向 Microsoft Learn 文档，不是 SigmaHQ 的规则页 |
| 铁证 | `sample-complex-condition.yml`（标题 "Complex Condition Should Be Skipped"）与 `sample-unsupported-mod.yml`（"Unsupported Modifier Should Be Skipped"）是**为测转换器边界而构造**的样本 —— SigmaHQ 不会发布「应当被跳过」的规则 |
| 项目自身口径 | `免责声明.md` / `开源发布清单.md` / `送审说明-20261022.md` / `HANDOFF.md` §53 都写「当前 6 条为自编样例，uuid 为编造值」 |

矛盾的本质不是「作者忘了标注」，而是**转换器写死了许可证**：

```powershell
# 修改前（tools\sigma-convert.ps1）
$uri = if ($rel -match '^rules/') { "https://github.com/SigmaHQ/sigma/blob/master/$rel" } else { $rel }
license = 'DRL-1.1'      # ← 判据只看路径
source  = 'sigma'        # ← 写死
origin  = 'derived'      # ← 写死
```

`uri` 按路径判（本地样例 → 相对路径），其余三个字段写死。于是产物同时声称两件互斥的事：
「作者是 errwatch sample / uri 在本地样例目录」＋「衍生自 SigmaHQ / 受 DRL-1.1 约束」。

## 二、修法（修根因，不留口径分裂）

1. **判据唯一**：`tools\sigma-convert.ps1` 引入单一判据 `$isSigmaHqRule = $rel -match '^rules/'`，
   `uri` / `license` / `source` / `origin` 四个字段全部由它驱动；产物级 `license` / `note` / `schema`
   （`errwatch-sigma-converted-rules`）也按实际来源生成。自编时 `note` 明确写「非 SigmaHQ 规则」。
2. **门禁双向自洽**：`tools\check-thirdparty-rules.ps1` 新增
   - 逐条：`origin=original` 却标 DRL → 拒绝；`origin=derived` 却没标 DRL → 拒绝。
   - 文件级：全部 `original` 却声明 DRL-1.1 → 拒绝（A1 的原始形态）。
   - 判定取 license 的**头部标识**（破折号/冒号前），不全文搜 "DRL" ——
     自编声明里会写「MIT … 不适用 DRL-1.1」，全文搜会把否定句当成声称（这个坑实测踩到一次）。
3. **重转不丢人工字段**：新增 `tools\merge-sigma-rules.ps1`，按 `sigmaId` 回填
   `verify / verifyStatus / why / do`（HANDOFF §53 记的教训：以前靠手工抄回，漏一条 lint 就 FAIL 6）。
4. **回归测试**：新增 `tests\test-sigma-source.ps1`（10 条），并接入 `tests\run.ps1`
   **参与失败判定**。同时修掉 `run.ps1` 里 `$tpOk` 算了却没进 exit 的漏判（「门禁只拦部分专项」复发）。
5. **SBOM 不再写死**：`tools\make-sbom.ps1` 按包内 `rules-sigma.json` 的 `origin` 判许可，
   而不是按文件名映射 `rule-derived → DRL-1.1`。

## 三、实测（本机 PS 5.1 / 5.1 语法，全部实跑）

| 场景 | 期望 | 实测 |
|---|---|---|
| 现行产物（6 条自编） | 准入 PASS | PASS，输出「6 条 origin=original（MIT），不适用 DRL-1.1」 |
| 逐条 `original` + `license=DRL-1.1` | 拒绝 | exit 1：`自编规则不适用 DRL-1.1` |
| 逐条 `derived` + `license=MIT` | 拒绝 | exit 1：`却没标 DRL-1.1 —— 分发不满足 DRL 署名要求` |
| 文件级 DRL + 全 `original` | 拒绝 | exit 1：`自相矛盾` |
| `origin=unknown` | 拒绝（旧行为） | exit 1 |
| 转换器 · 本地样例目录 | MIT / original / 相对 uri | 一致（6 条） |
| 转换器 · `rules/…` 布局 | DRL-1.1 / derived / GitHub uri | 一致（uri=`https://github.com/SigmaHQ/sigma/blob/master/rules/windows/…`） |
| 合并工具 | 人工字段 100% 回填 | 6 条 / 24 个字段全部回填，why 保持中文 |

`tests\test-sigma-source.ps1`：PASS 10 / FAIL 0。

## 四、这轮之后仍然开着的（诚实记录）

- `ISSUES.md` B 类 11 条、C 类证据缺口 4 条、D 类教训 6 条 —— 本轮未动。
- 自编样例**本身**仍是样例：正式对外发布检测能力前，要么明示「样例，不含真实规则」，要么引入 SigmaHQ 真实规则
  （此时转换器会自动切到 DRL-1.1，门禁会自动要求保留 author/uri）。
- `run.ps1` 里仍有若干专项只打印、不参与 exit（lint 属设计如此，其余待逐个确认）——
  本轮只修了 `$tpOk` 这一个明确漏判的地方，剩下的按「一条一条查」处理，不一次性改判定口径。
