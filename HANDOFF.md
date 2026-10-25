# errwatch 交接（2026-10-23 凌晨更新，UI + 复测 + 打包）

> ⚠ **本文档是历史档案，不是当前状态**（2026-10-25 审计回执后加这段）
>
> 这是 2026-10-23~24 那几轮的长交接记录，**里面的包名、条目数、测试数字都停在当时**。
> 直接拿它当「现在是什么状态」会出错 —— 审计方 2026-10-25 指出的「版本漂移」正是这一类。
>
> 想知道现在：① 看包外 `release.json`（当前候选包的权威身份）；② 看 `NEXT-SESSION.md` 顶部
> 「本轮交接」；③ 看 `tests\审计索引.md` 的基线表。**三个都比本文档新。**
> 本文档保留是因为它记着大量「为什么这么改」的过程证据，删掉等于丢背景。

> **给接手方（先读这三句）**
> 1. 这是一个**报错看护工具**：把电脑里的报错翻译成人话 + 给建议 + 说清该找谁。
> 2. 它不是安全工具、也不是救援盘合集 —— 详见 `定位.md`（**读它就是读这个项目的边界**）。
> 3. 想快速了解现状：跑 `pwsh -File errwatch-level.ps1`（现状概览）与 `pwsh -File errwatch-metrics.ps1`（五项指标），再看 `tests\audit-*.md`（26 份审计记录）；**还没做的事集中在 `ISSUES.md`**。

---

## 最新状态（2026-10-24 21:4x · 60 秒读完）

> 这一节是给**新会话接手**用的。读完它 + `STATE-CONTRACT.md` + `tests\审计索引.md` 就能开工，不必回读历史。

### 2026-10-24 21:2x–21:4x（交接后第一轮：A27 / A28 / A29）

> 这一轮从「接手第一眼看到根目录 144 个 `sentinel-pending.json.corrupt-*`」开始。

1. **A27 pending 空队列被误判「损坏」（宿主漂移事故）**
   - 现象：根目录 144 个 4 字节备份文件，每 65 秒新增一个，从 18:27 起持续。
   - 真因：`'[]' | ConvertFrom-Json` 在 **PS7** 走管道时输出零个对象（变量得 `$null`），**PS5.1 才保留空数组**；`Sync-Pending` 用 `$null -eq $raw` 判「文件损坏」→ 只要队列被写成 `[]`（= 当前没有待处理），**每一轮轮询都「修复」一次并留一个备份**。
   - 修法：判定改成 **try/catch 判解析成败**（返回值真假不参与）；`[]`=合法空队列；空文件 / `null` 字面量 / 半截 JSON = 损坏；备份**只留最近 5 份**（取证要证据，但 144 个 4 字节文件只会淹掉真正的那一份）。
   - 实测（生产目录，真实配置）：停哨兵 → 把 pending 写成 `[]` → 跑一轮 → **corrupt 0 个 / `integrity.repaired=false` / `[]` 原样保留**（旧代码在这一步必然多一个备份）→ 重启哨兵。`test-sentinel` V（含「哨兵必须真跑过」防空转断言）：**22/22**。
2. **A28 门禁命令在本机会直接挂**
   - `powershell -File tests\run.ps1` → `running scripts is disabled`。5.1 的 LocalMachine 策略是 **Undefined**（生效值 Restricted），而项目所有启动链（bat/vbs/计划任务）都自带 `-ExecutionPolicy Bypass`，**只有文档里的门禁命令没带** —— 交接文档「接手第一件事」照着敲就是失败。
   - 修法：新增 `tests\run.cmd`（自动优先 `pwsh` 7 + 自带 Bypass + 打印 `[gate] EXIT=n`），文档命令统一改掉。实测 **EXIT=0**。
3. **A29 P1「设置里手动添加监视目标」落地（用户拍板的方向）**
   - 用户原话：「学习机制和历史学习会是一个过程，如果初期就出现会导致用户不相信我们」→ 需要一个**可控出口**，不必等某个程序崩过一次才被学到。
   - 实现：`core\settings.ps1` 的 `watch.extra`（名字规范化：可粘完整路径 / 去 `.exe` / **拒绝通配符** —— `*` 等于监视整机）+ 增删查三个函数；哨兵加载 `$cfg` 后**注入成 watch 组**（`source=user`，与静态名单**重名不重复注入**）→ `Get-WatchNames` / 覆盖声明 / 兄弟判定三处自动生效；设置窗新增左侧「监视目标」页（「我加的（可移除）」与「内置（随包分发）」分开列）；命令行 `-AddWatch` / `-RemoveWatch`。
   - **端到端实测**：config 的 `watch` 为空、只靠 `settings.json` → 哨兵第一轮就认到（覆盖声明 note =「你在设置里手动添加的」），杀掉进程 → 第二轮产生 `ProcessExit`。`test-settings` W1/W2/W3：**12/12**。
4. **顺手补强 B15**：设置窗新增 `-CheckBuild`（真实构建整个界面、不显示、不进消息循环）—— `-Check` 只打印设置，构建期的错抓不到。纳入 `test-settings` I。
5. **发布链重跑**：基线 102 文件 → pack `20261024-bd` → make-sbom → verify **PASS** → gate **allow** → make-release → 材料一致性 **19/19**。

### 2026-10-24 21:5x–22:0x（第二轮：C2 / B14 / B13）

> 这一轮的关键是**先验前提再写代码**：C2 的方案形态完全由一次实测决定。

1. **C2 WER LocalDumps 一键布防 → `errwatch-dump.ps1`（A30）**
   - 先证前提：写 `HKCU\...\Windows Error Reporting\LocalDumps\<app>.exe`（DumpFolder/DumpType=2/DumpCount=5），用 `csc /unsafe` 编一个访问空指针的探针，跑出真 `0xC0000005`，等 24 秒 → **0 个 dump**；同一次实验 WER 事件 1001（故障存储段）有记录 → WER 处理了崩溃，但不理 HKCU。
   - 顺手排除了干扰项：`Environment.FailFast` 走的是 CLR 自己的路径（`0x80131623`），不经过 WER，不能用来做这个实验。
   - 结论：**只能写 HKLM → 必须管理员**（本机在 Administrators 组但进程未提升）。
   - 落地：默认只预览；`-Apply` 真写；`-Elevate` 弹一次 UAC 重跑自己；`-Remove`/`-All` 撤销（子键清空后连根键删，不留空壳）；`-Status` 先查 **WER 是否被策略禁用**（本机：未禁、历史 553 份报告、0 个 dump）；`-SelfTest` 自己编译探针、只给探针布防、跑崩、等 dump、撤键。
   - 细节判断：落盘用 `%ProgramData%\errwatch\dumps`（WER 是系统进程，`%LOCALAPPDATA%` 不可靠）；默认迷你 dump（CAD 完整 dump 可能 GB 级）；备份 `reg export` 且只留 5 份。
   - `test-dump` **6/6** 进门禁，三条守卫：预览不许改注册表 / 没权限不许假装成功 / **HKCU 那条死路不许加回来**（文件里还留着"怎么证明它无效"的方法）。
2. **B14 结案：不是「过宽」，是「名字写错」（A31）**
   - `Get-Process -Name` 实测：`dsh`=0、`electron`=0、`electron-shell`=0，`DSH Desktop`=12。DSH 真实 exe 名带空格，过去只能靠「有窗口」动态规则看着，而 12 个进程里只有 1 个有窗口。
   - 名单改成 `["DSH Desktop"]`。副作用实测：子进程正常退出 `exitCode=0` → `normal-exit` → 不进待处理；重启后 45 秒 +0、60 秒 +0。
3. **`diagnosing` 中间态被当成结论（A32，被上一条放大的既有缺陷）**
   - `Sync-Pending` 原来「边判定边合并」→ 最终记录（normal-exit）在合并前就被 continue 掉，pending 留下更早的 `diagnosing` → 一次正常退出以「诊断中」挂在待处理、托盘弹了通知（`notify=attempted` 可查）。
   - 改为「先按 id 去重（后写覆盖前写）再判定」+ 中间态不进待处理 + **超 120 秒兜底成 unknown-exit**（防哨兵取证途中被杀导致永久漏）。
   - 踩到一个静默坑：`$e.coverageReason = '...'` 在事件没有这个属性时抛错，而外面套着 try/catch → 理由永远是空。改成判属性存在再赋值/Add-Member。`test-sentinel` X：**23/23**。
4. **B13 结案：同一目录被枚举两遍（A33）**
   - 本机实测 `%TEMP%` 与 `%LOCALAPPDATA%\Temp` 是同一目录，acad/gstarcad 各配两条 → 白跑 + 「查过的位置」里出现两条一样的。
   - 按**展开后的真实路径**去重（不是配置原文：企业环境 TEMP 重定向时这两条仍是两个真实目录），新增 `duplicateDirSkips`。实测 gcad/acad 各跳 2，verdict 与文件数不变。`test-recover` T（写三遍 → 候选仍 1 条；去重被删就会变 3 条），**20/20**。
5. **发布链重跑**：基线 → pack `20261024-be` → verify **PASS** → gate **allow** → 材料一致性 **19/19**。

### 2026-10-24 22:0x（用户实测反馈：抓到却「没有收录」）

1. **现象（用户截图）**：主界面里 `crashprobe.exe / 0xe0434352 / KERNELBASE.dll`，结论「未覆盖」、可信度「无」、下一步「未收录这条报错：先按怎么验收集线索，再提交反馈」。——**抓到了却给不出说法**，等于在最需要的时候说不知道。（那条 `crashprobe.exe` 是上一轮验证 WER dump 时编的空指针探针，属测试污染，已按 `程序||错误码` 写进 `ui-ignored.json` 隐藏。）
2. **诊断出两个缺口**：
   - 规则库缺 `0xe0434352`（CLR 未处理异常 —— .NET 程序崩溃**最常见**的码）和 `0x80131623`（FailFast）；
   - 更根本：**任何未收录的码都是空白**。规则库 30 条覆盖不到的错误码，用户看到的就是「没有结论」。
3. **补两层**：
   - 2 条具体规则（含 why / do / verify / route）；
   - **4 条码段兜底**：`0xe0[0-9a-f]{6}`（CLR 异常段）、`0x8013[0-9a-f]{4}`（CLR HRESULT 段）、`0x8007[0-9a-f]{4}`（Win32/HRESULT 段）、`0xc0000[0-9a-f]{3}`（系统级异常段）。判据是「这是哪一类 + 下一步看哪儿」，不是编造具体原因。
4. **顺带发现（本轮最有价值的副产品）**：这两个码与同一秒的 `.NET Runtime` 事件**成对出现** ——
   - `0xe0434352` → 事件 **1026**「由于未经处理的异常，进程终止」
   - `0x80131623` → 事件 **1025**「应用程序通过 System.Environment.FailFast 请求终止进程」
   那条事件里直接写着**异常类型**，比错误码有用得多。所以两条新规则的 `verify` 就教用户去事件查看器看那一秒的 `.NET Runtime`。本机用探针实测配对，标 `verified`。
   另外写进了 why：这类崩溃的「出错模块 KERNELBASE.dll」只是**异常往外抛的通道**，不是 KERNELBASE 坏了 —— 这是最容易被误读的一点。
5. **测试 `test-rules` 5/5 进门禁**：具体码不许被段规则抢走 / 未收录的同段码必须有兜底 / 完全不认识的码必须仍是 unknown / 段规则必须排在具体规则之后 / 每条规则都得有 why+do+verify。
6. **反证（重要）**：把段规则换位后 A 与 D 双双 FAIL，恢复后 5/5。而 **D 的第一版是死测试**——它按「前 7 位」分组比对，`0xe0` 永远不等于 `0xe0434`，于是永远 PASS；正是这次反证把它抓出来并改成「具体码是否以段规则前缀开头」。
7. **还有第三层：事件 ID 规则**：前两层修完，报告仍显示「规则未覆盖 1」；追下去发现剩下的那条不是错误码，而是 `core\events.json` 缺 `.NET Runtime/1025`（和 0x80131623 成对的那半句）与 `Service Control Manager/7009`。补完后实测报告覆盖 **100%**（6/6 可给结论、8 个事件 0 个未收录）。`test-rules` 增到 **6/6**（新增 F：事件规则每条要有 why+do，且 .NET 那对 1025/1026 必须都在）。
### 2026-10-24 22:1x（用户看图提的两处体验：打开即扫描 / 监视目标可选 exe）

1. **打开主界面自动扫一次**（用户：「报错可以每打开一次就自动默认扫描一次吗，不用每次都自己点」）：原来扫描逻辑整个绑在按钮的 click 里、扫完必弹「扫描完成」结论窗。改成 `Invoke-Scan -ShowResult`：自动那次传 `$false`，**不弹窗、失败只写状态栏**；用 `Timer(500ms)` 在 `Add_Shown` 启动而不是同步跑 —— 否则窗体第一帧就卡在 5–10 秒的扫描上，用户会以为界面打不开。新增 `-NoAutoScan` 供自动化/排障。
2. **监视目标页加「浏览…」**（用户：「这里可以像选择保存路径那样选择吗」）：`OpenFileDialog` 限定 `*.exe`、默认打开 Program Files、取文件名去扩展名、**选完直接加入列表**（选 exe 已是明确意图，不必再点一次「加入监视」）。注意顺序坑：先 `Update-WatchList` 再写「已加入」提示，否则提示被计数文案覆盖。
3. **顺手补掉一个门禁漏洞**：`-CheckBuild`（真实构建界面、不显示）上轮就加了，但 `test-settings` 的 I 用例跑的是 `-Check`（只打印设置、不构建），所以「引用未定义控件」这类错一直没被覆盖。现在 J 用例真跑 `-CheckBuild`，K 用例守自动扫描三约束（打开即扫 / 不弹窗 / 可关闭）。`test-settings` **14/14**。
4. **验证方式**（不打扰用户）：WinForms Timer 接线用**屏幕外窗体**（Location -4000,-4000 + ShowInTaskbar=false）实测 —— 500ms 后触发 1 次、总耗时 579ms，证明是 timer 触发而不是立即执行。没有重启用户正开着的主界面（PID 24148 跑的是旧代码，下次打开才生效）。
5. **自己踩的坑（连续 4 次）**：用某一行当 `old_string` 插入内容时，`new_string` 里忘了把那一行带回去 → 整行被静默删除，而 markdown 不参与测试，门禁全绿也发现不了。这次丢了「**A1 的修法不是改一次 JSON**」标题，靠脚本复查表格连续性才发现。已写进 NEXT-SESSION 坑表。
6. **发布链重跑**：基线 → pack `20261024-bi` → verify **PASS** → gate **allow** → 材料一致性 **19/19**。8. **发布链重跑**：基线 → pack `20261024-bi` → verify **PASS** → gate **allow** → 材料一致性 **19/19**。

**当前包**：`E:\ai\_dist\errwatch-20261024-bn.zip`；条目数/大小/SHA **一律以 `_dist\release.json` 为准**（本文档本身在包里，写死就会自指漂移）。
（本机实测：verify **PASS** / gate allow / 材料一致性 **19/19**；含 A27 宿主漂移修复 + A28 门禁入口 + A29 手动监视目标 + `-CheckBuild`。）

**门禁**：`run.ps1` 28/28 · 哨兵 **21/21** · 托盘 **19/19** · 状态契约 **10/10** · 启动链 7/7 ·
恢复机会 13/13 · 应急恢复 **19/19** · **五项指标 7/7** · 崩溃字段 7/7 · **采集状态 11/11** · **保留策略 9/9** ·
**诊断进度 10/10** · **用户设置 9/9** · **兜底 6/6** · **真实链路 9/9** · **规则来源与许可 10/10** · **自检工具 8/8** · **互斥锁 3/3** · 基线 **98/98** · lint FAIL 0 / WARN 0。

**这一夜修完的（按严重度）**
1. **启动链断裂（P0-1）**：`register-watch` 原来只注册 `errwatch-notify`，sentinel/tray 从未被拉起；本机更糟 —— 那个任务**压根没注册过**。现在双通道（计划任务优先 / 启动文件夹回退，后者不需管理员）+ 三任务 + 哨兵单实例 Mutex。
2. **工具自己死了用户看不出来**：杀掉哨兵后托盘仍显示「待处理 0」+ 旧 coverage。现在托盘读 30 秒心跳，超时变红 + 「重启哨兵」+ coverage 标「停机前快照」。
3. **假退出丢事件（P0）**：`startTime` 经 JSON 往返变 DateTime，实例身份比较失效 → 活着的进程被误报退出，真退出反被 5 分钟去重挡掉。修法：`Get-InstanceKey` 归一。
4. **状态契约（结构性）**：`launched` 不再是终态；三维度 `lifecycle / notify / rescue` 拆开。契约见 `STATE-CONTRACT.md`，实现见 `core\ack-state.ps1`。
5. **更新后静默跑旧版**：`-Status` 现在比对启动项指向的目录与当前目录。
6. **兼容性**：notify 任务补 `-ExecutionPolicy Bypass`；`%TEMP%` 改走注册表 / `%LOCALAPPDATA%\Temp`（不再依赖进程环境）；doctor 报执行策略与 TEMP 重定向。
7. **兄弟实例降级**：同组还有实例在跑时，事件标 `OBSERVATION_UNCERTAIN` + `siblingInstances`（防「启动器退出」被说成「程序崩了」）。
8. **采集状态误判（2026-10-24 00:2x，接手后再查一遍抓到的）**：notify 靠中文文案判断「无匹配事件」，而 5.1 生产路径实抛「找不到**任何**与指定的选择条件匹配的事件」—— 差「任何」两个字，正则不命中，于是**「本机没有错误」被记成「检查失败」**：水印不推进、弹窗不触发、doctor 常红（`last-check.json` 从 18:05 起全是 `exit 2`，**弹窗静默失效 6 小时**）。修法：判定收进 `core\Test-ErrwatchNoEventError`（错误 ID 优先，文案只兜底），notify / timeline / `errwatch.ps1` 三处共用，并给水印加 `MaxAgeHours` 上限防积压。`test-collect-state` **11/11** 看守，且做过反证（退回旧正则 → B1 FAIL）。详见 `tests\audit-collect-20261024.md`。
9. **保留策略（2026-10-24，契约承诺 vs 代码事实不一致）**：契约 §三 早写「7 天滚动」，实际是两套相反口径 —— pending 按**事件发生时间**丢（第 6 天才被处理的事件第 7 天就消失）、acks **从不清理**（读窗口 4000 行溢出后早期终态读不到 → 已处理事件复活）。现在统一为**唯一判据：进入终态的时间**；`core\retention.ps1` 判定 + 执行，哨兵每 6 小时最多清一次，带并发保护（托盘在写就跳过本次）。`ack-state.ps1` 新增 `lifecycleAt`。`test-retention` **9/9**，两个方向都反证过（去掉 `lifecycleAt` → A/D/F 挂；改成「终态即清」→ B 挂）。详见 `tests\audit-retention-20261024.md`。
10. **没有明确的停止方式 + 改完代码不生效（2026-10-24，方案 §六 要求的能力）**：此前只能杀进程，而一堆 `pwsh.exe` 分不清哪个是哨兵。现在：`errwatch-sentinel.ps1 -Stop`（写停止标记，15 秒内没被消费就删标记并报失败）· `-InstanceName`（测试实例与生产实例共存，Mutex 隔离）· `-RetentionEveryHours`（测试钩子）· `errwatch-restart.ps1` + **双击「重启看护.cmd」**（按命令行精确匹配，只动 errwatch 两个进程）。`tools\verify-retention-live.ps1` 真起哨兵、真杀进程、真走清理。**踩到的坑**：重启脚本第一版用「心跳 < 5 秒」判成功，而刚停掉的旧进程心跳本来就很新 → 误报成功；已改成比较时间戳前进。详见 `tests\audit-restart-20261024.md`。
11. **第四维：诊断进度（2026-10-24，用户拍板的结构性扩展）**：契约 §十 先定稿再改实现 —— `progress ∈ {not-started, collecting, complete}`，`complete` **只表示流程终结，不代表诊断成功**（结论仍归报告五态）。**绝对时限** = `sessionStartedAt + maxDuration`（默认 600 秒），**心跳不延长**，**重试不重置** `sessionStartedAt`（只能用剩余时间），`attemptCount` 上限 2；崩溃恢复按开始时间判：过期 → `timeout`、未过期 → `interrupted`（不假装重试）。实现：`core\progress.ps1` 唯一实现 · `ack-state.ps1` 支持 `meta` · 哨兵取证前写 `collecting`、取证后写 `complete` · 托盘显示诊断后缀。`test-progress` **10/10**，两个反证都命中（重置开始时间 → B 挂；去掉上限 → C 挂）。详见 `tests\audit-progress-20261024.md`。
12. **用现场软件验证恢复（2026-10-24，用户：「CAD 只是例子」）**：盘点本机 86 个程序，用**真实存在**的 `%APPDATA%\Microsoft\Word\*.asd`（8-12，108 KB）跑了一遍 `errwatch-recover -App winword`：找到文件、判 **STALE**、给「先复制再改名」引导、**没改任何文件**。按真实路径新增 Photoshop 条目（`AutoRecover` 目录在、空 → doctor 报「很可能没开」并给开法）。嘉立创EDA 是**云同步**，不硬套本地恢复（否则给误导指引）。VSCode / Notepad++ / JetBrains / Blender 本机没装，doctor 已诚实报「缺」。详见 `tests\audit-field-recovery-20261024.md`。
13. **设置入口 + 发包卫生（2026-10-24，用户：「救援目录和超时该能设置」）**：
   ① **先修了发包卫生**：`tools\pack.ps1` 的排除列表原来只排了 9 个文件，`last-check.json` / `sentinel-*.json` / `opportunity.json` / `*.jsonl` **会被打进发行包**（含本机进程名、PID、目录、时间）—— 与 baseline.ps1 的 `$exclude` 对齐后才堵住。
   ② **用户设置层**：`settings.json`（不进基线、不进发行包）存 诊断时限 / 兜底决策时限 / 默认动作 / 救援额外目录；唯一实现在 `core\settings.ps1`，读取时逐项校验，越界忽略。
   ③ **两个入口**：命令行 `errwatch-settings.ps1`；主界面工具栏 **「⚙ 设置」** → `errwatch-settings-ui.ps1`（图形窗口，可浏览/添加/删除救援目录）。
   ④ `core\opportunity.ps1` 在策略返回前合并用户额外目录，sentinel / recover / doctor / ui 四个入口自动一致（现场验证：`%TEMP% / *.zzz → 0 个` 出现在 recover 的「查过的位置」里）。
   `test-settings` **7/7**；自己踩两个坑已修（越界值先写后校验、字符串插值括号错）。详见 `tests\audit-settings-20261024.md`。
14. **有限自动兜底（2026-10-24，契约 §十一）**：用户没回应时「别干等着」，但**超时不等于授权** —— 到期只做两件事：**菜单标记 `[⏰ 超时 N 分钟]` + 写一条 `tray-fallback.jsonl` 审计**，不碰文件、不碰进程。动作白名单 `notify-only / open-ui` **写死在 `core\fallback.ps1`**（配置只能选提示方式，不能扩大范围）；`delete / kill-process / restart / overwrite / move / system-change` 一律拒绝。计时起点是**事件被发现的时间**；`lifecycle` 终态不再升级；同一事件只升级一次。`settings.json` 的 `deadlineMinutes` 在这里**第一次真正被消费**。`test-fallback` **6/6**；真实验证：10 分钟不标记、45 分钟标记。详见 `tests\audit-fallback-20261024.md`。
15. **界面收拢 + 设置窗重写 + 救援入口（2026-10-24 晚，按用户截图改了三轮）**：
   ① **主界面只留**：搜索 / 时间范围 / 只看没说明的 / **↻ 刷新** / **✧ 生成修复** / **⚙ 设置**（`更多 ▾` 整个移除）。
   ② **原「更多」的功能按依赖关系分两处**：依赖选中行的（按程序统计、查官方定义、未命中规则、⚑ 应急救援）→ **表格右键菜单**；不依赖的（打开数据目录、打开最新报告）→ **设置窗「工具」页**。
   ③ **设置窗改成左侧分类 + 右侧面板**（救援目录 / 时限与兜底 / 工具 / 关于），参考用户给的 DSH 设置形态。
   ④ **看护服务开关**（工具页）：显示「运行中/已停止」，可停可启。停止 = 写停止标记（不新起进程）；启动 = 走登录启动项 `.vbs`（后台无控制台）。
   ⑤ **手动救援入口**（救援目录页）：下拉选程序 + `⚑ 开始应急救援`。候选 = 待处理事件 app + `recover.json` 已知 + **当前正在运行的已知程序**。**只影响手动救援**，哨兵发现故障时走事件自己的程序。
   ⑥ **recover 输出改人话**：状态不再抛 `NOT_FOUND / INCOMPLETE`；新增 **「现在的情况」** 一行（还在跑 → 先别关、回程序里保存；刚出过问题 → 下面能补救；都没有 → **可以不用管**）。
   **踩到的三个坑**：`Update-AppChoices` 定义了没调用（下拉永远空）· `$btnRescue` handler 插在按钮定义之前（一点就抛「不能对 Null 调用方法」）· 核验段搬到 `Finish` 外面而 **`Finish` 结尾有 `exit`** → 永不执行。
   **黑框根因**：`-WindowStyle Hidden` 的 `SW_HIDE` 会作用到进程**第一个窗口**（WinForms 主窗体），所以「藏黑框」连带藏界面。最终改为**主界面同进程 `&` 调用设置窗**（不新起进程 = 没有新控制台）。详见 `tests\audit-settings-20261024.md` §七、§八。
16. **recover 分清「没装」和「没开自动保存」（2026-10-24，用户点名：「acad 没装却说自动保存没开」）**：
   ① **根因一（数据）**：`recover.json` 里 autocad 的两条 `Documents`、blender 的一条 `Documents` 没标 `generic` —— 而 `Documents` 是人人有的目录，于是被判成「专属目录在但空」= `EMPTY` → 文案「自动保存没开」。已补 `generic: true`。
   ② **根因二（判定）**：根本没有「装没装」维度。新增 `Test-ErrwatchAppInstalled`（`core\opportunity.ps1`）：证据 = `install.files` 通配路径存在（便携版也能命中）/ 卸载项 `DisplayName` 命中 `install.words`；返回 **`yes / no / unknown`**，`unknown`（探测不可用）**绝不猜成没装**。七个 app 都配了 `install`。
   ③ **差点埋进去的坑**：第一版用子串匹配，`acad` 命中了「Windows SDK F**acad**e」→ 没装判成装了。改成**词边界** `(^|[^\w])词([^\w]|$)`。
   ④ **接线**：recover 与 doctor 都按三态分支；`installed=no` 时说「没找到安装痕迹，不用去改设置」，`yes+EMPTY` 才说「自动保存没开」。
   ⑤ **测试**：`test-recover` 7 → **11/11**（H 通用目录不冒充专属 / I 反证去掉 generic 必须变 EMPTY / J 文件命中 yes→删掉 no / K 无声明必须 unknown）；并**接进 `run.ps1`**，且 recover 失败会让门禁 `exit 1`（此前专项测试失败只打印不拦）。
   详见 `tests\audit-recover-install-20261024.md`。**现场实测**：acad=no（GENERIC_ONLY）· winword=yes（文件证据）· photoshop=yes（注册表 `Adobe Photoshop 2025`，装 D 盘 → 证明不能硬编码 Program Files）
17. **五项可观测指标（2026-10-24，方案 §七；plan-vs-current 第 16 条原是「未定义」）**：
   ① **先定口径再写代码**：`core\metrics.ps1` 唯一实现，五项 = 发现（lastSeenAt→detectedAt）/ 触达（detectedAt→notify=attempted）/ 决策（detectedAt→lifecycle 终态）/ 恢复（有 rescue 记录的事件里到 user-confirmed/verified 的比例）/ 安全（抑制数 + 人工「没有可操作的」+ 覆盖缺口）。
   ② **贯穿原则：没有样本就显示「量不出来」，绝不显示 0** —— 0 秒会被读成「延迟为零」，0% 会被读成「全失败」。`p50Sec` 在无样本时是 `null`。
   ③ **两条反证/坑**：`suppressed` **不算触达**（否则抑制越多显得触达越好）；恢复率**按事件去重**（同一事件 launching→launched→verified 三行只算 1 次）。
   ④ **接线**：CLI `errwatch-metrics.ps1`（人话 / `-Json` / `-Days` / `-Root` 只换数据目录，core 固定从脚本目录加载 —— 测试踩到过混用会报「核心层缺失」）。
   ⑤ **测试**：`test-metrics` **6/6**，接进 `run.ps1`（失败即拦）。
   **本机实测**（02:1x）：事件 0 条 / ACK 0 条 → 四项「量不出来」；覆盖目标 4 个全部非 OK（3 个启动时未运行 + 1 个观测不确定）。**这就是当前真实状态：没有故障样本，指标不该编数字。**
   详见 `tests\audit-metrics-20261024.md`。
18. **真实崩溃演练 #1（2026-10-24，Word 空白文档；用户点的目标）**：
   ① **前提**：Word 原本**不在**监视列表 → `core\sentinel.json` 新增 `{ "match": ["winword","excel","powerpnt"], "note": "Office" }`；重启看护（只结束托盘 21124，哨兵优雅停止）加载新配置，覆盖目标 4 → 5。
   ② **过程**：起 Word 空白文档（PID 13636，无内容）→ 哨兵 `MONITORED` → 02:11:17 强杀 → 哨兵 **1.037 秒**发现。
   ③ **结果**：事件 `ProcessExit / verdict=unknown-exit / coverage=MONITORED`（**不冒充崩溃**）落进 `sentinel-events.jsonl` + `sentinel-pending.json`；托盘 `pending=1/open=1`；`recover -EventId` 正确说「**这个程序刚出过问题**」。
   ④ **演练抓到的真问题（已修）**：事件里 `lastSeenAt` 被写成 `"10/24/2026 02:11:16"`（**丢毫秒**），指标自算得 1.4 秒，而事件自带 `latencyMs=1037`（1.04 秒）。修法：`core\metrics.ps1` 的「发现」**优先用 `latencyMs`**，自算只兜底。
   ⑤ **没证明的事**：空白文档没有自动恢复文件，所以这次只证明「**链路通**」，没证明「**救得回内容**」。
   **→ 第二轮（第 19 条）已完成，证明内容救得回。**
19. **真实崩溃演练 #2（有内容，2026-10-24）+ 救援副本保存（用户：「救回来的东西在哪里」）**：
   ① **`AutoRecoverTime` 注册表键是假的**：改成 1、等 90 秒、强杀，全盘没有 `.asd`；查 `Word.Options.SaveInterval` 还是 **10**。
      正确做法：`$w.Options.SaveInterval = 1`（Word COM 自己持久化），设完立刻读回验证。**这说明「按文档改注册表」会得到一个「以为开了、其实没开」的假状态。**
   ② **演练结果**：`TypeText` 输入内容（不保存）→ 02:21:40 出现 `“自动恢复”保存文档1.asd`（**31.5 KB**）→ 强杀 → `recover` 的 `freshnessSummary.inSession = 1`，落在「**本次会话（最可能是你刚丢的那份）**」。
   ③ **内容验证**：UTF-8 字节里命中演练文本；**Word 打开 `.asd` 正文 61 字符含该文本** —— 真的救得回，不是只找到文件。
   ④ **新增「复制备份」**：CLI `-SaveTo <目录>`（显式才复制，`-IncludeStale` 才带历史遗留）；UI 在「⚑ 开始应急救援」结果后问「要备份一份吗」→ 选目录 → 只复制。
      边界：只复制/原文件不动/不覆盖（同名加 (1)）/目标=原目录跳过/不改扩展名。实现 `Copy-ErrwatchRescueCandidates`（`core\opportunity.ps1`）。
   ⑤ **实测硬限制（必须知道）**：Word **只从它自己的恢复目录**能打开 `.asd`；同一份文件放 `%TEMP%` 或 `Documents` 都报「命令失败」（哈希一致，所以不是复制坏了）。
      所以副本定位是**保险**（防程序清理），不是「双击即开」——界面文案已这么写，并给出「复制回恢复目录」这条路。
   ⑥ **踩坑**：`.asd` 改名 `.docx` → Word 报「文件格式与文件扩展名不匹配」；`Split-Path -LiteralPath … -Leaf` 是**非法组合**（`-Leaf` 只属于 `-Path` 参数集，报「无法解析参数集」，`Set-PSDebug -Trace` 才定位到）；edit 后又丢 4 个文件的 BOM。
   ⑦ **测试**：`test-recover` 11 → **15/15**（L 复制成功+原文件不动 / M 不覆盖 / N 源目录跳过 / O STALE 默认不复制）。详见 `tests\audit-rescue-save-20261024.md`。
20. **缺陷自查（2026-10-24，用户：「看看有没有 bug 漏洞」）—— 挖出两个本轮改动引入的真 bug**：
   ① **B（真 bug）**：「同组还有实例 → 观测不确定」用的是**整组 match 列表**，而 Office 组把 winword/excel/powerpnt 放在一起 →
      实测：Word + Excel 同时开、强杀 Word → 事件标 **`OBSERVATION_UNCERTAIN` / sibling=1**，理由「同一软件还有 1 个实例在跑」——那个实例是 **Excel**。
      **Word 崩溃被 Excel 拖成「观测不确定」**。修法：拆组（11 组），只保留「同一软件的多进程」（PICO launcher+server、CAD 版本线、DSH）。修复后 `MONITORED / sibling=0`。
   ② **A（真 bug）**：Office 加进监视后，**正常关闭 Word/Excel 也产生 `unknown-exit` 待处理**（退出≠崩溃是既有设计），一天刷十几条假警报。
      修法：`Sync-Pending` 重建时**同一程序 24h 内只留一条** `unknown-exit`（第一条仍提示、`crash-suspected` 不受影响、**事件事实全留**、折叠数进 `integrity.droppedQuiet`）。
   ③ **C（隐患）**：`-SaveTo` 复制无大小上限（VSCode/Notepad++ 的 filter 是 `*`）→ 现在报总大小，>500 MB 提示。
   ④ **D（隐患）**：doctor 对 7 个 app 各判一次安装 = 21 次全量读注册表，3.5s。加进程内缓存 → **2.1s**。
   ⑤ **测试**：`test-sentinel` 新增 **P**（同程序 24h 内两次退出 → pending 仍 1、events 2、droppedQuiet≥1）；**反证**：把 24h 判断改成 `if ($false)` → P **FAIL**，还原后 **17/17**。
   ⑥ **未验证**：UI「备份副本」对话框只做了 5.1 语法检查，没端到端点击。**已知限制**：JetBrains 组内 6 个产品仍互为兄弟；24h 窗口写死。
   详见 `tests\audit-defect-scan-20261024.md`。
21. **外部审查的核实与修复（2026-10-24）—— 逐条核实，审查说的全对**：
   ① **P0-1（真）**：`errwatch-sentinel.ps1` 更新恢复机会时用的是 `$verdict`，而该变量在本作用域**从未定义**（全文只出现 1 次），恒为 `$null` →
      `crash-suspected` 分支永远进不去，**恢复机会永远记成 CLOSED**，「崩溃」与「正常退出」在 Opportunity 层面无法区分。改为 `$ev.verdict`。
   ② **P0-2（真）**：事件落盘晚于取证（取证 700-735 → 入队 737 → 落盘 807）。取证是读事件日志、可能慢也可能被强杀；被杀后磁盘上只有 `progress=collecting` 的 ACK、没有事件。
      改为**先落盘**：取证前先追加一条 `verdict=diagnosing`，取证后再追加最终记录（同 id，后写覆盖）。
   ③ **P1-3（真）**：`Get-ExitEvidence` 用 `-ErrorAction SilentlyContinue` + `catch {}`，把「查询成功但没匹配」和「查询失败」都变成 `$null` →
      外层「取证失败可重试一次」**从未触发**（死代码）。改为返回 `{queryOk, match, error}`，`no-match` / `evidence-failed` / `timeout` 分开记。
   ④ **open-ui 移除**：未实现却留在白名单 → 审计会写「执行了 open-ui」而实际只弹气泡。白名单只剩 `notify-only`；`settings.ps1` 改为问白名单而不是硬编码。
   ⑤ **Word 体检（审查 #1）**：`AutoRecoverTime` 被演练 #2 证伪；深挖后 `AutoRecoverySaveIntervalMetadata` **也不随设置变化**（设 5/10 都是 `0x80000001`）；
      且 `.asd` 在正常关闭时会被删除 → 两种自动判据都会撒谎。改成 `check.kind=com-option`：**只在 Word 已运行时**用 COM 读真值，没运行就报「查不到」。
   ⑥ **UI 串起数据（审查 #2）**：设置窗「工具」页新增 **📊 看护健康**（覆盖目标数 + 五项指标）。UI 备份改为「没有候选就不问」。
   ⑦ **测试**：`test-sentinel` 新增 **Q**（crash-suspected → LOST + 先落盘，用 `ERRWATCH_TEST_FAKE_EVIDENCE=1` 注入假证据）；
      **两个反证**：退回 `$verdict` → Q FAIL、去掉先落盘 → Q FAIL，还原后 **18/18**。兜底 6/6（open-ui 必须被拒）、设置 7/7（open-ui 存不住）。
   详见 `tests\audit-review-fixes-20261024.md`。**未做**：doctor 双通道检查、复制完整性校验、UI 端到端点验、WER LocalDumps、CAD 演练。

22. **第二轮外部审查的核实与修复（2026-10-24）**：
   ① **P1-4（真，且连带一个基础 bug）**：用户设置里的额外恢复目录只合并进扫描列表、**没进白名单** → 扫描时被判「白名单外，已跳过」；
      连带发现 `Test-ErrwatchPathAllowed` 用 `StartsWith($root)` 而 root **带尾斜杠** → **目录本身永远匹配不上**（只有子路径能过）。两处都修了，端到端验证：加设置后目录本身/子路径都 True，未授权目录仍 False，recover 扫到 `E:\ai\...\drawing.sv`。
   ② **门禁范围（真）**：`run.ps1` 原来只把诊断/冒烟/recover/metrics 纳入 exit 码，保留策略/进度/设置/兜底**打印但不拦**。现在 4 个专项的 `$LASTEXITCODE` 进 `$suiteFail` → 任一失败 `exit 1`。
      **反证**：`test-progress.ps1` 改 `exit 1` → 门禁 `⚠ 专项测试 FAIL` + EXITCODE 1；还原后 0。
   ③ **P1-6（真）**：`Start-Process -ArgumentList` 的数组元素不会自动加引号 → 装在含空格路径时 `-File` 会断。新增 `Quote-ExeArg`，托盘三处启动全部包裹。
   ④ **候选先截断后排序（真）**：大目录里最新文件可能不在前 N 个被漏掉。改为「枚举 → 按修改时间降序 → 取前 N」。
   ⑤ **文档漂移**：契约 §5 的「减超 7 天」与 §9 冲突 → 统一为「不按事件时间丢弃」；`ack-state`/`tray` 的「三维度」全部改「四维度」。
   ⑥ **法律项（未擅自改，等确认）**：`rules-sigma.json` 的 `author=errwatch sample` + 本地 uri 与 `source=sigma/origin=derived/license=DRL-1.1` 矛盾 —— 是「自编 Sigma 格式样例」还是「改编自 SigmaHQ」只有作者能定；两种都能合规，但不能含糊。
   详见 `tests\audit-review2-fixes-20261024.md`。
**现在机器上实际在跑什么**（2026-10-24 02:1x 核实）
- 启动项：`%APPDATA%\...\Startup\errwatch-sentinel.vbs` + `errwatch-tray.vbs`（校验过：指向当前目录）
- 进程：哨兵 **PID 6044** + 托盘 **PID 23336**（02:37 起，加载拆组后的 11 目标配置）；**主界面要重开才能看到新工具栏**（进程加载的是启动时的代码）
- 监视目标 **11 个**：CAD / Visual Studio / VS Code / JetBrains IDE / Notepad++ / PICO 串流（launcher+server）/ VRChat / Word / Excel / PowerPoint / DSH（**2026-10-24 拆组**：原来 Office 三件套和 IDE 混在一组，会让 Word 崩溃被 Excel 拖成「观测不确定」）
- 演练数据**已清理**（`sentinel-events.jsonl` / `sentinel-pending.json` / `tray-acks.jsonl` 删除）：演练时每次 COM 起停 Word 都被记了一条 `WINWORD 退出`，共 12 条（全是测试噪音，本机此前没有这两个文件）。演练结果保留在 `tests\audit-drill-word-20261024.md` 与 `tests\audit-rescue-save-20261024.md`。
- 重启方式：双击「重启看护.cmd」，或 `pwsh -File errwatch-restart.ps1`；停止：设置窗「工具」页「停止看护」，或 `pwsh -File errwatch-sentinel.ps1 -Stop`
- **计划任务没装**（非管理员：`Register-ScheduledTask` 与 `schtasks` 都「拒绝访问」）→ 走启动文件夹通道；
  notify 的定时由哨兵 `-NotifyEveryMinutes 2` 代跑
- last-check：`[OK]`
- `_dist` 已清理：只留当前包（ay）+ 上一版（ax / aw / av / au）+ 2 个送审存档（46 个包 / 18.4 MB → 6 个包 / 4.0 MB）

**下一步（按优先级）**
1. **用演练第二轮的数据看「恢复成功率」**：现在 `tray-acks.jsonl` 里没有 `rescue` 记录（演练时没在托盘里点「救援」），
   所以指标的「恢复」项仍是「量不出来」。**在托盘里对那条 Word 事件点一次「⚑ 应急救援」并走到核验**，
   指标的恢复项就有分母了（`errwatch-metrics.ps1`）。
2. **外部审计**：读 `STATE-CONTRACT.md`（§一～§十一）→ `core\ack-state.ps1` + `core\retention.ps1` +
   `core\progress.ps1` + `core\fallback.ps1` + `core\settings.ps1` → `tests\审计索引.md` 的 M46–M67

> **已完成于 2026-10-24**：`recover` 的「没装」判定（第 16 条）· 五项可观测指标口径（第 17 条）·
> 真实崩溃演练第一轮（第 18 条：发现 1.037 秒、托盘 pending=1、recover 说「刚出过问题」）·
> **真实崩溃演练第二轮（第 19 条：内容救得回 + 副本保存 `-SaveTo`）**。

**已知未做**（诚实记录 27–33 有细节）：真实崩溃样本（**已做两轮：链路通 + 内容救得回**；但「恢复成功率」还缺一次
托盘里走的救援确认）、托盘心跳 30 秒盲区、`.vbs` 可能被杀软误报、
常驻任务启动瞬间可能闪窗、兄弟实例不是进程树、保留策略没在**长期累积**的真实数据上跑过、
`collecting` 实际存活极短（取证是毫秒级，耗时取证场景还没出现）、`interrupted` 会话不补证据（无可重放上下文）、
设置窗的「救援后自检」依赖真实终端（管道里测不出）。

---

## 一、当前状态（可验证）

| 项 | 值 |
|---|---|
| 最新包 | `E:\ai\_dist\errwatch-20261023-ap.zip`（**在纯 5.1 下 verify PASS / allow**，材料一致性 19/19）；条目数 / 大小 / SHA256 **一律以 `_dist\release.json` 为准** |
| 本版修复 | ① **审计-ah 三处（新，`tests\audit-ah-20261023.md`）**：P2-1 托盘 ② 段补 `if ($decision.action -eq 'suppress')` 守卫（正常通知不再伪造 suppressed 记录，新增测试 L）；P2-2「打开主界面」改 `powershell.exe -File`（干净系统上 `.ps1` 默认关联是记事本）；P3-1 静默应用 suppressed 去重（不再每 2 秒写一行 ack）；② ACK 生命周期（launching → launched / launch-failed，失败保留待处理）；③ 通知投递与事件处理分开（attempted 非终态）；④ 全屏 UNKNOWN 保守；⑤ pending 原子写；⑥ M3c 联动；⑦ M3b 策略；⑧ M3a 托盘；⑨ 哨兵 M2/M1；⑩ 应急恢复；⑪ 轮询 10 → 2 分钟；⑫ 工具栏按钮裁切；⑬ `.cmd` 的 `-File` 双引号；⑭ 冲突检测 N1；⑮ 干净包 N3；⑯ 跨界面统一；⑰ 时间线英文分支；⑱ `Match-App` 收紧；⑲ bundle-analyze 收编；⑳ 发布链 fail-open；**㉑ 监视覆盖声明（P0-2）**：四态 + 事件 `coverage` 字段 + `sentinel-coverage.json` + 托盘菜单/气泡提示 + `-Status`；**㉒ 启动完整性（P0-3）**：pending 损坏先备份、每次同步从 `sentinel-events.jsonl` 重建投影（剔终态 ack / 超 7 天）；**㉓ 假退出丢事件（P0）**：`Get-InstanceKey` 归一 `startTime`，修掉「活着的进程被误报退出 → 真退出反被去重挡掉」；**㉔ 恢复机会（新，用户方向）**：`core\opportunity.ps1` 唯一实现（探针四态 + 新鲜度分档）· sentinel 会话登记 `opportunity.json` · recover 分档/折叠/空结果三分 · doctor 报「恢复机制开没开」· `recover.json` 升 v2（路径按真实位置重写 + mechanisms + convert）；**㉕ 启动链（P0-1，新）**：`register-watch.ps1` 双通道（计划任务优先 / 启动文件夹回退，不需要管理员）· 三任务（notify 定时 + sentinel/tray 常驻）· 哨兵单实例 Mutex · `-Status` 报生效通道 + 心跳；**㉖ 工具自身失败可见（P0，新）**：托盘读哨兵心跳（30 秒无心跳 → 变红 + 「重启哨兵」+ 覆盖声明标「停机前快照」）· `-Status` 阈值 120→30 秒 · doctor 报执行策略阻止；**㉗ 启动项指向校验（P0，新）**：`-Status` 比对启动项/任务里写的路径与当前目录，旧目录或文件失效都报错；**㉘ 兄弟实例降级（P0，新）**：同组还有实例在跑时事件标 `OBSERVATION_UNCERTAIN` + `siblingInstances`（防「启动器退出」被说成「程序崩了」）；**㉙ 兼容性三处**：notify 任务补 `-ExecutionPolicy Bypass` · `%TEMP%` 改走注册表/`%LOCALAPPDATA%\Temp`（不再依赖进程环境）· doctor 报 TEMP 重定向；**㉚ 诚实性两处**：jsonl 坏行计数进 `integrity.droppedLines` · `summaryAfterFullscreen` 真正接进决策；**㉛ notify 定时接进哨兵**：启动文件夹通道由 `-NotifyEveryMinutes 2` 代跑，两条通道都不缺定时；**㉜ 事件状态契约（结构性，新）**：三维度 `lifecycle / notify / rescue` 拆开（`core\ack-state.ps1` 唯一实现）· `launched` 不再是终态（点了救援事件仍留待处理）· 旧 JSONL 自动映射 · 事件 ID 贯通 recover（自动取会话窗口 + 核验回写 `user-confirmed`/`verified`）· 契约见 `STATE-CONTRACT.md` |
| 回归 | `run.ps1` **28/28** + 冒烟 PASS（主入口 + 5.1 Parser **47** 个 `.ps1`）· `unknown-chain` **9/9** · `env-tiers` **30/30** · lint **FAIL 0 / WARN 0** · **诊断契约 14/14** · **消费验收 9/9** · **修复授权链 8/8** · **证据包完整性 3/3** · **崩溃字段解析 7/7** · UI 列头筛选自检 **4/4** · **哨兵 16/16**（覆盖/缺口/假退出/兄弟实例/日志半行/终态语义）· **托盘 16/16**（覆盖文案 + 心跳 + 补弹开关）· **状态契约 10/10**（三维度不变式）· **应急恢复 7/7** · **恢复机会 13/13**（分档/四态/会话登记）· **启动链 7/7**（双通道构造/只读状态/互斥存在）；**以上全部在纯 5.1 下复跑通过** |
| 基线 | `baseline.json` **72 个文件**全一致 |
| 规则资产 | `core\rules.json` 28 条手写 + `core\rules-sigma.json` 6 条（Sigma 转换，why 已本地化）+ `core\events.json` **32 条**（事件 ID → 人话，全部带 `route` 三分类） |
| 目录结构 | `core\`（核心：逻辑+数据，含 `diagnose-contract.ps1` 诊断契约）、`runners\`（不同环境入口）、`tools\`（构建期工具）、`tests\`、根目录脚本 |

### 故障响应链（2026-10-23 晚：Sentinel / Tray / Recovery）

> 这一节是给「接手方」看的：四个进程各管什么、数据谁写、状态怎么流转、还剩什么没做。
> 对话里已经验证过的实现细节，都以这里为准。

| 组件 | 生命周期 | 职责 | 明确不做 |
|---|---|---|---|
| `errwatch-sentinel.ps1` | 常驻后台（可被计划任务拉起） | 进程退出/卡死检测 → 事件入队 + 取证 | 不依赖 UI、不修复、不杀进程 |
| `errwatch-tray.ps1` | 用户登录后常驻（UI） | 读 pending、通知策略、待处理菜单、点一条打开救援 | 不注入、不抢焦点、不自动重启 |
| `errwatch-recover.ps1` | 用户触发，用完退出 | 只读救援：候选文件 + 引导 + 三项核验 | 不点保存、不改名、不覆盖 |
| `errwatch.ps1` | 用户手动 | 诊断/报告/主 UI（原有职责） | 不被托盘取代 |

**事件模型**：`ProcessExit`（`verdict = crash-suspected / unknown-exit`）、`NotResponding`。
**事件状态机**：`pending → attempted/suppressed/failed/launching → launched / launch-failed / expired / acknowledged`；**终态只认 `launched` / `acknowledged` / `expired`**，`attempted` 只是「通知投递过」，事件仍在待处理菜单里。
**数据与所有权**（防数据竞争）：
- `sentinel-pending.json` —— 只由 Sentinel 写（写 `.tmp` 再 `Move` 原子替换）；**它是投影，每次同步都从 `sentinel-events.jsonl` 重建**（剔除终态 ack / 超 7 天；损坏则先备份成 `.corrupt-<时间戳>` 再重建）
- `tray-acks.jsonl` —— 只由 Tray 追加（append-only，后写覆盖前写语义）
- `sentinel-events.jsonl` —— 事实记录；pending 是**可重建的投影**
- `sentinel-coverage.json` —— 只由 Sentinel 写：监视覆盖声明 + 队列完整性结论（Tray 只读）

**覆盖声明（P0-2，2026-10-23 本轮）**：每个监视目标一个状态，回答「这段时间到底看没看到」，不是诊断结论。
| 状态 | 含义（给用户的话） | 什么时候出现 |
|---|---|---|
| `MONITORED` | 监视正常 | 进程出现后一直在看 / 当前没运行但退出已被记录 |
| `NOT_RUNNING_AT_START` | 启动时未运行 —— 之前崩过也抓不到 | 本轮监视开始前它就不在运行 |
| `MONITOR_GAP` | 监视有缺口 —— 退出时刻和原因都不确定 | 两次检查间隔 > `gapAfterSeconds`（默认 180 秒） |
| `OBSERVATION_UNCERTAIN` | 观测不确定 —— 分不清是不是同一个实例 | 取不到 StartTime / 缺口期间才出现 |

事件本身也带 `coverage` + `coverageReason`（那一次退出的观测可信度），托盘菜单与气泡据此加提示；`-Status` 输出 `coverage` / `coverageSince` / `integrity`。

**配置**：`core\sentinel.json`（监视目标：exe 名 + `gapAfterSeconds`）、`core\notify.json`（过期分钟、静默应用、摘要策略）、`core\recover.json`（恢复候选路径/步骤/核验）。

**测试**：`tests\test-sentinel.ps1`（13/13，含 P0-2/P0-3 故障注入）、`tests\test-tray.ps1`（15/15，含覆盖文案）、`tests\test-recover.ps1`（7/7）；均为合成夹具，**不宣称验证了真实 CAD/PICO 的恢复能力**。

**剩余（按用户审计优先级）**：
1. ~~**P0-2 监视覆盖声明**~~ —— ✅ 2026-10-23 完成（四态 + 事件字段 + 托盘文案 + `-Status`；`test-sentinel` G/H/M/I、`test-tray` M/N/O 看守）。**未做**：报告/UI 两个入口还没消费 coverage
2. ~~**P0-3 启动完整性**~~ —— ✅ 2026-10-23 完成（原子写 + 损坏备份 + 从 jsonl 重建投影 + 剔终态/超期；`test-sentinel` J/K 看守）。**未做**：启动时对 `sentinel-events.jsonl` 本身做行级校验（半行 JSON 目前是跳过，不是报错）
3. **P1-4 全屏判断** —— 仍是主屏尺寸比较，未覆盖多显示器/DPI/无边框
4. **P1-5 应用识别** —— 仍是 exe 名匹配，未扩到 `pathHint/publisher/role/instancePolicy`

### 启动链（2026-10-23 晚：P0-1，本轮修）

**旧版的问题**：只注册了 `errwatch-notify` 一个任务（每 2 分钟扫事件日志）。
sentinel / tray **从来没被登录拉起过** —— 整条故障响应链只存在于代码里，真实用户机器上崩了不会有任何提醒。
本机实测更糟：`Get-ScheduledTask` 里根本没有 `errwatch-notify`，说明它从未注册成功过。

**现在（`register-watch.ps1` 双通道）**：

| 通道 | 需要管理员 | 能提供 |
|---|---|---|
| 计划任务（优先） | **是** —— 本机实测 `Register-ScheduledTask` 与 `schtasks /create` 都「拒绝访问」 | 定时（notify 每 2 分钟）+ 常驻 + 崩溃自愈 3 次 + 不设时限 |
| 启动文件夹（回退） | **否**（本机已可写，现有 `mifit-sync.bat` 就在那） | 登录时静默拉起常驻项（`.vbs` + `Run ..., 0, False`，无控制台窗口） |

`-Mode auto`（默认）先试计划任务、失败自动回退并说清原因；`-Mode task` 不静默回退；`-Mode startup` 强制走启动文件夹。

**三个任务**：`errwatch-notify`（定时·跑完就退）/ `errwatch-sentinel`（常驻·不依赖 UI）/ `errwatch-tray`（常驻·需要交互桌面）。

**单实例互斥**：哨兵用命名 Mutex `Local\errwatch-sentinel-single-instance`。启动文件夹 + 手动双击 + 计划任务三条路都可能各拉一个，两个哨兵会抢写同一队列（直接破坏「sentinel 是唯一写者」）。实测：第二个实例 1 秒内退出并打印原因。

**启动文件夹通道的定时（本轮已解决）**：哨兵的启动项带 `-NotifyEveryMinutes 2`，由它每 2 分钟代跑一次 `errwatch-notify.ps1`。计划任务通道仍由任务自己定时，两条通道都不再少这一路。

**启动项指向校验（P0）**：`-Status` 读出启动项/任务里写的脚本路径，和**当前目录**比对；指向旧目录、或文件已不存在，都明确报错。否则「更新到新版本」之后跑的可能还是旧代码 —— **任务存在 ≠ 跑的是这份代码**。

### 事件状态契约（2026-10-23，结构性改造）

> **完整契约：`STATE-CONTRACT.md`（要审这一层就读它）。**
> 起因：原来 `tray-acks.jsonl` 是「一个事件一个 status」，`launched / acknowledged / expired`
> 混在同一个终态集合里，后写覆盖前写。于是「救援启动了」「用户确认了」「过期了」互相踩，
> 通知投递状态也被当成事件处理状态。

**三个维度，互不覆盖**（唯一实现：`core\ack-state.ps1`，托盘与哨兵共用）：

| 维度 | 取值 | 决定什么 |
|---|---|---|
| `lifecycle` | `open` / `acknowledged` / `expired` | **事件是否还需要处理**（唯一终态来源） |
| `notify` | `eligible` / `attempted` / `failed` / `suppressed` | 是否还要再弹；不决定事件去留 |
| `rescue` | `not-started` / `launching` / `launched` / `launch-failed` / `user-confirmed` / `verified` | 救援走到哪一步 |

**关键语义变化**：`launched` **不再是终态**。点了救援、窗口起来了，事件仍留在待处理（菜单显示 `[救援窗口已开]`），
直到用户确认内容回来了（`user-confirmed` / `verified`）或自然过期。这是本轮最重要的行为改动。

**存储**：仍是 JSONL，`{id, dimension, value, at}`，append-only，后写覆盖同维度。
**旧数据**：没有 `dimension` 的行按映射表解释（`acknowledged/expired`→lifecycle，`attempted/failed/suppressed`→notify，`launching/launched/launch-failed`→rescue），不做文件迁移。

**事件 ID 贯通**：托盘点某条事件 → `Start-Recover -EventId`；recover 用它从事件日志取那次会话的
`startTime`/`lastSeenAt`（不用猜窗口），核验完把 `rescue` 维度写回（`user-confirmed` / `verified`）。

**测试**：`tests\test-ack-state.ps1`（10 项，盯不变式：维度不互覆盖、终态不回退、旧格式映射、`launched` 非终态、通知失败仍可救援）+
`test-sentinel` K/K2（终态才剔除 / `launched` 不剔除）+ `test-tray`（菜单显示救援进展）。

### 工具自身失败必须可见（2026-10-23，本轮）

> 起因是一次实测：杀掉哨兵后，托盘仍然显示「待处理 0」+ 一份完整的 coverage。
> 那份 coverage 是哨兵死前的旧快照 —— 用户看起来「一切正常」，其实什么都没在看。
> **这比崩溃更危险的是「看起来没事」。**

| 层 | 谁看 | 做了什么 |
|---|---|---|
| 托盘 | 用户 | 菜单第一项「监视状态：正常（心跳 N 秒前）」；超过 30 秒 → 变红 + 出现「重启哨兵」；**coverage 行前缀「（停机前快照，不是现状）」**；tooltip 改成「errwatch：监视没在跑」 |
| 自检 | 手查 | `register-watch -Status` 心跳阈值从 120 秒收紧到 **30 秒**（哨兵 poll=1 秒，2 分钟太宽） |
| 诊断 | 修机器 | `doctor` 新增「脚本执行策略」段：组策略 `AllSigned/Restricted` 时报 `[阻止]` —— `-ExecutionPolicy Bypass` 覆盖不了组策略 |

实测：把心跳推到 5 分钟前 → 托盘当场显示「⚠ 没在跑（最后心跳 5 分钟前）」+「监视没有覆盖 —— 待处理与覆盖声明都是停机前的快照」。

**实测记录（2026-10-23 23:46）**：`-Mode auto` → 计划任务被拒 → 回退启动文件夹 → 写入 `errwatch-sentinel.vbs` / `errwatch-tray.vbs` → wscript 启动后 **哨兵 1 个 + 托盘 1 个**、心跳 1 秒前、监视 2 个进程；托盘自检能读到真实 coverage（`CAD 启动时未运行` / `串流/VR 观测不确定`）。

### 恢复机会（2026-10-23 晚：用户定的方向）

> 用户原话：**「崩溃发生的时间不可预测，所以真正有效的应急设计，不能依赖『提前知道它什么时候崩』。
> 不是预测故障，而是在正常工作时就持续保留恢复机会；故障发生后，再尽快把这些机会组织起来。」**
> 设计方案与依据：`tests\design-recovery-opportunity-20261023.md`（**要理解这一层就读它**）。

**把「保留」拆成两件事**（不这么拆就会变成磁盘/隐私黑洞）：
- **持续做（便宜）**：登记机会点 —— 每个会话拍 2 次只读探针（进程出现＝基线、消失＝事后）
- **故障后才做（贵）**：取内容 —— 列候选、让用户复制（`errwatch-recover.ps1`）

| 组件 | 职责 | 写什么 |
|---|---|---|
| `core\opportunity.ps1` | **唯一实现**：策略匹配 / 白名单 / 探针 / 分档 | — |
| `errwatch-sentinel.ps1` | 会话出现拍基线、消失拍事后 | `opportunity.json` |
| `errwatch-recover.ps1` | 分档展示 + 旧文件折叠 + 空结果说清三种之一 | 只读 |
| `errwatch-doctor.ps1` | **没崩的时候**就报「哪个恢复机制没开」 | 只读 |

**探针四态**（「没找到」太笼统，用户没法据此行动）：`HAS_FILES` / `EMPTY`（多半自动保存没开）/ `GENERIC_ONLY`（只有 `%TEMP%`，不算证据）/ `NO_DIR`（没装或路径表过时）。

**会话结论**（`opportunity` 字段）：`NEW_DURING_SESSION`（最值得抢救）/ `NONE_NEW` / `VANISHED` / `NONE` / `NO_MECHANISM` / `NO_BASELINE`。

**分档**（这是「能救」与「扫一堆旧垃圾吓人」的分水岭）：`IN_SESSION`（mtime ≥ 进程 StartTime−60s）/ `EARLIER_TODAY` / `STALE`（默认折叠）。只按 mtime 排序是不够的 —— 上周留下的 `.sv$` 会排第一，用户会以为那是刚画的图。

**本轮顺带修掉的真 bug（P0，丢事件级）**：`startTime` 写进 JSON 再读回来会变成 DateTime，而快照里是 ISO 字符串 —— 直接拼 `"$pid|$startTime"` 两边永不相等，于是**每轮都把还活着的进程误报成刚退出**；更糟的是那条假事件占满 5 分钟去重窗口，**真正的退出反而被挡掉**。修法：所有实例比较统一走 `Get-InstanceKey`（`ConvertTo-InstanceTime` 先归一成 ISO 再比）。回归护栏：`test-sentinel` M（进程一直活着 → 连续两次扫描都不许报退出）。

**关键决策（不要随手改回去）**：
- 不自动重启/关闭目标程序（Resurrector 那种行为与「保住现场」冲突）
- 不注入、不 Hook、不模拟输入（VAC/反作弊边界）
- pending 只读 + 独立 ack（两个进程写同一 JSON 会丢事件）
- 通知失败/被抑制不丢事件（状态可查、可补弹）

## 二、本会话（2026-10-22 下午）做了什么

1. **分级架构**：L1 正常看护 / L2 安全模式诊断 / L3 恢复环境取证；新增 `errwatch-level.ps1` 定级
2. **核心与入口分离**：规则匹配/翻译/安全模式判断全部收进 `core\analyze.ps1`；`core\` 与 `runners\` 成为物理边界
3. **L3 取证闭环**：`runners\L3-collect.cmd`（纯 cmd，WinRE 可跑）+ `errwatch-bundle-analyze.ps1`（离线分析）+ 证据包格式契约
4. **自动采集**：`runners\VentoyAutoRun.bat`（借 Ventoy 注入机制）
5. **回归语料**（审计第 4 项）：`tests\cases.jsonl` 20 → 28 条；**靠它抓出两个真缺陷**（hay 拼接破坏行首锚点、`TranslateForApp` 拼 App 名 → 所有行首锚点规则从未生效）
6. **对标社区**：抓了 Sigma/Hiren's/Medicat/SystemRescue/Ventoy/Chainsaw/Hayabusa 的实证（`tests\audit-benchmark-*.md`）
7. **Sigma 规则转换**：真实规则库 3302 条 → 转换成功 1638 条（49.6%），并发现**与我们相关的只有 63 条、真·故障类约 10 条**
8. **字段感知匹配（mapping）**：学 Chainsaw 的 `--mapping`，规则保留 `fieldConditions` → evtx 按字段精确匹配（`MatchBy=field`）
9. **补齐采集盲区**：System 日志的关键/错误 + Application 的"崩溃之外"报错（Perflib/VSS/.NET/Hang…）
10. **环境指纹**：6 维（系统/显卡/网卡/磁盘/音频/内存）→ 环境变了会警告并列出差异项；历史记录带 env，`query -CurrentEnv` 只看当前环境
11. **日志完整性**：记录号缺口 + 最长空窗（借鉴 Chainsaw 的 `analyse gaps`）
12. **可信度分档 + 怎么验**：每条结论带「高/中/弱」与"怎么推翻它"
13. **环境指纹分层（晚间第 2 次会话）**：核心层（系统/CPU/显卡/固定磁盘/内存/网卡）vs 外围层（音频端点/可移动磁盘）—— 只有核心层变化才警告，历史按核心层分段；顺带修掉 `cpu`、`memoryGB` 两个**从未取到**的维度，并过滤掉 9 类虚拟网卡与虚拟显示适配器（开热点/开 VPN/开投屏不再误报"换了硬件"）
14. **L3 本机预演（真机前必做）**：抓出并修掉 5 个会让真机实测失败的 bug —— manifest 空 `{}` 元素、`wevtutil` 被自己重定向占住（exit 32，**事件日志必然采不到**）、5MB 上限拒绝 20MB 日志、分析器把事件 ID 0 当成 Perflib、分析器不分日志（Application/1001 被贴成"蓝屏 878 次"）；详见 `tests\audit-l3-online-20261022.md`，操作卡 `tests\onsite-20261022.md`
15. **WinRE 真机实测通过（20:03）**：`shutdown /r /o` 进恢复环境，跑 `C:\ai\go.cmd`（一键脚本，正常系统里生成、本机测过）→ **17 条目**、System/Application 各 20.9 MB 原件、离线注册表 `reg-services.txt` 67.9 KB、bcdedit 成功、目标盘自动探测到 `D:`；又抓出并修掉 `where` 在 WinRE 失效导致 `disk/packages` 被误判"无权限"的 bug（改为 `if exist` 探测 + `env.txt` 记录能力）
16. **PowerShell 5.1 兼容性修复（重要）**：安全模式下没有 `pwsh`（商店版），只能靠 5.1；而项目里**所有 `.ps1` 都是无 BOM 的 UTF-8**，5.1 按 GBK 解码 → 中文与引号相邻时引号被吃掉 → 语法错误，**此前在 5.1 下从未跑通过**。新增 `tools\ensure-bom.ps1`（幂等补 BOM，21 个文件），随后 7 个关键脚本在 5.1 下全部 exit=0
17. **安全模式真机实测通过（20:19）**：L2 判定正确 —— `运行模式：**安全模式（最小）**（判据：SafeBoot\Option\OptionValue=1）`，不是模拟值；安全模式提示块、采集、日志完整性、心跳都正常。顺带修掉隐患：**安全模式下不再写 `env-last.json`**（安全模式只加载基本驱动，GPU/网卡常读不到，会把正常模式指纹覆盖掉）
18. **WinRE 第二次实测（20:53，修复验证）**：**21 条目**（上次 17）、missing 7→**3**（全是合理缺失）；`disk/diskfree/packages` 全部采到，证实 `where → if exist` 修复生效。顺带修掉 `diskpart` 脚本里 `list partition` 缺 `select disk` 的 bug（退出码 0x80070057）。⚠️ WinRE 里**没有 `vssadmin`**（`shadows` 采不到，属环境精简，不是权限问题）

### 晚间第 3 段（合规 / 时间线 / 5 轮审计整改）

19. **合规体系落地**：`LICENSE`（MIT，`Copyright (c) 2026 猫咖没有猫猫 (@zlw6639-collab)`）· `THIRD-PARTY-NOTICES.md`（Sigma DRL-1.1 / Hayabusa AGPL 未使用）· `CONTRIBUTING.md`（规则模板 + DCO）· `发布流程.md`（8 步，含权属确认）· `免责声明.md`（8 节，含"已静态验证不联网"）· `tests\审计索引.md`（M1–M19 整改映射）
20. **发布身份自动化**：`tools\make-release.ps1` → `release.json`（条目数 / SHA-256 / **逐文件哈希** / 测试绑定），审计索引不再手抄数字（此前写 66 条目、实际 71）
21. **故障时间线原型**：`errwatch-timeline.ps1`（只读、不碰现有脚本）—— 191 事件 → 21 案件；实测出「WUDFRd 驱动失败 23 次、PICO 服务崩溃 12 次」，并区分「每次开机的常规事件」与「反复失败的真故障」
22. **修 O4（真 bug）**：历史库只录前 10 条崩溃（`$histRecords` 写在打印循环里）→ 改为先遍历全部，再只打印前 10
23. **修 O1**：`errwatch-prune.ps1` 零调用 → notify 末尾自动清理（报告 >40 份触发，prune 自己备份）
24. **修 O3**：`events.json` +6 条 unknown 源（DCOM 10005 / VSS 8193 / .NET 1022·1026 / SCM 7043 / WUClient 20）+ `noise.json` 把 DCOM 进 quiet
25. **修降噪口径**：`noise.json` 收进 core（`Test-ErrwatchNoise` 唯一实现）；**此前主报告完全不读 noise**，与弹窗"一静一吵"
26. **修 events.json provider 歧义**：153/7001 补 provider；core 的按 id 兜底**不再绕过**已声明 provider 的条目
27. **修配置**：`config-fix` 多候选路径 + 自动选 pwsh / powershell 5.1（不再硬编码）
28. **补测试防线**：`run.ps1` 冒烟（主入口 + 5.1 Parser）；`doctor` 加 BOM 自检、计划任务段、核心文件 5→17
29. **审计索引**：区分「当前基线 / 历史审计 / 整改映射 / 合规状态 / 剩余风险」，明确写「本机自测，非第三方复验」
30. **五个项目署名统一**：errwatch / WriteGuard / sleepmetrics 均为 `猫咖没有猫猫 (@zlw6639-collab)`

### 第六段：产品层 5 个增量（`brainstorm-20261022.md` 落地）

31. **崩溃重复模式（方向②）**：报告 §1 加「重复模式」——同 (程序+错误码+模块) ≥3 次即标注「不是偶发」，基于**本次窗口**、不依赖历史库；本机照出 `ps_service_launcher+0xc0000409+ucrtbase.dll` ×10
32. **unknown 度量（方向①）**：心跳写 `unknown`（事件/分组双口径 + Top3）；报告 §7 显示「还没收录人话」的百分比；`query -UnknownRank` 按「次数 × 持续天数」排补录优先级（注入假记录实测 12=3×4）
33. **route 字段（方向④）**：`events.json` 32 条加 `route` 三分类（软件方 6 / 系统 18 / 自己修 8）；文案唯一实现在 `core\Get-ErrwatchRouteText`，报告与弹窗都说同一句「该找谁」。route 不进匹配文本，28 条回归未受影响
34. **反馈闭环（方向⑤）**：新增 `errwatch-feedback.ps1`（CLI 可测）+ UI「看完的感受」按钮 → `feedback.jsonl`（只存时间/选择/报告名，不联网）；报告 §7 摆出入口
35. **可执行性 lint（方向③）**：`tests\lint-human.ps1` 进 `run.ps1`（默认警告级，`-Strict` 才拦）；预演照出 19 条 `rules` 缺 ref，并顺带把 6 条 Sigma 的英文 `why` 本地化
36. **verify 与四态 lint（收尾）**：**66 条规则全部补上 `verify`**（65 已核验 / 1 待审核 / 0 缺失 / 0 无效）——64 条给普通人可执行步骤、1 条需调试器（已标能力边界）、1 条明标「无可靠自查」；**`ref` 原样保留、不与 verify 互替**；lint 升级为四态（`verify` 存在 ≠ 验证有效）；报告「怎么验」优先用规则自带 verify；同时把 10 条判断句 `do` 改成动作句（WARN 10 → **0**）
37. **盲测前置修复（测前预修，非盲测结果）**：按 `blind-test-20261022.md` 的 6 个案例预修——§1 重复组合只详列最近 1 条＋其余时间表、未收录程序如实标注、§2 英文不再裸奔＋通用兜底、§6「缺口」改「不连续」并把解释前移、§7 新增「先做这件事」、过滤「安装成功或错误状态: 0」的误报
38. **UI 可用性修复（用户实操反馈）**：列宽从 `Fill` 强制均分改为固定宽度可手动拖；加 4 项右键菜单（复制/查官方定义/生成修复/看未命中）；列表只留第一句并去掉术语括号，详情给「为什么/怎么办/怎么验/该找谁」四段，且列表与详情都按**当前规则**重算；**修掉 5.1 下列表中文乱码的 bug**（`Get-Content` 未指定编码，按 GBK 读 UTF-8）；9 条高频错误码的 `why/do` 改成「大白话＋（技术名）」

### 第七段：UI 重做 + 复测 + 打包（2026-10-23 凌晨）

39. **UI 大改**：列头（白底浅灰字→灰底深字，原来几乎看不见）、忽略列挪到最右可多选、按程序统计、时间范围筛选、搜索/只看没说明、详情区可折叠、列可手动拖宽、行高字号调整、圆角按钮 + 图标
40. **无黑框启动**：`启动报错看护.vbs`（VBScript 窗口样式 1 + `-WindowStyle Hidden`；用样式 0 会把界面也藏掉），桌面快捷方式已指向它；`启动报错看护.bat` 保留为备用
41. **查明 `ps_service_launcher`** = **PICO 串流服务 v2.2.4.4**（`C:\Program Files\Streaming Service\`，日志里 `server abnormal exit` 循环），已收进 `apps.json`；顺带修了 UI 用 `provider` 而非 `app` 认软件的 bug
42. **一键检查**：`errwatch-check.ps1`（证据→官方定义→分诊）；「生成修复」里可「复制命令」或「生成 .cmd」（可选保存位置、带说明头、GBK 编码，默认放桌面）
43. **文案改造**：9 条高频错误码改「大白话＋（技术名）」；PICO/DSH/ComfyUI 的术语都加了中文注释；「已解释/待人工」→「有说明/没说明」
44. **人工验收清单**：`tests\人工验收清单-20261023.md`（用户已点完，全部通过）
45. **WinRE 第三次复测通过**（01:30）：21 条目、`disk.txt` 分区列表完整、missing 3；发现并修掉 `diskpart` 退出码误判（对不存在的盘 list partition 报 `0x80070057`，但内容已采到）
46. **重新打包**：`errwatch-20261023-送审包.zip`（84 条目 / 302.1 KB / `BA2822EE…`），运行时文件（`ui-ignored.json`/`feedback.jsonl`/`report-*`/`一键检查-*.cmd`）全部排除
47. **M11 通知器三层状态机**（10-23 白天）：`last-check.json` 升级 v2 —— `run`（运行状态）/ `collect.watermark`（采集水位，失败不推进）/ `delivery`（投递状态 + pending）；稳定通知 ID = `app|code|年-周`（同一错误每周最多提醒一次）；投递失败进 pending，**下次即使没有新告警也会重试**；新增 `-Simulate collect-fail|deliver-fail|state-fail` 故障注入。顺带修掉「中文『找不到与指定的选择条件匹配的事件』被判成采集失败」的误报
48. **M19 补录入口**（rrwatch-source.ps1 -AddEvent）：半自动落库 —— 默认预览、-Commit 才写、写前备份到 _prune-Backup\events\、写后立刻 JSON 验证（坏了自动回滚）、同 log+id 重复检测、没给 -Verify 标 pending。过去只能手改 events.json，写坏一个逗号整库就废
49. **C 修复器执行契约**（`errwatch-fix.ps1`）：Plan（打印风险/回滚/验证）→ Validate → Confirm（`-Commit`）→ **Revalidate**（执行前复核环境没变，防 TOCTOU）→ Execute → Verify → Record；`restart-service` / `restart-process` 标 **high 且不可逆**，必须 `-IUnderstandRisk` 才执行并记审计。实测：演练不写入、`-Commit` 后 `STATUS: verified`、高风险未确认 → `refused`
50. **M12 / E 第三方规则准入门禁**（`tools\check-thirdparty-rules.ps1`）：Sigma 是 DRL-1.1，分发必须保留 author/uri —— 门禁要求文件级 `license/source/generatedAt`、每条 `author/uri/license/source`，**占位署名一律拒绝**（唯一例外：uri 指向 `tools/sigma-samples/` 的自测样例）。已接进 `tests\run.ps1` 与打包脚本（不合格直接拒绝打包）
51. **生成的 `.cmd` 从「只查」升级为「查 + 修」**（用户反馈：昨天试生成脚本，发现它只帮自己查报错）：新增 `errwatch-repair.ps1` —— 先打印规则建议与软件档案，再检查「日志过大」（默认阈值 50MB）→ 询问 y/N → 调 `errwatch-fix.ps1 -Action log-rotate`（可逆：先备份再清空）。服务停着**只提示不自动重启**（高风险不可逆）；没有可修项就明说「这个报错需要人工处理」。生成的 .cmd 末尾加这一段 + `pause`；「复制命令」也同步改成**两行**（检查 + 修复）—— 之前它只复制检查，和 .cmd 效果不一致。实测：PICO 找到两个日志、DryRun 不动、无权限时先备份失败即不改（日志原样、无 .bak 残留）
52. **外部审计第一轮整改**（2026-10-23）：审计共 6 项（F-01~F-06）。已做 **F-02**（`restart-process` 精确目标：多实例默认拒绝、`-ProcId` 精确、只允许当前会话、执行前复验 StartTime 防 PID 复用）、**F-05**（log-rotate 改 SHA-256 校验 + 占用检测 + 回滚失败明确报错）、**F-03**（Evidence/TaskId 白名单约束 + 补 AWS/GitHub/JWT/URL/连接串脱敏）。未做：F-01（判定为 P2，Windows-only 下风险≈0）、F-04（诊断结论分级，建议轻量版）、F-06（历史并发）。⚠️ 发现并修正：`-Pid` 与 PowerShell 自动变量 `$PID` 冲突，改名 `-ProcId`
53. **第三方合规：从"待核实"改为"事实表 + 门禁"**（2026-10-23，外部建议）：核验结论 —— `rules.json` 28 条全手写、`sigma-samples` 9 个是自造样例（author/date/编造 UUID 可证）、`rules-sigma.json` 6 条由样例转换、SigmaHQ 真实规则 3303 个文件在 `_tmp`（包外）、Hayabusa 未用代码/规则。据此：**THIRD-PARTY-NOTICES 重写为"当前发行包规则来源（事实核验）"打头**，加外部引用范围、未来引入条件、版本适用范围；`免责声明.md` 加"第三方资料与诊断限制"（不含绝对免责措辞）；README 加简短披露。工程化：转换器产物加 `origin=derived` + `originSource`，门禁 `origin=unknown` 拒绝入包。**教训**：重跑转换器会覆盖手工补的 `verify` 与本地化 `why`（lint 立刻 FAIL 6）——已从备份按 id 合并回来，以后重转必须做这一步
54. **建议安全性测试（第 2 批第一项）**（2026-10-23）：新增 `tests/recommendation-safety.jsonl`（10 条）+ `tests/run-safety.ps1`，测的不是"答案对不对"而是**"不许说什么"**——单条证据不能断言因果、采集失败不能说"未发现问题"、危险操作必须提醒备份、未收录必须 unknown。已接入 `tests\run.ps1`（报告，不阻塞；`-Strict` 才拦）。**首轮就抓到真缺陷**：`0x80070005` 的建议没提醒先备份注册表 → 已补。现 10/10
55. **F-04 轻量版：结论标注（第 2 批第二项）**（2026-10-23）：报告每条改为「**人话**（解释，未验证因果）」（8 处），报告开头加「怎么读这份报告」——人话是候选解释、确认因果按「怎么验」核对、证据不足给 `unknown` 不编造；UI 详情「为什么」同样标注（2 处）。**规则正文 34 条 why 未改**（避免一次大改），后续可按需把断言式措辞改成「观测→候选→验证」
56. **第 3 批：F-01 锁 + F-06 历史并发**（2026-10-23）：修复器锁改为 Windows **命名 Mutex**（内核互斥、退出自动释放、没有删锁文件竞态）；`errwatch-report.ps1` 写入历史改为 Mutex + 单次 `AppendAllText` + 写前 JSON 自检。实测：并发两个修复一个被挡；5 个并发上报 37 行 0 坏行
57. **第 3 批：发布工程**（2026-10-23）：新增 `tools\make-sbom.ps1`（SBOM-lite，逐文件哈希+许可）与 `tools\verify-package.ps1`（**解压到临时目录**独立验证：关键文件 / BOM / doctor / UI 自检 / 建议安全性）。实测：SBOM 90 组件、哈希与包一致；独立验证 5/5 PASS。**踩坑**：`Start-Process -PassThru` + 重定向时 `WaitForExit` 后 `ExitCode` 可能为 null → 必须用 `-Wait`；直接 `& pwsh -File` 在本环境会挂住
58. **诊断契约 v1 第 1 步落地**（2026-10-23，接上次 402 中断的点）：`core\diagnose-contract.ps1` —— 五态判定（collection-failed > insufficient > conflict > unknown > known，按「用户还能不能相信自己的判断」排）、confidence 与 status 分工（能不能给结论 / 给了有多确定）、nextAction（unknown 不许是 ignore）、六条不变量。**不改现有行为**（报告/UI/通知暂不消费）。验收 `tests\test-diagnosis-contract.ps1` **7/7**，已接入回归。下一步（第 2、3 步）：报告/UI 消费该契约、UI 三层

59. **诊断契约 v1 第 2 步：报告 / UI 开始消费**（2026-10-23）：五态函数不再只有测试调用 —— 现在报告 §7、心跳、UI 首页与详情全部走同一出口。
    - **报告**：`errwatch.ps1` §7 改为「五态分布 + 判定」；新增 `Invoke-EwCollect` 区分「零事件」（`Get-WinEvent` 报"找不到与选择条件匹配的事件"）与「采集失败」（其他异常）；采集失败时**置顶警示**，且绝不再写「窗口期内没有发现异常」。
    - **心跳**：`last-success.json` 新增 `diagnosis` 段（五态计数 / 采集失败源 / verdict）；`sources` 不再硬编码 `ok`。UI 首页直接读这一段 —— 同一份判定，不在 UI 里重算。
    - **UI**：标题栏内加**首页概览条**（采集完整性 / 结论分布 / 下一步，采集失败时琥珀底警示）；详情区加「结论状态 · 可信度 · 局限 · 下一步」。
    - **两个判断（需记住）**：① **绿灯门槛比设计文档 Q4 更严** —— `unknown` 也拦（有报错但没解释时显示绿色，与本页内容自相矛盾）；② **`insufficient` 只认「实质缺口」**（缺 ≥5 条 **且** 跨度 ≥10 分钟，事件在该缺口结束后 2 小时内）—— 本机 24h 实测 109 处缺口（Application 55 / System 54），满足该条件的 **0 处**；按"有缺口就降级"会把所有 known 压掉。
    - **抓到真 bug**：`$g = if (...) { ... } else { @() }` 在 PowerShell 里得到 `$null`，而 `@($null).Count` 是 **1** → 首跑 24 条结论里 23 条被误判「证据不足」。契约层改为先滤空值再计数，并新增用例 ⑧ 防回归。
    - **验收**：契约 **11/11**（新增 ⑧空缺口 ⑨适配层 ⑩汇总 ⑪绿灯门槛）+ 新增 `tests\test-diagnosis-consume.ps1` **8/8**（含 `ERRWATCH_SIMULATE_COLLECT_FAIL` 故障注入，专测红线）；5.1 下报告与 UI 实跑均 exit 0；doctor 无 FAIL（新增 `core\diagnose-contract.ps1` 核心文件检查）。
    - **未做（留第 3 步/后续）**：问题列表按 status 分组（会牵动「只看没说明的」与忽略逻辑，单独一轮）、报告正文逐条标注 status、详情完整版、规则补 `evidence`/`limitations`。

60. **未收录程序 → 读出它是谁 + 详情区限宽**（2026-10-23，用户截图反馈）：
    - **问题**：记事本崩溃时详情只写「本工具没收录 Notepad.exe，不确定它是什么」；详情正文铺满 1220px 窗口，一行 80~90 个汉字。
    - **程序身份**：`core\Get-ErrwatchProgramInfo`（报告 / UI 共用）—— 找 exe 路径（事件路径 → `PATH` → `App Paths` 注册表 → 同名运行中进程 → 常见目录浅搜 2 层），再读 `VersionInfo.FileDescription`。本机实测 `System32\notepad.exe` → **记事本**，报告与 UI 都显示「记事本（Notepad.exe，路径）」+ 版本。**不联网、不写 `apps.json`、也不算"收录规则"** —— 它只回答"这是什么软件"，不解释崩溃原因（原因仍走 rules/apps 的 known）。
    - **详情限宽**：详情区外包一层 `detailHost`，正文最长 **1000px**，窗口更宽时左右留白居中（实测留白 88/88，正文 1000），窗口变窄时留白自动收掉。
    - **回归**：`tests\run.ps1` 新增「程序身份 notepad.exe」真样本检查（本机无记事本时自动跳过）；5.1 下报告与 UI 实跑均 exit 0。

61. **修「可信度」链路 bug + 给可信度加人话**（2026-10-23，用户问「可信度是什么呢」时查出）：
    - **真 bug**：`rules.json` 的 `verifyStatus` 从来没被 `Import-CoreRulesFile` 读进核心规则对象；`TranslateForApp` 的通用分支又**重新构造**返回对象，把 `RuleId/Source/Confidence/verifyStatus` 全丢了 → 契约的 confidence 只能从 verifyStatus 推，永远算不出 → **所有结论一律「低」**。实测：Notepad `0xc0000409` 的规则明明是 `verified`，界面却显示「可信度：低」。
    - **修法**：① 读入 `verifyStatus`；② `Translate` 带出；③ `TranslateForApp` 两处返回不再丢字段；④ 契约 confidence 改为「`verified` → high；否则按依据档位 高/中/弱 → high/medium/low；都没有 → low」；⑤ 系统 API 兜底（FormatMessage）补 `Confidence='中'`（官方消息依据硬，不该算"低"）。
    - **加人话**：新增 `Get-ErrwatchConfidenceText` —— 「高（解释依据硬：事件 ID 或具体错误码，且规则已核验）」「中（依据具体错误码或手写经验，但这条还没被核验过）」「低（只凭程序名/宽泛文本，最容易误判）」。报告 §1 与 UI 详情同一份措辞。
    - **现状**：Notepad → 高；PICO（`apps.json` 手写 known，无 `verifyStatus`）→ 中。
    - **回归**：契约 **13/13**（新增 ⑫可信度分级 / ⑬四档人话）；`tests\run.ps1` 新增「可信度链路 0xc0000409」—— 锁住 `verifyStatus` 从 `rules.json` 一路传到调用方，再丢就红；5.1 下报告/UI 实跑 exit 0。

62. **按可信度分级标注：不再每条都要求人核对**（2026-10-23，用户反馈「未验证因果……每个都的话」）：
    - **问题**：F-04 的「（解释，未验证因果）」挂在每条上，等于每条都要求用户自己核对一遍；而多数条目依据其实很硬（具体错误码 + 已核验）。
    - **做法**：复用第 61 条修好的可信度做分级 —— `high` 不挂后缀、且「怎么验」改成「**想自查时看**」（明确是可选动作）；`medium`/`low` 保留「（解释，未验证因果）」与「怎么验」；未收录/证据不足/矛盾照旧要求核对。
    - **报告顶部「怎么读这份报告」重写**：高 = 直接按建议做、不用自己核对；中 = 先做、想更确定再验；低 / 证据不足 / 结论矛盾 / 未收录 = **这几条才需要核对**。
    - **覆盖**：§1 崩溃、§2 安装、§4 系统组、§5 应用组、UI 详情全部改；§2/§4/§5 顺带补上「可信度」行（原来只有 §1 有），否则顶部说法对不上。
    - **实测**（本机 24h 报告）：11 条「人话」里只有 **1 条**仍挂「未验证因果」（PICO 那条，中可信度）。
    - **回归**：契约 **14/14**（新增 ⑭分级标注）；消费验收 **9/9**（新增「按可信度分级标注」—— 有高可信度条目时，不允许全部人话都挂后缀）。

63. **列头筛选：点「程序 / 错误码 / 模块 / 状态 / 时间」列头出下拉**（2026-10-23，用户需求，含一次返工）：
    - **需求**：想「只看 409 这种错误码」「只看某个模块」，后补充「程序和时间也要」。
    - **初版做错**：先加在工具栏（三个下拉 + 工具栏 52→92 两行）。用户截图指出「**不是这种，是在这里（列头）加**」→ 已**回退**工具栏改动（高度回到 52、删掉 `New-FilterCombo`/`Update-FilterOptions`），改为列头筛选。
    - **做法**：点列头 → 弹菜单：该列去重值（带计数）+「全部（清除筛选）」+「↕ 按此列排序」。「时间」列特殊：复用时间范围（全部时间 / 今天 / 3 天 / 7 天 / 30 天），不逐分钟列。多列筛选可叠加。
    - **状态栏**：显示当前筛选（如 `筛选 错误码=0xc0000409`），避免用户困惑「为什么只剩几条」。
    - **自检**：`-Check` 新增「列头筛选自检」—— 程序 / 错误码 / 模块 / 状态 四列各选第一个真实值，断言 `行数 == 应有行数` 且无一行不匹配（基准扣掉被忽略的 4 条）。本机 **4/4 PASS**（5.1 下同）。
    - **排序没丢**：原「点列头即排序」变成菜单最后一项。

64. **首页概览拆两行 + 标题区压缩 + 打包发布 -n**（2026-10-23，用户三轮视觉反馈 + 「打包审计」）：
    - **概览条**：原来「结论分布 + 下一步」拼一行、铺满窗口 → 拆两行。第一行 `本次扫描 24 条 · 可给结论 23 · 无法给结论 1（规则未覆盖 1）`；第二行 `下一步：按建议处理；想更确定就看每条下面的「怎么验」`。「下一步」不再是 verdict 的长句（范围声明），改为按 blockers 生成**可照做的一句话**。
    - **标题区压缩**（用户：`上下两边太宽` / `采集和报错看护重叠`）：根因是**手写坐标** —— 17pt 标题实际 35px 高，副标题写死 y=42 正好压在标题底边。现在副标题位置 = `标题底 + 2`、面板高度 = `副标题底 + 概览高`，**不写死数字**（DPI/字体变了也不会叠或留空）。面板 140 → **109**、概览 66 → **46**，副标题与概览之间 0 间隙（上下行连排）。
    - **`-Check` 新增「标题区」硬检查**：输出标题/副标题/概览的垂直区间 + `重叠=True/False`，回归时能直接抓到重叠。
    - **工具栏按钮**（用户先说"太宽"，后澄清不是按钮）：仍保留按文字自适应（刷新 86px / 生成修复 119 / 按程序统计 114 / 更多 84），不占横向空间。
    - **打包 `errwatch-20261023-n.zip`**：**97 条目 / 394.3 KB**，SHA `9587A1AA…`；独立验证 **PASS / releaseGate allow**（解压 / 关键文件 / BOM / doctor / UI 自检 / 建议安全性 6 项全 PASS）。
    - **门禁顺序**（照 `发布流程.md`）：ensure-bom → run（28/28 + 契约 14/14 + 消费 9/9）→ unknown-chain（9/9）→ env-tiers（30/30）→ doctor（0 FAIL）→ baseline（57/57）→ pack → make-release（带 `-TestRecord`）→ make-sbom → verify-package。
    - **审计索引**已更新（当前包 -n、校验文件名、独立验证行）；`release.json` 仍是唯一权威。**教训**：`make-release.ps1 -TestRecord` 要传 `tests\last-run.json` 的**路径**，不传则 `testRecord: null`（首次打 -m 时踩到）。

65. **发行件身份闭环（外部审计 P0：SBOM 与 ZIP 不是同一份构建产物）**（2026-10-23）：
    - **先核事实**：审计方看到的 SBOM 是 340,536 B / 90 组件 / `12BEAEAA…` —— 那是 `errwatch-20261023-送审包.sbom.json`；本机 `-n` 的 SBOM 是 403,742 B / 97 组件 / `9587A1AA…`，与 `-n` 本身一致。**但批评成立**：四份材料之间没有绑定，拿错谁也发现不了。
    - **新增 `tools\check-release-identity.ps1`**（四层绑定，**19 项**）：ZIP ↔ release（file/bytes/sha/条目数/逐文件哈希）、release ↔ SBOM（文件哈希 + SBOM 声明的 ZIP 身份）、SBOM ↔ ZIP（组件数 + 逐组件哈希 + path 集合）、release ↔ verify（verify 记录的 zipSha256 + verdict + gate）、`sourceSnapshot`（防"包对了但源码不是这版"）。不一致 → exit 1。
    - **`make-release.ps1` 升到 schemaVersion 2**：`sbom` / `verification` / `sourceSnapshot` / `testRecord.beforePackaging` 全部绑进 `release.json`；**SBOM 或 verify 声明的 ZIP 不是这个包就 throw**（错配在生成阶段就死）。
    - **流程固定**（已写进 `发布流程.md` §3/§6）：pack → make-sbom → make-release（第一遍）→ verify-package → make-release（第二遍，绑验证）→ check-release-identity（19/19）。
    - **发布 `errwatch-20261023-o.zip`**：**98 条目 / 400 KB** / SHA `82B8B365…`；verify **PASS / allow**；identity **19/19 PASS**（5.1 下同）；基线 58 文件。
    - **审计方其余意见的处理**：① 「五态是分类不是可信度」—— 已记录（`confidence/limitations/nextAction` 本就分开，但要在文档明写"known ≠ 可信"，列入待办）；② INDETERMINATE 已有；③ **P0 修复授权链审计、P1 真人盲测、P1 WinRE 恶劣环境未做**，已进 §三 待办。
    - **人工验收清单是空的**（只有表头、无 ✓/✗）—— 审计这条属实；HANDOFF 第 44 条"用户已点完"只是口头，没有留痕。已列为待办。

66. **修复授权链 P0/P1 整改（外部审计点名的那条）**（2026-10-23）：
    - **P0-1 STOP 只覆盖 1/5 写动作**：新增 `Test-StopRequested`（不抛异常版），5 个写动作全部埋点 —— `config-fix`（执行前）、`rescan-devices`（扫描前）、`restart-service`（停止前 + 启动前；**已停时先启动回去再报 aborted**，不让服务停在半路）、`restart-process`（逐个目标之间，并报告"已结束几个、还剩几个没动"）。不再出现"承诺急停但只有 log-rotate 实现"。
    - **P1-1 审计不记终态**：`Done()` / `Fail()` 都写审计（`verified/partial/verify-failed/rolled-back/aborted/refused`）；新增 `ERRWATCH_AUDIT_PATH` 供测试重定向，不污染真实 `fix-audit.jsonl`。
    - **P1-2 UI 命令未转义**：新增 `ConvertTo-ErrwatchPsArg`（**单引号** + `''` 双写；单引号内 PS 不展开 `$`）。`.cmd` 无法可靠转义（cmd 只认双引号）→ `Test-ErrwatchCmdUnsafe` 含 `" % & | < > ^ 换行` 时**拒绝生成**并提示改用「复制命令」（fail closed）。
    - **测试**：新增 `tests\test-fixauth.ps1` **8/8**（转义单测 / .cmd 危险字符 / 审计终态**动态实测** / STOP 覆盖静态断言 / UI 拼接静态断言 / 风险文案唯一来源 / rescan 复验 / force-override Critical），已接进 `run.ps1`。
    - **P2 也一起收尾了**（2026-10-23 晚）：P2-1 契约移到 `core\action-contract.ps1`（唯一实现，repair 不再硬编码「低」）；P2-2 「修复方案」窗口加边界说明（只做查+生成方案，能自动处理的只有日志轮转）；P2-3 `rescan-devices` 复验不再空转（检查 pnputil）；P2-4 `force-override` 审计改 `-Critical`。
    - **「known ≠ 可信」已写进 `定位.md`** §二·五（五态是分类不是可信度；known 不保证适用范围/时效/关联/证据完整）。
    - **仍未做**：STOP 与命令注入的**动态真机验证**（需真杀进程/伪造事件，风险高）；真人盲测、WinRE 恶劣环境（需你本人）。
    - **发布**：`errwatch-20261023-p.zip`（99 条目 / 407.5 KB），verify PASS / allow，材料一致性 **19/19**。

67. **WinRE 恶劣环境：把能「注入复现」的部分做成自动测试**（2026-10-23，回应「小伙伴做不了 WinRE」）：
    - **真问题**：`runners\L3-collect.cmd` 过去无论缺多少项，最后都打印「采集完成」并 `exit /b 0` —— **部分成功被显示成完整成功**；分析器也没读 `target.detected`。
    - **采集器**：结束前统计 `miss.tmp` 行数，打印「采集不完整：有 N 项没取到」；`TGT_OK!=1` 时打印「目标系统盘没读到（TARGET=x）—— 这次采到的可能不是目标系统」。**实测**（本机非管理员，真实跑）：12 项里缺 8 项 → 正确警告。
    - **分析器**：新增**置顶三态** —— 🔴 `target.detected=false`（错盘/BitLocker/只读/盘符重排）→「不能当作目标系统的取证结论」；⚠ 有缺失项 →「不能说系统没有问题」；✅ 完整采集 →「只说明采集没缺东西，不代表系统健康」。
    - **测试**：新增 `tests\test-bundle-integrity.ps1` **3/3**（注入三个假证据包），已接进 `run.ps1`；另用**真实非管理员采集**做了端到端（缺 8 项 → 报告置顶警告）。
    - **仍未做**：真机 WinRE（盘符重排 / BitLocker / 只读 / 断电）—— 需真重启。操作卡：`runners\L3-操作卡.md`；给「什么都不会」的人不要用这个。

68. **给「不熟电脑」的人加一个启动器**（2026-10-23，用户反馈：小伙伴连 exe 都不太会打开）：
    - **根目录新增两个文件**（随正式包一起分发）：
      - `① 双击打开报错看护.bat`（GBK）：双击即启动（优先走 `wscript.exe` 调 `启动报错看护.vbs`，无黑框；找不到就回退 `powershell.exe -File errwatch-ui.ps1`）；找不到 `errwatch-ui.ps1` 时打印「你是'全部解压缩'出来的文件夹，而不是双击压缩包」。
      - `★ 先看我.txt`（UTF-8 BOM）：三步说明（右键解压 → 打开文件夹 → 双击 `①`），加一句「只读、不改电脑、不联网」，以及「双击没反应就右键管理员运行或截图求助」。
    - **验证**：解压到临时目录后，根目录有 ①/★/启动 vbs；5.1 下 doctor **0 FAIL**、UI `-Check` 初始化 OK。
    - **发布**：`errwatch-20261023-s.zip`（104 条目 / 419.9 KB），verify PASS / allow，材料一致性 19/19。

69. **纯 5.1 环境下的真缺陷（外部审计复现，我此前漏测）**（2026-10-23）：
    - **根因**：我一直用 `pwsh 7` 跑门禁，从没在「只有 5.1」的机器上跑过 `run.ps1` / `baseline` / `doctor` / `verify`。而 5.1 的 `Get-Content` 默认按 GBK 解码 → UTF-8 的 `.json/.jsonl` 被读坏。
    - **P0-1 数据文件编码（14 处）**：读 json/jsonl 没带 `-Encoding UTF8` —— baseline / query / prune / notify / fix / feedback / evidence / doctor×3 / report / errwatch×2 / tests·run。全部补上。
    - **P0-2 崩溃解析只认中文**：新增 `core\Get-ErrwatchCrashFields`（**中英双语**：`出错应用程序名称`/`Faulting application name`、`异常代码`/`Exception code`、`出错模块名称`/`Faulting module name`），`errwatch.ps1` / `notify` / `evidence` / `timeline` 四处改用它。英文系统上报告不再显示「Application Error」+ 空错误码。
    - **P1 测试写死 pwsh（7 处）**：`& pwsh` 改为 `$pwshExe` 回退（无 pwsh 7 用 `powershell.exe`）；`test-verify-package.ps1` 不再要求必须有 pwsh。
    - **P1 验证器在 5.1 下解压失败**：`verify-package.ps1` 缺 `Add-Type System.IO.Compression.FileSystem` → 5.1 下 `[ZipFile]` 类型找不到 → 解压 ERROR → `releaseGate=deny`。已补。
    - **P2 `pack.ps1` 默认 `OutDir` 写死 `E:\ai\_dist`** → 改为「项目根上级 `_dist`」，可用 `-OutDir` 覆盖。
    - **验证**（**纯 5.1**）：baseline 62/62 一致 · doctor 0 FAIL · run.ps1 28/28 + 契约 14/14 + 消费 9/9 + 修复授权链 8/8 + 证据包 3/3 + 崩溃解析 4/4（当时 4 个用例；后扩至 7 个）· unknown 9/9 · env-tiers 30/30 · **verify-package PASS / allow**。
    - **发布**：`errwatch-20261023-u.zip`（105 条目 / 423.3 KB），材料一致性 19/19。
    - **教训**：把「5.1 兼容」当已验证之前，必须在**没有 pwsh 的解释器**下跑一遍门禁。之前只跑了语法解析 + 主报告，那是半个验证。

70. **第二轮自找 bug（中英双语遗留 + 一处自己引入的坑）**（2026-10-23）：
    - **MSI 安装失败过滤只认中文**：英文系统的 `Installation success or error status: 0` 不含中文 → 成功的安装被误报成失败。抽成 `core\Test-ErrwatchMsiFailure`（中英双语）+ 测试。
    - **时间线关联对象提取只认中文**：219 / 7031 / 7000 / 7001 / 7011 / 1002 / 7045 七个事件 ID 在英文系统全退化。每个都加英文分支（标准 Windows 事件模板）。
    - **notify 弹窗「该找谁」缺软件名**：`Get-ErrwatchRouteText` 只传了 Route、没传 App/Code → 弹窗和通知报告里变成笼统的「这个软件」。补传两处。
    - **evidence 调 core 函数却没 dot-source core**（本轮自己引入）：上一轮把 evidence 的中文正则换成 `Get-ErrwatchCrashFields`，但 evidence 是「独立入口」没加载 core → 函数不存在，`SilentlyContinue` 吞掉错误 → 所有崩溃事件的 code/mod 显示空。已加 dot-source + 防回归测试⑦。
    - **测试**：崩溃字段解析 **7/7**（新增 ⑤ MsiInstaller / ⑥ 时间线英文分支 / ⑦ core 加载断言）。5.1 全量 run.ps1 EXIT=0。

71. **A1 结案：Sigma 规则来源与许可（2026-10-24 18:2x，上一轮留给用户的唯一「只有你能定」项）**：
    - **判决**：自编样例（不是 SigmaHQ 衍生）。证据链 —— 9 个 `sigma-samples/*.yml` 全部 `author: errwatch sample` / `date: 2026-10-22` / 编造规律 UUID（`1a111111-1111-…`）/ `references` 指向 Microsoft Learn；其中两份标题就叫 **"Complex Condition Should Be Skipped"**、**"Unsupported Modifier Should Be Skipped"** —— 那是为测转换器边界造的样本，SigmaHQ 不会发布这种东西。项目自身文档（免责声明 / 发布清单 / 送审说明 / 本文件 §53）口径也一致。
    - **根因不是漏标**：`tools\sigma-convert.ps1` 里 `uri` 按路径判、`license/source/origin` 写死成 `DRL-1.1/sigma/derived` —— 同一份产物同时声称「作者是 errwatch sample」和「衍生自 SigmaHQ」。
    - **修法（消口径分裂）**：单一判据 `$isSigmaHqRule = $rel -match '^rules/'` 驱动 `uri/license/source/origin` 四字段；产物级 `license/note/schema`（`errwatch-sigma-converted-rules`）同步。落到 `rules-sigma.json`：6 条 `origin=original / license=MIT / source=errwatch`。
    - **门禁双向自洽**（`tools\check-thirdparty-rules.ps1`）：`original` 标 DRL → 拒绝；`derived` 标 MIT → 拒绝；文件级声明与全部条目矛盾 → 拒绝。**踩坑**：第一版全文搜 "DRL"，把自编声明里的「不适用 DRL-1.1」当成声称 → 改判 license **头部标识**。
    - **新增 `tools\merge-sigma-rules.ps1`**：重转后按 `sigmaId` 回填 `verify/verifyStatus/why/do`（§53 的教训就此工具化，不再手抄）；实测 6 条 / 24 字段全回填。
    - **新增 `tests\test-sigma-source.ps1`（10 条）**：正例 + 三向反例 + 转换器两条分支 + 合并回填；已接进 `run.ps1` **参与失败判定**。
    - **顺手修 `run.ps1` 漏判**：`$tpOk` 算了却没进 exit（「门禁只拦部分专项」的复发面），现已纳入；其余只打印不拦的专项记在 `ISSUES.md` B12。
    - **`tools\make-sbom.ps1`**：SBOM 许可改按包内 `origin` 判定，不再「文件名 → DRL-1.1」硬映射。
    - **实测**：准入 PASS；三向矛盾各自 exit 1；`rules/` 布局自动升 DRL-1.1 + GitHub uri；`test-sigma-source` **10/10**；`run.ps1` **EXIT=0**；反证（把一条 `original` 标成 DRL → 整轮门禁 **EXIT=1**）。详见 `tests\audit-sigma-license-20261024.md`。

72. **托盘菜单修三处（2026-10-24 18:2x，用户真机反馈：点不动、没有「不需要处理」）**：
    - **① 动作缺失（最严重）**：待处理项过去**左键直接启动应急救援**，菜单里根本没有「不需要处理」—— 用户想「这条不用管」时无处可点。现在每条待处理项带子菜单：`⚑ 应急救援（找自动保存副本）` / `✓ 不需要处理（从待处理里移除）`。后者写 `lifecycle=acknowledged`（契约里唯一的「用户明确说不用管」），**只移出待处理、事件记录保留**，且不伪造 notify/rescue 动作痕迹。
    - **② 点击有延时**：主循环 `Start-Sleep -Milliseconds 2000` 让 WinForms 消息泵**停摆 2 秒** —— 点击/悬停要等下一轮才被处理。改成 20×100ms 分片，每片 `Application.DoEvents()`，轮询节奏不变。
    - **③ 没有选中效果**：菜单**打开期间**每 2 秒 `DropDownItems.Clear()` + 重建，销毁正在悬停的项 → 无高亮、点了像没反应。改为 `$menu.Visible` 时跳过重建，关闭后下一轮补上。
    - **测试**：`test-tray` 16 → **17/17**（新增 Q：每条待处理必须同时有「应急救援」与「不需要处理」，少一个就 FAIL；自检新增 `pendingMenuActions` 字段供断言）。
    - **实测**：重启托盘后真实数据自检 `pendingMenuItems=2`、每组动作 `⚑ 应急救援 / ✓ 不需要处理`。

73. **B 类清账（2026-10-24 18:4x，用户：「继续修复啦」）—— 修掉 5 条，B 类从 14 条降到 9 条**：
    - **B13 跨休眠毁指标（最值钱的一条，被自己的机器实证）**：一次 14.7 小时休眠把 `53011315ms` 写进「发现延迟」样本，p50/p95 从此失真；醒来后进程消失还被写成「启动时间取不到」。**根因是判定顺序**：`startTime 缺失` 排在 `hadGap` 前面，而服务型进程根本没有启动时间 → 盲区事实被吃掉。修法：① 顺序改为 **盲区 > 启动时间 > 兄弟实例**，理由明写「这段空档不计入发现延迟」；② 事件新增 `latencySource = observed / after-gap`；③ 盲区样本单独进 `latencyGapMs` / `latencyGapCount`，**不进 p50/p95**；④ `core\metrics.ps1` 同样排除并报 `detect.gapSamples`；⑤ **数据自愈**：`Save-Status` 把历史样本里 ≥5 分钟的搬到 gap 通道 —— 本机重启后实测 `53011315` 已迁移，p50 回到 **1104ms**。
    - **B14 哨兵偶发「当文件已存在时」**：① 可定位 —— `catch` 补 `文件:行号 + 栈顶帧`；② 可终止 —— 五处状态写盘（哨兵 pending/coverage/opportunity + retention events/acks）统一走 `Publish-StateFile` / `Publish-RetentionFile`（失败先删目标再移一次）。PS 5.1 覆盖已存在文件的偶发失败不再打断一轮 tick。
    - **B1 doctor 落后于架构**：重写为**响应链**一段 —— 三个通道 ×（计划任务 + 启动文件夹回退）+ **哨兵心跳**（>5 分钟判停）。实跑立刻抓到一个自己造的误报：启动文件夹通道下 notify 由哨兵代跑，不该报「缺失」，已按此分支。`tests\test-doctor.ps1` 8 条接进门禁。
    - **B2 扫描吞错**：枚举加 `-ErrorVariable +scanErrs`，区分 `PermissionDenied`；探针新增 `scanErrors` / `deniedDirs`；recover 人话里加「⚠ 有 N 个位置没有读取权限 —— 那里可能有文件名没被算进来，这不是『确实没有』」。
    - **B3 复制不可信**：`Copy-Item` 到 `.part` → 比长度 →（≤32MB）比 SHA256 → 改名发布；失败删 `.part`，`copied` 带 `verified` / `hashChecked`。
    - **测试**：`test-sentinel` **19/19**（I 扩展 + R 静态守「不许裸 Move-Item」）· `test-metrics` **7/7**（新增 I）· `test-recover` **17/17**（新增 P/Q）· `test-doctor` **8/8**（新）· `test-tray` **17/17**；`run.ps1` **EXIT=0**。

74. **托盘/界面四连（2026-10-24 18:5x，用户真机截图反馈）**：
    - **① 菜单没状态**（用户原话：「应该是状态 —— 没打开时出现打开，已打开可以选择关闭、杀掉」）：主界面启动写 `ui.pid`，托盘三重校验（文件在 / PID 活着 / 命令行含 `errwatch-ui.ps1`，防 PID 复用杀错）→ 已打开时菜单显示「关闭主界面（PID N）」，点了就关。实测：启动后 `ui.pid=2176` → 托盘自检 `uiOpenPid=2176`；关掉回落 0。
    - **② 打开主界面弹大黑框**：根因是托盘新建 `powershell.exe` 进程 → 带出控制台。`-WindowStyle Hidden` 不可用 —— 它会把进程第一个窗口（WinForms 主窗体）一起藏掉（§15 已踩过）。改为**界面自己**用 `ShowWindow(GetConsoleWindow(), 0)` 精确隐藏控制台，托盘传 `-HideConsole`；用户自己从命令行启动时不传，控制台照常。
    - **②b 修完仍「还是黑框」——真因是旧进程残留（重要教训）**：用户复测时黑框还在，枚举窗口才发现真相 —— 一个 **17:59 就在跑的旧版界面进程（PID 5416）**没退，而它没有隐藏控制台的代码，那个黑框就是它的窗口。新界面起来了、旧的还在，用户看到「黑框还在」却找不到是谁的。修法：**界面单实例化** —— 新实例启动时按命令行精确匹配，关掉同脚本的其它实例（`-Check` 自检不参与，不能因为跑自检关掉用户正开着的界面）。清掉旧进程后实测：PID 9780 的可见窗口**只有** `errwatch · 报错看护`，没有任何控制台窗口，也没有 conhost。教训记在 D 类：**改完 UI 类问题要连旧进程一起清**，光看代码通过不代表用户屏幕上对。
    - **③ 看不到「原因」**（用户：「出现了崩溃但是没有出现问题原因」）：原因其实在详情区，但排在「结论状态/可信度/下一步」之后，而详情区有滚动条 —— 等于看不到。顺序改为 **原因 → 结论状态/可信度/下一步 → 怎么办/怎么验/该找谁**。
    - **④ 「和托盘没同步」的错觉**：主界面那张表是**全时段崩溃记录**（28 条，含已处理/已过期），托盘只列还要你处理的（0 条）。数字不同是设计如此，但界面不解释就等于 bug。状态栏补一句「托盘里待处理 N 条（在那里处理）」。
    - **测试**：`test-tray` 17 → **19/19**（R：uiOpenPid 字段 + 「关闭主界面」分支 + `-HideConsole` + UI 侧 `GetConsoleWindow`/`ui.pid`；S：按源码位置断言「原因排在结论状态之前」）。

75. **B 类再清四条 + CAD 演练就位（2026-10-24 19:0x，用户：「继续优化啦 我下载cad」）**：
    - **B4 快照不一致（核心：复制的必须是你点头的那批）**：过去 UI 是「展示扫一次、探测候选扫一次、备份再扫第三次」—— 三次之间 CAD/Office 可能自己清理了临时文件，于是复制的不是用户看到的那批。现在：`errwatch-recover.ps1` 新增 `-SnapshotOut`（人话照旧打印、结构化结果同时落盘）与 `-OnlyPathFile`（备份只认清单），UI **只扫一次**、用快照判断有没有候选、把清单写文件传给备份；清单里的文件若已消失会明说「有 N 个候选在你确认之后不在了」。`test-recover` 新增 R（清单外不碰 + 消失要提示），**18/18**。
    - **B8 降噪窗口写死**：`settings.json` 新增 `sentinel.quietHours`（默认 24，允许 1–168，越界忽略）；哨兵启动时读。`test-settings` 新增 H（含源码守卫：不许再有 `TotalHours -le 24`），**8/8**。
    - **B11 含空格路径 —— 实测通过（不是静态改）**：整个项目复制到 `E:\ai\_tools\errwatch 空格 test\`（1.96 MB / 509 文件），在该路径下 UI `-Check` OK、托盘 `-Check` iconOk=True、doctor exit 0、`restart -DryRun` 路径正确、并用托盘的启动方式端到端拉起界面（`ui.pid=19872`、进程存活）。**顺带挖出真缺陷**：界面被强杀时 `ui.pid` 残留（实测 9780 被关后文件仍在）→ 托盘 `Get-UiProcessId` 现在会自愈删除。
    - **A12 CAD 演练手册**：`tests\drill-cad-20261024.md` —— 装好后 30 秒确认识别 → SAVETIME=1、画内容不保存、任务管理器结束进程 → 读四项指标（发现延迟 / verdict / coverage / 是否 after-gap）→ 救援 → **手工验证 `.sv$ → .dwg` 能不能打开** → 回填。已写明三种结果各自要改哪里（尤其「打不开」要把 CAD 自带图形恢复管理器提到第一步）。

76. **B 类清到只剩 2 条 + 浩辰CAD 现场适配（2026-10-24 19:4x，用户去洗澡，自主推进）**：
    - **浩辰CAD（C1 的现实版）**：用户装的不是 AutoCAD 而是**浩辰CAD 2027**（`D:\cad\浩辰CAD 2027\gcad.exe`，进程名 `gcad`）。`recover.json` 原来只认 `acad/autocad/acadlt/dwg` + `acad.exe` 路径 → **完全看不见浩辰**。现场实测：`SAVEFILEPATH` 在 `HKCU\Software\Gstarsoft\GstarCAD\R27\zh-CN\Profiles\<<未命名配置>>\Config` = `%LOCALAPPDATA%\Temp`；**`SAVETIME` 没有可靠注册表值**（所以只做行为证据）。已加 `recover.json` 的 `gstarcad` 条目 + `apps.json` 条目；`errwatch-recover -App gcad` 现在能认出「浩辰CAD 自动保存」。
    - **顺带消掉一个误报**：「只有通用临时目录 → 路径表可能过时」对浩辰是错的（它的自动保存**本来就在** %LOCALAPPDATA%\Temp）。新增 `autosaveInGenericDir` 字段（带实测依据），doctor / recover 改口径为「它的自动保存就在通用临时目录里（已实测确认）」；没有依据时仍说「可能换了路径」——`test-recover` 新增 S 双向断言（含反证）。
    - **B7 分组粒度**：JetBrains 6 个产品拆成 6 个独立组（杀 PyCharm 时 IDEA 在跑不再降级）；**同类一并修**：AutoCAD 完整版与 LT 拆开。`test-sentinel` 新增 T（不许混组、**拆组不许漏目标**），**20/20**。
    - **B6 ACKS 竞争窗口**：加命名 Mutex `Local\errwatch-acks-write`。保留策略整段持锁（拿不到就跳过本轮并说明）；托盘 `Add-Ack` 用同一把锁（拿不到也照写 —— 宁可晚清，不能丢用户操作）。`tests\test-lock.ps1` **3/3**：**必须用另一个进程持锁**才测得出（Mutex 同线程可重入，本机第一次写测试就踩了这个坑）。已接进 `run.ps1`。
    - **B5 语义**：`verified` 的展示从「已核验」改为**「你逐项核对过」**，`user-confirmed` → 「你自己确认救回了」——来源是用户自检，不能读成机器核验。
    - **B10 / B12 门禁**：设置窗 `-Check` 首次纳入自动验证（`test-settings` I，9/9）；`run.ps1` 里 9 个「只打印不拦」的测试类专项全部纳入 `$testFail`（lint 仍只报告）。
    - **状态**：`run.ps1` **EXIT=0**，包 `166 条目 / 751.7 KB / SHA 5E2770723AB9…`，verify PASS，一致性 19/19，基线 98/98。B 类剩 2 条（B9 coverage 回填、B13 重复路径去重），另加一条新发现的 B14（electron 组可能过宽）。

77. **浩辰CAD 真实崩溃演练（2026-10-24 20:07）+ 现场修两个缺口 + 一个新 bug**：
    - **演练全链路通**：用户把 `SAVETIME` 设成 1 分钟 → 20:07:19 自动保存写出 `Drawing1_1_…_4417.sv$`（40.7 KB）→ 20:07:42.066 强杀 `gcad.exe` → **1052 ms 发现**（`unknown-exit` / `MONITORED` / `latencySource=observed`）→ 救援 1 候选、复制后**原件与副本 SHA256 一致** → **`.sv$` 头是 `AC1032`（DWG 2018 容器）** → 用户打开副本确认内容都在。
    - **现场抓到的第一个缺口**：`gcad` **不在** `core\sentinel.json` 的监视目标里 → 崩溃了没人报（比"救不回来"更严重）。已加独立组 `[gcad, gstarcad]`。
    - **现场抓到的第二个缺口**：`recover.json` 只认 AutoCAD → 找不到浩辰的恢复文件。已加 `gstarcad` 条目；`howToEnable` 按实测改写为「命令行输 `SAVETIME` → 1（1 分钟）」。
    - **顺带消一个误报**：浩辰的自动保存**本来就在** `%LOCALAPPDATA%\Temp`，不该说「路径表可能过时」。新增 `autosaveInGenericDir`（带实测依据），doctor / recover 改口径；无依据时仍提示。`test-recover` S 双向断言。
    - **新 bug（A19）**：20:09 重启哨兵后又造了**第二条**同一次退出的记录 → 用户 ack 了第一条，第二条仍挂待处理。根因：去重只靠内存 `recent` 的 5 分钟窗口，重启边界不可靠。改为**持久化判据**（pending 里已有同 `app + pid` 的未终态事件就不再新增）。`test-sentinel` U，**21/21**。
    - **测试夹具踩坑**：`test-recover` 的 S 用例原来拿 `%TEMP%` 当「空的通用目录」，而演练真在 `%TEMP%` 留了 `.sv$` → 门禁单跑绿、真实环境跑红。改成**空的自建目录**作夹具（用例不该依赖真实目录内容）。
    - **诊断过程自己的 bug（A21）**：`@(ConvertFrom-Json).Count` 对 `[]` 得 **1**，我据此误判「ack 没生效」查了半小时 —— 项目里早记过同一条，这次踩的是诊断脚本。
    - **状态**：`run.ps1` **EXIT=0**、哨兵 **21/21**、恢复 **19/19**、设置 **9/9**、互斥锁 **3/3**；包 `169 条目 / 769.1 KB / SHA 9B58B6AB…`，verify PASS，一致性 19/19，基线 98/98。C1 结案；C 类只剩 WER LocalDumps 与人工验收清单。

78. **运行时介入第一步 + 一键卸载（2026-10-24 21:0x，用户：「先看看社区方案再动手」）**：
    - **社区调研结论（三条真正有用的）**：① Windows 官方的 **ARR**（`RegisterApplicationRestart`）只能由应用**自己**注册，第三方替不了；② **Restart Manager** 是给安装程序用的（关闭占用文件的应用→更新→重启），不是崩溃守护；③ **resurrecter / watchdog 类工具**的标准做法就是「轮询 + 判断异常退出 + 重启」，而且它们同样要面对「用户正常关闭 vs 崩溃」这个难点；④ **Chromium 多进程隔离**证明「崩一个模块不影响整体」的前提是**被守护对象自身是多进程** —— VRChat + PICO 模块这种 in-process 崩溃，外部无法隔离，只能事后重启。
    - **主界面合并两个证据来源（A23）**：原来只读 `history.jsonl`（Windows 事件日志），哨兵看到的退出（强杀/无日志崩溃）在桌面上看不到。现在合并 `sentinel-events.jsonl`，加**「来源」列**（`Windows 日志` / `哨兵观测`），哨兵行在详情区给完整判定（为什么 / 发现延迟 / 观测可信度 / 接下来），并写明「判定为『没有崩溃证据』≠ 不是崩溃」。**脱敏**：用户名→`***`、`C:\Users\<名字>`→`C:\Users\***`。实测 28 → **32 条**。
    - **托盘通知四段式（A24）**：发生了什么 / 我们做了什么 / 现在什么情况 / 接下来。时长进 `settings.json` 的 `notify.seconds`（默认 8，3–30）；不抢焦点、不置顶、全屏抑制、同事件不重复弹。同一程序反复崩时，「接下来」自动改成「已第 N 次异常退出，建议先更新/重装」。
    - **一键卸载（A22）**：`uninstall.ps1` 默认只预览，覆盖 7 处（进程 / 启动文件夹 / 计划任务 / 桌面快捷方式 / 运行期状态 / 项目目录 / 历史包），**默认保留用户数据**。
    - **踩到的测试坑**：消费验收断言「UI 详情区有结论状态」，而详情区第 1 行现在可能是哨兵行 → 测试失败。修法不是改测试，而是让 `-Check` **分别输出**「详情(日志行)」与「详情(哨兵行)」两个样例 —— 否则「所有行都变成哨兵行」这种退化会被当成正常。
    - **状态**：`run.ps1` **EXIT=0**、消费验收 **9/9**；包 `169 条目 / 772 KB / SHA CFCAD70C…`，verify PASS，一致性 19/19，基线 99/99。

79. **退出意图判定：用户自己关 vs 异常退出（2026-10-24 21:1x，用户质疑「进程消失可能是用户正常触发」）**：
    - **问题成立**：此前所有「进程不见了」都记 `unknown-exit` → 用户自己关个软件也弹通知（打扰），真崩了反而不被当回事。社区里那些 watchdog 工具也卡在同一处（只能靠退出码，而 GUI 程序正常退出常返回非 0）。
    - **做法**：新增 `core\exit-intent.ps1`（**纯函数**，无 IO）：判据 = 有可见窗口 + **上一轮 tick 时它是前台** + 没有崩溃证据 → `user-closed`。三态输出，`quiet=true` 的那类**不进待处理、不弹通知**，但**事实照记**（主界面「来源=哨兵观测」里能看到，人话写明「看起来是你自己关掉的」）。**有崩溃证据时任何用户关闭信号都不许覆盖**（单测 F 专锁这条）。
    - **只读两个值**：`GetForegroundWindow` 的 pid、`GetLastInputInfo` 的"距上次输入多少秒"——**不读输入内容**、不注入、不联网。
    - **踩的坑（值得记）**：① 我第一版把加载块插进了 `ack-state` 的 **else 分支**里（走了 if 分支就永不执行）→ `hasCmd=False`；② `Add-Type -MemberDefinition` 里嵌套 `struct` 在脚本上下文会静默失败 → 改成独立 `-TypeDefinition`；③ 调试用的 `[Console]::Error.WriteLine` 混进 `-Json` 输出 → JSON 解析失败（"Unexpected character: D"）。
    - **验证边界（诚实记录，已入 ISSUES C5）**：纯函数 7/7 + 接线守卫过；但**无人值守环境无法验证「前台窗口」那一路** —— `SetForegroundWindow` 受 Windows 前台锁定限制（本机实测：设画图前台失败，`GetForegroundWindow` 仍返回调用方）。所以「用户点 × → 不弹通知」需要真人点一次。
    - **状态**：`run.ps1` **EXIT=0**（新增 `test-exit-intent` 接进门禁）；包 `171 条目 / 780.1 KB / SHA A3EE5F52…`，verify PASS，一致性 19/19，基线 101/101。

80. **主判据换成退出码（2026-10-24 21:2x，用户追问打穿第一版）**：
    - **用户的两个追问直接否掉了第一版**：① 「正在输入的时候崩溃了可以吗」→ 崩溃时程序就是前台，第一版会判成"用户关的"（**漏报**，最严重）；② 「软件一般是自带退出的，不是 ×，这个会被计入吗」「进程自己自带的退出呢」→ 程序自己 quit 与用户点 × 在外部完全一样。
    - **新判据：Process.ExitCode**（哨兵监视期间持有进程句柄才读得到）：
      `0 → normal-exit`（不打扰、事实照记）· `非 0 → unknown-exit`（必须让用户知道）· `拿不到 → unknown-exit`（**不假设用户关闭，宁扰不漏**）。
      前台信号降级为「说明性证据」，只在理由里出现。
    - **实测对照（常驻哨兵 + 真实画图进程）**：
      | 场景 | exitCode | verdict | quiet |
      |---|---|---|---|
      | `CloseMainWindow()`（= 菜单退出 / 点 ×，同一条正常退出流程） | **0** | **normal-exit** | **True** |
      | `Stop-Process`（= 任务管理器强杀） | **-1** | unknown-exit | False |
      所以「不是 × 的退出（菜单退出、程序自己退）」**同样被正确计入**，因为它衡量的是「程序有没有正常走完退出流程」，不是「用户点了哪个按钮」。
    - **踩的坑（都很值钱）**：① 句柄表用 `Get-InstanceKey $pid $startTime` 做键，两处生成方式不一致 → 永远取不到退出码，改 **pid 做键**；② `Process` 对象不设 `EnableRaisingEvents` 时，进程退出后常常读不到 ExitCode（最小复现验证过）；③ `-Once` 每轮是新进程，句柄表不跨进程 → **必须在常驻模式验证**；④ `-Config` 指向不存在的文件原来会退化成「空 watch」继续跑 → 快照为空 → 上一轮看到的进程全被判成退出 → **一次性误报一堆假事件、污染生产目录**（已加存在性校验，exit 2）；⑤ 测试用 `-Once` 起测试哨兵会被生产哨兵的 Mutex 挡住，要加 `-InstanceName`。
    - **验证边界（诚实）**：退出码路径**已用常驻哨兵 + 真实进程验证通过**（见上表），不再依赖"前台窗口"；不再是 C5 那种无法自测的盲区。
    - **状态**：`run.ps1` **EXIT=0**、退出意图 8/8；包 `171 条目 / 782.5 KB / SHA 0BE2D815…`，verify PASS，一致性 19/19，基线 101/101。

## 三、待办

### A. 需要用户人在电脑前（未验证项）
| # | 事项 | 说明 |
|---|---|---|
| ~~1~~ | ~~**WinRE 实测 L3 采集**~~ | **已完成**（2026-10-22 20:03）：`shutdown /r /o` 进 WinRE，**17 条目**、System/Application 各 20.9 MB、离线注册表 67.9 KB；顺带修掉 `where` 探测 bug（详见 `tests\audit-l3-online-20261022.md`） |
| 2 | Ventoy 自动采集实测 | 模板按文档写，未在真机启动过 |
| ~~3~~ | ~~真实安全模式实测~~ | **已完成**（2026-10-22 20:19）：真安全模式下报告 `运行模式：安全模式（最小）（判据：SafeBoot\Option\OptionValue=1）`，采集/日志完整性/心跳均正常；顺带修掉「安全模式指纹覆盖 env-last」的隐患 |
| 4 | 抖音"镜像声音" | 复现时双击 `E:\ai\audio-check.cmd`，看「播放」页几个设备在跳 |
| ~~5~~ | ~~**WinRE 第三次复测**~~ | ✅ **已完成（2026-10-23 01:30）**：**21 条目**、`disk.txt` 有完整分区列表（磁盘 0/1、卷 0–4，含 EFI 与恢复分区）、missing 3（SrtTrail / ntbtlog / bootstat，均合理）。⚠️ 发现 `diskpart` 退出码 `0x80070057` 是「对不存在的盘（2/3）list partition」导致的**误判**——已修采集器（`disk.txt` 里出现「磁盘 ###」表头即视为成功）；**该修复待下一次 WinRE 复测确认** |
| 6 | **人工验收清单回填**（外部审计指出） | `tests\人工验收清单-20261023.md` 的「结果」列**是空的**（只有表头，没有 ✓/✗）—— 第 44 条写的"用户已点完"只是口头。需真人逐项打 ✓/✗，✗ 的写一句现象 |
| 7 | **真人盲测（P1）** | 找一个没用过 errwatch 的人 + **换一台电脑**，不提前教学。**观察表 / 预案 / 给小伙伴的一句话：`tests\盲测-换环境-20261023.md`**。已做换环境预检：含空格路径 + 5.1 下 doctor / 报告 / UI / 修复演练全部 exit 0 |
| 8 | **WinRE / L3 恶劣环境（P1）** | 盘符重排、BitLocker 锁定、空间不足、断电、只读介质、证据截断；重点防「把错误的数据盘当系统盘」「部分成功显示成完整成功」 |

> 2~5 项的操作步骤、要记录什么、已排掉的坑：**`tests\onsite-20261022.md`**（照着做即可）。

### B. 不需要人在电脑前（可直接做）
| # | 事项 | 依据 |
|---|---|---|
| ~~1~~ | ~~**指纹分层**~~ | **已完成**（2026-10-22 晚）：核心层/外围层 + 虚拟设备过滤；见 `tests\audit-env-tiers-20261022.md`，回归 `tests\env-tiers.ps1`（28/28） |
| 2 | 挖 `Kernel-PnP/219`（驱动加载失败 ×13）具体驱动名 | 很可能是本机反复出问题的根源，与 `explorer 0xc0000142` 疑似同源 |
| 3 | 挖 `SCM/7031`（服务意外终止 ×8）具体服务名 | 同上 |
| 4 | 收录剩余 Provider 人话 | VSS / .NET Runtime / RestartManager / Perflib(已收录) / `CodexSandboxService/1003` |
| 5 | `report.ps1` 等入口的 history 也带 env | 目前只有 `errwatch.ps1` 写入 env |
| 6 | 需管理员的采集源 | SMART / `Get-PnpDevice` 设备状态（实测非管理员被拒） |
| 7 | L3 采集器补外设/固态采集项 | 目前只采事件日志原件 + 启动证据 |
| 8 | `fix.ps1` 动作扩展 | 现在 7 种；Perflib 那条建议的 `lodctr /R` 它做不了 |
| 9 | 审计路线第 6 项 | 真实试用与误诊统计 |
| 10 | 历史挂账 | ~~TOCTOU~~ ✅ A66 的 `Test-Revalidate` 已覆盖（log-rotate / restart 执行前都调）· ~~并发未真压测~~ ✅ A78 已做（6 进程 × 25 行零丢失）· ~~`-Port` 只验监听~~ ✅ A83 已改（抽 netstat PID 跟服务 pid 对照，占用者不是本服务时降级 partial）· **`-Value` 无边界仍开放**：校验责任在外部组件 WriteGuard，而包内 config-fix 本来不可用（缺依赖会明确拒绝）→ 记为已知局限 |
| 11 | **O5：`-AddEvent` 半自动落库** | `errwatch-source.ps1` 加：输入 provider/id/人话/建议/来源 → 写进 events.json（写前确认、写后校验） |
| 12 | **审计整改 A（P0）**：notify 三层状态机 | collection watermark / delivery state / run state 分开；稳定通知 ID；故障注入测「A成功B失败/双失败/状态写入失败/进程被杀」 |
| 13 | **审计整改 C（P0）**：修复器执行契约 | Plan→Validate→Confirm→**Revalidate**→Execute→Verify→Record；部分失败要说清"已经发生了什么"；不可逆动作独立高风险标识 |
| 14 | **审计整改 F（P1）**：UI 六场景 | 空历史/畸形 JSONL/无 pwsh 回退/外部程序失败/非交互/修复入口失败 |
| 15 | **审计整改 E（P1）**：规则准入清单 | 真实第三方规则：来源/commit/作者/SPDX/原始哈希/转换器版本/处置；缺 author 拒绝进产物 |
| 16 | **时间线后续** | 案件持久化 `cases.jsonl`（"我见过这个案件"）、接入主报告（`-Timeline` 开关）、未收录事件的"常规启动事件"措辞 |
| 17 | **补 19 条 rules 的 `ref`**（lint WARN） | `rules.json` 28 条里 19 条 `ref` 为空 —— 要么给踩坑大全编号，要么改成 verify 文本；补完后 `lint-human.ps1` 可加 `-Strict` 当发布门禁 |
| 18 | UI 两个按钮人工点一次 | WinForms 无自动化点击覆盖：①「开始扫描」→ 应后台跑完并刷新表格；②「看完的感受」→ 选一项后 `feedback.jsonl` 多一行 |
| 19 | **UI 首页概览条肉眼过一遍** | 第 2 步新增：标题栏里的概览条（采集失败时应变琥珀底警示）、详情区「结论状态 · 可信度」——`-Check` 自检已过，**外观需人看一眼**（尤其窄窗口下是否被挤） |
| ~~20~~ | ~~**修复授权链审计（P0）**~~ | ✅ **P0-1 / P1-1 / P1-2 已修**（2026-10-23，见第 66 条）：STOP 覆盖 5 个写动作、审计记终态、命令转义。**未做**：P2-1~P2-4（repair 文案漂移 / UI 文案口径 / rescan 复验空转 / `force-override` 未 Critical）、STOP 与命令注入的**动态真机验证** |
| 21 | 「**known ≠ 可信**」写进文档 | 五态是**分类**不是可信度：`known` 只说明有规则、有证据，不保证适用范围/时效/关联正确。要写进 `定位.md` 与诊断契约文档，防止 `known` 被当成"可信结论"的通行证 |
| 22 | **报告 / UI 消费 coverage（P0-2 剩余）** | 现在只有 `-Status` 与托盘读 `sentinel-coverage.json`；主报告与 UI 里还看不到「这次看没看住」。改动点在报告 §故障响应、UI 概览条，`tests\audit-p02-p03-20261023.md` §七-1 |
| 23 | **`sentinel-events.jsonl` 行级校验** | 现在半行 JSON 是静默跳过；应在 `integrity` 里给 `droppedInvalidLines` 计数，且启动时对事实记录自身做一次完整性体检（§七-3） |
| 24 | **主报告 / UI 消费 `opportunity.json`** | 现在只有 recover 与 doctor 读；报告里还看不到「这次崩溃前有没有产生过恢复文件」。改动点在报告「故障响应」节与 UI 概览条（`design-recovery-opportunity-20261023.md` §七-7） |
| 25 | **`recover.json` 路径表按真实机器校准** | 本机实测旧表 6 漏 4；已按通用位置重写，但**没有在真装了 CAD / Office 的机器上逐个核对过**。这条只能靠实地验证或用户反馈收敛 |
| ~~26~~ | ~~把「每 2 分钟扫事件日志」接进哨兵~~ | ✅ **已做（2026-10-23）**：`errwatch-sentinel.ps1 -NotifyEveryMinutes N`（默认 0）；启动文件夹通道的启动项自动带 `-NotifyEveryMinutes 2`。实测 75 秒内 `last-check.json` 被更新 |
| ~~27~~ | ~~`summaryAfterFullscreen` 还没接进决策~~ | ✅ **已做（2026-10-23）**：设 false 时，被全屏压下来（acks 全是 suppressed）的事件退出全屏后不补弹；`test-tray` P 用例看守。tray 另加 `-NotifyConfig` 供测试注入 |
| ~~28~~ | ~~事件 ID 贯通到 recover~~ | ✅ **已做（2026-10-23）**：`Start-Recover -EventId` → recover 从 `sentinel-events.jsonl` 取该事件的 `startTime`/`lastSeenAt` 当会话基准；核验后写回 `rescue` 维度 |
| ~~29~~ | ~~状态契约（三维度）~~ | ✅ **已做（2026-10-23）**：`STATE-CONTRACT.md` + `core\ack-state.ps1`；三维度互不覆盖、终态只认 lifecycle、`launched` 非终态、旧数据自动映射；`test-ack-state` 10 项盯不变式。**未做**：acks 文件的 7 天滚动保留策略 |

### C. 本机已发现但未处理的真实问题（用户知情）
- `Kernel-PnP/219` 驱动加载失败 ×13、`SCM/7031` ×8、`Resource-Exhaustion-Detector/2004` ×3（内存耗尽）
- `explorer.exe 0xc0000142`：桌面 shell 当前未运行，且该失败**不进事件日志**
- Startup 里 `mifit-sync.bat` 的 `MODULE_NOT_FOUND` → **已修**（改为转发 `E:\ai\mifit\同步-静默.bat`）
- Perflib：`sysmain.dll` 存在但计数器加载失败 → 建议"可以先不管"，想修用 `lodctr /R`

## 四、不能丢的原则与决策

1. **定位**：面向「遇到报错、不做技术的人」，中文交流、非程序员。**借社区的条件，自己写人话。**
2. **三条原则**：有证据 / 有边界 / 有路由（fix-agent-driver-community）
3. **漏比误好**：字段名对不上就**不命中**，绝不做可能误诊的近似
4. **unknown 是显式状态**：没收录就写"事件表里没有收录 —— 需要人工判断"
5. **每条结论带可信度 + 怎么验**（高=事件ID/字段级，中=错误码/手写规则，弱=仅凭来源名）
6. **采集与分析分离**：采集器不下结论；分析器不碰原机器；失败也要如实记录
7. **核心资产只有一份**：`core\`；入口可以换、环境可以坏
8. **改动后必须**：跑回归 → **确保 BOM**（`pwsh -File tools\ensure-bom.ps1`；5.1 下无 BOM 会语法崩；**edit 工具会丢 BOM，改完必须补**）→ 重建基线 → 打包（`_tmp\pack-errwatch-audit.ps1`：目录遍历，新文件自动进包；`pack-errwatch9.ps1` 是旧的固定白名单版，别再用）
9. **反馈归反馈**：`feedback.jsonl` 里的「看不太懂」**不等于**规则判断错了 —— 不得直接把它当规则可信度、排序权重或训练标签。它只说明"表达没让人读懂"，该修的是文案与入口，不是判定逻辑。

## 五、诚实记录（未验证 / 有损）

1. **Ventoy / 安全模式 两个"真机"未验证**（WinRE 已于 2026-10-22 20:03 真机通过）
2. **真实 Sigma 规则库只做过转换，没有启用**（1561 条带字段条件，但与"报错人话"目标无关的占绝大多数）
3. 字段匹配依赖「Sigma 字段名与 Windows 事件同名」；不同名时表现为**漏**（不命中）
4. `UserData` 段未解析（Windows Update 类事件会退回事件 ID + 文本）
5. `tools\sigma-convert.ps1` 不支持 `all of selection_*` / `1 of selection_*` 组通配 → 跳过约 1000 条
6. YAML 解析器只覆盖子集（无锚点/别名/流式）
7. UI（`errwatch-ui.ps1`）只做过语法检查，两个改动点无自动化覆盖
8. **内存维度在受限环境取不到**：注册表是 REG_RESOURCE_LIST（.NET 取值为 null）+ CIM 被拒 → `memoryGB` 缺失属预期；普通用户机器上 CIM 可读，**未真机验证**
9. **虚拟设备过滤是黑名单**：没见过的虚拟设备名仍会被当核心硬件；外围层变化**完全不提示**是刻意取舍（数据仍记在 `env-last.json`）
10. **`Application/1001`（WER 错误报告）没有解释**：修好"按日志区分"后它不再被贴成蓝屏，但也从「关键事件」里消失了 —— 补一条表项即可，未做
11. `dir` 类命令遇到"目录不存在"时 exit=1，被记成"命令失败"（`MEMORY.DMP` / `System32\config` 两例），语义上应是"没有这个文件"，属噪音级
12. **此前的 PowerShell 5.1 兼容性只是"纸面声明"**：README 写"没有 pwsh 就回退 5.1"，但从未在 5.1 下跑过；本次实测才发现无 BOM 会直接语法崩（已修：21 个文件补 BOM，并纳入打包流程）
13. **安全模式的「修复拒绝」还没真正验到**：第一次跑时目标文件不存在，结论是"目标不存在"而非"安全模式拒绝"；`safe.cmd` 已改为先建真实文件，**下次安全模式复测才验得到那条判断**
14. **故障时间线只是原型**：只读、案件未持久化（`cases.jsonl` 未做）、未接入主报告；「触发按严重度」已修，但「未收录事件」仍显示"（未收录）"
15. **O5（`errwatch-source.ps1 -AddEvent`）尚未实现**：unknown 补录仍靠手改 `events.json`
16. **coverage 只到「轮次级」**：`gapAfterSeconds` 判的是两次检查的间隔。哨兵被挂起后恢复、系统睡眠、时钟跳变都按同一规则处理 —— 会保守地说「有缺口」，但识别不出「进程还在、采样却被冻住」这种更隐蔽的情况
17. **事件级 coverage 不回填历史**：只按「本轮有没有缺口」判定，更早的缺口不会补写进已入队的事件
18. **`sentinel-events.jsonl` 的半行 JSON 是「跳过」不是「报错」**：解析失败的行被静默忽略，`integrity` 里也没有这一项的计数 —— 事实记录本身的完整性只做到「能读的读出来」
19. **coverage 目前只有 `-Status` 和托盘在读**：主报告 / UI 两个入口还没消费（用户在 UI 里仍看不到「这次看没看住」）
20. **托盘的「救援」与「覆盖」尚未联动**：覆盖有缺口时仍会照常推荐救援，只是文案加了提示 —— 没有做到「缺口时不建议把这次退出当确凿证据」
21. **`recover.json` 的新路径表没有在真机核对过**：旧表在本机 6 漏 4（这是实测），新表按通用安装位置重写，但**没在真装了 CAD / Office 的机器上逐个验证**。所以「找不到恢复文件」仍可能是路径表错，不是内容没了
22. **只判断「有没有恢复文件」，不判断「内容对不对」**：候选是不是你要的那份，仍然只能人看（这是设计边界，不是待办）
23. **`behavior` 型检查是推断**：近 7 天产生过恢复文件 = 机制在工作；没有 = 可能没开，也可能是这周没干活
24. **会话时间可能拿不到**：哨兵中途启动 / 进程已退出且无记录时，降级为按 mtime 粗分，并标注 `sessionKnown=false` —— 不假装知道
25. **主报告 / UI 还没消费 `opportunity.json`**：现在只有 `recover` 与 `doctor` 读它（待办 24）
26. **真实崩溃样本仍未测**：本轮全部是合成夹具（假 app + 假 `.sv$`），不宣称验证了真实 CAD / Office 的恢复能力
27. **状态契约已做，但 acks 文件还没有保留策略**：`tray-acks.jsonl` 只追加不清理。量级不大（每事件 2–3 行 × 约 120 字节），但长期跑会缓慢增长。预留方案：按 7 天滚动（与 pending 一致）
28. **recover 写 acks 是受控例外**：契约第六节允许 recover 在「有 `-EventId` + 非交互核验」时写 `rescue` 维度。代价是「唯一写者」这条原则有了一个例外 —— 若将来出现写冲突，优先怀疑这里
29. **托盘心跳有 30 秒盲区**：哨兵挂掉后最多 30 秒内托盘仍显示「正常」（阈值换来的抗抖动）。可接受，但要知道
30. **常驻任务的窗口会闪一下**：用 `-WindowStyle Hidden` 起 pwsh，启动瞬间可能闪一个控制台窗口。真嫌吵就换 VBS 静默启动器（`Write-Starter` 已经是 .vbs 了，但计划任务通道还没有）
31. **`.vbs` 启动器被杀软误报的概率不是零**：内容是 `WScript.Shell.Run`，个别杀软会盯这种模式
32. **兄弟实例只判「同组其他实例」**：不是进程树分析。跨组的父子关系（launcher 与主程序名字完全不同且都配在两个组里）仍会被误报
33. **`-Status` 的路径校验只比对文本相等**：如果用户把目录**搬家后没重新注册**，会报「旧目录」；如果搬家后又手动改了启动项指向新路径，则显示正常 —— 两者都符合预期，但「同一份代码的两个副本同时存在」这种情形它分不出来

## 六、怎么继续

```powershell
$root = "E:\ai\_tools\errwatch"

pwsh -File "$root\errwatch-level.ps1"                 # 定级：现在属于 L1/L2/L3
pwsh -File "$root\errwatch.ps1"                       # 全量报告（7 节）
pwsh -File "$root\errwatch-timeline.ps1"              # 故障时间线（只读原型：案件聚合）
pwsh -File "$root\tests\run.ps1"                      # 规则回归 28 条 + 冒烟 + 可执行性 lint
pwsh -File "$root\tests\lint-human.ps1"               # 只跑 lint（加 -Strict 当门禁）
pwsh -File "$root\tests\unknown-chain.ps1"            # unknown 全链路 9 项
pwsh -File "$root\tests\test-opportunity.ps1"          # 恢复机会 13 项（分档 / 四态 / 会话登记 / doctor 段）
pwsh -File "$root\tests\test-register.ps1"             # 启动链 7 项（双通道构造 / 状态 / 单实例互斥）
pwsh -File "$root\tests\test-ack-state.ps1"            # 状态契约 10 项（三维度不变式）
pwsh -File "$root\register-watch.ps1" -Status          # 看启动链实际走哪条通道 + 哨兵心跳
pwsh -File "$root\register-watch.ps1" -DryRun          # 只看会装什么，不动系统
pwsh -File "$root\tests\env-tiers.ps1"                # 环境指纹分层 30 项
pwsh -File "$root\tests\test-diagnosis-contract.ps1"  # 诊断契约 11 项（五态 / 适配层 / 汇总 / 绿灯）
pwsh -File "$root\tests\test-diagnosis-consume.ps1"   # 报告 / UI 消费验收 8 项（含采集失败注入）
pwsh -File "$root\errwatch-query.ps1" -Stats -CurrentEnv   # 只看当前环境的报错
pwsh -File "$root\errwatch-query.ps1" -UnknownRank    # 补录优先级（次数 × 持续天数）
pwsh -File "$root\errwatch-feedback.ps1" -List        # 看「看完的感受」记录
pwsh -File "$root\errwatch-bundle-analyze.ps1" -Bundle <包>  # 离线分析证据包
pwsh -File "$root\tools\make-release.ps1" -Zip <包>   # 生成发布清单 release.json
```

**先读**：`tests\审计索引.md`（**最新**：当前基线 / 历史审计 / M1–M24 整改映射 / 剩余风险）→
`定位.md`（边界）→ `tests\design-diagnosis-contract-20261023.md`（诊断契约方案 + 第 2 步落地记录）→
`tests\brainstorm-20261022.md`（产品层 5 个增量 + 落地状态）→
`tests\audit-coverage-20261022.md`（覆盖面）→ `tests\audit-env-tiers-20261022.md`（指纹分层）→
跑一次 `errwatch-timeline.ps1` 看时间线效果。

**本机相关信息**：Sigma 规则包在 `E:\ai\_refs\sigma_rules\`；解压后的规则在 `E:\ai\_tmp\sigma-src\`；
完整转换报告在 `E:\ai\_tmp\sigma-full-report.md`（临时目录，可能被清理）。

### 2026-10-24 22:2x（用户看详情区截图：内部枚举 + 看不懂的解释）

1. **三个问题一起改**（用户原话：「观测可信度：OBSERVATION_UNCERTAIN 我觉得这种不行」「什么叫找到了崩溃证据（系统记录），按崩溃处理？我觉得普通用户想知道为什么崩溃了 原因 解决办法」）：
   - 枚举值 `OBSERVATION_UNCERTAIN` 直接打在界面上 → `Get-CoverageHuman` 翻成「准 / 不太准 / 没看到 / 可能不准 —— <原因>」；
   - 「为什么」在讲**判定流程**而不是**故障本身** → `Get-SentinelWhy` 分三种说（有崩溃记录 / 有非 0 退出码 / 什么都没有），并把局限一起讲明；
   - 最要命的一点：`evidence` 字段**一直有值**（实测 `1000 10-24 21:35:29 出错应用程序名称： crashprobe.exe…`），但界面从来没渲染过 —— 用户只被告知"找到了崩溃证据"，看不到证据。现在原样贴出来。
2. **新增两段普通用户真正要的东西**：`Get-SentinelHints` → 可能的原因（按常见度排序）+ 你可以这样做（可执行步骤，含「反复出现就用崩溃设置里的崩溃快照」）。
3. **`core\exit-intent.ps1`** 里那句 `'找到了崩溃证据（系统记录），按崩溃处理'` 也换掉 —— 它还出现在列表的「人话」列，所以文字要能独立读懂。
4. **守卫**：`test-settings` L（枚举不许直出 / 三段必须存在 / 证据原文必须显示 / 不许再说"按崩溃处理"），`test-settings` **15/15**；反证过：把 coverage 直出改回去，L 立刻 FAIL。
5. **被自己的守卫误报一次**：L 把文件头**引用用户原话的注释**（「…按崩溃处理？」）当成了违规 —— 静态守卫要排除注释行，否则"记录用户原话"反而违规。
6. **发布链重跑**：基线 → pack `20261024-bj` → verify **PASS** → gate **allow** → 材料一致性 **19/19**。

### 2026-10-24 22:3x（用户看托盘菜单：批量处理）

1. **需求**（用户截图三条 `unknown-exit`）：「这个可以加批量或者多选或者全部处理吗」。
2. **两条路**（托盘 `ContextMenuStrip` 本身不支持多选）：
   - **「✓ 清掉这 N 条『进程消失』」**：只清 `unknown-exit`；标题里写明「保留 M 条崩溃的」；**全部都是崩溃时这一项变成只读说明**「（N 条都带崩溃证据，请逐条看）」——一条真崩溃混在十条噪音里被一起清掉，用户就再也不会去翻了，这个保护是刻意的；点之前还有一次 YesNo 确认。
   - **「☑ 选择多项处理…」**：`CheckedListBox` 勾选窗，崩溃项**默认不勾**并标「〔崩溃：建议单独看〕」，带全选/全不选/取消。
3. **性能细节**：新增 `Add-AckBatch`——一次拿 Mutex、一次写多行。逐条调 `Add-Ack` 的写法在 N 条时要抢 N 次锁，而保留策略那边正持锁时每次各等 2 秒，十条就能卡住托盘 20 秒。
4. **落地前的风险预判**：多选窗用 `ShowDialog`，先实测托盘进程的线程公寓状态（**STA**）和 `CheckedListBox` 的勾选读写，确认可用才写代码——否则点了没反应只会留一行 tray-error.log。
5. **测试**：`test-tray` Q 从「单场景断言」改成**双场景**：全崩溃 → 断言**不许**出现「清掉」并必须说明原因；混合（1 noise + 1 crash）→ 断言「清掉这 1 条」+「保留 1 条崩溃的」。**19/19**。
6. **发布链重跑**：基线 → pack `20261024-bk` → verify **PASS** → gate **allow** → 材料一致性 **19/19**。

### 2026-10-24 22:4x（用户连问六件）

1. **C6 结案（本轮最重要的验证）**：用户主动说「UAC 我可以处理」，于是跑 `pwsh -File errwatch-dump.ps1 -SelfTest -Elevate`。结果：`%ProgramData%\errwatch\selftest\dumps\errwatch-probe.exe.24416.dmp` **5.86 MB 真实落地**。至此 A30 的唯一缺口补上：**HKLM 的 LocalDumps 确实产出 dump**，三层防线的第二层不是设想。
   - 顺带修掉 SelfTest 的一个残留：子键撤了、**空根键留着**（实测发现）。现在空了就连根键一起删。
   - 注意：本次遗留的那个空根键是管理员上下文建的，普通权限删不掉，无害（没有子键就不会产出 dump）。
2. **先纠正一个误解（用户问「我如果选择不处理 它也会产生文件吗」）**：**不会**。`acknowledged` 只是往 `tray-acks.jsonl` 写一行；会占磁盘的只有救援副本（`-SaveTo` 复制出来的）+ 崩溃快照。
3. **A38 保留与清理**：
   - 新 `core\storage.ps1`，与 `retention.ps1` **按判据分工**（这是关键，混在一起会互相污染）：retention 管状态数据、按「进入终态的时间」清；storage 管磁盘文件、按**修改时间**清。
   - `settings.json` 新增 `storage{keepDays=7, fileKeepDays=30, copyDir}`；哨兵调 retention 不再写死 `-KeepDays 7`。
   - CLI：`-KeepDays` / `-FileKeepDays` / `-CopyDir` / `-ClearCopyDir` / `-StorageShow` / `-Cleanup`（**默认只预览，`-Confirm` 才删**）。
   - 设置窗新增「存储与清理」页（页首就写清「点不需要处理不产生文件」+「我们会保留多久」）。
   - 主界面详情区新增「相关目录」两行（崩溃快照 / 救援副本，存在与否都说清）。
   - 保护：只扫自己知道的目录、只删超期文件、不跟符号链接、**相对路径的 copyDir 直接拒绝**（相对路径会随工作目录漂移，清理时可能删到别处）。
4. **旧包清理**：`_dist` 12.91 MB → 2.5 MB（删 56 个文件 / 10.41 MB），保留当前版 + 上一版正式交付。
5. **测试**：`test-settings` 加 M1（设置往返 + 越界 + 相对路径拒绝）与 M2（**40 天前删、新文件一个都不许动**、阈值 60 天时不许删、不存在的目录不能抛异常），**17/17**。
6. **发布链重跑**：基线 → pack `20261024-bl` → verify **PASS** → gate **allow** → 材料一致性 **19/19**。
7. **（收尾）存储页把「会保留多久」写成一句承诺**：用户要求「给用户说我们会保留一段时间，可以移动到存储与清理里说明」。于是页面最上方放一段**跟着两个天数输入框实时更新**的说明（`Add_TextChanged` + 变量插值）：已处理记录保留 N 天且未处理的永不清 / 副本与快照保留 M 天、超过只进「过时」清单且**程序不会自己删** / 点「不需要处理」不产生文件。写死天数会立刻变成假话，所以守卫 `test-settings` N 直接检查文案里必须有 `$k` / `$f` 插值。`test-settings` **18/18**。
8. **发布链重跑**：基线 → pack `20261024-bn` → verify **PASS** → gate **allow** → 材料一致性 **19/19**。

---

## 本文件的边界（2026-10-25 补）

**A39 之后的完整记录改记在 `NEXT-SESSION.md` 的「二、这轮做完了什么」**（逐条编号，截至 A51），
本文件停在上面那条 22:4x。这不是丢记录，是**避免两份真相**：

- 每轮必读、必更新的：`NEXT-SESSION.md`（当前状态 / 这轮做了什么 / 待做 / 坑）
- 结案细节按编号查：`ISSUES.md` 的 A 类表（A1–A51）
- 本文件保留 2026-10-24 之前的过程记录 —— 里面有大量「当时为什么这么想」的推理痕迹，`ISSUES` 不重复这些

要补 A39 之后的内容，请**先确认 `NEXT-SESSION.md` 里那条已经稳定**，别在这里写第三份。