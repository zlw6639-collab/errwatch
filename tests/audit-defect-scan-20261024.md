# 审计：缺陷自查（2026-10-24，用户：「看看有没有 bug 漏洞」）

> 方法：静态扫描（写操作 / 动态执行 / 命令拼接）→ 挑出可疑点 → **实测复现** → 修 → 加测试 →
> **反证**（把修复去掉，测试必须失败）。不猜、不写「疑似」当结论。

## 一、结论

| # | 类型 | 问题 | 状态 |
|---|---|---|---|
| B | **真 bug（本轮新改动引入）** | 「同组还有实例 → 观测不确定」用的是**整组 match 列表**：Word 和 Excel 都在跑时，杀 Word 会被说成「观测不确定」（理由「同一软件还有 1 个实例在跑」，而那个实例是 Excel） | ✅ 已修：拆组（11 组） |
| A | **真 bug（本轮新改动引入）** | 把 Office 加进监视后，**正常关闭 Word/Excel 也产生 `unknown-exit` 待处理事件**（退出≠崩溃是既有设计），一天会刷十几条假「待处理」 | ✅ 已修：24h 内同程序只留一条（事实全留） |
| C | 隐患 | `-SaveTo` 复制**没有大小上限**：VSCode/Notepad++ 的 filter 是 `*`，候选可能是任意大小，用户不知道会占多少盘 | ✅ 已修：报告总大小，>500 MB 提示 |
| D | 隐患 | doctor 对 7 个 app 各判一次安装 → **21 次全量读注册表**，doctor 从 2.1s 涨到 3.5s | ✅ 已修：进程内缓存 → **2.1s** |
| E | 未验证 | UI 的「备份副本」对话框（右键救援 → 问是否备份 → 选目录）只做了 5.1 语法检查，**没有端到端点击验证** | ⚠️ 记录 |
| F | 已知限制 | JetBrains 组内 6 个不同产品仍互为兄弟（同 B 类）；Word 的 `.asd` 只能从恢复目录直接打开 | ⚠️ 记录 |

静态扫描**没有发现**命令拼接/注入类漏洞：UI 调用都是 `& $exe -File script -App <参数>`（数组形式，非字符串拼接），写操作都在授权链（fix）或备份逻辑（retention tmp+Move）里。

## 二、Bug B：Word 崩溃被 Excel「降级」（实测复现）

修复前实测：

```
起 Word + Excel → 强杀 Word
事件: WINWORD verdict=unknown-exit coverage=OBSERVATION_UNCERTAIN sibling=1
      reason=同一软件还有 1 个实例在跑 —— 这次退出可能只是一个启动器或一个窗口结束了
```

**Word 崩溃被说成「观测不确定」**，而那个「兄弟实例」是 Excel。

根因（`errwatch-sentinel.ps1`）：

```powershell
$groupNames = @($w.match)          # 整组：winword/excel/powerpnt
$siblings = @($snap | Where-Object { $groupNames -icontains $_.Name -and ... })
```

「兄弟实例」的语义本来是「同一软件的多进程/多窗口」，但**数据层把不同程序放进了同一组**。

修法（数据层，不改判定逻辑）：拆成 11 组，只保留「同一软件的多进程」：

| 组 | 说明 |
|---|---|
| CAD | acad / autocad / acadlt（同一产品的不同版本线） |
| Visual Studio / VS Code / Notepad++ | 各自独立（原来混在「IDE/编辑器」一组） |
| JetBrains IDE | idea64 / pycharm64 / …（同厂商，保留一组；**已知限制 F**） |
| PICO 串流 | launcher + server（**启动器关系，降级是有意义的**） |
| VRChat | 独立 |
| Word / Excel / PowerPoint | 各自独立（原来混在「Office」一组） |
| DSH | dsh / electron / electron-shell |

修复后实测：`coverage=MONITORED sibling=0`（Word 崩溃不再被 Excel 降级）。
回归：哨兵 16/16、托盘 16/16、启动链 7/7 全过。

## 三、Bug A：正常关 Word 也报「待处理」（实测复现）

```
Word 正常 Quit → pending 1 条：WINWORD verdict=unknown-exit coverage=MONITORED
```

设计原意是「退出≠崩溃，触发调查」（`errwatch-sentinel.ps1` 第 24 行注释写死了「进待处理」），
CAD 这种低频程序没问题；**Office 是高频开关的程序**，一天关十次就是十条假警报。

修法（折中，比「完全不提示」安全）：`Sync-Pending` 重建时，**同一程序 24 小时内只留一条 `unknown-exit`**：

- 第一条仍然提示（不会完全静默）
- 有崩溃证据的 `crash-suspected` **不受影响**
- 事件事实**全留**在 `sentinel-events.jsonl`（报告/指标能看到）
- 折叠数量进 `coverage.integrity.droppedQuiet`（可见、可测）

实测：

| 操作 | pending | events | 说明 |
|---|---|---|---|
| 第 1 次关 Word | 1 | 1 | 提示 |
| 第 2 次关 Word | **1** | **2** | 折叠，事实仍留 |

测试：`test-sentinel` 新增 **P** 用例；**反证**：把 24h 判断改成 `if ($false)` → P **FAIL**，还原后 17/17。

## 四、隐患 C / D

**C：复制没有大小上限**。`Copy-ErrwatchRescueCandidates` 现在返回 `totalBytes`，界面显示「共 32 KB」，
超过 500 MB 给提示（不阻止 —— 用户显式要求备份）。VSCode/Notepad++ 的候选可能是任意文件，这条提示有必要。

**D：doctor 性能**。安装探测每次全量读 3 个注册表键（约 293 项），doctor 对 7 个 app 各判一次。
加进程内缓存后 **3.5s → 2.1s**。缓存不影响正确性（doctor 是一次性进程）。

## 五、没发现问题的方向（也记录下来）

| 检查 | 结果 |
|---|---|
| 命令拼接 / 注入 | 无：UI 全部 `& $exe -File <脚本> -App <参数>` 数组形式；`-App` 有路径注入检查（test-recover E） |
| 任意写文件 | 写点都在：fix（授权链 + 备份 + STOP）、retention（tmp+Move 原子写）、settings（HKCU 用户设置）、recover 复制（用户显式指定、只复制） |
| 并发覆盖 | 复制有 TOCTOU 窗口（两进程同时复制同目录可能抢同一目标名），但源相同、内容相同，**无实际危害**；不同源同名时概率极低 |
| 坏行容错 | 已有测试 O：半行 JSON 不阻断重建，`droppedLines` 可见 |

## 六、剩余（诚实记录）

1. **UI 备份流程未端到端验证**：FolderBrowserDialog 在真实点击下是否正常弹出、`$row.程序` 取值是否正确，
   没有用自动点击验过（代码逻辑已审、5.1 语法已过）。
2. **JetBrains 组仍是「多产品同组」**：杀 PyCharm 时 IDEA 在跑，仍会被降级成观测不确定（同 B 类，低频）。
3. **降噪的代价**：同一程序 24 小时内如果「先正常关闭、后真崩溃且无 WER 证据」，第二次不会提示
   （只在事件日志里）。有 WER 证据的崩溃不受影响。
4. **24h 窗口没有配置项**：暂时写死，需要的话再进 `settings.json`。
