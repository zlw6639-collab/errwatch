# 第 4 项：故障测试集 / 规则回归语料 — 记录与发现

- 日期：2026-10-22
- 审计路线里的第 4 项："建立故障测试集（rules 的回归语料）—— 拿真实崩溃当样本，标注正确诊断 / 误诊 / 漏诊"
- 结论：**语料从 20 条扩到 28 条（含 7 条真实样本），并借此抓出 2 个真实缺陷（均已修）**；回归 28/28、误诊 0、漏诊 0

---

## 一、做了什么

| 动作 | 说明 |
|---|---|
| 扩充语料 | `tests/cases.jsonl` 20 → **28 条**：新增 7 条**真实崩溃样本**（r01–r07）+ 1 条锚点样本（x02） |
| 修正失效样本 | x01 原标注是"冲突样本"，但规则收紧后已不再冲突 —— 换成真正同时命中两条规则的文本，冲突检测恢复有效覆盖 |
| 消除测试分叉 | `tests/run.ps1` 过去**复制**了 Match-App / Translate / TranslateForApp 三个函数（注释还写着"改了那边记得同步"），现改为 dot-source `core\` |
| 消除生产分叉 | `errwatch-notify.ps1` 里是**旧版 core 的完整副本**，现改为复用 core |
| 修 2 个真实缺陷 | 见第三节 —— 这是本次最有价值的部分 |
| 标注分类 | 正确诊断 / 弱证据 / 冲突 / 负样本 / 阴样本 / 未知，每条 case 的 `note` 里写明类别与依据 |

## 二、标注依据（不是照抄 history）

**重要发现：`history.jsonl` 里的 `matched` / `why` 是"当时"的判断快照，不能直接当标注真值。**

证据：同一个 `vrwebhelper.exe 0xe0000008` 在历史里出现两次，一次 `matched=true`、一次 `matched=false` ——
同样的 code、同样的 app。原因是这两次采集之间 rules.json 被改过。所以标注必须重新按**当前规则**判定。

做法：先用脚本对每个候选样本跑一遍当前判定（`TranslateForApp` + `Count-RuleHits`），再据此写 `expect_*`，
并把判定结果与依据写进 `note`。真实样本的判定结果：

| id | 样本 | 判定 | 标注类别 |
|---|---|---|---|
| r01 | CodexSandboxService（无码无消息） | 命中（按来源名） | **弱证据**：只有来源、没有错误信息，靠 apps.json 档案；措辞已限定为"多为…" |
| r02 | ps_service_launcher.exe 0xc0000409 | 快速失败（码义准确） | 正确诊断 |
| r03 | VRChat.exe 0xc0000005 + UnityPlayer.dll | Unity 访问违例 | 正确诊断（app 专属比通用更具体） |
| r04 | vrwebhelper.exe 0xe0000008 | VRC 自定义失败码 | 正确诊断（措辞可再精确，见第五节） |
| r05 | VRChat.exe 0x80000003 | Unity 断点异常 | 正确诊断 |
| r06 | Agents Anywhere.exe 0x80000003 | 桌面壳 2.0.3 已知缺陷 | 正确诊断（有实测 ref） |
| r07 | app_check.exe 0xc0000409 | 快速失败 | 正确诊断（无档案 → 走通用规则） |

## 三、抓出的两个真实缺陷（这是语料的产出，不是副产品）

### 缺陷 1：`hay` 用空格拼接 → code 为空时留下前导空格 → 破坏行首锚点

```
"$code $msg"   当 code 为空 →  " Access is denied"（前导空格）
                                  ↑ (?im)^Access is denied 永远不匹配
```

- 影响面：`errwatch.ps1`（采集）、`errwatch-bundle-analyze.ps1`（离线分析）
- 修法：core 新增 **`New-ErrwatchHay`**，两个调用方改用它
  （规则：都有用换行分隔；只有一个就原样用；都没有给空串）

### 缺陷 2：`TranslateForApp` 把 App 名拼进匹配文本 → **所有行首锚点规则在这条路径上从未生效**

```
Translate "$AppName $Text"   →  "noise_app.exe Access is denied 出现在行首"
                                      ↑ "Access" 不在行首 → ^ 锚点失效
```

这个比缺陷 1 更隐蔽：它影响**所有**经过 `TranslateForApp` 的判定（报告、弹窗、离线分析），
而且不限于 code 为空的情况。也就是说 —— 装了行首锚点的规则（如 `(?im)^Access is denied`），
**在这条路径上一直等于没生效**，只是平时靠错误码规则兜住了，没露出破绽。

- 修法：把一次拼接拆成**两次匹配** ——
  ① 先用**消息文本**匹配通用规则（不拼 App 名，保住锚点语义）
  ② 再用 **App / 来源名**匹配（保留"靠来源命中"的规则，如 CodexSandboxService）
- 修完瞬间：**x02 从"漏诊"变 PASS**，回归 27/28（96.4%）→ **28/28（100%）**

修复过程的完整链条（可复现）：
新增 x02 期望命中 → 跑出漏诊 → 修 hay 拼接 → **仍然漏诊** → 追到真根因 → 修 TranslateForApp → 全绿

## 四、顺带修掉的分叉

| 文件 | 原来 | 现在 |
|---|---|---|
| `tests/run.ps1` | 复制三个函数 | dot-source core（测试与生产同一份实现） |
| `errwatch-notify.ps1` | 旧版 core 的完整副本（含缺陷 2） | dot-source core |
| `errwatch.ps1` | — | 改用 `New-ErrwatchHay` |
| `errwatch-bundle-analyze.ps1` | 空格拼接 | 改用 `New-ErrwatchHay` |

**为什么必须消除分叉**：core 在本次修掉了缺陷 2，而 notify 里那份副本没修 ——
结果是**同一条报错在报告里和在弹窗里可能给出不同结论**。测试与生产用不同实现时，"测试全绿"证明不了生产正确。

## 五、剩余的"分叉清单"（下一轮直接照做）

仍然自实现规则匹配、没有复用 core 的地方：

| 文件 | 位置 | 性质 |
|---|---|---|
| `errwatch-query.ps1` | 第 22–31 行（自加载 rules + 自实现 Translate） | 分叉风险（逻辑等价，但会不同步） |
| `errwatch-report.ps1` | 第 88–114 行（自实现匹配） | **行为已正确**（上一轮修过 hay，且先消息后来源，与新版 core 一致）—— 属于分叉而非缺陷 |
| `errwatch-ui.ps1` | 第 219–225 行（自加载 rules.json） | 分叉风险 |
| `tests/unknown-chain.ps1` | 第 51–76 行（自实现 TranslateLocal + 冲突计数） | 分叉风险；且 `Count-RuleHits` 的口径改了，这里也该跟 |

另外一条待改进：`0xe0000008` 的措辞"不是标准 NTSTATUS"不够精确
（该码段属于 NTSTATUS 里保留给厂商自定义的区段），本轮不改，记录在案。

## 六、诚实记录

1. **样本量很小**：12 条真实崩溃记录去重后只有 **7 个唯一组合**（app+code）。
   这足以锁定当前行为，但不足以称"统计"。
2. **没有"真实误诊"样本**：现有负样本（n）与阴样本（y）覆盖的是"期望未命中"，
   能抓住"把无关判成已知"的回归，但它们是我构造的，不是历史上真实发生过的误诊。
3. **`msg` 用事件首行**：真实样本的 `msg` 取自 history.jsonl（事件消息首行），
   而生产路径用的是完整消息（多行）。对规则匹配而言影响有限（关键信息在 code），但**不是完全相同的输入**。
4. **r02/r07 的 `expect_app=null`** 表示"不应归属到任何软件档案"——
   这只在 `expect_hit=true` 时被检查（run.ps1 的逻辑），语义上略含混，暂未改。

## 七、复现

```powershell
$root = "E:\ai\_tools\errwatch"
pwsh -File "$root\tests\run.ps1" -Verbose    # 28 条，看每条 PASS/FAIL 与原因
pwsh -File "$root\tests\unknown-chain.ps1"   # unknown 全链路 9 项
```

结果文件：`tests\last-run.json` + `tests\history.jsonl`（带 rulesHash，可做跨版本对比）。
