# 第三方声明（THIRD-PARTY-NOTICES）

> 本文件说明 errwatch 使用或**曾参考**的第三方材料、其许可证，以及本项目的合规处理。
> 与 `LICENSE` 配合阅读：代码是 MIT，**第三方规则/数据不是**。

## 一、当前发行包的规则来源（事实核验）

以下是根据当前发行包的来源核验记录（规则文件实际内容 / 转换器输入 / 打包脚本范围）：

| 内容 | 数量 | 性质 |
|---|---|---|
| `core/rules.json` | **34 条** | **项目自编规则**（手写；其中 9 条带 `ref`，指向本项目自己的踩坑记录 `#xx`） |
| `tools/sigma-samples/` | 9 个 `.yml` | **自编测试样例**，采用 Sigma 格式编写（`author: errwatch sample`、`date: 2026-10-22`、UUID 为编造值） |
| `core/rules-sigma.json` | 6 条 | **转换结果**，来源于上述自编测试样例（另 3 个样例因条件不受支持被跳过） |

**当前发行包未包含 SigmaHQ 的真实检测规则，也未包含 Hayabusa 的代码或规则。**

SigmaHQ 的 Sigma 格式仅作为**规则格式参考**；Hayabusa 仅作为**规则工程化、样本验证及弃用机制的设计参考**。

> 以上声明仅适用于本声明对应的具体发行版本，**不代表未来版本的内容**。

## 二、外部资料引用

项目可能在诊断说明、规则描述或参考链接中引用 Microsoft Learn 等官方技术文档，用于说明 Windows 事件、错误码及相关技术行为。

- 项目通过**链接**指向相关资料，不以此声明拥有这些外部资料的版权。
- 引用范围**限于必要的技术要点**（事件含义、错误码定义），**不整段复制**原文、表格、图片或文档片段。
- 外部资料的权利归其相应权利人所有；引用行为及具体引用内容应遵守适用法律及相关资料的使用条件。
- Windows 系统组件及 SDK 文件（如 `ntstatus.h` / `winerror.h`）**仅在运行时读取、不随发行包分发**，不应视为本项目对这些文件的再分发。

## 三、Sigma 与 Hayabusa 的具体使用情况

### Sigma（DRL 1.1）

| 项 | 内容 |
|---|---|
| 来源 | [SigmaHQ/sigma](https://github.com/SigmaHQ/sigma) |
| 许可证 | **DRL 1.1** — https://github.com/SigmaHQ/Detection-Rule-License/blob/main/LICENSE.Detection.Rules.md |
| 本项目用法 | `tools\sigma-convert.ps1` 将 Sigma 规则的检测条件转换为 errwatch 可用的近似规则 |
| 当前产物 | 由**自编样例**转换而来，非 SigmaHQ 真实规则；每条 `origin=original`、`license=MIT`、`source=errwatch`（**不适用 DRL 1.1**） |
| 合规要求（如引入真实规则） | **保留** `author`（原作者）、`uri`（规则地址），声明 DRL + 附链接；DRL 1.1 允许商业使用（含 sell / sublicense）。转换器按来源自动分级：规则落在 SigmaHQ 仓库布局（`rules/…`）下 → `origin=derived` / `license=DRL-1.1` / 产物 uri 变 GitHub 链接；否则 → `origin=original` / `license=MIT` |

**转换是近似，不是等价**：errwatch 用文本正则，Sigma 用结构化字段；表达不了的条件一律跳过（不硬转），每条产物都带 `note` 说明近似点。

**来源与许可必须自洽**（2026-10-24 修正，`ISSUES.md` A1）：`uri`、`license`、`source`、`origin` 四个字段由**同一个判据**产生 —— 过去 `uri` 按路径判、其余字段写死成 DRL-1.1，于是自编样例被标成 SigmaHQ 衍生，署名与许可自相矛盾。

> ⚠️ **规则格式规范与规则内容的许可并不相同**：采用 Sigma 的 YAML 格式不改变规则内容的权利归属。

### Hayabusa（AGPL-3.0）

| 项 | 内容 |
|---|---|
| 来源 | [Yamato-Security/hayabusa](https://github.com/Yamato-Security/hayabusa) |
| 许可证 | **AGPL-3.0** |
| 本项目用法 | **未使用任何代码或规则文件**。仅在项目方案中参考了其「规则工程化 / 样本验证 / 弃用机制」的思路 |
| 合规结论 | 不构成衍生作品，**不触发 AGPL 传染** |

⚠️ 若将来引入 Hayabusa 的规则或代码，必须重新评估：AGPL 会要求本项目整体以 AGPL 发布。

## 四、未来引入第三方检测规则的条件

如未来版本引入第三方检测规则，包括**复制、修改、转换**或其他基于第三方规则形成的发行内容，项目应在发布前完成来源与许可核验。必要措施：

1. 记录原始规则来源、作者、许可证及版本；
2. 保留适用许可证要求的版权、署名及来源信息；
3. 对修改、转换及生成产物建立**可追溯关系**（产物必须能追回原始规则）；
4. 在发行包中提供相应许可证及第三方声明；
5. 确保规则匹配结果、报告及 UI 满足适用的署名要求；
6. 对**无法确认来源或授权**的内容，**不纳入正式发行包**。

> 第三方规则的使用应以**具体规则的实际来源、适用许可**为依据，不因文件格式或转换方式而自动改变其权利归属。

### 工程实现（发行门禁）

为避免"靠人记得检查"，项目提供自动化门禁：

- `tools\check-thirdparty-rules.ps1`：检查每条例行的 `author/uri/license/source` 是否齐全，**占位署名一律拒绝**（唯一例外：`uri` 指向 `tools/sigma-samples/` 的自测样例）；并检查 **`origin` 分级与 `license` 是否自洽** —— `original` 标 DRL-1.1、`derived` 标 MIT、文件级声明与全部条目矛盾，三种都拒绝入包。
- `tests\test-sigma-source.ps1`：把上述判定钉成回归测试（含反向对照：`rules/` 布局必须自动升到 DRL-1.1）。
- 已接入 `tests\run.ps1`（**失败即门禁失败**）与打包脚本（**不合格直接拒绝打包**）。
- 规则条目携带 `source`（`sigma` / `errwatch`）、`origin`（`original` / `derived` / `third-party` / `authored`）与 `sigmaId`，用于追溯来源。

## 五、版本适用范围

本声明仅适用于明确标识的发行版本。

每次正式发布应记录：**版本号、发行日期、规则清单及发行包哈希**（见 `_dist\release.json`）。后续版本应重新核验第三方内容及其许可情况。

## 六、Windows / PowerShell 运行时

- 项目**不打包**任何 Microsoft 组件；运行时依赖系统自带的 PowerShell 5.1 / 7 与 `cmd.exe`。
- 调用系统工具（`wevtutil`、`diskpart`、`reg`、`certutil`、`fsutil`）不构成再分发。

## 七、本项目自编内容（MIT）

| 内容 | 许可证 |
|---|---|
| 全部脚本代码（`*.ps1 / *.cmd / *.bat`） | MIT（见 `LICENSE`） |
| `core\rules.json`（**34 条**手写规则） | MIT（随代码） |
| `core\events.json`（事件 ID 人话表） | MIT（随代码） |
| `core\apps.json`、`core\noise.json`、`core\schema\*.md` | MIT（随代码） |
| 文档（README / 定位 / 免责声明 / 操作卡 / 审计记录） | MIT（随项目；如需 CC-BY-4.0 请发布前明确） |

## 八、发布时需附带

1. 本文件 `THIRD-PARTY-NOTICES.md`
2. `LICENSE`
3. `core\rules-sigma.json` 文件头自带 `license` 字段（已内置）
4. **仅在未来引入真实 Sigma 规则时**：DRL 1.1 全文或链接（见第三节）
