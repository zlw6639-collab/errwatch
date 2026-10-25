# 审计：设置入口（救援目录 / 时限）+ 发包卫生修复（2026-10-24）

> 这一轮本来只做「用户设置入口」，结果先查出一个**发包卫生问题**，先修那个。
> 下面按发现顺序记，不按计划顺序。

## 一、先发现的真问题：发行包里带着本机运行痕迹

用户问「救援目录能不能在 UI 或别处设置」时，我去看 `tools\pack.ps1` 的排除列表，发现它**只排了 9 个文件名**：

```powershell
$excludeNames = @('history.jsonl','last-success.json','env-last.json','fix-audit.jsonl',
                  'feedback.jsonl','ui-out.log','ui-err.log','ui-ignored.json','ui-crash.log')
```

而 `Get-ChildItem -Recurse -File` 会把下面这些一并打进发行包：

| 文件 | 里面有什么 |
|---|---|
| `last-check.json` | 本机事件日志水印、失败原因 |
| `sentinel-last.json` / `sentinel-status.json` | **被监视进程名、PID、心跳** |
| `sentinel-coverage.json` | 监视目标列表 + 缺口 |
| `sentinel-pending.json` | 待处理事件（app 名、PID、时间） |
| `opportunity.json` | 本机装了哪些软件、恢复目录有没有文件 |
| `sentinel-events.jsonl` / `tray-acks.jsonl` | 事件与状态流水 |
| `sentinel-retention.jsonl` / `sentinel-error.log` | 清理记录 / 异常 |

**后果**：用户拿到包 = 拿到别人机器的进程名、PID、目录、时间线。发布流程文档写的是「自动排除运行时产物」，
但代码没实现 —— 又一次「文档说做了、代码没做」（和 M61 保留策略同一类）。

**修法**：把 `pack.ps1` 的排除列表补全，并**与 `errwatch-baseline.ps1` 的 `$exclude` 对齐**
（两处列表漂移就会复发，已在两边注释里互指）。

> 本机当时 `sentinel-events.jsonl` / `tray-acks.jsonl` 还不存在，所以「已经泄露过」不成立；
> 但 `last-check.json` / `sentinel-*.json` 确实在上一版包里（release.json 的 files 列表可查）。

## 二、用户设置层：覆盖，而不是改基线

`core\recover.json` 是**策略基线**（进 baseline、随包分发、每次校验必须一致）。
让用户改它 = 基线变红 + 升级被覆盖 + 审计看不出谁改的。

所以新增 `settings.json`（`<root>\settings.json`，**不进基线、不进发行包**）：

| 项 | 默认 | 范围 | 用途 |
|---|---|---|---|
| `diagnosis.maxDurationSeconds` | 600 | 60–7200 | 第四维诊断会话的绝对时限 |
| `autorespond.deadlineMinutes` | 30 | 5–1440 | 兜底决策时限（现阶段只影响提示） |
| `autorespond.defaultAction` | `notify-only` | `notify-only` / `open-ui` | **本版不提供任何自动执行动作** |
| `recovery.extraPaths` | 空 | 按 app 分组 | 用户自己的救援目录，**叠加**在 core 默认之上 |

**唯一实现**：`core\settings.ps1`。读取时逐项 try + 区间校验，任何一项坏了不影响其它项。

**合并点**：`core\opportunity.ps1` 的 `Get-ErrwatchRecoveryStrategy` 在返回前追加
`Get-ErrwatchRecoveryExtraPaths`，所以 sentinel / recover / doctor / ui 四个入口自动一致。

现场验证（真实合并，不是单测）：

```
pwsh -File errwatch-settings.ps1 -AddPathApp photoshop -AddPath '%TEMP%' -PathFilter '*.zzz'
pwsh -File errwatch-recover.ps1 -App photoshop -Json
→ notes: 查过的位置：…AutoRecover / * → 0 个；%TEMP% / Photoshop Temp* → 0 个；%TEMP% / *.zzz → 0 个
```

## 三、两个入口

| 入口 | 用途 |
|---|---|
| `errwatch-settings.ps1`（命令行） | `-Show` / `-DiagnosisSeconds` / `-DeadlineMinutes` / `-AddPathApp` / `-RemovePathApp` / `-OpenFile` / `-Reset` |
| **主界面工具栏「⚙ 设置」** → `errwatch-settings-ui.ps1` | 图形窗口：两个时限数字框 + 额外目录列表（浏览/添加/删除）+ 保存 |

UI 自检（`errwatch-ui.ps1 -Check`）确认按钮在工具栏：
`工具栏: ↻ 刷新=83px / ✧ 生成修复=110px / 按程序统计=109px / ⚙ 设置=90px / 更多 ▾=83px`

设置窗放成独立脚本，而不是塞进 82KB 的主界面 —— 低频操作、结构简单，塞进去只会让主 UI 更难维护。

## 四、这一轮踩到的两个坑（都是自己写出来的）

1. **越界值仍被写进文件**：`-DiagnosisSeconds 10` 时先写盘再读回校验 → 文件里留下 `10`，
   虽然读的时候被忽略，但下次谁看这个文件都会困惑。改成**先校验、再写**。
2. **字符串插值括号写错**：`"…$(if (...) { '，递归' } else { '' }）)"` 少了右括号，
   PowerShell 把全角括号当命令执行 → 运行时错误。改成 `-f` 格式化，不再手拼。

两个都是「跑一遍就暴露」的，说明**手工验证段是必要的**（只靠单测不会碰到命令行层）。

## 五、测试与门禁

`tests\test-settings.ps1` **7/7**（默认值 / 往返 / 越界忽略 / 按 app 合并 / 删除 / **不进基线不进包** / 动作白名单）。

| 项 | 结果 |
|---|---|
| `run.ps1` | 28/28 |
| 设置 7/7 · 诊断进度 10/10 · 保留策略 9/9 · 采集状态 11/11 | ✅ |
| 哨兵 / 托盘 / 契约 / 恢复机会 / 恢复 / 启动链 | 16/16 · 16/16 · 10/10 · 13/13 · 7/7 · 7/7 |
| 基线 | **89 文件**一致 |
| doctor | exit 0 |

## 六、剩余

1. `autorespond.deadlineMinutes` / `defaultAction` **目前只被读出来显示**，还没有消费方 ——
   它们是给「自动兜底骨架」（契约 §十一）预留的；在那之前它们是配置，不是行为。
2. 设置窗没有做「目录是否存在」的实时校验（命令行有）；填错目录会在救援时表现为「路径不存在」提示。
3. `recovery.extraPaths` 的 app 匹配用的是宽松包含（与 core 策略一致），
   `winword` 会不会误匹配到别的含 `win` 的程序？—— 用的是 `name -like "*key*" 或 key -like "*name*"`，
   短 key（如 `ps`）可能过宽，建议用户用完整名（winword / photoshop / acad）。

## 七、设置窗重写（2026-10-24 晚，用户截图反馈后）

用户截图指出三个问题，加上我自己跑出来的两个，一共五个：

| # | 现象 | 真因 | 修法 |
|---|---|---|---|
| 1 | 两个时限框**看不见数字** | `NumericUpDown` 继承了窗体的浅色 `ForeColor`，**白底白字** | 换成深底 `TextBox` + 保存时校验 |
| 2 | 「程序名（如 winword / photoshop / acad）」被裁成两半 | 提示塞在 120px 的标签旁边 | 提示单独占一行、宽 520 |
| 3 | 一页堆所有设置太挤 | 没有分类 | **左侧分类导航 + 右侧面板**（救援目录 / 时限与兜底 / 关于），参考 DSH 设置面板形态 |
| 4 | **点任何分类都跳到「关于」** | **闭包捕获**：`foreach { $key = $k; $b.Add_Click({ Show-Page $key }) }` —— scriptblock 触发时才读变量，循环结束后 `$key` 只剩最后一个值 | 用按钮自己的 `$this.Tag`（创建时钉死） |
| 5 | 右侧内容左边被导航条裁掉 | `Dock=Left` 与 `Dock=Fill` 混用：WinForms 按集合逆序布局，后加的 Fill 先占满 | 改**显式坐标 + Anchor** |

**截图对照验证**（不是靠读代码猜）：

- 改前：「诊断最多跑多久（秒）」框是空的（白底白字）
- 改后：`600` / `30` 清晰可见；分类可切换；提示一行完整

**端到端验证**（用户原话是「时间设置不了」）：

1. 点进「时限与兜底」→ 把 600 改成 **420**
2. 点「保存」
3. 读 `settings.json`：`"maxDurationSeconds": 420` ✅
4. `errwatch-settings.ps1` 读回：`诊断时限 : 420 秒` ✅
5. 恢复默认（删掉测试值）

> 教训（两条，都是这类 bug 的通用形状）：
> 1. **「控件看着空白」先怀疑颜色**，不要急着怀疑没赋值 —— 深色主题下这是高频坑。
> 2. **事件处理器里不能直接用循环变量**：PowerShell 的 scriptblock 是后绑定，
>    循环一结束变量就只剩最后一个值。要么用 `$this.Tag`，要么用 `.GetNewClosure()`。

## 八、主界面收拢 + 那个「大黑框」（2026-10-24 晚，用户第二张截图）

### 主界面工具栏定版

用户要求「主页面只留 搜索 / 筛选 / 刷新 / 生成修复 / 设置」：

| 位置 | 内容 |
|---|---|
| 工具栏 | `↻ 刷新` · `✧ 生成修复` · `⚙ 设置`（`更多 ▾` 整个移除） |
| 表格右键菜单 | 复制 · 查官方定义 · 生成修复 · 看未命中规则 · 忽略 · 社区搜 · 恢复已忽略 · **按程序统计** · **⚑ 开始应急救援** |
| 设置窗「工具」页 | **打开数据目录** · **打开最新报告** |

**为什么不把「更多」里的东西一股脑塞进设置窗**：`按程序统计`、`查官方定义`、`未命中规则`、`应急救援`
都依赖**主界面表格里选中哪一行**或内存里的 `$script:AllRows`。放进独立设置进程会直接失效。
所以按依赖关系分两处放 —— 功能一个没丢，位置更合理。

### 黑框的真因（第一次修错了方向）

第一次修：给 `Start-Process` 加 `-WindowStyle Hidden`。**结果更糟 —— 窗口根本不出现了。**

真因：`-WindowStyle Hidden` 把 `STARTUPINFO` 的 `SW_HIDE` 传给新进程，而它作用于**进程的第一个窗口** ——
对 WinForms 来说那个窗口是主窗体，不是控制台。于是「藏了黑框」连带把界面也藏了。

正确修法（双管）：

1. 调用方**正常启动**（不加 `-WindowStyle Hidden`）
2. 脚本自己**隐藏控制台**：`GetConsoleWindow()` + `ShowWindow($h, 0)`（DllImport，见脚本开头）

同样的坑也修在托盘菜单的「打开主界面」上。

> 教训：**「隐藏窗口」不要用启动参数去猜**。启动参数是给"第一个窗口"的，
> 而你想隐藏的往往不是它。让程序自己决定藏哪个窗口，才可控。
