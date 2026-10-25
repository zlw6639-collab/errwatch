# 审计：外部审查的核实与修复（2026-10-24）

> 用户转来一份外部审查（P0/P1 清单 + 全景评审）。按惯例**逐条对着代码核实**——
> 真就修、假就说明为什么假，不照单全收。

## 一、核实结果

| 审查条目 | 判定 | 证据 |
|---|---|---|
| **P0-1** `$verdict` 未定义 → 恢复机会永远记不成 `LOST` | ✅ **真** | `grep '\$verdict' errwatch-sentinel.ps1` → 全文只出现 1 次（`$endState = if ($verdict -eq ...)`），无定义，恒为 `$null` |
| **P0-2** 事件落盘晚于取证（取证中被杀 → 事件丢失） | ✅ **真** | 取证在 700-735 行，`$events += $ev` 在 737，落盘在 807（循环后）。process 被杀 → 只剩 progress ack |
| **P1-3** 取证失败/无匹配/超时未区分 | ✅ **真** | `-ErrorAction SilentlyContinue` + `catch {}` 把两种都变 `$null`；外层「可重试一次」**从未触发**（没有可捕获异常）→ 死代码 |
| `open-ui` 未实现但审计写 `open-ui` | ✅ **真** | 白名单含 `open-ui`，托盘无对应分支；`settings.ps1` 也接受它 |
| UI 备份无候选也询问 | ✅ **真** | handler 里没检查 `candidates.Count` |
| UI 0 处引用 coverage/metrics | ✅ **真** | `grep coverage\|metrics errwatch-ui.ps1` 无结果 |
| doctor 落后（只查旧 notify 任务、文案「每 10 分钟」） | ✅ **真** | 只 `Get-ScheduledTask errwatch-notify`，文案写着 10 分钟（实际哨兵每 2 分钟代跑） |
| Word 体检用被证伪的 `AutoRecoverTime` | ✅ **真** | 且比审查说的更糟：`AutoRecoverySaveIntervalMetadata` 也不随设置变化（实测设 5/10 都是 `0x80000001`）；`.asd` 在正常关闭时还会被删 —— **两种自动判据都会撒谎** |

**没有发现审查说错的地方。** 这份审查的质量高于「泛泛挑刺」。

## 二、修复（每项都有测试或反证）

### 1. P0-1：恢复机会永远记不成 LOST

```powershell
# 修前（从未定义的变量 → 永远 CLOSED）
$endState = if ($verdict -eq 'crash-suspected') { 'LOST' } else { 'CLOSED' }
# 修后
$endState = if ($ev.verdict -eq 'crash-suspected') { 'LOST' } else { 'CLOSED' }
```

**测试 Q**：用测试钩子 `ERRWATCH_TEST_FAKE_EVIDENCE=1` 注入假证据（真实崩溃的 WER 事件造不出来），
真正走一遍 sentinel 退出分支，断言 `opportunity.json` 里该 app 的 `state = LOST`。
**反证**：退回 `$verdict` → Q **FAIL**；还原 → 通过。

### 2. P0-2：先落盘，再取证

取证前先把最小事件（`verdict=diagnosing`）追加进 `sentinel-events.jsonl`，取证后再追加最终记录
（同 id，pending 重建按 id 去重，后写覆盖前写）。这样即使哨兵在取证中途被杀，磁盘上仍有事件可看。

**测试 Q** 同时断言「存在 `diagnosing` 记录」。
**反证**：去掉先落盘 → Q **FAIL**；还原 → 通过。

### 3. P1-3：取证返回结构化结果

`Get-ExitEvidence` 现在返回 `{ queryOk, match, error }`：

- `queryOk=true, match=$null` → 查询成功但**没匹配**（记 `reason=no-match`，不重试）
- `queryOk=false` → **查询失败**（记 `reason=evidence-failed`，在硬时限内重试一次）
- 硬时限到 → `reason=timeout`

「找不到任何匹配的事件」用 core 的 `Test-ErrwatchNoEventError` 判定（不靠文案），与采集状态那条修法同源。

### 4. `open-ui` 从白名单移除

`core\fallback.ps1` 的允许动作只剩 `notify-only`；`core\settings.ps1` 不再硬编码名单，改为问白名单函数。
**理由**：动作和记录必须一致 —— 否则审计写着「执行了 open-ui」，实际只弹了个气泡，比不做更糟。
等真正实现（打开界面 + 验证启动结果 + 防重复 + 全屏策略）再加回来，并补测试。

**测试**：`test-fallback` C 改为「只有 notify-only 允许；open-ui 必须被拒」；
`test-settings` G 改为「open-ui 存不住」。

### 5. Word 体检：不再报假状态

两条自动判据都实测作废：

| 判据 | 实测结果 |
|---|---|
| `AutoRecoverTime` 注册表键 | 改成 1 后 `Word.Options.SaveInterval` 仍是 10 |
| `AutoRecoverySaveIntervalMetadata` | 设 5 / 设 10 都还是 `0x80000001`，不随设置变 |
| `.asd` 新鲜度 | **正常关闭 Word 时会删除 `.asd`** → 空目录 ≠ 没开 |

改成 `check.kind = com-option`：**只在 Word 已运行时**用 COM 读 `Options.SaveInterval`（真值），
没运行就报「查不到」——**绝不猜**。实测：

```
Word 没跑 → [?] 程序没在运行，查不到（注册表键与 .asd 新鲜度都实测会撒谎）
Word 在跑 → [开] SaveInterval = 10 分钟（程序自己报的真值）
```

跨版本注意：`Marshal.GetActiveObject` 是 .NET Framework 独有，PowerShell 7 没有 → 加了
`New-Object -ComObject` 回退（Word 已运行时复用实例，不新建）。

### 6. UI 串起 coverage + 五项指标（审查 #2）

设置窗「工具」页新增 **📊 看护健康**：显示看护目标数、正在监视/没在运行的数量、
最近快照时间，以及五项指标（发现/触达/决策/恢复/安全）的中位数与样本数。
数据源就是已经采集好的 `sentinel-coverage.json` + `errwatch-metrics.ps1 -Json`（5.1 下已验证可解析）。

### 7. UI 备份：没有候选就不问

先取一次结构化结果，`candidates.Count = 0` 时直接返回，不弹「要备份吗」。

## 三、测试

| 套件 | 结果 |
|---|---|
| `run.ps1` | 28/28（5.1 语法 68 个 `.ps1` PASS） |
| 哨兵 | **18/18**（新增 Q） |
| 托盘 | 16/16 |
| 兜底 | 6/6（C 改为「open-ui 必须被拒」） |
| 用户设置 | 7/7（G 改为「open-ui 存不住」） |
| 应急恢复 | 15/15 |
| 五项指标 | 6/6 |
| 启动链 | 7/7 |

## 四、这轮**没做**的（诚实记录）

1. **doctor 双通道检查**（审查 #3）：还是只查 `errwatch-notify`，「每 10 分钟」文案过时。
   要改成查三个任务 + 启动项 + 心跳，改动中等，留待下一轮。
2. **事件级 coverage 回填 / 半行 JSON 计数**：自审清单里的欠账，未动。
3. **复制完整性（临时文件 + SHA 校验）**：审查建议的「复制到临时再发布」未做，仍是直接复制。
4. **UI 备份的「快照一致」**：两次扫描之间候选可能变化（审查提过），未实现「保存刚看到的那批」。
5. **WER LocalDumps 布防 / 真实 CAD 演练**：需要新脚本 / 需要机器上装 CAD。
6. **UI 的「看护健康」没有端到端点击验证**：只做了 5.1 语法检查 + 数据源验证。
