# 新会话入口（2026-10-25 15:xx 交接）

> 上一会话上下文过大，这里是**精简底座**。先读这一份就够开工；细节再翻 `HANDOFF.md` 与 `tests\审计索引.md`。
> 不要回灌全部历史 —— 下面是可验证的事实，不是叙事。

## 本轮交接（2026-10-25）

- 完成 **A61–A73**：托盘超时提醒降噪、WER 1001 报告 ID（含 UI 显示与报告目录）、副本目录引导、门禁 WARN 3 清零、test-lock F 用例加固、C4 8.2/8.3（执行策略绕过 + 可选中复制 + 交给 agent）、C5 退出意图判定、托盘退出标记、看护健康/doctor 托盘状态、同程序折叠改「保留最新」、程序名中文化（mspaint→画图、olk→Outlook）、**UI 六场景自动化（审计整改 F）**、**第一份审计回执四处收尾 + 卸载真缺口**。
- **发行件**：以包外 `release.json` 与 `*.zip.sha256` 为准，**本文件不写包名**（写死了必然漂移 —— 2026-10-25 审计回执就是这么抓到上一份包材料不一致的）。两种包（user / dev）见 `发布流程.md` §3.0。
- **权属确认**：维护者本人 2026-10-25 再次确认（三项均「没有」；与 2026-10-22 一致）。已记入 `tests\审计索引.md` §六。
- 下一步：主界面「进程消失」表达优化；**G 陌生用户决策测试（需真人，脚本可先备）**；P1 只剩第 6 项（低优先）。

## 一、当前状态（全部可核对）

| 项 | 值 | 怎么验 |
|---|---|---|
| 当前包 | **不写包名** —— 以包外 `release.json` + `*.zip.sha256` 为准（`E:\ai\_tools\_dist\`）。<br>两种类型：`user`（默认，给拿到包的人）/ `dev`（`-Profile dev`，给审阅者），见 `发布流程.md` §3.0 |
| 独立验证 | verdict **PASS** / gate **allow** | `*.zip.verify.json` |
| 材料一致性 | **19/19** | `pwsh -File tools\check-release-identity.ps1 -Zip <zip>` |
| 哈希基线 | **一致** | `pwsh -File errwatch-baseline.ps1` |
| 门禁 | `tests\run.cmd` **EXIT=0**（**开发目录与干净解压目录都必须绿** —— 审计 P2-1 就是"只在开发目录绿"） | 直接双击；发布前必须解压到空目录再跑一次 |
| 专项 | 哨兵 23/23 · 设置 20/20 · 托盘 23/23 · **WER 报告 ID 7/7** · **崩溃快照 6/6** · **快照接线 29/29** · **快照解读 13/13** · **发行包卫生 6/6** · **翻译规则库 6/6** · 恢复 21/21 · 互斥锁 6/6 · 退出意图 9/9 · doctor 9/9 · 指标 9/9 · 保留 13/13 · **状态契约 12/12** · 进度 10/10 · 采集 11/11 · 兜底 7/7 · 契约 14/14 · 消费 9/9 · 安全性 10/10 · 规则来源 10/10 · **诊断追溯 12/12** · **记录号 9/9** · **规则定位 9/9** · **归位 21/21** · **主界面六场景 9/9** · lint **FAIL 0 / WARN 0** |
| 规则数（**两个口径，别混**） | **报错规则 34 条**（`test-rules.ps1` 数的是这个：具体码 → 码段兜底 `0xe0`/`0x8013`/`0x8007`/`0xc0000` → 真 unknown 三层）· **core 总规则 40 条**（= 34 报错 + 6 事件规则，界面「规则数量」显示这个）。审计回执说「写着 34 条规则」时指的就是前者，不是过时数字 | `pwsh -File tests\test-rules.ps1` / `errwatch-ui.ps1 -Check` |
| 看护 | 哨兵在跑（pwsh 7），监视 **19 个目标** | `sentinel-status.json` |
| 待处理 | 通常 0–3 条（真实事件，用户自己点「不需要处理」/ 批量清） | `sentinel-pending.json` |

**当前在跑的**：`ps_service_launcher`、`ps_server`（PICO）· `DSH Desktop`×10、`msedge`、`Notepad`、`QQ`、`Twinkle Tray`、`猫猫云`。
**设置里的手动目标**：0 个（`settings.json` 已创建，`watch.extra` 为空数组）。
**存储与清理**：`storage{keepDays=7, fileKeepDays=30, copyDir=""}`；副本目录没设 → 现在无从清理（这是有意的：不设就不乱删）。
**崩溃快照**：**已布防 21 个程序**（2026-10-24 22:46 写入，全部迷你 dump / 每个最多 5 份 / 落 `C:\ProgramData\errwatch\dumps`）。本机真装了的 8 个，其余是"装了即生效"的占位。端到端实测过一次真崩溃（A41）。

## 二、这轮做完了什么（一句话一条）

1. **A1 `rules-sigma.json` 许可归属** → 判为自编样例，`origin=original/license=MIT`；转换器判据唯一化，门禁双向自洽，新增 `merge-sigma-rules.ps1` 回填人工字段。
2. **A2 托盘菜单点不动** → 待处理项加子菜单（应急救援 / 不需要处理）；`Start-Sleep 2000` 拆成 20×100ms；菜单打开时跳过重建。
3. **A3 跨休眠毁指标** → 盲区优先判定 + `latencySource` + 盲区样本不进 p50/p95 + 数据自愈（`53011315` 已迁到 gap 通道，p50 回到 1104ms）。
4. **A4 写盘偶发「文件已存在」** → `Publish-StateFile`（失败先删目标再移）+ 错误带行号。
5. **A5 doctor 落后架构** → 「响应链」三段（计划任务/启动文件夹/心跳），notify 代跑不算缺。
6. **A6 扫描吞错** → `-ErrorVariable` 区分权限拒绝，出 `scanErrors/deniedDirs`，人话加警告。
7. **A7 复制不可信** → 临时名 → 比长度 →（≤32MB）比 SHA256 → 发布。
8. **A8 托盘/界面四连** → 菜单状态化（`ui.pid` + 三重校验）；黑框真因是**旧界面进程残留**→界面单实例化；详情区原因提前；状态栏补「托盘里待处理 N 条」。
9. **A9 UI 备份快照不一致** → 一次扫描 + `-SnapshotOut` + `-OnlyPathFile`。
10. **A10 24h 降噪窗口** → `settings.json` 的 `sentinel.quietHours`（1–168）。
11. **A11 含空格路径** → 实测通过（整项目复制到 `errwatch 空格 test\`，UI/托盘/doctor/restart 全过）。
12. **A13 浩辰CAD 现场适配** → 装的是**浩辰CAD 2027**（`gcad.exe`），`recover.json` 原来只认 AutoCAD，已加 `gstarcad` 条目 + `apps.json` 条目。
13. **A18 浩辰真实崩溃演练（C1 结案）** → 1052 ms 发现；`.sv$` 头 `AC1032`（DWG 2018 容器）；救援复制后原件与副本 **SHA 一致**；**用户打开副本确认内容都在**。
14. **A19 重启哨兵会重复记录同一次退出** → 去重改用持久化 pending（同 `app+pid` 未终态不再新增）。
15. **A22 一键卸载** → `uninstall.ps1`，默认预览，覆盖 7 处，用户数据默认保留。
16. **A23 主界面看不到哨兵观测** → 合并 `sentinel-events.jsonl`，加「来源」列，哨兵行详情给完整判定；脱敏（用户名/`C:\Users\xxx`）；28 → 32 条。
17. **A24+A26 通知** → 气泡**压到 3 行 / 52 字**（发生了什么 / 已记录没动文件 / 点托盘）；时长 `notify.seconds`（默认 8，3–30）；UI 详情区**保留完整解释**（那是给普通人的）。
18. **A25 退出意图** → 第一版靠「前台窗口」被用户两个追问打穿（正在输入时崩溃=漏报；程序自己退出=分不清）→ **换成退出码**：`0 → normal-exit`（安静）/ `非0 → unknown-exit`（报）/ `拿不到 → unknown-exit`（宁扰不漏）。
19. **动态监视三层（用户两次否决后收敛）** → v1 只认窗口（漏后台）/ v2 全用户空间（**89 个进程，噪音不可接受**）→ **v3 = 有窗口 ∪ 崩溃历史学到的 ∪ 静态名单**（实测 7–8 个）。

### 2026-10-24 21:2x–21:4x（本次交接后的第一轮）

20. **A27 pending 空队列被误判「损坏」（宿主漂移事故）** → 根目录攒了 **144 个 `sentinel-pending.json.corrupt-*`**，每 65 秒一个。真因：`'[]' | ConvertFrom-Json` 在 **PS7** 得 `$null`、**PS5.1** 得空数组；旧代码用 `$null -eq $raw` 判损坏 → 只要队列是 `[]`（无待处理），每轮都「修复」一次。修法：**try/catch 判解析成败**，返回值真假不参与判定；备份只留最近 5 份。生产实测（真实 pending 改成 `[]` 跑一轮）：corrupt 0 个、`repaired=false`、`[]` 原样保留。`test-sentinel` V（含防空转断言）22/22。
21. **A28 门禁命令在本机会直接挂** → `powershell -File tests\run.ps1` 报 `running scripts is disabled`（5.1 LocalMachine = Undefined → Restricted）。新增 `tests\run.cmd`（优先 pwsh 7 + 自带 Bypass + 打印 EXIT），文档命令全部改掉。
22. **A29 P1「设置里手动添加监视目标」已完成** → `settings.json` 的 `watch.extra`（规范化 + 拒绝通配符）；哨兵加载 cfg 后注入成 `source=user` 的 watch 组（与静态名单重名不重复）；设置窗新增「监视目标」页（我加的/内置分开列，可加可删）；命令行 `-AddWatch` / `-RemoveWatch`。**端到端实测**：config 的 watch 为空、只靠 settings → 第一轮就认到（note=「你在设置里手动添加的」），杀进程 → 第二轮出 `ProcessExit`。`test-settings` W1/W2/W3，12/12。
23. **顺手补强 B15** → 设置窗新增 `-CheckBuild`：**真实构建整个界面但不显示**（`-Check` 只打印设置，构建期的错抓不到）。纳入 `test-settings` I。
24. **发布链重跑** → 基线 102 文件 → pack `20261024-bd`（172 条目 / 793.7 KB）→ verify PASS → gate allow → 材料一致性 19/19。

### 2026-10-24 21:5x–22:0x（接手后第二轮：C2 / B14 / B13）

25. **A30 C2 崩溃快照布防落地** → 新增 `errwatch-dump.ps1`（默认只预览；`-Apply` 真写；`-Elevate` 弹 UAC；`-Remove`/`-Status`/`-SelfTest`/`-WatchList`）。**先实测方案前提再写代码**：`HKCU` 的 LocalDumps 写好后造一次真原生崩溃（`csc /unsafe` 空指针 → `0xC0000005`），等 24 秒**没有 dump**，而 WER 事件 1001 有记录 → **HKCU 不生效，必须 HKLM（要管理员）**。改前 `reg export` 备份；落盘 `%ProgramData%\errwatch\dumps`（不用 `%LOCALAPPDATA%`：WER 是系统进程）；默认迷你 dump（`-Full` 切完整）；`-Status` 先查 WER 是否被策略禁用。`test-dump` 6/6 进门禁，含三条守卫（预览不许改注册表 / 没权限不许假装成功 / **HKCU 那条死路不许加回来**）。
26. **A31 B14 结案：不是「过宽」，是「名字写错」** → `dsh`/`electron`/`electron-shell` 在本机 `Get-Process -Name` 全是 **0 个**，DSH 真实 exe 名是「DSH Desktop」（12 个，只有 1 个带窗口）。名单改成 `["DSH Desktop"]`，无窗口子进程崩溃现在也能抓到。副作用评估：子进程正常退出 `exitCode=0` → `normal-exit` → 不进待处理。
27. **A32 `diagnosing` 中间态被当成结论（被 A31 放大的既有缺陷）** → `Sync-Pending` 原来是「边判定边合并」，最终记录（normal-exit）在合并前就被 continue 掉，pending 里留下更早的中间态 → **一次正常退出以「诊断中」挂在待处理、托盘还弹了通知**。改为「先按 id 去重（后写覆盖前写）再判定」+ 中间态不进待处理 + **超 120 秒兜底成 unknown-exit**（防取证途中被杀导致永久漏）。`test-sentinel` X，23/23。
28. **A33 B13 结案：同一目录被枚举两遍** → `%TEMP%` 与 `%LOCALAPPDATA%\Temp` 本机实测就是同一目录，acad/gstarcad 各配了两条。按**展开后的真实路径**去重（企业环境 TEMP 被重定向时不会误合并），新增 `duplicateDirSkips`。`test-recover` T（写三遍仍只有 1 条候选），20/20。

### 2026-10-24 22:0x（用户实测反馈：抓到却「没有收录」）

29. **A34 规则库覆盖缺口** → 用户在界面抓到 `crashprobe.exe / 0xe0434352 / KERNELBASE.dll`，却没有说法（结论「未覆盖」、可信度「无」）。补三层：① 2 条具体规则（`0xe0434352` = CLR 未处理异常、`0x80131623` = FailFast）；② **4 条码段兜底**（`0xe0[0-9a-f]{6}` / `0x8013[0-9a-f]{4}` / `0x8007[0-9a-f]{4}` / `0xc0000[0-9a-f]{3}`）—— 让「没收录的具体码」也能说清属于哪一类、下一步看哪儿，而不是一片空白；③ **补事件 ID 规则**（`core\events.json` 缺 `.NET Runtime/1025` 与 `Service Control Manager/7009`）—— 前两层修完报告仍显示「规则未覆盖 1」，追下去才发现剩下的不是错误码，是事件 ID 没写规则。修完实测报告覆盖率 **100%**（6/6 可给结论、8 个事件 0 个未收录）。**顺带查到一个更有用的东西**：这两个码与同一秒的 `.NET Runtime` 事件成对出现（→1026「未经处理的异常，进程终止」/ →1025「FailFast 请求终止」），那条事件里直接写着异常类型，规则的 `verify` 就教用户去那看。也写清了最容易被误读的一点：这类崩溃的「出错模块 KERNELBASE.dll」只是异常往外抛的通道，**不是 KERNELBASE 坏了**。`test-rules` **6/6** 已进门禁，并且**做过反证**（把段规则换位 → A 与 D 双双 FAIL）；其中一条静态守卫的第一版是**死测试**（前缀比对写错，永远 PASS），正是反证抓出来的。
### 2026-10-24 22:1x（用户看图提的两处体验）

30. **A35 两处「每次都要用户自己点」** → ① **打开主界面就自动扫一次**：把绑在按钮里的扫描拆成 `Invoke-Scan -ShowResult`，自动那次传 `$false`（**绝不弹结论窗**，一开界面就被弹窗拦住比不扫更烦），失败只写状态栏；用 `Timer(500ms)` 在 `Add_Shown` 里启动而不是同步跑（否则第一帧就卡在 5–10 秒扫描上，看起来像打不开）；新增 `-NoAutoScan`。② **监视目标页加「浏览…」**：`OpenFileDialog` 限定 `*.exe`、默认 Program Files、选完**直接加入**。顺带补上一个**没人发现的门禁漏洞**：`-CheckBuild` 上轮就加了，但 `test-settings` 的 I 用例跑的是 `-Check`（不构建界面），所以「引用未定义控件」一直没被覆盖 —— 现在 J 真跑 `-CheckBuild`、K 守自动扫描三约束。`test-settings` **14/14**。验证方式：WinForms Timer 用**屏幕外窗体**实测（500ms 触发 1 次 / 耗时 579ms），不打扰用户。
### 2026-10-24 22:2x（用户看详情区截图提的：内部枚举 / 看不懂解释）

31. **A36 详情区对普通用户不可读** → ① 界面上直接打「观测可信度：OBSERVATION_UNCERTAIN」；②「为什么：找到了崩溃证据（系统记录），按崩溃处理」是在讲**我们怎么判的**，不是**故障本身**；③ 更糟：`evidence` 字段一直有值（`1000 10-24 21:35:29 出错应用程序名称：…`），但**界面从来没渲染过它** —— 用户只被告知"找到了证据"，看不到证据是什么。改成四段：**为什么没了**（有崩溃记录 / 有非 0 退出码 / 什么都没有，三种说法）→ **系统记录原文** → **可能的原因**（按常见度排）→ **你可以这样做**（可执行步骤）。枚举值翻成人话，`core\exit-intent.ps1` 那句「按崩溃处理」也换成说清「证据在哪、局限是什么」。守卫 `test-settings` L：**15/15**，且反证过（把 coverage 直出改回去 → L 立刻 FAIL）。

### 2026-10-24 22:3x（用户看托盘菜单提的：批量处理）

32. **A37 托盘待处理加批量/多选** → 托盘菜单不支持多选，给两条路：**「✓ 清掉这 N 条『进程消失』」**（只清 `unknown-exit`，有崩溃证据的一律不碰、并在标题里写明「保留 M 条崩溃的」；全带崩溃时这一项变成只读的说明文字）+ **「☑ 选择多项处理…」**（勾选窗，崩溃项默认不勾、标注「建议单独看」、带全选/全不选）。新增 `Add-AckBatch`：一次拿 Mutex、一次写多行（逐条调 `Add-Ack` 时 N 条要抢 N 次锁，保留策略持锁时每条等 2 秒，十条能卡托盘 20 秒）。落地前先实测托盘进程的公寓状态（**STA**）和 `CheckedListBox` 勾选读写，确认 `ShowDialog` 可用。`test-tray` Q 改成双场景（全崩溃 → 不许给「清掉」；混合 → 只清 1 条、保留崩溃的），**19/19**。

### 2026-10-24 22:4x（用户连问六件：堆积 / 保留 / 清理 / 目录 / UAC / 旧包）

33. **C6 结案（重要）—— HKLM 的崩溃快照真的能产出 dump** → 用户点了 UAC，`-SelfTest -Elevate` 跑完，`%ProgramData%\errwatch\selftest\dumps\errwatch-probe.exe.24416.dmp` **5.86 MB 真实落地**。三层防线第二层不再是设想。顺带修掉 SelfTest 的一个小残留（子键撤了、空根键留着）。
34. **A38 保留与清理** → 先纠一个误解：**点「不需要处理」不产生任何文件**（只写一行 ack）。新 `core\storage.ps1` 与 `retention.ps1` 按判据分工：前者管磁盘文件（按修改时间），后者管状态数据（按进入终态的时间）。设置新增 `storage{keepDays=7, fileKeepDays=30, copyDir}`；CLI 加 `-StorageShow` / `-Cleanup -Confirm`（默认只预览）；设置窗新增「存储与清理」页；主界面详情区新增「相关目录」两行（崩溃快照 / 救援副本）。保护：只扫自己知道的目录、只删超期的、不跟符号链接、相对路径 `copyDir` 直接拒绝。`test-settings` M1/M2，**17/17**。
35. **旧包清理** → `E:\ai\_dist` 从 **12.91 MB → 2.5 MB**（删掉 au~bj 共 56 个文件 / 10.41 MB），只保留当前 `bl` 和上一版正式交付 `bc`。
36. **存储页把「会保留多久」写成承诺**（用户：「给用户说我们会保留一段时间，可以移动到存储与清理里说明吗」）→ 页面最上方一段**跟着天数输入框实时更新**的说明：已处理记录保留 N 天（未处理的永不清）/ 副本与快照保留 M 天（超过只进「过时」清单，**程序不会自己删**）/ 点「不需要处理」不产生文件。天数用变量插值，不写死（写死就又会说谎）。守卫 `test-settings` N，**18/18**。


### 2026-10-24 22:45–23:0x（新会话接手：P1 第 1、2 项一起结案）

37. **A39 崩溃快照真的布防上去了**（P1 第 1 项）→ `-WatchList -Apply -Elevate` 一次写入 **21 个程序**（全部 `DumpType=1` 迷你 / `DumpCount=5` / `DumpFolder=C:\ProgramData\errwatch\dumps`），写前自动 `reg export` 备份（`LocalDumps-backup-20261024-224614.reg`，254 字节 = 布防前的空状态）。**核验方式是直接读注册表子键**，不信命令行自己打印的 [OK]。
    顺带查清「名单虚高」的事实：21 个里**本机真装了的只有 8 个**（gcad/devenv/winword/excel/powerpnt/ps_launcher/ps_server/DSH Desktop），CAD 装在 `D:\cad\浩辰CAD 2027`（不在 Program Files，所以按目录搜会漏）；没装的照样布防是**有意的**（不触发就不产 dump，用户以后装了不用重新布防）。
38. **A40 dump ↔ 事件接线**（P1 第 2 项）→ 新增 `core\dump-link.ps1` + 哨兵两处接点。判据是 **app + pid 双匹配 + 时间窗口**（退出前 2 分钟 ~ 后 15 分钟），而不是"找最近的 dump" —— 同一程序一天崩几次时，按时间配会把别次的快照张冠李戴，比找不到更糟。
    **两个真实坑**：① `$Pid` 是 PowerShell 只读自动变量，参数写成 `$Pid` 会让整个绑定失败、返回 `$null`，表现成「永远找不到快照」，改成 `$ProcId`；② dump 由 WerFault **异步**写盘，判定那一刻通常还没有 → 加了 `Update-DumpLinks` 每 20 秒回填（补丁必须写**完整事件**，因为 Sync-Pending 是整条替换）。
    UI 详情区新增「这次的内存快照」段，**三种状态分开说**：有（给文件 + 大小 + 说明不会上传）/ 还在找（<2 分钟，说明 Windows 稍后写盘）/ 真没有（说清两条原因：没布防、或被自带崩溃处理器/杀软抢先）。
    文案实现在 **`core\dump-link.ps1` 的 `Get-ErrwatchDumpDetailLines`**（不在 UI 里）—— 两次实现必然漂移，所以加了一条静态守卫：UI 里再自己写一份就 FAIL。`test-dump-link` **16/16** 已进门禁：8 条纯函数正反例 + 3 条文案三态 + 1 条静态守卫 + 端到端回填 + 反证「pid 对不上不许补」+「补丁字段不许丢」。**反证过**：把 pid 匹配关掉 → B/E/J 三处立刻 FAIL。
39. **A41 端到端实测（不是模拟）** → 编译了一个**带窗口**的探针 `errwatch-crashprobe.exe`（后台线程 6 秒后空指针），布防 → 启动 → 真崩。结果：**dump 17,352,812 字节真实落地**，事件最终记录拿到 `verdict=crash-suspected` + `dumpPath` + `dumpBytes` + `exitCode=-1073741819`（0xC0000005）+ `evidence=1001 …`，发现延迟 2346 ms。
    **这次的 dumpPath 是判定时直接命中的**（回填日志为空）—— 说明 2.3 秒的检测延迟下，迷你 dump 已经写完了；回填逻辑是给更慢的情况兜底，由 `test-dump-link` 的合成场景覆盖。
    验证痕迹已清理：撤销探针布防（子键数回到 21）、探针事件 ack 掉、**dump 文件保留**（那是"这条链真的通了"的证据，30 天内可看，随时可删）。
40. **顺手查到的两个「自带崩溃处理器」**（写进 P3）→ `D:\cad\浩辰CAD 2027\senddmp.exe` 与 `C:\Program Files\Streaming Service\parfait_crash_handler.exe` —— 这两个程序**自己就带崩溃转储器**，崩溃时可能先被它们接管，WER 的 LocalDumps 拿不到。目前没实测过谁赢，先记成已知局限，不假装布防一定生效。

### 2026-10-24 23:2x–23:5x（继续：把 16 MB 的 .dmp 读成「卡在哪儿」）

41. **A42 崩溃快照解读**（用户：「接下来最值钱的是从 dump 里直接读出卡在哪个 DLL」）→ 新增 `core\dump-parse.ps1`，**纯 PowerShell 读二进制**，不依赖 dbghelp、不装调试器、不改 dump。读出四件事：异常码、访问动作（读/写/执行 + 目标地址）、**出错模块 + 偏移**、崩溃线程与系统版本。
    **两种场景必须分开说，这是这轮最重要的判断**：
    · **原生崩溃** → 精确给出 `ntdll.dll + 0x165852`（实测造了一次真的：C# 里 P/Invoke `RtlMoveMemory` 往地址 0 写，崩溃地址落在 ntdll 区间内）；如果命中模块是系统 DLL，追加一句「通常不是它坏了，而是传进去的参数已经不对」—— 不知道这句，用户会去找一个根本不坏的 DLL。
    · **.NET 崩溃** → 出错地址在 **JIT 现场编译的代码区**，不在任何模块区间里。这时**明说**「不在任何已加载模块里，是运行时现场编译的代码，不是某个 DLL 文件坏了」，**绝不硬凑一个模块名**（硬凑就是张冠李戴）。
    另外给出「它当时还加载了这些非系统模块」——按**路径位置**判（`\Windows\` 下算系统），不是按名字猜：第一版用 System32/SysWOW64 白名单，结果 .NET 程序的第三方列表全是 `mscorlib.ni.dll` 这种框架库，用户真正关心的插件被挤没影了。
    入口：`pwsh -File errwatch-dump.ps1 -Inspect`（看最新那份）/ `-Inspect -InspectFile <路径>`；主界面详情区在「这次的内存快照」下面多一段「**从快照里读出来的**」。带缓存（同一份 dump 第二次 2ms，首次 11ms —— 只 seek 头部，不读整个文件）。
    `test-dump-parse` **12/12** 已进门禁，用**手工合成的最小 minidump** 测（不依赖机器上恰好有某份真实快照，否则换台机器就绿得毫无意义）；**反证过**：把模块归属关掉 → C 与 I 立刻 FAIL。
42. **A43 顺手修掉一个「自检一直在验错行」的既有 bug**（做 A42 时发现）→ 原来的 `-Check` 自检靠 `$grid.CurrentCell = $grid.Rows[$i].Cells[0]` 触发详情渲染。**没有消息泵时设 CurrentCell 根本不会触发 `SelectionChanged`**，详情框里留着上一行的内容 —— 于是「详情(日志行)/(哨兵行)/(第1行)」三条自检一直在读**错的行**（而且看起来"有内容"，所以没人发现）。实测证据：`Rows[79]` 是 crashprobe、`grid.Rows[79].DataBoundItem` 也是 crashprobe，但渲染出来的是 DSH Desktop。
    修法：把整段渲染体抽成 `function Render-DetailForRow($r)`，事件里调它、自检里也**直调**它。修完四个标签立刻各归各位（日志行→带错误码的那条、哨兵行→哨兵事件、带快照行→真正带 dumpPath 的那条）。守卫：`test-dump-parse` L（渲染必须抽成函数、自检必须直调、UI 必须加载并调用解读）。

### 2026-10-24 23:5x–00:3x（外部审计复检：2 个 P2 + 2 个 P3 全部修完）

43. **A44 审计 P2-1｜门禁在干净解压目录跑不绿（EXIT=1）** → 审计的复现方式很关键：开发目录有真实 state 所以一直是绿的，**审阅者一解压就红**。根因不是测试太严，是 **doctor 的输出结构不一致**：心跳有三种说法，只有「N 秒前」与「停在某时刻」以「哨兵心跳：」开头，「从未跑过」输出的却是一行**没有标签**的 `[未跑过] 没有 sentinel-status.json`。所以修的是**产品**（三种状态统一前缀），不是放宽测试断言。验证方式按审计要求：**解压到干净目录**跑 `tests\run.cmd` → **EXIT=0、零 FAIL**（干净环境里 settings.json / sentinel-status.json / 各 jsonl 全部不存在）。
44. **A45 审计 P2-2｜真实运行数据进了送审包** → 包里 `tray-fallback.jsonl` 含本机真实进程名（QQ / 雷神加速器 / PhanteksNexLinq / DSH Desktop）与真实时间戳；同类还有 `tests\_gate-b12.txt`、`tests\last-run.json`。
    **根因不是"漏写一行排除"**：打包（目录全扫 + 名字黑名单）与基线（扩展名白名单 + 名字黑名单）**各写一份判据**，两套判据必然漂移，而黑名单永远追不上「某个功能新引入的落盘文件」。
    修法按审计建议划硬边界：新增 **`tools\pack-filter.ps1`** 作为唯一判据，两个工具都引用它；再加**白名单** —— 包里允许出现的 `.jsonl/.log/.txt` 只有三个（两个测试夹具 + 包根的 `★ 先看我.txt`），**新文件默认进不了包**。
    守卫 `tests\test-pack-hygiene.ps1` **6/6** 已进门禁，**反证过**：临时造 `brand-new-state-2026.jsonl` → 进不了包（证明不是"恰好这个文件名在黑名单里"）。
    顺带清掉一个审计没点名的泄漏：三份演练/讨论文档里含真实用户名 `C:\Users\<名字>\`，已脱敏成 `C:\Users\<用户>\`（文档保留 —— 它们是"这套东西真跑通过"的证据）。
45. **A46 审计 P3-3｜uninstall 会误杀编辑器** → 注释写「按命令行精确匹配」，实际是**子串正则**：`notepad errwatch-tray.ps1`（开着源码的编辑器）命令行里也含这个串，会被 `Stop-Process -Force` 强杀、**丢未保存内容** —— 恰好违背这个项目最核心的承诺。修法：先按**进程名**限定是 `pwsh.exe/powershell.exe` 宿主，编辑器不是它们，就绝不会被命中。守卫在 `test-pack-hygiene` F。
46. **A47 审计 P3-4｜retention 不清 tray-fallback.jsonl** → 加第 ③ 段按**行时间**清（它没有"终态"概念，只有 `at`）。**修的过程撞出一个真 bug**：`dropIds` 为空时 `Invoke-ErrwatchRetention` **直接 return**，于是「没有待清事件」= 「连升级记录也不清」—— 实测造 2 行 10 天前的记录，返回「删了 0 行、剩 0 行」，文件一个字节没动。现在只写说明、不返回（`$dropSet` 为空时 ①② 天然无操作）。`test-retention` **12/12**（新增 J 清理 / K 反证「保留期内一条不动」/ L 守卫「dropIds 为空时仍要清」）。
    并发代价写清楚：写它的是托盘，用裸 `Add-Content`、不拿锁，所以清理用「写前/写后签名比对」兜底 —— 真撞上最多丢刚追加的一行（后果是该事件下一轮再升级通知一次），比覆盖掉托盘刚写的行更可接受。

### 2026-10-25 00:3x–01:1x（外部审计方向 01：状态机盘点 + 修最狠的一条）

47. **A48 状态机与结果语义盘点**（审计清单 01 项）→ 先证明问题存在、不直接改代码：`tests\audit-state-machine-20261025.md`。方法 = 读契约（`STATE-CONTRACT.md`）+ 读唯一实现（`core\ack-state.ps1`）+ 用 `grep` 列出**全部写入点** + 每个可疑点实跑验证。结论 **6 CONFIRMED / 3 CLEARED / 3 UNVERIFIED**（「没发现」不写成「不存在」，「没验过」一律标 UNVERIFIED）。
    **修掉最狠的两条（同一个写入点）**：
    · **S1（P0）** 契约 §四.2 明写「用户明确确认时显式写 `acknowledged`」，而 `errwatch-recover.ps1` **全文零处**写它。实测：用户逐项核验完 → `rescue=verified`、`lifecycle` 仍是 `open`、`Test-ErrwatchAckTerminal=False` → **事件照样挂在待处理里**，用户做完了最有价值的一步还得再点一次「不需要处理」。
    · **S3** 判据只有两档 `if ($okN -eq $r.verify.Count) {verified} else {user-confirmed}` —— 用户**全按 N**（0 项确认）也会写 `user-confirmed`，被记成「你自己确认救回了」；metrics 再把它算进 `rescueOk`，于是**完全没救回来的一次也给恢复成功率 +1**。
    修法：判据改三档（全通过=verified / 部分=user-confirmed / **0 项=不写**）+ 确认后同时写 `lifecycle=acknowledged`。契约新增 **§八.1**（三档表 + 不变式 8/9）—— **实现改了契约必须同步改，否则又是两份真相**。`test-recover` **21/21**（新增 U），**反证过**：删掉 `acknowledged` 那行 → U 立刻 FAIL。
    **剩下 5 条没修**，记在 ISSUES 的 B-状态机：S2 `verified` 一词三义（改名牵连历史数据）/ S3 剩余统计口径 / S4 三个「完成」概念散落 / S5 终态后写入被连带清 / S6 `expired` 混进决策统计。

### 2026-10-25 01:1x–02:0x（状态机盘点 S3 后半 + S6：metrics 口径）

48. **A49 把「弱信号」从「强信号」里拆出来** → 两处都在 `core\metrics.ps1`。
    · **S3 后半**：`confirmed` 原来 = `user-confirmed ∪ verified`，但 recover 的判据是「自检项**全部**通过=verified / **部分**通过=user-confirmed」—— 于是「部分救回来」被算成「救回来了」。现在 `confirmed` 只认 `verified`，部分单列 `partial`。
    · **S6**：`expired` 是 30 分钟到点**系统自动关**的，不是用户决策，原来却和 `acknowledged` 一起算进「决策延迟」（本文件注释还写着「用户一直不处理就没有样本」）。现在只算 `acknowledged`，自动关闭单报 `expiredAuto`。
    **改前先存了对照数据**，改完实测：决策中位 **28.8 分钟 → 6.8 分钟**（另有 14 条系统自动关闭）、确认救回 **3 次（100%）→ 1 次（33.3%）+ 2 次部分确认**。**这两个数字变小是修复的诚实代价** —— 以前是虚高：一半「决策」没人参与、2/3 的「救回」只是部分核对。
    `test-metrics` **9/9**（新增 J/K），**两个都反证过**。顺带发现原来的 F 用例**从来没造过 `user-confirmed`** —— 这就是 bug 一直没被发现的原因。

### 2026-10-25 00:5x–01:2x（外部审计方向 02：诊断追溯）

49. **A50 历史结论可追溯、可区分、尽可能可复现** → 新增 `core\diagnosis-trace.ps1` + `errwatch-trace.ps1`，并在 `errwatch.ps1` 的结论段接线（`$diags` 完整后写一次）。
    **规则集指纹覆盖 6 个来源**：`rules.json` / `rules-sigma.json` / `events.json` / `apps.json` / **`noise.json`** / **`field-mapping.json`**（后两个是审计没点名、但确实会改变结论的）。完整 SHA-256 不截断；任一份变了指纹就变。实测改一个字节 `noise.json` → `29D0D7B0…` → `F7C4D154…`。
    **两种能力分开**：`errwatch-query.ps1` 仍用当前规则重算；`errwatch-trace.ps1` 只回答「当时是什么」。trace 只追加、永不改写。
    **去重键** = 「事件主题键 + 规则集指纹」：规则没变不重复写，规则变了写新一批（新旧并存 = 重算）。实测 16 → 16 → 16 稳定；改规则后 16 → 32。
    `test-diagnosis-trace` **12/12** 进门禁（T1–T6 全覆盖 + 反证）。
    **两个前置缺口（如实记录，没绕过去）**：
    · `subject.eventId` 是 **Windows EventID（1000）**，不是唯一标识 —— 整条链路没有 EventRecordID。所以只能做到「同一类事件」级，**不能**声称精确到某一次。
    · 诊断对象的 `explanation.ruleSource` 存的是**出处说明文本**（"本机实测（.NET Runtime/1026）"），**不是文件路径**。所以「单条规则内容哈希」现在算不出来：记录里 `ruleContentHash` 为空、`contentLocatable=false`、`reproducible=false` —— **不伪造**。
    **踩坑两条**：① `[ordered]` 字典的 `PSObject.Properties[...]` **恒为 null**，用它判断导致每条诊断都 continue（表现是「代码在、条件真、指纹算好了、就是不写」）；② 去重键读回时写成 `$old.eventId` 而写入用 `subjectKey`，键不一致 → 第二次跑又追加 16 条。

### 2026-10-25 02:0x–02:4x（接手第一件：补 EventRecordID，A51）

50. **A51 T1 结案：采集链路补 EventRecordID** → `history.jsonl` 的 `id` 是 **Windows EventID**（1000 = 应用崩溃），不是唯一标识；同秒两次崩溃会被去重键合并，追溯到不了「某一次」。四段一起改：
    · **采集层**：记录加 `recordId = [string]$c.RecordId`；去重键抽成 `Get-EwHistoryKey`（**唯一实现**，写入与读回两侧都调它）—— 有 recordId 用 `rid:{provider}|{id}|{recordId}`，没有则**逐字退回旧键**（否则老 history 会被整份重写一遍）。
    · **契约层**：`New-ErrwatchDiagnosis -RecordId`，`subject.recordId` 只有两种合法值（具体记录号 / 空），**空 = 不是单次事件**，不许有第三种。
    · **追溯层**：`Get-ErrwatchEventSubjectKey` 有 recordId 时追加 `#rid:N`，空时与旧版逐字相同；`New-ErrwatchDiagnosisTrace` 落盘 `subject.recordId`；`Get-ErrwatchDiagnosisTrace -RecordId` 过滤。
    · **查询层**：`errwatch-trace.ps1 -RecordId <N>`，并显示「记录号」—— `-Event 1000`（这一类）与 `-RecordId N`（这一次）是两种粒度。
    **聚合诊断（§4/§5 按来源分组）刻意不传 recordId**：一条结论对应 N 次事件，硬塞首条记录号就是伪造。
    **实测**：新增 8 条记录全带唯一 recordId（27943/27946/27949/27969/27978/27981/27800…），**35 条老记录一个字节没动**；再跑一次 → 历史库 +0、traces 24→24（键稳定）；`crashprobe.exe` 由「每类一条」变成「3 条带记录号 + 3 条老的并存」（历史不改写）；`-RecordId 27949` 精确回 1 条，查不存在的号回 0 条并明说「不许用时间邻近去猜」。
    `test-record-id` **9/9** 进门禁，**两个反证**：去掉去重键里的 recordId 分支 → A FAIL；subjectKey 不带 recordId → F/H FAIL。
    **顺手堵掉一个同形状的泄漏**：手工备份 `history.jsonl.bak-before-recordid` 既不叫 `history.jsonl` 也不匹配 `*.bak`，会带本机真实进程名进送审包 → `pack-filter` 加 `*.bak-*` + `test-pack-hygiene` C 加第三条探针（反证过），备份本体已移出项目目录。

### 2026-10-25 02:4x–03:1x（接着做完 T2：规则条目定位，A52）

51. **A52 T2 结案：让「单条规则内容哈希」算得出来** → 缺口原貌：`explanation.ruleSource` 存的是**出处说明**（`handwritten` / `本机实测（.NET Runtime/1026）`），**不是文件路径**；而 `rules.json` 的 34 条规则**没有 id**。于是索引不到条目 → `ruleContentHash` 恒空、`reproducible` 恒 false。
    **一层一层接起来**（缺一环就等于没做）：
    · **加载层** `Import-CoreRulesFile` 用 `for` 而不是 `foreach` —— 记下**文件里的原始下标**（中间被丢弃的规则不能让后面的全部指错）；`File` 只在规则落在项目根下时才标（外部路径标了会让 trace 声称"能复现"而实际取不回来）。
    · **命中层** `Translate` / `TranslateEvent` / `TranslateEventRecord`（field 分支）带出 `RuleFile` / `RuleIndex` / `RulePat`；`TranslateForApp` 三条分支全部透传。`events.json` 的条目加载时挂 `_ewFile` / `_ewIndex`（`_ew` 前缀 = 内部标记，不碰它自己的字段）。
    · **契约层** `explanation` 新增 `ruleFile` / `ruleIndex` / `rulePattern`，**`ruleSource` 语义一律不动**（还是出处说明）——换语义会让所有既有读法悄悄错掉。适配层 `New-ErrwatchDiagnosisHit` 两种形态都认（`RuleFile` 或 `_ewFile`）。
    · **定位算法**（`Get-ErrwatchRuleContentHash`）顺序改成 **Index（带 pattern 校验）→ Pattern → Id**：下标最精确但会随文件增删**漂移**，所以用 pattern 校验它；`events.json` 同一个 id 可以有多个 provider，所以 Id 排最后。
    · **判据修正**：`contentLocatable` 从「文件在不在」改成「哈希算出来了」—— 以前「文件在、下标指不到条目」也算可定位，是个假绿灯。
    · **接线** `errwatch.ps1` §7b 把 `explanation.ruleFile` 传给 `-RuleSource`，`ruleSource` 传给 `-RuleNote`。`[int]` 强转会把空值变 0（= "命中第 0 条"）→ 显式用正则判数字。
    **实测（副本目录跑真实采集，不污染生产 traces）**：16 条 trace 里 **14 条可定位、14 条 `reproducible=true`**；下标逐个核对过：`rules.json[9]=0xc0000005|c0000005`、`[11]=0x80131623`；`events.json[33]=SCM/7009`、`[22]=BTHUSB/12`、`[29]=.NET Runtime/1026`。**没定位的 2 条都是应该不定位**：`ps_service_launcher/0xc0000409` 命中的是 `apps.json` 的**嵌套**规则（内容哈希定位只认顶层数组，不伪造）、`Microsoft Office/2001` 是 `unknown`（根本没有规则）。
    `test-rule-locate` **9/9** 进门禁（A 加载下标 / B+C 两个命中源 / D 契约与 ruleSource 语义 / E 落盘可复现 + F 反证改内容哈希必变 / G 定位不到不许假装可复现 / H 静态守卫「拿 ruleSource 当路径」的接线错误模式 / I 文案区分「旧记录当时没记」与「新记录定位不到」）。

### 2026-10-25 03:1x–04:0x（T2 收尾时撞出的真 bug：abandoned mutex 会让看护静默消失，A53）

52. **A53 `AbandonedMutexException` 全线漏处理**（做 T2 时并行跑两份门禁撞出来的）→ 现象：干净目录那份门禁的互斥锁测试 B 抛 `The wait completed due to an abandoned mutex.`。**根因不是测试偶发**：`.NET` 在「持锁线程异常终止」时让 `WaitOne` 抛 `AbandonedMutexException`，**而锁其实已经归调用方**。五处持锁点全都当成「没拿到」：
    · **哨兵**（最恶劣，P1）：打印「哨兵已经在运行了」并 `exit 0` —— 明明没有任何哨兵在跑，**看护静默消失**，用户以为还在看护。而这个工具监控的正是崩溃，「持锁进程崩掉」是日常，不是假设。
    · **retention**：每轮都跳过 ACK 清理 → `tray-acks.jsonl` 只涨不清。
    · **托盘** Add-Ack/Add-AckBatch：$got=false 就不 Release，托盘是常驻进程 → 这把锁被它一直占着。
    · **fix**：拒绝修复 —— 而「上一次修复崩了」正是最需要再修一次的场合。
    · **report**：拒绝写历史库。
    修法：五处各加一条**在前面**的 catch（`catch [System.Threading.AbandonedMutexException] { $got = $true }`），通用 catch 保留在后面。**实测过 PowerShell 的 typed catch 能捕获它**（异常被包成 `MethodInvocationException`，但类型匹配会看 InnerException）。
    **造 abandoned 的三个必要条件**（前三版用例都在这翻车，值得记住）：① 子进程必须**真拿到锁**再杀（用 flag 文件确认，别靠固定等待）；② 必须强杀；③ **本进程必须同时持有一个句柄**，否则子进程退出时内核对象引用归零、直接销毁，abandoned 状态跟着消失（真实现场天然成立：托盘常驻 + 哨兵/保留策略都打开同一把锁）。
    `test-lock` **6/6**：新增 D（abandoned 下 retention 必须照常清理）、E（静态守卫：每个持锁点都要有 AbandonedMutexException，**只看代码行不看注释**）、F（**真实场景**：abandoned 下用 `-DurationSec 2 -InstanceName -StateDir` 真起一次哨兵，断言不打印「已在运行」且能正常启动）。
    **两个反证都做过**：改掉 retention 的 catch 类型 → D/E 双红；改掉哨兵的 → E/F 双红。
    **F 的第一版是死测试**：用 `-Once` 跑哨兵 —— 而 `-Once` 在 1439 行就提前退出，**根本不经过单实例锁（1474 行）**，永远绿。是反证把它抓出来的。

### 2026-10-25 04:1x–05:0x（用户提出：崩溃后程序自己回来了，那条事件该自动归位，A54）

53. **A54 「归位」：崩溃后程序自己恢复运行 → 自动离开待处理**（用户原话：「崩溃后自动重启进程我想的理想化啦 但是我觉得依然有价值 看看社区方案？先不管啦 接着做」+ 追问「进程存活 60 秒，如果用户自己退出了呢」）
    **做了什么**：新增 `core\recovery.ps1`（纯函数）+ 哨兵接线（每 30 秒一次）。判定成立时写 `rescue=auto-recovered` + `lifecycle=acknowledged`，并**追加一条 `verdict=recovered` 的事实记录**（不改写原崩溃事件）。
    **判据七条**（宁可多留一条，不许误归位 —— 误归位会让真崩溃被静默吞掉）：
    · 只对 `crash-suspected`（`unknown-exit` = 用户关的/被强杀，不是崩溃恢复）
    · 24 小时内
    · 崩后**没有再崩过**
    · **多实例应用不归位**（崩时还有兄弟实例在跑 → 分不清是不是它恢复了）
    · **崩后新实例正常退出（退出码 0）也算恢复** —— 这条是用户追问「如果用户自己退出了呢」补的：用户「崩了→重开→用一下→自己关掉」永远凑不满 60 秒，那条崩溃会一直挂着；而「自己关的」恰恰是「它当时好好的」的硬证据。反过来 `unknown-exit`（可能被强杀/又崩了）**不**算
    · 或者：现在的进程是**崩后新起**的实例（startTime > 崩溃时间；拿不到启动时间不归位）
    · 且已活 ≥ 60 秒（刚起来 3 秒可能是「又要崩」的前奏）
    **明确不做自动拉起**（2026-10-25 已实测四个坑并评估，结论见 P1-7）：主进程崩了之后 `CommandLine` 拿不到了，无脑重启会制造崩溃循环、覆盖 `.sv$` 等救援证据、抢 CAD/Office 许可。
    **端到端实测**（临时 StateDir + 独立 InstanceName，不碰生产）：手工注入一条 `crash-suspected`（notepad）+ 真起 notepad → 哨兵第 2 次检测（61 秒）判归位：事件 `crash-suspected → recovered`（"已稳定 1 分钟，窗口正常"）、acks 两条（`rescue=auto-recovered` / `lifecycle=acknowledged`）、`sentinel-pending.json` = `[]`、`sentinel-recovery.jsonl` 一行日志、`sentinel-error.log` 空。测完清理（杀 notepad + 删临时目录）。
    **契约同步**：`STATE-CONTRACT.md` 的 `rescue` 取值表加 `auto-recovered`（写者是 sentinel）、不变式 2 补第二处例外、并写明「它证明程序能用了，**不证明**崩溃原因查清了」。`core\ack-state.ps1` 的 `Get-ErrwatchRescueLabel` 加「程序自己恢复运行了（自动归位）」；UI 的 `Get-SentinelHuman` / `Get-SentinelWhy` / `Get-SentinelHints` 三条都加了 recovered 分支（**不许落进「什么都没留下」那句 —— 它当时确实有崩溃证据**）。
    **metrics 口径**：`auto-recovered` **不算救援尝试**，从 attempts 分母里排除、单列 `autoRecovered` —— 否则程序自己好了会把救援成功率稀释成假数字（与 A49 的 S3 同一类错误）。
    `test-recovery` **19/19** 进门禁；**两个反证**：去掉「正常退出也算恢复」→ M FAIL；去掉多实例收窄 → P FAIL。
    54. **同一条的用户补充：归位不代表没问题，主页面必须显示** → 发现一个**既有缺陷**：主界面所有哨兵行的「状态」列**一律写「哨兵观测」**，而且合并行时（`$r.状态 = '哨兵观测'`）会把判定标签**再覆盖一遍** —— 主页面永远只有一种状态，等于没显示。改法：
    · 新增 `Get-SentinelStateLabel`（唯一实现）：崩溃 / 已恢复 / 进程消失 / 自关；合并行时**保留**该标签（不再覆盖）。
    · 列表「人话」：`recovered` 行改成「程序崩后自己恢复运行了；**这次恢复正常，但崩溃原因还没查** —— 反复出现要查」（不许写「不用处理」）。
    · 详情区三段（为什么 / 可能原因 / 可以这样做）全部按「恢复了 ≠ 问题解决」重写。
    · 首页概览新增 `⚑ 崩溃后已恢复运行 N 条（原因未查，反复出现要查）`，**且不依赖扫描结果**（走"还没有扫描结果"分支时也显示）—— 统计用 `core\recovery.ps1` 的 `Get-ErrwatchRecoveredCount`（24h 窗口、按 id 去重）。
    **验证方式**：在**干净目录**造 4 条事件（崩溃→已恢复 / 进程消失 / 自关）跑 `-Check` —— 概览出现「已恢复运行 1 条（原因未查…）」、状态列变成 **3 种**（选「崩溃」= 1/3），测完清理。守卫 `test-recovery` S：状态列不许再写死、人话必须含「崩溃原因还没查」、详情必须含「不代表问题解决」、概览必须有统计与「原因未查」。
### 2026-10-25 01:2x–01:3x（P1 剩余第 1 项结案：事件日志的崩溃行也能指出快照，A55）

55. **A55 Windows 日志行（无 pid）也能指出崩溃快照** → 缺口原貌：`Find-ErrwatchDump` 靠 **app + pid** 匹配，而 `history.jsonl` 从事件 1000 采集来的记录**没有 pid**（事件消息里只有应用名/模块/异常码）→ 那些行永远显示不出快照，**即使文件就在目录里**。
    **桥怎么搭**：哨兵抓崩溃时**有 pid**（它监视着进程），也已经用 pid 找到 dump 并写进 `sentinel-events.jsonl`。所以把两边**同一次崩溃**对上就行：同 exe 名（`ConvertTo-ErrwatchDumpAppName` 自动补 `.exe`，解决 `gcad.exe` vs `gcad`）+ 时间差 ±5 分钟 + 该哨兵事件确实带 `dumpPath`。**不**用「找最近一份 dump」——同一程序一天崩几次时按时间就近配会张冠李戴。
    新增 `core\dump-link.ps1` 的 `Find-ErrwatchDumpForSnapshot`（纯函数），两处消费：
    · **主界面详情**（Windows 日志行）：`$script:SentinelRaw` 缓存原始事件（必须收集**每一条**，含同 id 的回填记录 —— `dumpPath` 是后来回填到后写那条里的），文案复用 `Get-ErrwatchDumpDetailLines`（三态与哨兵行完全一致）。
    · **报告 §1**：每条崩溃下加 `- **内存快照**：路径（X MB）…不会上传`；2 分钟内没有则说「还在等 Windows 写盘」。
    **踩到的坑**：报告最初用 `-Tail 500` 读哨兵事件，实测**一条快照都显示不出来** —— 22:56 那条带 dumpPath 的记录正好在 500 行之外。改成 `-Tail 2000` + 3 天过滤，并在测试里加了守卫（不许再退回 500）。
    **实测**：真实数据里 43 条 history 崩溃行中，`errwatch-crashprobe.exe`（10-24 22:56:50）成功命中 `errwatch-crashprobe.exe.20248.dmp`（差 **0.1 分钟**，就是 A41 那次真崩溃）；其余（code.exe / notepad++ / errwatch-probe）无 dump —— 正确（没布防或 dump 在别处）。干净目录造 1 条 history + 1 条带 dumpPath 的哨兵事件 → `-Check` 的「详情(日志行)」末尾出现「这次的内存快照：…（17 MB）」。重跑报告 → §1 出现真实 `16.55 MB` 那行。
    `test-dump-link` **21/21**（新增 M 桥接命中 / N 四种不借（时间外/别的程序/没 dumpPath/空输入）/ O 多条取最近 / P+Q 静态守卫），**反证过**：去掉 app 名规范化 → M 与 O 双红。
### 2026-10-25 01:4x–02:1x（用户四点核查：关联强度分级 + 两个既有错误，A56）

56. **A56 「快照属于哪次崩溃」这件事必须分级，不能拿时间窗当证明**（用户逐条追问，每一条都命中了真问题）
    **核查结论（全部用本机数据验证，不是推理）**：
    · **T1 的 recordId 并不在「两条记录」里**：`history.jsonl` 43 条中只有 **8 条**有（A51 之后采集的）；`sentinel-events.jsonl` 1404 条里 **0 条**有 `evidenceRecordId`（那个字段 A56 才加，只有新崩溃才会带上）。所以「按 RecordId 对死」这条路**目前对历史数据 0 命中**。
    · **哨兵存的 evidence 只是格式化文本**：`1000 10-24 23:13:35 出错应用程序名称： notepad++.exe…`、`1001 10-24 22:56:52 故障存储段 2051154488769383202…` —— 只有事件 ID + 时间 + 首行，**没有 RecordId、也没有 WER 报告 ID**（1001 的 P1 从来没解析过）。
    · **dumpPath 是「当场尽力 + 事后回填」两段**：判定那一刻 `Find-ErrwatchDump`（app+pid 校验）查到就写；没查到由 `Update-DumpLinks` 每 20 秒回填并盖 `dumpLinkedAt`。实测本机唯一那条是**当场拿到**的（事件时间 22:56:53，无 dumpLinkedAt）—— 迷你 dump 写得比进程消失只晚约 1 秒。
    · **dump-parse 早就有流目录解析**（header + `$streams`），加 MiscInfo **不是重复劳动，而且实测证明了必要性**（见下）。
    **改了什么**：
    ① 哨兵 `Get-ExitEvidence`：候选改为按「事件 ID 优先级（1000 优先，那是采集链路采的那一类）+ 离现在最近」排序（原来是取**第一条**含 appName 的 —— 同程序反复崩时会配到别的那次），并保存 `RecordId`；事件里新增 `evidenceRecordId` / `evidenceEventId`。
    ② 桥接 `Find-ErrwatchDumpForSnapshot` 加 **强度分级**：`exact`（RecordId 对死 / dump 内部 pid 与这次进程一致）vs `weak`（只做到同程序+时刻相近）。**弱关联的文案不许写成「这一次的快照」**，报告与界面都加了标题区分。
    ③ **硬排除**：双方都带 RecordId 但不相等 → 直接丢弃（不是降级）——「明确不是同一次」不能当「可能同一次」。
    ④ **交叉验证**：`-CrossCheck` 读 dump 的 MiscInfoStream，pid 与事件 pid **不一致就丢弃**；一致则升级为 exact。
    ⑤ **修掉一个既有错误**：`dump-parse.ps1` 的流编号映射把 **15 标成 MemoryInfoList** —— 错了，**15 = MiscInfoStream、16 才是 MemoryInfoList**。名字错不只是显示难看：会让人以为「没有 MiscInfo 流」而放弃交叉验证。
    ⑥ **报告漏加载 `core\dump-parse.ps1`** → 交叉验证静默跳过 → 实测报告把 A41 那份 16.55 MB 的真快照显示成「不能确认就是这一次」。补上加载 + 加守卫。
    **实测（最有说服力的一条）**：A41 那条**老数据**（哨兵事件没有 evidenceRecordId、只有时间窗可用）经交叉验证后读出 dump 内部 **pid=20248**，与事件 pid、WER 文件名 `.20248` 三者一致 → 升级为 `exact`，报告据此写成「关联依据：快照内部的 pid 与这次崩溃的进程完全一致（两个独立来源对上）」。
    **MiscInfo 的三个「不可用」判据**（用户明确要求，缺一个就会把 0 当真 pid）：没有该流 / `Flags1` 未声明对应位 / pid 读到 0（0 不是合法进程号）。另外边界按「实际读的 16 字节」卡，不按结构声明大小卡（SystemInfoStream 就踩过这个）。
    `test-dump-link` **27/27**、`test-dump-parse` **13/13**；**三个反证**：去掉 Flags 校验 → S 红；去掉弱匹配的 RecordId 硬排除 → U 红；去掉 app 名规范化 → M/O 红。
### 2026-10-25 02:2x–02:5x（P1 新第 1 项结案：反复崩溃压过归位，A57）

57. **A57 「反复崩溃」不许被「归位」掩盖**（用户：「归位不代表没有问题」的另一半）→ 缺口：A54 的每条判据都只看「这一次崩完有没有恢复」，于是**同一程序一天崩 5 次、每次都被归位**也完全符合 —— 用户看到一串「已恢复」，实际是复发（驱动/插件/数据损坏的典型形态）。
    **判据**（`core\recovery.ps1`）：同一 app 在 **6 小时**内 `crash-suspected` ≥ **3 次** → 不再自动归位，`Code=repeat-crash`，理由写「同一程序在 6 小时内崩了 N 次 —— 反复崩溃，不自动归位（每次都恢复也不等于原因查清）」。
    **计数在哪算**：判据是纯函数不读文件，所以由 `Select-ErrwatchRecoveryBatch` 拿着全部事件算好传进去（`-PriorCrashCount`）。窗口外的老崩溃不计数 —— 昨天的 3 次不妨碍今天的第 1 次归位。
    **界面**：`Get-SentinelRows` 顺便统计「近 6 小时每程序崩溃次数」，人话列对 ≥3 次的崩溃行追加「**6 小时内第 N 次崩溃** —— 反复出现说明原因没查清，别只靠重启」。只对 `crash-suspected` 加，不动其它状态（不打扰偶发）。
    **取舍**：托盘没改 —— 它只显示 pending 里的条目，而这里的事件本来就留在 pending（不归位就不离开），点开详情能看到完整解释。改托盘文案要动它的渲染链，收益不成比例。
    `test-recovery` **21/21**（H 从「3 条一起归位」改成 2 条 —— 3 条现在按重复崩溃处理；新增 X 重复崩溃不归位 + Y 窗口外不计数），**反证过**：把判据改成 `if ($false)` → X 立刻红。
### 2026-10-25 02:5x–03:2x（P1 第 2 项结案：状态机剩余三条 S2/S4/S5，A58）

58. **A58 S2 / S4 / S5 一起结案**（都属「状态语义」，一次改完一次验）
    · **S2 三个 `verified`**：先确认了**数据层不会混淆** —— 它出现在三套互不相干的命名空间（`rescue` 维度 / 规则的 `verifyStatus` / `fix` 的动作结果），不共享字段。混淆只发生在「人读输出」时。所以**不改任何值**（改历史值要迁移，风险远大于收益），改为加一份**术语表** `Get-ErrwatchVerifiedMeaning`（唯一实现）+ 契约 **§八.2**：三者各一句带限定的说法，约束是「输出里出现 verified 必须带语境，禁止裸写」。
    · **S4 三个「完成」**：新增 `Get-ErrwatchStageText` —— 把 `notify / progress / rescue / lifecycle` 合成一句「走到哪一步了」（`还在待处理 · 程序自己恢复了 · 取证结束 · 通知已发`）。优先级刻意按「用户最关心的先说」：是否已结束 > 来没来过 > 证据收完没 > 通知发没发。主界面详情区（哨兵行）新增「进度：…」一行。
    · **S5 终态后被连带清**：先**量化**了本机影响 —— 1569 条 acks、38 个终态 id 里只有 **1 条**在终态后还有写入。影响很小，但判据本身是错的（它按 `lifecycleAt` 清，会把"终态后确实发生过的动作"一起抹掉）。修法：取「终态时间」与「最后一次写入」的**较晚者**计时 —— 终态后没人再写时与原来完全相同（**不推迟**正常清理）。契约 §九 同步。
    **顺带查出一个门禁漏洞**：改 S2 时 `test-ack-state` 的 J 用例红了 —— 它断言 `verified → 已核验`，而实现早在 A48/B5 就改成了「你逐项核对过」。它红了很久没人知道，因为 **`test-ack-state` 从来不在 `run.ps1` 里**（正是项目记过的「门禁只拦部分专项 = 门禁撒谎」）。现在修正断言并**纳入失败判定**。
    `test-ack-state` **12/12**（新增 K 三个 verified 必须互不相同 / L 进度摘要四种组合）、`test-retention` **13/13**（新增 M 终态后写入按最后写入计时），**反证过**：去掉 retention 的 lastAt 判据 → M 立刻红。
### 2026-10-25 03:2x–03:5x（P1 第 3 项结案：B9「证据不回填到结论」，A59）

59. **A59 B9 结案 —— 但缺口的实际形态和审计写的不是一个**：审计原话是「事件级 coverage 不回填」。核对代码后：
    · **coverage 本来就不该回填**：它描述的是「当时看没看到」，盲区是历史事实，不会因为后来找到证据而变。回填它反而是伪造观测史。
    · **真正缺的是「证据没回填到结论」**：`Update-DumpLinks` 事后找到 dump 时只补了 `dumpPath/dumpBytes`，**没有改 `verdict`** —— 一个判成 `unknown-exit`（判定时没有崩溃证据）的事件，后来明明找到了这次崩溃的快照，结论仍停在「进程消失」。两个实际后果：① 主界面状态列显示「进程消失」而不是「崩溃」；② 托盘的「清掉这 N 条『进程消失』」会把它当噪音**批量清掉** —— 而那条保护的全部意义就是「有崩溃证据的不许被顺手抹掉」。
    **修法**：新增 `Get-ErrwatchVerdictUpgrade`（纯函数，`core\dump-link.ps1`）：只把 `unknown-exit` + 有快照 升级为 `crash-suspected`，并写 `verdictBefore / upgradedAt / upgradeReason` 留痕（审计能看出从什么改成什么、凭什么）。`normal-exit` / `user-closed` 与快照矛盾属「崩溃时自己 exit(0)」的已知罕见局限，**不在这里硬掰**（宁可显示矛盾，也不改用户可见判定）；`coverage` 不动。
    **踩到的坑（值得记）**：K 用例第一版把断言写成「`unknown-exit` 或 `crash-suspected` 都算过」—— 反证时把升级接线关掉，它**照样绿**，是个死断言（守卫留了「两种都接受」的退路）。收紧成「fixture 里有 dump → 必须已升级」后反证立刻红。
    `test-dump-link` **29/29**（新增 B9 纯函数五种输入 + 端到端留痕 + K 断言收紧），反证：关掉升级接线 → K 红。
### 2026-10-25 04:0x–04:3x（用户验收回来：C4 结案 + 补了一个门禁大洞，A60）

60. **A60 门禁补全：31 个专项里原来只跑 26 个**（用户点完验收清单后核对发现）
    **用户验收结果**：**39 项全部通过**；两个「未见」都是设计如此 —— 1.3 本机暂无「崩后恢复」案例；**6.4 多选处理没出现，因为当时待处理只有 1 条**（他的猜测完全正确）。
    · **6.4 修法**：`openList.Count -gt 1` 的条件不动（1 条时多选没意义），但 **1 条时在菜单里放一个禁用项「（只有 1 条待处理，不需要批量）」** —— 原来整块消失，用户会以为功能没了。`test-tray` S 守住。
    · **顺带盘点门禁覆盖率**：`tests\` 下 **31 个**专项，`run.ps1` 只跑了 **26 个** —— 没进去的包括 **`test-sentinel`（23 项，测的正是这个项目的心脏）** 和 **`test-tray`（20 项，测用户真会点的菜单）**。它们一直绿，但**没有任何东西保证**（正是项目记过的「门禁只拦部分专项 = 门禁撒谎」；上一轮 `test-ack-state` 的过时断言就是这么活了很久）。
    · **补进来四个**（实测耗时）：哨兵 52s + 托盘 21s + 恢复机会 14s + 启动链 12s ≈ +99 秒，门禁从 ~6 分钟到 ~8 分钟。换来的是核心回归每轮都跑。
    · **唯一不进的是 `test-verify-package.ps1`**（49 秒）：它验的是发布链产物（需要真实 zip、会留临时工作区），属于 `make-release` 之后的检查，不是每轮门禁该干的 —— 理由写进 `run.ps1` 注释，避免下次有人"补全"时误加。
    **结果**：门禁现在跑 **30/31**，EXIT=0（工作区与干净解压目录各一遍）。
### 2026-10-25 10:4x–11:2x（用户早上开机反馈：托盘超时提醒刷屏，A61）

61. **A61 托盘「超时未处理」被不确定事件刷屏**（用户原话：「一开机都是崩溃超时提醒 好烦啊 这个是什么呢」）
    · **根因两条**：① `ui-ignored.json` 只有主界面读（A34 建的是「程序||错误码」，给 WER 崩溃行用），托盘 `Get-ErrwatchOverdueEvents` **完全不看它**；② pending 里 DSH Desktop 每几秒一个启动器 `exit 1`（coverage=OBSERVATION_UNCERTAIN、siblingInstances=9~11），30 分钟后在托盘每 5 秒轮询里反复触发「N 条已超过 30 分钟」气泡 —— 开机时 pending 跨会话留存，所以一开机就成串。
    · **修法**：`core\fallback.ps1` 新增纯函数 `Filter-ErrwatchUncertainNoise`（剔除 coverage=OBSERVATION_UNCERTAIN 且 siblingInstances>0）；托盘两处接上（主循环 / `-Check` 自检）。**只减提醒，不改采集**：事件仍在 pending / 主界面 / 审计里可查。
    · `test-fallback` 加 G 组 5 条判据（uncertain+sibling 剔除 / uncertain+0 保留 / MONITORED 保留 / pending 本体不变 / 空输入不抛）+ F 加静态接线守卫（托盘没接上就红）；基线已重刷；门禁 **FAIL 0**（WARN 3 是 `rules.json` 既有措辞，与本项无关）。实测 `-Check`：「超时未处理：无」。
    · 已用 `errwatch-restart.ps1` 重启哨兵+托盘生效（心跳正常，eventsTotal 继续增长）。

### 2026-10-25 11:3x–12:0x（P1 第 4 项：1001 的 WER 报告 ID，A62）

62. **A62 1001 报告 ID 进 evidence**（A56 的延续：用户问过「1000 与 1001 是同一次，凭什么」）
    · **缺口**：`Get-ExitEvidence` 存了 `RecordId` 和格式化文本，但 1001 的「报告 ID」从未解析 —— 「同一次」只剩时间窗一个凭据。
    · **修法**：新增 `core\wer-info.ps1` 纯函数 `Get-ErrwatchWerInfo`（解析 报告 ID / 故障存储段 / P1 / 事件名称，中英双系统，拿不到一律 $null）；哨兵从**时间最近且 ≤120 秒**的 1001 取报告 ID 与存储段 → 事件新增 `evidenceReportId` / `evidenceStoreId`。120 秒窗防「反复崩溃时把别一次的 1001 配给这次」。
    · **实测**（本机真事件）：`best=1000`（rec 28016, 02:25:30）+ 同次 `1001`（rec 28018, 02:25:42）→ 报告 ID `dcb127eb-eb55-40d5-b3c0-8786bc939498`、存储段 `2006949791625634474`。
    · **踩坑**：事件名称正则漏 `(?m)` —— `$` 只匹配文本结尾，真实中文文本下 `EventName` 恒为空；G 组测试当场抓到。
    · **第二小步（同日）**：UI 详情显示「WER 报告 ID」+「WER 报告目录」；`core\wer-info.ps1` 加 `Get-ErrwatchWerReportPath`（解析「可在此处获取这些文件」路径、去 `\\?\` 前缀），哨兵写 `evidenceWerReportPath`。**两个实测结论**：① 报告目录名最后的 GUID ≠ 报告 ID（dcb127eb-… 的目录是 05d595e7-…），不能按 ID 反查；② 该目录 `Test-Path=True` 但 `Get-ChildItem` 被拒（Access denied）—— UI 判定改用「真列一次目录」，读不到就写「需要管理员才能打开」。
    · `test-wer-info` **7/7**（A–G，新增 F 报告目录路径 / G 接线守卫），`test-sentinel` **23/23**，门禁 **FAIL 0**（WARN 3 是 rules.json 既有措辞）。

### 2026-10-25 12:0x–12:2x（P1 第 5 项：副本目录引导，A63）

63. **A63 副本目录没设时的引导**
    · **缺口**：`storage.copyDir` 为空时，设置页只有一句灰字静态说明，备份完也不提示 → 程序不知道副本在哪、永远无法清理（用户问过「恢复文件堆积怎么办」）。
    · **修法**：① 设置页「存储与清理」说明按 copyDir 是否为空分支（空时「⚠ 还没固定副本目录…建议现在点「浏览…」固定一个。」）；② `errwatch-recover.ps1` 保存副本成功且 copyDir 为空时，在 notes 里追加固定提示（用户刚看到「副本已保存」的那一刻最相关）。
    · `test-settings` 加 H 组 4 条静态守卫（文案 + 分支条件 + recover 读 settings.copyDir），**19/19**；门禁 FAIL 0。

### 2026-10-25 12:2x（门禁 WARN 3 清零，A64）

64. **A64 门禁 WARN 3 清零**：`rules.json` 三条规则的 `do` 不以动词开头（`0xe0434352`「① 每次做同一件事就崩…」、`0xe0[0-9a-f]{6}`「事件查看器 →…」、`0xc0000[0-9a-f]{3}`「按完整错误码搜一次…」）。改成「先看崩溃的规律：①…」「先在事件查看器…」「查完整错误码确认…」——**只动文案开头，不动 pat / verify / 数组顺序**。`lint-human` **FAIL 0 / WARN 0**（原 WARN 3），`test-rules` **6/6**（34 条规则 + 事件规则），门禁 FAIL 0。门禁从此可以 `-Strict` 运行而不被既有 WARN 挡住。

### 2026-10-25 12:25（门禁偶发红：test-lock F 加固，A65）

65. **A65 test-lock F 用例不稳（不是回归）**：12:25 门禁 **exit 1**，唯一红项「互斥锁测试 F 哨兵单实例锁被 abandoned 时…」明细「持锁子进程 15 秒内没拿到哨兵锁（环境异常）」；单跑 **3 连绿**、无残留 holder 进程 → 判定为环境时序（子进程慢启动/被 Defender 扫脚本拖住）。加固：等 flag **15s→30s**；等待中检测子进程 `HasExited` 并带退出码（区分启动失败 vs 被拖慢）；holder 的 `WaitOne` 1000→5000ms；强杀后等待 800→1500ms。加固后 `test-lock` 6/6，门禁复跑 **exit 0 / FAIL 0 / WARN 0**。

### 2026-10-25 12:5x（C4 8.2/8.3 验收反馈修复，A66）

66. **A66 8.2 真 bug + 8.3 增强**（用户验收反馈：「复制的命令报禁止运行脚本」「复制是自动的，想要手动选中」「交给 agent 要带上下文和证据目录」）
    · **8.2 bug**：复制出来的是 `& '…\errwatch-check.ps1' …`，在默认 Restricted 的机器上直接报「禁止运行脚本」。改成每条 `powershell -NoProfile -ExecutionPolicy Bypass -File …` 开头（PS 5.1 实测通过）。
    · **8.2 手动复制**：原 MessageBox 文本选不中，自动复制失败就再也拿不到 → 新增 `Show-CopyOkDialog`（只读可选中、已全选、带复制按钮），「复制命令」和「交给 agent」共用。
    · **8.3 交给 agent**：新增按钮，生成可复制的上下文（程序 / 错误码 / 出错模块 / 事件时间 / 最近装改占位 / 带绕过前缀的证据命令 `errwatch-evidence.ps1 -App …`），不用用户自己找目录。
    · `test-tray` 加 T 组 6 条守卫（绕过前缀 / 可选中窗 / agent 按钮与段落 / 证据命令），**21/21**；门禁 FAIL 0。

### 2026-10-25 13:3x（C5 验收 + 托盘退出判断，A67/A68）

67. **A67 C5：任务管理器「结束任务」不弹**：实测任务管理器「结束任务」在 Win11 先发 WM_CLOSE（礼貌关闭，exitCode 0），「结束进程」才是 TerminateProcess（exitCode -1）。原判定把 exitCode 0 一律判 normal-exit quiet → 两种都不弹。修法：退出码 0 + 有窗口 + **退出前不在前台** → unknown-exit（点 × 时窗口在前台；任务管理器结束时前台是它）。代价：有窗口程序自己后台退出会弹一次（P3 记录）。`test-exit-intent` 加 H 组 **9/9**；真实链路 WM_CLOSE → unknown-exit quiet=false。
68. **A68 托盘退出判断**：托盘「退出」原来不留痕迹 → 无法区分主动退出与崩溃。现在退出写 `tray-exit.json` + `tray-exit.jsonl`，启动读并删除标记，tooltip 显示「上次由你主动退出」；两文件进 pack-filter 排除。`test-tray` 加 U 组 **22/22**。

### 2026-10-25 14:0x（托盘状态接入看护健康 + doctor，A69）

69. **A69 托盘状态消费端**：A68 只把标记写进 tooltip，用户仍得猜。① 设置→工具→「看护健康」加两行：「托盘：在跑 / 没在跑（气泡不会出现，哨兵仍在记录）」+「上次托盘退出：XX:XX（reason=user）」；② `errwatch-doctor` 响应链加「托盘进程」检查：在跑 → OK；没在跑 → 黄色警告 + 读 `tray-exit.jsonl` 解释。`test-doctor` 加 I 组 **9/9**、`test-settings` 加 I 组 **20/20**；门禁 FAIL 0。

### 2026-10-25 14:2x（C5 重测失败的真正原因：折叠吞掉新事件，A70）

70. **A70 同程序折叠保留最早一条 → 新退出被吞**（用户重测 C5：「刚刚重新测试 不存在」）：现场核对 —— 12:44 的 mspaint 事件判定**完全正确**（unknown-exit / quiet=false / 理由「不在前台，可能是任务管理器」），但 pending 里是 12:22 的旧 mspaint（我 12:22 的实验），折叠「同 app 24h 只留一条」保留最早 → 新事件被吞 → 托盘不弹。修法：折叠改为按时间**倒序**、每 app 只留**最新**一条（旧的丢弃 = 替换），仍满足 B8「只留一条」，但用户看到的是最近这次。实测重建：mspaint→12:44、DSH→12:48。`test-sentinel` **23/23**；门禁 FAIL 0。

### 2026-10-25 14:4x（程序名中文化，A71）

71. **A71 普通用户认不出 mspaint/olk**：实测这两个 exe 都**没有 FileDescription**（文件版本信息那一路给不出名字），而主界面程序列直接显示裸 exe 名。修法：`core\analyze.ps1` 加 `EwCommonProgramNames`（约 30 个常见程序显示名，Match-App 之后、文件描述之前查）；UI 程序列改走 `Get-AppDisplayName`（`AppDisplayCache` 缓存，避免 1141 行每行查文件）。实测：mspaint→「画图（Windows 自带）（mspaint）」、olk→「Outlook 启动器（Microsoft 365）（olk）」、Notepad→「记事本（Notepad）」。`test-tray` 加 V 组 **23/23**；门禁 FAIL 0。

### 2026-10-25 13:3x–（被打断后接手：审计整改 F 结案）

72. **A72 审计整改 F：UI 六场景自动化（P1 最后一项）** → 主界面是用户唯一直接接触的东西，而它的**失败路径一条都没测过**（同源教训：A43 发现 `-Check` 自检一直在验错行，门禁全绿、只能靠碰巧发现）。新增 `tests\test-ui-scenarios.ps1` **9/9** 已进门禁，全部在**临时最小树**里起真进程（不碰开发目录的真实数据）：
    · **A 空历史** —— 没有 `history.jsonl` 的第一次装机：EXIT 0、0 条、坏行 0、有「扫描引擎」输出。
    · **B 畸形 JSONL** —— 6 行里 2 条合法 + 半行 + 非 JSON + 空行 + 坏时间：好行保留 2 条、**坏行计数 3**（空行不算坏行，否则计数永远不为 0）。
    · **C 无 pwsh 回退** —— C1 把引擎选择抽成 `core\engine.ps1` 的 `Select-ErrwatchPsExe` 纯函数，三分支（有 pwsh / 只有 5.1 / 都没有→`$null`）全部断言；C2 **真用 `powershell.exe` 5.1 跑一次 `-Check`**（EXIT 0、设置窗冒烟也过）。
    · **D 外部程序失败** —— 目录里放 `exit 1` 的 `errwatch.ps1` 桩，走**真实** `Start-Process` 调用链（不 mock）：状态栏必须写「自动扫描失败：扫描退出码 1…」、按钮必须复位（否则界面永远停在「扫描中…」）。
    · **E 非交互** —— stdin 关掉 + `-NonInteractive`（**引擎参数必须在 `-File` 之前**，写后面会被当成脚本参数直接报错）：90 秒内跑完、EXIT 0。
    · **F 修复入口失败** —— 三种坏输入（正常行 / `$null` / 字段全空）都必须产出方案文本且一个也不抛；F2/F3 两条静态守卫（方案正文只许一份实现、探针块只许待在 `-Check` 段里）。
    **产品侧只动了三处，都是为了可测、不改正常行为**：`core\engine.ps1`（引擎选择纯函数）、`Get-HistoryRows` 的坏行计数（`$script:HistBadLines`）、`New-FixPlanText`（从 `Show-FixDialog` 抽出的方案正文，唯一实现），外加两个**测试专用**开关 `-ProbeScanFail` / `-ProbeFixFail`（只有测试传，正常启动永不到）。
    **四个反证都做过（不反证不算通过）**：引擎优先级反转 → C1 红；去掉 `$bad++` → B 红；`Show-FixDialog` 里塞回第二份方案正文 → F2 红；探针挪到 `-Check` 段外 → F3 红。改完按 SHA256 校验已完整还原。
    **本轮踩到的新坑**：无控制台子进程的 stdout 是**系统 OEM 代码页**（中文机器 936），按默认 UTF-8 解码会读到「UI ��ʼ�� OK」—— E 用例第一版就是这么红的。不是脚本坏了，是「被托盘/计划任务拉起」时的真实输出形态，必须在 `ProcessStartInfo.StandardOutputEncoding` 里显式指定 OEM 编码。

### 2026-10-25 14:xx–（第一份外部审计回执：四处收尾 + 一个真缺口）

73. **A73 审计回执处理（`audit-bu-20261025.md` 那轮的四个问题）** → 审计方拆的是 **bu**（我随后已打 bv），它做的静态检查全过（ZIP 完整 / 94 个 .ps1 全带 BOM / 10 个 .json 可解析 / 基线 121 文件哈希全匹配），但指出四类收尾问题。逐条处理：
    · **P1「新手说明承诺过绝对」→ 已重写 `★ 先看我.txt`**：原来写「它不会改你电脑上的任何东西…用完直接删掉整个文件夹就行」，而项目本身有修复、看护记录、崩溃快照和清理功能。现在分三段说清：**扫描只读不写 / 但它会留下哪些记录（文件夹内、ProgramData、系统里的启动项与注册表布防）/ 只删文件夹不等于卸载**。
    · **P1 顺带查出一个真缺口（比文案严重）**：`uninstall.ps1` 原来 8 步**完全没处理** `C:\ProgramData\errwatch\dumps` 和 HKLM 的 LocalDumps 布防。实测本机：**17.1 MB 崩溃快照 + 21 个程序被布防**在卸载后全部遗留 —— 程序删了、注册表还在替它工作（那些程序一崩就继续写几 MB 的快照）。新增 ⑤.5（撤销布防，判据是 `DumpFolder` 指向 errwatch，**不按名字猜**，免得误删别的软件的布防）与 ⑤.6（快照文件，默认保留，要删加 `-RemoveDumps`）。
    · **P1「交付包混过时内部材料」→ 分包**：`tools\pack.ps1` 加 `-Profile user|dev`，判据在 `pack-filter.ps1` 的 `EwShippableDocs`（**白名单**，新文档默认不进 user 包）。实测 user **135 条目** / dev **198 条目**，差 63 个开发文档；补白名单时踩了两处：① 第一版误排了 `runners\L3-操作卡.md` 与 `USB-自动采集.md`（**给用户看的操作卡**）；② **`STATE-CONTRACT.md` 不能排** —— `test-sentinel` J 与 `test-tray` F 拿它当契约规格断言，排掉后 user 包解压跑门禁 **EXIT=1**（两条用例报「找不到该路径」）。这条只有「解压后真跑门禁」才抓得到，正是 A44 那条教训的复发。
    · **P2「验收结论与明细不一致」→ 重算**：原写「39 项全部通过」，按实际留痕是 **46 项：PASS 38 / NOT_APPLICABLE 2（1.3、6.4）/ NOT_RUN 6（0.3、8.1–8.5）/ FAIL 0**。新增状态口径表（四个值、每项只许一个、未点不许算通过），修掉 4.x/5.x/6.x/7.x 四节的表格列错位，`8.x` 标明入口已迁到「设置 → 工具」。另加第十一节「卸载验收」（对应上面的 ⑤.5/⑤.6）。
    · **P2「门禁记录要跟当前包绑定」+ 根因**：写死包名必然漂移，所以 `tests\审计索引.md` 的「当前包 / 校验 / 独立验证」三行**改成不写具体包名**（以包外 `release.json` 与 `*.zip.sha256` 为准）。`HANDOFF.md` 顶部加「本文档是历史档案，不是当前状态」横幅。`发布流程.md` §3 新增 3.0 两种包、并把「**先改完文档再打包**」写成硬规则（bv 那轮正是打完包才改文档，包里装的还是旧数字）。
    **本轮实测**：`③ 卸载报错看护.cmd`（新增，GBK 编码；`-Encoding Default` 在 pwsh 7 里其实是 UTF-8，得用 `GetEncoding(936)` 写）预览 → 问 Y/N → 选 N 输出「已取消，什么都没动」，全程零删除。

### 2026-10-25 15:xx–（第二轮审计：证据归属与状态判定，2 P2 + 3 P3 + 上轮两 P3）

74. **A74 证据归属专项（审计 `audit-state-evidence-20261025.md` 那轮）** → 审计方的方向判断是对的：「证据是不是属于这一次」「界面读到的是不是最新状态」比 UI 小毛病重要得多。**逐条核实后修了 8 项，另有 1 项我判定为理论风险并如实降级**：
    · **P2-1 旧 WER 记录把正常退出压成崩溃**（真 bug，已修）→ `Get-ExitEvidence` 原来固定取「最近 3 分钟」，而 3 分钟内完全可能有**上一次**崩溃的 1000 记录；「崩溃 → 重开 → 很快点 × 关闭」正是救援主流程的形态，被判成 crash-suspected（而 `exit-intent` 又规定它不许被退出码覆盖）。改成**下界取本进程启动时间**（`$p.startTime - 2s` 与 3 分钟取较晚者）——崩溃只可能发生在进程生命周期内。守卫 `test-exit-intent` G2。
    · **P2-2 UI 先见者胜**（真 bug，已修）→ 同一 id 依次写 `diagnosing → unknown-exit → crash-suspected（dump 回填升级）→ recovered`，哨兵投影取后写覆盖、UI 取先见者胜 → 状态列停显示「进程消失」、Raw 里没有后补的 `dumpPath`。**根因是这段逻辑长在 UI 脚本里、没法被单测**（跑到 `exit 0` 就退出），所以抽到 **`core\sentinel-view.ps1`**（`Select-ErrwatchLatestEventById` / `Get-ErrwatchCrashCounts`），UI 只渲染。新测试 `test-sentinel-view.ps1` **11/11** 已进门禁。
    · **P1 反复崩溃计数重复算**（真 bug，已修）→ dump 回填会把同一事件再追加一行（verdict 不变），而计数不按 id 去重：2 次真崩溃 → 数成 4 次 → 踩到「6 小时 ≥3 次」熔断，本该归位的程序不回位。`Select-ErrwatchRecoveryBatch` 改成**先按 id 去重（后写覆盖）再判定**；UI 的 6h 计数同样去重（口径保留「曾判崩溃就计数」）。守卫 `test-recovery` Z1/Z2。
    · **P1 dump 关联可能配到另一轮崩溃**（**部分可修，如实降级**）→ 审计给的「10:00 崩溃 → 10:01 与 10:12 两份候选」在**当前命名规则下不可达**：LocalDumps 文件名是 `<exe>.<pid>.dmp`，同名文件磁盘上只有一份（实测本机 dump 目录确认）。所以「取最新写入」那行实际是死代码。**但同一报告里的另一半是真 bug**：`Find-ErrwatchDumpForSnapshot` 的 RecordId exact 分支**直接 return，绕过了 pid 交叉验证** —— RecordId 对死只能证明两条**记录**是同一次，不能证明**文件**是那次写的。已抽 `Test-ErrwatchDumpPidMatches` 让两条关联路径共用，exact 也必须过验证；排序语义改成「与事件时间距离最近」并带出 `CandidateCount`/`DeltaSeconds`（防的是将来命名规则变化）。守卫 `test-dump-link` X/Y。
    · **P2 自定义 dump 目录进不了清理**（真缺口，已修）→ `storage.ps1` 只扫固定 `%ProgramData%\errwatch\dumps`，而布防时允许把 DumpFolder 指到别处 → 文件只增不减而界面说「已清理」。新增 `Get-ErrwatchAllDumpFolders`（判据与 uninstall 一致：只看 DumpFolder 实际值，不按子键名猜），storage 与查找端同源；加 `-DumpDirs` 注入让它可以被测。守卫 `test-settings` O。
    · **P3 批量归位绕过年龄限制**（真 bug，已修）→ 原来 `EventIds` 取所有未终态崩溃，年龄只看最新一条 → 48 小时前的旧事件被一起终态化。改成先筛 `inAge`，判据与范围都只作用于它。守卫 `test-recovery` Z3。
    · **P3 ACK 读窗口 4000 行**（真 bug，已修）→ `Get-Content -Tail 4000` 让更老的终态从读取视图消失（复活 + 清不掉的僵尸数据）。**本机实测当时已 2605 行、605 KB，正在往 4000 走**。默认改成读完整文件（`-Tail 0`），要限流就压文件而不是用 Tail 换正确性。守卫 `test-ack-state` N（4301 行）。
    · **P3 EventRecordID 类型过窄**（真 bug，已修）→ 全链 `[int]`，30 亿的 ID 表现为**静默降级**（TryParse 失败 → 跳过精确匹配 → 退回弱关联），比报错更糟。写入/解析/比较统一 `[int64]`。守卫 `test-dump-link` Z。
    · **P3 上轮两个**：README 的校验指引不再让人在解压目录读 `release.json`（它**从不在 zip 内**，是伴随文件，已在文档里写明并给出 `Split-Path -Parent $zip` 的读法）；`errwatch-trace.ps1` 的 `Find-ReleaseId` 候选顺序把「项目根上一级\_dist」提到最前 —— **实测坐实**：`E:\ai\_dist\release.json` 里是 `bt`（旧包），`E:\ai\_tools\_dist` 里是 `bw`，修前 trace 会显示 bt。守卫 `test-diagnosis-trace` N。

### 2026-10-25 16:xx–（第三条链路：清理与备份 —— 挖到一个灾难级误删）

75. **A75 清理与备份（审计列的第四条链路里我还没查的那条）** → 结论：**这不是"边界情况"，是正常操作就能触发的数据丢失**。
    · **★ 灾难级：副本目录没有边界，清理按修改时间删光目录下所有文件**（已修）→ 实测构造：把一个目录设成 `copyDir`（设置页那栏叫「备份副本存哪里」，用户很容易选桌面或「文档」），里面放一个 40 天没动的 `年终总结.docx`，跑 `Get-ErrwatchStoragePlan` —— **它出现在 Drop 列表里**。也就是说点一次「删除过时文件」，用户自己的文档就没了，全程不需要任何误操作。而 `settings.ps1` 对 copyDir 只校验「绝对路径」。
    · 修法：**归属标记**。新增 `.errwatch-copydir` 标记文件，`Get-ErrwatchStorageScope` 只在有标记时才把目录纳入清理；没有标记 → 跳过**并如实说明原因**（不许静默）。标记写入时机两处：① 用户在设置里保存副本目录（= 明确授权）② 第一次往那里保存副本（`errwatch-recover.ps1 -SaveTo`）。CLI（`-StorageShow/-Cleanup`）与设置页「存储与清理」都改成读 Scope，被拒时把原因打到界面上。守卫 `test-settings` P（并反证过：把「必须有标记」改成恒真 → P 立刻红）。
    · **顺带修的三处**：① CLI 里 dump 目录原写死成 `%ProgramData%\errwatch\dumps`，改成显示**实际清理范围**；② `retention.ps1` 的 `reason` 在「没有终态超期记录但按行时间清了升级记录」时自相矛盾（日志会同时写「没有超期记录」和「删了 N 行」），现在两者对齐；③ 哨兵对 `-not $ret.ok` 有留痕（`sentinel-retention.jsonl` 带 error），这条本来就是对的。
    · **我自己在这轮写出的两个 bug（都当场修掉）**：`"*$copyDir*"` 在 copyDir 为空时等于 `"**"`，把有 2 个快照的 dump 目录筛成「（还没有）」；以及一行无意义的自赋值 `$res.ok = [bool]$res.ok`。记在这里是因为它们说明「改清理逻辑时必须真的看一眼输出」，光跑测试绿不算。

### 2026-10-25 17:xx–（兼容性审计：P2 发布材料包级化 + 五处 P3）

76. **A76 兼容性审计（`audit-compatibility-20261025.md`）** → 审计结论「运行时双栈可用」是好消息（5.1 与 7 的关键 API 全通、PS7 解析 0 错、主要入口实跑 exit 0）。要修的是**跨版本/跨包的假设**，六项全处理：
    · **P2 发布材料包级化**（已修）→ `make-release` 原来固定写 `<zipDir>\release.json`：一个目录塞多个候选包时，后打的覆盖前面，**旧包无法自证身份**（拿 bu 的路径去校验，读到的是 bx 的清单，5.1/7 都 FAIL）。现在主产物是包级 `<zip>.release.json`（与 `.sbom/.verify/.sha256` 同一套命名），`release.json` 保留当「最新构建」指针（不破坏 trace 与文档）。`check-release-identity` 优先读包级、回退共享。**实测**：by 19/19 PASS；bu 现在明确 FAIL 并指出「release.file 指向 by」——原因清楚，不再被静默冒充。
    · **P3 进程检测三处不一致**（已修）→ 新增 `core\proc-host.ps1`：① 宿主双认（pwsh/powershell）② 命令行必须有我们的脚本名 ③ **锚定当前安装目录**。doctor/settings-ui 原来只查 `pwsh.exe`（托盘跑在 5.1 下时误报「托盘没跑」），UI 单实例只查 `powershell.exe`（PS7 下重复界面杀不掉），且都不锚定目录（别的目录那份托盘被当成本包在跑 —— 症状是「说在跑但气泡不出来」）。
    · **P3 VBS 编码**（已修，注释早写对了、枚举选错了）→ `register-watch.ps1` 用 `-Encoding Default` 写 `.vbs`，而 Default **随版本变**：5.1 = ANSI、7 = UTF-8 无 BOM，wscript 按 ANSI 读 → PS7 下注册的启动项在中文路径下指向乱码路径，静默失效。改成显式 ANSI 代码页写入（读回也用同一编码）。
    · **P3 设置窗启动回退**（已修）→ 「启动看护」原来硬编码 `C:\Program Files\PowerShell\7\pwsh.exe`，没装 PS7 的机器上启动一个不存在的路径。改用 `core\engine.ps1` 的 `Get-ErrwatchPsExe`（先 PATH、再默认安装位置、最后 System32 的 5.1）。
    · **P3 doctor 不校验启动项指向**（已修）→ 原来只 `Test-Path` `.vbs` 存在就报 OK，而对「指向旧目录」`register-watch` 在同一台机器上会报「代码不会生效」——**两处结论相反，用户信 doctor**。判据抽到 `core\startup-check.ps1`，两边共用；doctor 现在会打「指向旧目录 / 文件已失效」并给出两行路径对照。
    · **P3/低 隐式 BOM 依赖**：本轮只在必须的地方显式化（VBS 写入与读回、启动项解析）；其余 `Get-Content` 依赖 BOM 的地方**没有统一扫**，作为已知项留下（当前 WER `Report.wer` 是 UTF-16LE+BOM，暂时安全）。
    **新增守卫** `test-proc-host.ps1` **10/10** 已进门禁，重点测**不该认的绝不认**（传错目录必须 0 个）；两条反证都做过：去掉锚定 → A/B 红；doctor 改回只查 pwsh → J 红。

### 2026-10-25 18:xx–（编码显式化收尾：同类问题的最后一处）

77. **A77 显式编码收尾（兼容性审计 P3/低 的完整版）** → 上轮只把「必须的地方」显式化了，这轮全仓扫完：**非注释行里已 0 处依赖隐式编码**。
    · 起点：`Get-Content/Set-Content/Add-Content` 不带 `-Encoding` 的共 **16 处**（其中 6 处是注释里提到函数名，不是调用）。
    · **关键判断：不能无脑加 `-Encoding UTF8`。** 两个方向都可能出错，实测验证了分界：
      · **我们自己写的文件**（`ui.pid` / `sentinel-*.json` / acks / 状态文件）：PS 7 的 `-Encoding UTF8` 写出来**不带 BOM**，5.1 隐式读会按 ANSI 解 → 乱码。所以这些必须**显式 UTF8**。
      · **系统产出的文件**（WER 的 `Report.wer`）：本机实测前两字节 `FF FE` = **UTF-16LE + BOM**。这里加 UTF8 反而会把内容读坏 —— 必须显式 `-Encoding Unicode`。
    · 顺带把一处**文本比较改成字节比较**：`test-recover` 原来用 `Get-Content -Raw` 比副本与原文件，既依赖隐式编码（7 写 5.1 读会误判"不一致"），又拿文本读二进制（`.sv$` / `.asd` 都不是纯文本）。改成比 SHA256。
    · 守卫 `test-proc-host` 加 **K/L** 两条（现 **12/12**）：K 扫全仓非注释行必须显式；L 管**对应关系**（状态文件→UTF8、WER→Unicode），因为"写错编码"同样是静默乱码。**反证过**：去掉 `ui.pid` 的 `-Encoding` → K 立刻红并指出具体行号。

### 2026-10-25 19:xx–（并发真压测：ISSUES 历史挂账「并发未真压测」结案）

78. **A78 并发真压测 + events 清理的签名保护** → 挂账里那句「并发未真压测」到今天才真的动了手。
    · **补了一个真缺口**：`retention.ps1` 的 ① 段（清理事件记录）原来**既没有锁也没有签名检查** —— 读全量、写临时文件、`Move-Item` 覆盖。当前没出事，是因为清理者和写者（哨兵 `Add-Content`）在**同一进程里串行**；但那只是"恰好"，不是保证 —— 哪天把保留策略挪到托盘/独立脚本，一次清理就能把刚写进来的事件覆盖掉（Move 是替换不是追加）。已补上与 ③ 同款的「写前取签名 → 写临时文件后核对」，被追加就放弃本次并保留原文件。
    · **新增 `test-concurrency.ps1`**（**4/4** 已进门禁）：起 **6 个真子进程 × 各 25 行**、用「命名 Mutex + Add-Content」（即托盘 Add-Ack 的实现方式）写同一个 acks → **150 行一行不丢、无粘行、每个进程的 id 都在**。这不是模拟：`Start-Process` 起的是真的独立 powershell 进程。
    · **诚实的能力边界（重要，写在测试输出里）**：A 证明的是「持锁写入在高并发下不丢行」——**回归保护**，不是「锁是必要的」。因为 B 组对照（同一批写入**不拿锁**）在本环境实测**也没丢行**（150/150 全在）。所以我没有把 B 写成一条会绿的用例（那会是死测试），而是把它降级成**信息性输出**，如实打印「本环境未复现」。真要证明锁的必要性得让写入窗口变大（慢 IO / 更多进程），成本高于收益 —— 锁本身有 `test-lock` 的 6 项守着（含「锁被外部持有时托盘仍能写」）。
    · 另外两条静态守卫：D 守「① 段必须有两次签名调用」（防退化）；E 守「托盘的锁名必须与压测用的同一把」——否则压测证明的根本不是真实实现。
    · **压测自己也踩了两个坑**（记下来，因为都是"测试写错而不是产品错"）：① 子进程 id 前缀用文本替换注入，模式没匹配上 → 6 个进程写了同一批 id，看起来像"全丢了"；改成参数传 prefix。② 造「超期终态」的 ack 时用了 `New-ErrwatchAckRecord`，而它的 `at` 永远是**现在** → 按设计那条就不该被清，是我的期望写错了；改成手工写 30 天前的 `at`。

### 2026-10-25 20:xx–（收尾：fix.ps1 最高风险那条不变式）

79. **A79 `fix.ps1` 的失败注入 —— 只做最值得做的那一条** → 读完全部 57 处失败/状态处理后，判断是**不展开做全套**，理由写在下面。
    · **为什么不全做**：四个有副作用的动作里，`restart-service` / `restart-process` 的失败路径是「杀/起进程失败」——代码已经把中间态分得很清（`aborted` / `rolled-back` / `verify-failed`），而且 `restart-process` 会明确报「启动命令已执行，但进程没有出现」（**不假装成功**）。要造真实失败需要 50MB 日志文件 + 独占句柄 + 权限受限的服务环境，成本显著高于收益；而这些路径属于**防御性代码**（写全了不容易退化），退化风险低于逻辑错误。
    · **做的那一条（最贵的失败）**：`log-rotate` 是唯一会**清空用户文件**的动作。它的正确顺序必须是 ①复制备份 → ②SHA-256 校验备份 → ③才允许 `Clear-Content`。一旦颠倒，「备份其实是坏的」这个事实发现得太晚 —— 原文件已经没了。`test-fixauth` 新增 ⑨（现 **9/9**）用文本位置守这条顺序不变式 + 守「校验失败时原文件保持原样」的文案。
    · **反证过**：把 `Clear-Content` 挪到备份校验之前 → ⑨ 立刻红，报「清空出现在备份校验之前 —— 备份坏了也会先把原文件清掉（数据丢失）」。
    · **守卫自己也踩了一次**：第一版搜的字符串漏了原文里的 `**`（`**未清空任何内容**，原文件保持原样`）→ 守卫先红。改搜 `原文件保持原样`。这件事本身说明它不是死测试。

### 2026-10-25 21:xx–（「都做」：fix.ps1 失败注入全量补齐）

80. **A80 `fix.ps1` 失败注入（把上轮「判断不做」改成做了）** → 上轮我判断成本高于收益；这轮换了做法，成本其实很低：**log-rotate 没有大小阈值**（只要非空），不需要造 50MB 文件。
    · 新增 `test-fix-failure.ps1`（**6/6** 已进门禁），全部**真跑 CLI**、不 mock：
      · **A 正常路径**：`STATUS=verified` + 备份存在 + **备份 SHA == 原文件 SHA** + 原文件被清空
      · **B 文件被独占**（用 `FileShare.None` 持住）：`STATUS=aborted` + 说明是独占 + 写清「未做任何改动」+ **原文件一个字节没变** + 不留下半截备份
      · **C 扩展名不在白名单**（`.dll` 不带 `-Force`）：`STATUS=refused` + 原文件未变
      · **D 演练**（不带 `-Commit`）：`STATUS=dry-run` + 零写入 + 不产备份
      · **E/F `restart-process` / `restart-service` 目标不存在**：实测输出 `STATUS: refused | 没有找到进程：…` / `服务不存在：…` —— 断言收紧到**必须 refused**（不能只断言"不是 verified"，那太松：拒绝、静默、崩溃三种都满足）
    · **两条反证**：① 正常路径谎报成 `verify-failed` → A 红；② 跳过独占检查 → B 红，且一次红三条（状态错 / 没说明独占 / 没写「未做任何改动」）。
    · 顺带确认了一件事：**独占时即使跳过检查，原文件也没坏**（`Clear-Content` 自己也会失败）—— 但那属于"运气好"，报错状态错了就是把一次中止说成"完成了"，所以 B 守的仍然是必要的那条。

### 2026-10-25 22:xx–（实测「自带崩溃处理器 vs WER」—— A30 遗留悬念结案）

81. **A81 `senddmp.exe` vs WER 谁赢 —— 已实测，进程内 handler 赢** → 这是我从 A30 起标了「没实测过、不许承诺」的那条悬念。
    · **先说为什么不能"强杀一次 CAD"**：强杀是 `TerminateProcess`，**根本不会触发 WER dump** —— 那个实验设计从一开始就是错的（之前记的"要真崩一次 gcad"方向对，但"强杀"错了）。必须让进程**未处理异常**崩溃。
    · **现场查到的事实**：`senddmp.exe`（643 KB）存在；**它没有注册到 AeDebug，也没有 gcad 的 IFEO 项** → 说明它不是系统级调试器，而是 **CAD 进程内自己调用的**。这一点决定了结论方向：进程内 `SetUnhandledExceptionFilter` 优先于 WER 的默认处理器。
    · **实验设计与最大的坑**：HKCU 的 LocalDumps 布防**复测仍不生效**（A30 的结论 100% 成立）——对照组也一个 dump 都没有，等于白跑。绕过的办法是**借用已有的 HKLM 布防**：LocalDumps 只按 exe **文件名**匹配，所以把自己的探针改名成 `ps_service_launcher.exe`（已布防的程序名）就命中了，不需要管理员。
    · **对照实验结果**（各跑一次，等 8 秒让 WerFault 写盘）：
      · **A 组（无进程内 handler）**：产出 `ps_service_launcher.exe.4968.dmp` **6006 KB** → 布防生效、WER 路径正常
      · **B 组（用 `SetUnhandledExceptionFilter` 装 handler，模拟 senddmp 抢先）**：handler **确实执行了**（标记文件落地），但 **dump 0 个**
      → **结论：进程内 handler 赢**。真 CAD 崩时 `senddmp` 大概率抢先，我们拿不到快照。
    · **这条结论的边界（照实写）**：我用的是**模拟** handler（.NET 里 `SetUnhandledExceptionFilter` + 直接返回 `EXCEPTION_EXECUTE_HANDLER`），不是 `senddmp.exe` 本体；它回答的是"进程内接管会不会挡住 WER"，答案是**会**。具体到浩辰，它是否真的装了这么个 handler、handler 里是否转储后重新抛给 WER —— 仍然只能靠真崩一次确认。但**产品侧的行为不需要改**：详情区本来就写了「可能被自带处理器抢先接管」，现在这句话有实验依据。
    · 实验痕迹已清：假 dump（pid 4968）删掉、HKCU 的 werprobe 键删掉、临时目录清掉；复查 HKLM 布防仍是 **21 个**、`ps_service_launcher` 的配置没动。

### 2026-10-25 23:xx–（把验收 8.1–8.5 做成机测，顺带挖出一个「功能凭空消失」）

82. **A82 验收 8.1–8.5 机测化 —— 并抓到一个真 bug** → 用户问「8.1–8.5 是什么」，答完后顺手把这 5 项从「只能口头确认」变成可重复机测（`tests\test-verify-8x.ps1`，现 **7/7** 进门禁）。
    · **★ 抓到的真 bug（A67 的副作用，活了很久没人发现）**：工具栏撤掉「更多 ▾」之后，挂在 `$menuMore` 上的 8 项里有两项**失去了全部入口**：
      · **「♡ 看完的感受」** —— feedback 闭环的唯一入口
      · **「▤ 打开证据目录」**
      它们既不在右键菜单里，也没进设置的工具页（工具页只搬了「打开最新报告」）。L1663 的注释写着「`$menuMore` 仍保留（供 tray/旧调用），但不再有工具栏入口」—— 而 **tray 并没有调用它**。
      **这正是 8.4 只能记 `NOT_RUN` 的原因：不是用户没点，是找不到。** 已修：两项挂到主界面右键菜单（与「按程序统计」「恢复已忽略的条目」同为全局操作，零布局风险）。
    · **机测内容**：8.2 真跑「复现命令拼接」（执行策略绕过 + 两条 + 单引号转义）；8.3 **真跑 check.ps1**（模板 + GBK 写入 + 能跑通不报语法错）；8.1 验「取最新 + 报告可读 + 存在带 §1 的完整报告」；8.4/8.5 守按钮/选项/链路。
    · **边界照实写**：机测**不等于**人工验收 —— 按钮能不能点、窗口长什么样仍需人眼。清单里已按这个口径改成 `机测 PASS + 待人眼项`。
    · **我自己在这轮返工了 5 次**，全是"守卫不可靠"：
      ① 8.1b 要求「最新报告必须有 §1」—— 错：报告有**通知型**（`## 🔔`，无 §1）和**完整型**两种；
      ② 8.4 猜的选项文案（太吵/没看懂/…）与实际（按建议处理了/看不太懂/没有可操作的/看懂了）全不一样；
      ③ 「右键菜单里有没有」用正则写，`$ctx` 的 `$` 被当行尾锚点 → 永远不匹配；
      ④ 改成切段 + `Contains('看完的感受')` → **被解释这个 bug 的注释骗过**（注释里也有这几个字）；
      ⑤ 改成 `Contains('$miFeedback')` → 注入 `$miFeedback = $null` 照样含变量名。
      **最后决定降级**：不再假装能验"可达性"，只验「按钮存在 + 4 个选项 + feedback 链路完整」，并把**右键菜单能否看到**明确列为**人眼项**。宁可少一道守卫，也不要一道永远绿的假守卫。
    · 顺手修了一个守卫自身的误报：编码守卫把 `if ($src -notmatch 'Add-Content')` 当成真实调用 —— 现在**先抹掉字符串字面量再判断**（与"全文 grep 文件名把注释也算违规"同一类错）。

### 2026-10-26 00:xx–（发布前合规材料核对 —— 用户问「许可啊什么的更新了吗」）

84. **A84 合规材料核对：查出 1 个法律缺口 + 3 处事实漂移** → 用户这句话问得准，这类东西最容易"代码改了文档没跟上"。
    · **★ 法律缺口：免责声明完全没提崩溃快照**（已补）→ 2026-10-24 加的「崩溃快照」会往 `C:\ProgramData\errwatch\dumps` 写**进程内存转储**（每份 5–17 MB），而**内存转储可能包含用户当时正在处理的内容**（文档片段、剪贴板、聊天文字、登录态）。`★ 先看我.txt` 里提了这份文件，但 `免责声明.md` 的「数据与隐私」一节**一个字都没有**。已在 §三补完整条款：默认关闭 / 会写 HKLM `LocalDumps`（系统级，给出撤销方法）/ 只存本机不上传 / 不建议在含敏感资料的机器上开。
    · **事实漂移①：`rules.json` 条数** → `THIRD-PARTY-NOTICES.md` 和 `README.md` 都写「28 条」，实际 **34 条**（改了 5 处）。
    · **事实漂移②：联网声明的扫描日期** → 免责声明写「已静态验证（2026-10-22）」；今天新增了 4 个 core 文件（engine / proc-host / startup-check / sentinel-view），**必须重扫**。重扫结果：**0 处网络 API 命中**（扫 `.ps1/.cmd/.bat/.vbs`，含 `TcpClient`/`UdpClient`/`System.Net.Http`/`DownloadString` 等）。声明已更新为「2026-10-22 首验 + 2026-10-25 全仓重扫」。
    · **事实漂移③：README 的校验指引** → 还写着共享 `release.json`，而现在清单是**包级** `<zip>.release.json`。已改：优先包级、回退共享，并说明「同目录的 `release.json` 只是最新构建指针，不能用来校验旧包」。
    · **顺带核对的**：`LICENSE`（MIT / 版权主体正确）、`THIRD-PARTY-NOTICES` 的 sigma 数字（9 个样例 / 6 条转换结果，都对）、`审计索引 §六` 合规状态表（隐私证据已更新为重扫结论）。**user 包里 7 个合规文件全在**。
    · **踩到的坑（已进坑表）**：`[System.IO.File]::WriteAllText('免责声明.md', ...)` 在 pwsh 里 `cd` 过之后**写到了 `E:\ai\免责声明.md`**（按进程 CWD 解析，不是 `$PWD`），而脚本还打印「已更新」——**看着成功，真实文件一个字节没动**。同一天在审计索引上又踩一次。判断"改成功没有"必须**回读文件**。

## 三、待做（按优先级）

> 2026-10-25 01:1x 更新：**P1 1–3 全部结案（A39–A42），审计方向 01 的盘点与首要修复也做完（A48）**。

### P1 — 下一步候选（能自己验证的）

> 2026-10-25 13:4x 更新：**审计整改表 F（UI 六场景）已结案（A72）** —— P1 候选只剩第 6 项（低优先）
> 与第 7 项（自动拉起，已评估「不做无脑版」）。打磨期剩下的「主界面进程消失表达优化」与
> G（陌生用户决策测试，需真人）见顶部交接那节。

> 2026-10-25 03:1x 更新：**P1 的 1–3（A39–A42）、方向 01（A48/A49）、方向 02 追溯层（A50）与
> 两个前置缺口 T1（A51）/ T2（A52）全部结案。下面第 1 项是定好要做的下一件事。**

> 2026-10-25 02:2x 更新：**P1 旧 1–4 全部结案（A39–A42 / A51 / A52 / A55 / A56）**，方向 01（A48/A49）、
> 方向 02（A50）、abandoned mutex（A53）、归位（A54）也都做完。**下面第 1 项是定好要做的下一件事。**

1. ~~**★ 「反复崩溃」要能压过「归位」**~~ ✅ **已结案（A57）**：A54 的归位判据看的是「崩后新实例活够 60 秒 / 正常退出」，**同一个程序 24 小时崩 5 次、每次都被归位**也完全符合 → 用户看到的是「都归位了」，实际是**复发**（驱动/插件/数据损坏的典型形态）。
   改法：同一 app 在窗口内（建议 6 小时）`crash-suspected` 次数 ≥ 3 → **不再自动归位**，并把事件标成「反复崩溃（N 次）」，人话写清「它每次都恢复了，但反复崩说明原因没查清」。
   验收：造 3 条同 app 的 crash-suspected + 一个存活实例 → 不归位、pending 里出现一条带「反复崩溃」字样；2 次以内仍归位。
2. ~~**状态机剩余 3 条**~~ ✅ **已结案（A58）**：S2 加术语表 `Get-ErrwatchVerifiedMeaning` + 契约 §八.2（值不动、只约束输出语境）；S4 加 `Get-ErrwatchStageText` 合成「走到哪一步」；S5 终态清理改用「终态时间 vs 最后写入」较晚者（顺带把 `test-ack-state` 纳进门禁）。
3. ~~**B9 事件级 coverage 不回填**~~ ✅ **已结案（A59）**：核对后定性变了 —— `coverage` 本来就不该回填（回填等于伪造观测史），真缺口是「证据没回填到结论」：`Get-ErrwatchVerdictUpgrade` 只把 `unknown-exit`+有快照 升级为 `crash-suspected` 并留痕。
4. ~~**哨兵 evidence 只存格式化文本**~~ ✅ **已结案（A62，含第二小步）**：A56 补了 `evidenceRecordId`；A62 补了 1001 的 `evidenceReportId` / `evidenceStoreId` / `evidenceWerReportPath`（`core\wer-info.ps1`），UI 详情已显示报告 ID 与报告目录（不可读时如实注明），「1000 与 1001 是同一次」有独立凭据。
5. ~~**副本目录没设时的引导**~~ ✅ **已结案（A63）**：设置页 copyDir 为空时显示 ⚠ 提示；备份完（保存副本成功且未固定）也会在 notes 里提示去固定。
6. **从调用栈里给出最后几个函数地址**（低优先）：栈在 ThreadListStream 里，能再往下读几层。但没有符号就只能给地址，普通人看不懂 —— 现有「模块+偏移」已经够用。
7. **自动拉起崩溃的程序**（用户提过；**2026-10-25 评估完成：不做无脑版，四个坑实测数据见下**）：
   ① **CommandLine**：实测崩后 600ms 内 CIM 查不到（空）、`Get-Process` 也找不到 → 必须崩溃前缓存；CIM 单次 **58ms**，只对白名单程序缓存（否则开机首轮几十个新进程 × 58ms 会拖慢）。
   ② **dump 抢写**：历史真实数据（errwatch-crashprobe）dump 创建比哨兵检测**早 1.18 秒** → dump 与崩溃几乎同时写完；等 5–10 秒绝对安全。**风险低**。
   ③ **崩溃循环**：本机 5 条 crash-suspected、同 app 最多 2 次；A57 的「6 小时 ≥3 次」判定可直接当闸门 + 预算 2 次。**风险可控**。
   ④ **抢许可**：本机有浩辰 CAD + Office，重启会弹许可/欢迎窗口 → 唯一真正挡住自动拉起的坑 → **只能 opt-in 白名单，默认绝不自动拉起**。
   **结论**：不做无脑版。若做，最小可行：opt-in 白名单 + 等 10 秒（dump 写完）+ 预算 2 次 + 先复制救援副本（不覆盖 `.sv$`）+ 拉起后验证并审计；CAD/Office 默认不在白名单（或拉起前提示「会弹登录界面」）。

### P2 — 必须真人做（无人值守环境验不了）
- ~~**卸载 `-Confirm` 真跑一次**~~ ✅ **2026-10-25 已真跑（非管理员会话）**：①停进程 ②删 2 个启动项 ③计划任务未注册 ④删快捷方式 ⑤清 14 个运行期文件 · **⑤.5 撤销 21 个布防全部失败并逐条报 `Requested registry access is not allowed`**（没假装成功：退出码 1、收尾写「有 21 步失败」）· ⑤.6 快照保留 2 个 · ⑥用户数据保留（history 44 行 / 35 份报告 / settings）· ⑦目录保留 · ⑧历史包保留。跑完环境已完整恢复（状态回填 / 启动项重建 / 看护重启 / 心跳正常）。**顺带发现「卸载会删桌面快捷方式但安装链从不建它」→ 已修**（register-watch 现在会建，`-NoDesktopShortcut` 可关）
- ~~**人工验收 8.1–8.5 补点**~~ ✅ **2026-10-25 已完成**：`tests\test-verify-8x.ps1` **7/7** 进门禁（8.2/8.3 真跑，8.1/8.4/8.5 守入口与关键行为）+ **GUI 实测截图确认**右键菜单里有「♡ 看完的感受」「▤ 打开证据目录」。**顺带修掉一个真 bug**：A67 撤掉「更多 ▾」后这两项失去全部入口 —— 那才是 8.4 只能记 NOT_RUN 的真因
- ~~C4 人工验收清单~~ ✅ **2026-10-25 用户已点完 39 项，全部通过**（`tests\人工验收清单-20261025.md`，结论写在文件开头）。两个「未见」都是设计如此：1.3 本机暂无「崩后恢复」案例；6.4 待处理只有 1 条时批量项不出现 —— 后者已改成在菜单里显示一句「（只有 1 条待处理，不需要批量）」（`test-tray` S 守住）。8.2/8.3 的反馈已修（A66：执行策略绕过 + 可选中复制 + 交给 agent 上下文）。
- ~~C5 退出意图真实链路~~ ✅ **已修（A67）+ 用户实测通过（2026-10-25）**：任务管理器「结束任务」在 Win11 是礼貌关闭（WM_CLOSE，exitCode 0），原判定一律 quiet → 不弹。现在「退出码 0 + 有窗口 + 退出前不在前台」判 unknown-exit（点 × 时窗口在前台 → 仍安静）。用户确认：点 × 不弹；任务管理器结束会弹。实测 WM_CLOSE 路径 → unknown-exit quiet=false 进待处理。
- ~~B15 设置窗的四页真实点选~~ ✅ **2026-10-25 用户已点完**（看护健康 / 备份副本 / 监视目标 / 存储与清理）
- ~~**自带崩溃处理器 vs WER 谁赢（A30 的遗留悬念）**~~ ✅ **2026-10-25 已实测结案（A81）：进程内 handler 赢** → 见下面 §三 的 A81 记录。结论：**布防了也不保证有快照**，详情区那句「可能被自带处理器抢先接管了」是对的、不是免责话术。

### P3 — 已知局限（诚实记录）
- 有些程序**正常退出返回非 0** → 会误弹一次（宁扰不漏）
- 有些程序**崩溃时自己 exit(0)** → 会被判正常退出（罕见）
- 只在 watch ∪ 动态目标 ∪ **设置里手动加的**范围内；新装的**后台**软件要崩过一次才被学到
- **多进程应用（如 DSH，12 个同名进程）**：子进程正常退出判 `normal-exit` 不进待处理；「拿不到退出码」时会以 `unknown-exit` 进一次待处理 —— 已被「同程序 24h 内只留一条」折叠
- 崩溃快照**不保证抓到**：杀软/反作弊先截住进程的崩溃，WER 也拿不到
- **自带崩溃处理器的程序会跟我们抢**（2026-10-24 查到的具体案例）：`浩辰CAD` 目录里有 `senddmp.exe`、`Streaming Service` 目录里有 `parfait_crash_handler.exe` —— 它们在崩溃时可能先接管并自己转储/上报，WER 的 LocalDumps 就拿不到。**2026-10-25 已实测（A81）：进程内 handler 确实赢** —— 所以「布防了就一定有快照」这个承诺**不能给**；详情区那句「没有快照，可能被自带处理器抢先接管了」是有实验依据的，不是免责话术
- **「布防 21 个」不等于「21 个在用」**：本机真装了的只有 8 个，其余 13 个是新装即生效的占位。`-Status` 现在都列出来，不区分装没装
- **`start_protected_game.exe` 之类不是崩溃**：VRChat 的启动保护器会正常退出一次，被记成 `unknown-exit` 进待处理（已按「不需要处理」处理过）
- **副本目录不设 = 永远无法清理**：程序不知道副本在哪（设置 →「存储与清理」里可以固定）
- **归位（A54）也有边界**：取不到进程启动时间的程序**不**自动归位；**多实例应用**（DSH 这类）永不自动归位（分不清是哪个实例恢复了）；「崩后新实例自己 exit(0)」的罕见崩溃会被当成恢复（与上面「崩溃时自己 exit(0)」同源）；归位只说明**程序能用**，不说明崩溃原因查清了

## 四、必须知道的坑（血泪，按踩到的顺序）

| 坑 | 现象 | 正确做法 |
|---|---|---|
| **`@($null).Count` = 1** | 读 `[]` 得 1，误判「数据没清」 | 判空用 `$null -eq` / `ConvertFrom-Json` 结果直接 `@()` 包住前先判空 |
| **Mutex 同线程可重入** | 测试「锁被占」测不出来 | 测并发必须**另一个进程**持锁 |
| **`Add-Type -MemberDefinition` 里嵌 struct** | 静默失败 → 功能整块不执行 | 用独立 `-TypeDefinition` |
| **`-MemberDefinition` 的 `$ewWinReady` 作用域** | 变量在函数里读不到 | 用 `$script:` 前缀统一 |
| **patch 用 `@(a + b, c + d)`** | 逗号优先级低，整块被压成一行 | 每个元素加括号 |
| **`-MemberDefinition`/`Add-Member` 对 `[ordered]`** | 字段静默丢失 | 有序字典用 `$ev['key'] = v` |
| **`Get-InstanceKey $pid $startTime` 两处生成方式不同** | 句柄表永远取不到 → 拿不到退出码 | 用 **pid** 做键 |
| **`Process` 对象不设 `EnableRaisingEvents`** | 进程退出后读不到 `ExitCode` | 建对象时立刻设 true |
| **`-Once` 每轮是新进程** | 句柄表不跨进程 → 永远拿不到退出码 | 必须用**常驻哨兵**验证 |
| **`-Config` 指向不存在的文件** | 退化成空 watch → 上一轮进程全被判退出 → 一次误报一堆、污染生产 | 已加存在性校验（exit 2） |
| **测试哨兵被生产 Mutex 挡** | 静默不启动 | 加 `-InstanceName` |
| **edit 后 `.ps1` 丢 BOM** | 5.1 下中文全乱码 | 每次改完跑 `tools\ensure-bom.ps1` |
| **旧 UI 进程残留占着黑框** | 「修了还有黑框」 | 改 UI 类问题要连旧进程一起清（已加界面单实例化） |
| **完整输出塞进气泡** | 用户看不到重点 | 气泡 3 行；完整解释放 UI 详情区 |
| **PS5.1 与 PS7 对 `'[]' \| ConvertFrom-Json` 行为不同** | PS7 走管道输出零个对象（得 `$null`），5.1 保留空数组 → 用 `$null -eq $x` 判「解析失败/损坏」的代码在 7 上**每轮误判一次**（这次就这样攒了 144 个备份） | 判解析成败只许用 **try/catch**；哨兵生产跑 `pwsh` 7，所以测试也必须用 `pwsh` 7 跑 |
| **`powershell -File xxx.ps1` 在本机默认被拦** | 5.1 的 LocalMachine 策略 Undefined → 生效值 Restricted → `running scripts is disabled` | 一律带 `-ExecutionPolicy Bypass`，或直接用 `tests\run.cmd` |
| **静默的周期性副作用最难发现** | 「每轮多写一个文件」不会报错、不影响功能，只会慢慢把目录塞满 | 状态目录里的文件**数量**要当成一项指标看（这次是交接时一眼看到 144 个才发现的） |
| **配置里写的名字可能从来没匹配上** | `dsh` / `electron` / `electron-shell` 三个 match 在本机各匹配 **0 个**进程 —— 这个条目静默失效了很久，覆盖率声明里还显示「启动时未运行」，看着像正常 | 加/改监视目标后必须跑一次 `Get-Process -Name <名字>` 看计数；`DSH Desktop`（带空格）可以正常匹配，不带空格的名字匹配不到「DSH Desktop」 |
| **「先落盘再取证」的中间态会被下游当成结论** | 事件先写 `verdict=diagnosing` 保命，但投影逻辑「边判定边合并」，最终记录被提前 continue 掉 → 中间态留在待处理里还弹通知 | 多版本记录的合并必须**先按 id 去重（后写覆盖前写）再判定**；中间态要么不进待处理，要么带超时兜底 |
| **`-CheckBuild` 抓的是运行时错误，`Parser::ParseFile` 抓不到** | 本轮把说明块颜色写成 `$cText2`（主界面的变量，设置窗里是 null）—— 语法检查 0 错误，`-CheckBuild` 一跑就抛「无法将 null 转换为 Color」 | 改界面后必须跑 `-CheckBuild`（每轮门禁都跑），别只靠语法检查 |
| **edit 用某行做 old_string，就必须在 new_string 里把它带回去** | 连续踩了 4 次：拿「**A1 的修法…**」当锚点插入新的表格行，new_string 里忘了包含它 → 那一行被**静默删除**，而且门禁和测试都发现不了（markdown 不参与测试） | 插入型编辑要么把锚点行原样带回，要么用「在 X 之后追加」的短锚点；改完 markdown 一定用脚本复查结构（表格行是否连续、关键小标题是否还在） |
| **系统设置别假设「对称」** | 想当然以为 `HKCU` 和 `HKLM` 的 LocalDumps 等效 —— 实测 HKCU 写了、真崩溃了、dump 一个没有 | 任何「应该也能在用户级配」的系统项，都要用真实触发条件验一次（这次造 `0xC0000005` 才证伪） |
| **`$Pid` 是只读自动变量** | 函数参数写成 `[int]$Pid`，整个参数绑定失败（报「无法覆盖变量 Pid」），调用方只看到 `$null` —— 表现成「永远找不到快照」，比直接报错更难查 | 变量名避开 `$PID`/`$Host`/`$Args`/`$Input`/`$Error` 等自动变量；这次改成 `$ProcId`。反证时正是它让 `Find-ErrwatchDump` 全部返回 null |
| **WerFault 写 dump 比进程消失晚** | 哨兵 1 秒左右就发现退出，那一刻 dump 往往还不存在 —— 「查一次没找到 = 没有」会漏掉绝大多数崩溃 | 判定时查一次（撞上了就赚）+ 每 20 秒对最近 15 分钟的事件**回填**；回填的补丁记录必须是**完整事件**（Sync-Pending 是整条替换，只写 `{id, dumpPath}` 会把字段冲掉） |
| **winexe 的 UI 线程会吞掉崩溃** | 探针在 WinForms 的 `Timer.Tick` 里写空指针，30 秒没崩（异常被消息泵的处理器接住），一个 dump 也没有 | 造崩溃要放在**后台线程**（`IsBackground=true` 的 `Thread`），别放在 UI 线程的 Tick 里 |
| **`0xC0000005` 是 int32 负数** | 8 位十六进制在 PowerShell 里按**有符号**解析成 `-1073741819`，于是：`-eq 0xC0000005` 对 int64 的 3221225477 永远 False（少掉最关键那句）；`[uint32]0xC0000005` **直接抛异常**（负数不许转无符号），整个解析进 catch、`ok=false` | 别跟这个字面量比数值 —— 用格式化好的字符串 `$x.exceptionHex -eq '0xC0000005'`；要写常量就写十进制 3221225477 并注释原因。这一处两轮内踩了三次（core 判定、formatter、测试默认参数） |
| **合成二进制结构要按「实际写了几项」算偏移** | 自己造测试用 minidump 时按 2 个流算出 56，实际写了 3 个流（目录占 36 字节），流和目录**重叠** → 模块数 0、异常码空、版本号空，三个用例一起红 | 先算 `32 + 项数×12`，再用变量推后续偏移；别手写魔数 |
| **`$grid.CurrentCell = ...` 不触发事件** | `-Check` 自检靠设 CurrentCell 来渲染详情，但没有消息泵时 `SelectionChanged` **不触发**，详情框留着上一行 —— 三条自检一直在验错的行，而且"有内容"看不出错 | 界面逻辑要抽出可直调的函数（这次抽成 `Render-DetailForRow`），自检调函数、不依赖控件事件 |
| **只在开发目录绿 = 没验** | 开发机有真实 state、有上次的产物，很多"缺失分支"永远走不到。审计一解压就 EXIT=1：doctor 的「从未跑过」分支没有任何测试走过 | 发布前**必须解压到空目录跑一遍门禁**。凡是"某状态不存在时怎么显示"的代码，都要在**真的没有那个状态**的环境里验一次 |
| **`baseline -Create` 必须在 `ensure-bom` 之后** | 改了 `.ps1` → 先建基线 → 再补 BOM：补 BOM **改变了文件哈希**，而 `baseline.json` 本身在包里 → 用户解压后跑 `errwatch-baseline.ps1` 会报「有文件被改过」（2026-10-25 打包 `ca` 时真踩到，靠"解压后先跑基线自检"抓到） | 固定顺序：`ensure-bom` → `baseline -Create` → 校验 → 门禁 → `pack`。验证：解压到空目录，**先跑基线自检**（必须全部一致）再跑 `tests\run.cmd` |
| **`[System.IO.File]::ReadAllText('相对路径')` 不是按 pwsh 的 `$PWD` 解析** | 在 pwsh 里 `cd` 到项目目录后，`[System.IO.File]::WriteAllText('免责声明.md', ...)` **写到了 `E:\ai\免责声明.md`**（进程 CWD），真实文件一个字节没动 —— 而脚本还打印了「已更新」，看着像成功。同一天在审计索引上又踩一次（`Could not find a part of the path 'E:\ai\tests\审计索引.md'`）。`Get-Content`/`Set-Content` 这类 **cmdlet 可以**用相对路径，只有 **.NET 静态方法不行** | 用 .NET 静态方法时一律传**绝对路径**（`Join-Path $PWD.Path 'x.md'`）。判断"改成功没有"**必须回读文件**，不能信脚本自己打印的那句「已更新」 |
| **edit 工具写文件不带 BOM** | 每次 `edit` 改过 `.ps1` 之后 BOM 就没了，`pack` 会拒绝（「缺 UTF-8 BOM」）—— 这是门禁在正常工作 | 改完 `.ps1` 一律先跑 `tools\ensure-bom.ps1`，再谈打包。别看到 pack 报错就去查别的原因 |
| **黑名单追不上新文件** | 排除清单漏了某个功能新引入的落盘文件（tray-fallback.jsonl），本机真实进程名进了送审包。而基线用扩展名白名单、打包用目录扫描，两套判据天然漂移 | 判据收成**唯一一份**（`tools\pack-filter.ps1`）+ **白名单**：数据文件必须在白名单里才准进包，新文件默认挡住 |
| **改判据结构要同步改"检查结构"的测试** | 把排除名单从两个脚本搬到 pack-filter 之后，`test-settings` F 仍在原文里搜 `'settings.json'` → 永远 FAIL；门禁红了但功能是好的 | 断言尽量打**行为/判据**（"pack-filter 里有它"、"两处引用了同一份"），少打源码文本结构 |
| **提前 `return` 会让后加的段落永远不跑** | `Invoke-ErrwatchRetention` 在「没有终态超期记录」时直接 return，于是新加的「升级记录按时间清」永远执行不到 —— 实测删 0 行、剩 0 行，文件一个字节没动 | 往长函数里加新段之前先找有没有前置 `return`；改成"只写说明不返回"，或把各段拆成独立可测函数 |
| **`[ordered]` 字典与 `PSCustomObject` 的判据不能混用** | `$dict.PSObject.Properties['k']` **恒为 null**（哪怕键在）。实现里用它判断 → 每条诊断都 `continue`（上一轮踩过）；**测试断言里用它 → 把正确实现判成红**（这轮 D/H 用例，白改了两轮实现才发现是断言错） | 字典用 `.Contains('k')` 或点访问；对象才用 `PSObject.Properties`。写断言时先问一句「我验的这个东西到底是不是字典」 |
| **「状态文件的带后缀备份」逃过所有判据** | 改 `history.jsonl` 前手工备份成 `history.jsonl.bak-before-recordid` —— 它既不是精确名 `history.jsonl`（状态名单），也不匹配 `*.bak`（glob）→ 会带着本机真实进程名进送审包。审计 P2-2 同类，换个后缀就复发 | 判据加 `*.bak-*`；**重要改动的备份直接放项目外**（`%TEMP%`）。做完改动先跑一次「会打包什么」的测试，别等审计抓 |
| **改契约字段要连着改三个读它的人** | 给 `subject` 加 `recordId` 会连锁影响：UI 详情构造诊断（要传进去）、`Get-ErrwatchEventSubjectKey`（要纳入键）、`errwatch-trace.ps1`（要能按它查）。漏掉任一环，功能"加了但用不上" | 加字段先 `grep` 全仓引用点，逐个确认「读 / 写 / 比较」三种用法都考虑过；空值语义要写进注释（**空 ≠ 未知**） |
| **无控制台子进程的 stdout 不是 UTF-8** | 用 `ProcessStartInfo` 重定向跑 `-Check`，断言「UI 初始化 OK」永远不匹配 —— 读回来是 `UI ��ʼ�� OK`。不是脚本坏了：子进程按**系统 OEM 代码页**（中文机器 936）输出 | 重定向读中文必须显式 `$psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)`；同进程 `&` 调用不受影响，所以只有"跨进程"的测试才会踩到 |
| **`-NonInteractive` 写在 `-File` 之后会被当成脚本参数** | `pwsh -File x.ps1 -Check -NonInteractive` → 「找不到名为 NonInteractive 的参数」，因为 `-File` 之后的都归脚本 | 引擎参数一律放 `-File` 之前：`pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File x.ps1 -Check` |
| **PATH 操纵验不了"没有 pwsh"** | 想用 `$env:PATH='C:\Windows\System32'` 造出「机器上没装 pwsh」，结果 `pwsh` 启动后把自身目录**重新塞回 PATH**，`Get-Command pwsh` 依旧命得中 —— 这个验证方式从头就是无效的 | 把「选哪个引擎」抽成**纯函数**测分支（这次是 `core\engine.ps1` 的 `Select-ErrwatchPsExe`），再用**真 5.1** 跑一遍；别指望改 PATH 模拟缺件 |

## 五、关键文件与命令

```
E:\ai\_tools\errwatch\
  NEXT-SESSION.md          ← 本文件（新会话从这读）
  ISSUES.md                ← A 类已结案 51 条 / B 类剩余 / C 类证据缺口 / D 类教训
  HANDOFF.md               ← 完整历史（80+ 条），要细节再翻
  STATE-CONTRACT.md        ← 状态契约（三维度 + 四维进度 + 保留策略）
  core\exit-intent.ps1     ← 退出意图判定（纯函数，8 条单测）
  core\dump-link.ps1       ← 崩溃快照 ↔ 事件接线（app+pid 双匹配 + 时间窗口；纯函数）
  core\dump-parse.ps1      ← 崩溃快照解读（纯读二进制解析 minidump：异常码 / 访问动作 / 出错模块）
  core\diagnosis-trace.ps1 ← 诊断追溯核心（规则集指纹 / 单条规则内容哈希 / **事件主题键含 recordId**）
  errwatch-trace.ps1       ← 查「当时用的是哪一版规则」+ **-RecordId 精确到某一次事件**（只读）
  core\settings.ps1        ← 用户设置（quietHours / notify.seconds / **watch.extra 手动监视目标**）
  errwatch-dump.ps1        ← 崩溃快照布防（WER LocalDumps；默认预览，-Apply 才写，-SelfTest 自证）
  tests\run.cmd            ← 门禁入口（免执行策略；run.ps1 的包装）
  uninstall.ps1            ← 一键卸载（默认预览）
  tests\drill-cad-20261024.md   ← 浩辰演练手册（C1 已跑通）
  tests\audit-drill-cad-20261024.md ← 演练审计（含时间线/SHA/结论）
```

**常用命令**
```powershell
cd E:\ai\_tools\errwatch
tests\run.cmd                                  # 全门禁（必须 EXIT=0）★ 免执行策略，双击也行
pwsh -File errwatch-doctor.ps1                 # 自检（响应链 + 恢复机会）
pwsh -File errwatch-restart.ps1                # 改完代码后重启看护（会按命令行精确匹配）
pwsh -File errwatch-recover.ps1 -App gcad      # 救援（完整输出）
pwsh -File errwatch-recover.ps1 -App gcad -Brief  # 救援（4 行，托盘用这个）
pwsh -File errwatch-trace.ps1                  # 当前规则集身份（指纹 / 发布标识）
pwsh -File errwatch-trace.ps1 -Latest 10       # 最近 10 条追溯记录
pwsh -File errwatch-trace.ps1 -RecordId 27949  # **某一次**事件（EventRecordID）
pwsh -File errwatch-trace.ps1 -Event 1000      # 这一类事件（1000=应用崩溃）全部追溯记录
pwsh -File tools\ensure-bom.ps1                # 改完 .ps1 必跑
# 发布链（顺序不能反：先基线，再打包）
pwsh -File errwatch-baseline.ps1 -Create
pwsh -File tools\pack.ps1 -Version 20261024-bc -OutDir 'E:\ai\_dist' -Force
pwsh -File tools\make-sbom.ps1 -Zip <zip>; pwsh -File tools\verify-package.ps1 -Zip <zip>
pwsh -File tools\make-release.ps1 -Zip <zip>; pwsh -File tools\check-release-identity.ps1 -Zip <zip>
```

> ⚠️ 不要再写 `powershell -File tests\run.ps1`：本机 5.1 的 LocalMachine 策略是 Undefined
> （默认 Restricted），会直接报 `running scripts is disabled`。`tests\run.cmd` 内部已带
> `-ExecutionPolicy Bypass`，且自动优先用 pwsh 7。

## 六、接手第一件事

```powershell
cd E:\ai\_tools\errwatch
tests\run.cmd                           # 先确认基线绿（免执行策略）
pwsh -File errwatch-doctor.ps1          # 再看工具自己的健康
Get-Content sentinel-pending.json       # 有没有待处理
```

绿了就直接接 **P1 第 1 项（给真实程序布防崩溃快照）** —— 功能已验证（C6 实测 5.86 MB dump 落地），但还没用在任何真实程序上。
一条命令：`pwsh -File errwatch-dump.ps1 -WatchList -Apply -Elevate`（会弹一次 UAC）。
