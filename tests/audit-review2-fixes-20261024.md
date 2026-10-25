# 审计：第二轮外部审查的核实与修复（2026-10-24）

> 用户转来第二轮审查（含整包走查 + 法律风险）。同样**逐条核实**：真就修，假就说明。

## 一、核实结果（全部为真）

| 审查条目 | 判定 | 证据 |
|---|---|---|
| **P1-4** 用户配置的外部恢复目录被白名单跳过 | ✅ **真** | `Get-ErrwatchAllowedRoots` 只含 TEMP/APPDATA/LOCALAPPDATA/USERPROFILE/ProgramData + 用户 TEMP；`extraPaths` 只合并进扫描列表，没进白名单 → 扫描时「白名单外，已跳过」 |
| **门禁范围不足**：专项回归不一定拦得住发布 | ✅ **真** | `run.ps1` 的 `exit` 条件只含诊断/冒烟/recover/metrics；retention/progress/settings/fallback（还有 sentinel/tray 的独立测试）打印了但**不拦** |
| **P1-6** 安装路径含空格时 `-File` 参数会断 | ✅ **真** | `Start-Process -ArgumentList` 的数组元素**不会自动加引号**，路径里的空格会被拆成两个参数 |
| **契约 §5 与 §9 冲突** | ✅ **真** | 第 60 行「pending = 所有事件 − 超 7 天」；第 117 行「不再是 7 天窗口，超期只记 staleOpen 不丢」 |
| **「三维度」注释残留** | ✅ **真** | `ack-state.ps1` 2 处、`tray` 3 处，实际维度已是 4 个（含 progress） |
| **候选先截断后排序** | ✅ **真** | `Get-ChildItem \| Select -First N` 之后才按新鲜度排序 → 大目录里最新文件可能不在前 N 个里被漏掉 |
| **rules-sigma.json 的来源/许可证字段矛盾** | ✅ **真** | `author=errwatch sample` + 本地 uri，却标 `source=sigma / origin=derived / license=DRL-1.1` |

## 二、修复

### 1. P1-4：用户批准的目录必须能扫（连带修了一个更基础的 bug）

`Get-ErrwatchAllowedRoots` 现在把**用户设置里所有 app 的额外目录**（`Get-ErrwatchRecoveryExtraPaths -App ''`，只认真正存在的）合并进白名单。

**连带发现并修复**：`Test-ErrwatchPathAllowed` 原来是 `$full.StartsWith($root)`，而 root **带尾斜杠**、`$full` 不带 ——
**目录本身永远匹配不上**，只有子路径能过。于是「扫 `%TEMP%` / `D:\CAD` 这个目录本身」会被判「白名单外」。
现在 `等于` 与 `以 root\ 开头` 两种都认。

**端到端验证**：
```
加设置前：Test-ErrwatchPathAllowed(E:\ai\_ew-user-cad) = False
加设置后：目录本身 True · 子路径 True · 未授权目录(C:\Windows\System32) 仍 False
recover：cands=1，path=E:\ai\_ew-user-cad3\drawing.sv
```

### 2. 门禁：把专项纳入统一失败判定

`run.ps1` 新增 `$suiteFail`，把 **保留策略 / 诊断进度 / 用户设置 / 有限兜底** 四个专项的退出码纳入最终 `exit 1`
（加上原有的 recover / metrics，共 6 个）。

**反证**：把 `test-progress.ps1` 改成 `exit 1` → 门禁输出 `⚠ 专项测试 FAIL` 且 **EXITCODE 1**；还原后 0。
（第一次反证用「只有注释的文件」是错的——那文件正常结束 exit 0，什么都没测到，已重做。）

### 3. P1-6：启动参数包引号

新增 `Quote-ExeArg`，托盘里三处 `-File (Join-Path $PSScriptRoot 'xxx.ps1')` 全部改为
`-File (Quote-ExeArg (Join-Path ...))`。这样装在 `C:\Program Files\errwatch` 也能启动。

### 4. 候选先排序再截断

`Invoke-ErrwatchRecoveryProbe` 改为「枚举 → `Sort-Object LastWriteTime -Descending` → `Select -First N`」，
保证被保留的是**最新**的 N 个（救援里最新那份最值钱），不会因为目录里文件多而被截掉。

### 5. 文档漂移

- `STATE-CONTRACT.md` §5 第 3 条：改成「pending = 所有事件 − lifecycle 终态」，并说明超期只记 `staleOpen`、
  终态清理由 §九 管；新增第 6 条说明 24h `unknown-exit` 折叠。
- `ack-state.ps1` / `tray` 的「三维度」全部改为「四维度」（含 progress）。

## 三、法律风险（如实报告，**不擅自改**）

`core/rules-sigma.json` 的 6 条规则字段：

```
author=errwatch sample · uri=tools/sigma-samples/sample-*.yml
source=sigma · origin=derived · license=DRL-1.1
```

**矛盾点**：`author` 与 `uri` 都指向「项目自编样例」，但 `source/origin/license` 声称是 SigmaHQ 衍生。
外部审计者无法凭文件判断究竟是「自编的 Sigma 格式样例」还是「改编自 SigmaHQ 的真实规则」。

**我没有改它**——这不是技术判断，是**权属事实**，只有项目作者能确认：

- 若确为自编样例：应改成 `source=errwatch / origin=original / license=MIT`（跟项目许可证一致），
  并在 `THIRD-PARTY-NOTICES.md` 写明「兼容 Sigma 格式，但规则内容自编」。
- 若确实改编自 SigmaHQ：应保留**原始** uri / author（指向 SigmaHQ 仓库），按 DRL-1.1 处理署名与再分发。

两种都能合规，但**不能含糊**。建议公开前先定这一条。

## 四、测试

| 套件 | 结果 |
|---|---|
| `run.ps1` | 28/28（含 4 个新纳入的专项） |
| 哨兵 / 托盘 / 兜底 / 设置 / 恢复 / 指标 / 启动链 / 恢复机会 | 18/18 · 16/16 · 6/6 · 7/7 · 15/15 · 6/6 · 7/7 · 13/13 |

## 五、未做（诚实记录）

1. **`Get-ChildItem -ErrorAction SilentlyContinue` 吞错**：访问被拒的目录会被当成「没有文件」。改动要引入错误收集，未做。
2. **`verified` 的语义**：用户自检通过写的是 `verified`，实际来源是用户确认而非工具独立核验。指标文档已注明，状态名未改。
3. **retention 的竞争窗口**：最后一检查到替换之间仍有极小窗口（用了文件签名做并发保护）。
4. **复制完整性校验**（临时文件 + SHA-256 再发布）：未做。
5. **UI 备份的候选快照一致性**：两次扫描之间候选可能变化，未做快照传递。
6. **`errwatch-tray.ps1` 的引号改动未在含空格路径下实测**（只做了静态修正 + 托盘 16/16 回归）。
