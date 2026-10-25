# 审计：真实崩溃演练 #2（有内容 · 救得回）+ 救援副本保存（2026-10-24）

> 第一轮（`audit-drill-word-20261024.md`）只证明了「链路通」——空白文档没有恢复文件可救。
> 这一轮要证明「**救得回内容**」，并顺手回答用户的问题：「救回来的东西在哪里？能不能让用户选保存路径？」

## 一、第二轮演练（有内容）

### 关键前置：`AutoRecoverTime` 注册表键**不是** Word 读的地方

第一次尝试按惯例改注册表：

```
HKCU\Software\Microsoft\Office\16.0\Word\Options\AutoRecoverTime = 1
```

结果：等 90 秒、强杀、全盘搜 `.asd` —— **一个都没有**。查证：

```
Word.Options.SaveInterval = 10 分钟   ← 还是 10，不是 1
```

**结论：那个注册表键不生效**。正确做法是通过 Word 自己的 COM 接口设：

```powershell
$w = New-Object -ComObject Word.Application
$w.Options.SaveInterval = 1     # Word 自己持久化
```

设完立刻验证 `$w.Options.SaveInterval` 返回 `1`，然后才起文档。**这一条是这次演练最有价值的发现**：按「文档里写的」改注册表，会得到一个「以为开了、其实没开」的假状态——和这个项目之前踩的「文案判断」是同一类错。

### 时间线

| 时刻 | 事件 |
|---|---|
| 02:2x | COM 设 `SaveInterval=1` → 验证读回 1 |
| 02:2x | `Documents.Add()` + `TypeText("errwatch drill v2 …")`，**不保存** |
| 02:21:40 | `%APPDATA%\Microsoft\Word\` 出现 `“自动恢复”保存文档1.asd`（**31.5 KB**） |
| 02:2x | 强杀 WINWORD |
| 之后 | `recover -App winword`：`freshnessSummary.inSession = 1`，候选落在「**本次会话（最可能是你刚丢的那份）**」 |

### 内容验证（不是只看文件名）

| 验证 | 结果 |
|---|---|
| 原始字节 | UTF-8 编码里命中 `errwatch drill v2` |
| Word 打开 `.asd` 读正文 | **成功，61 字符，含演练文本** |
| 结论 | **这一轮真的证明了「内容救得回」**，不是「找到文件」 |

## 二、用户的问题：「救回来的东西在哪里 / 要选保存路径吗」

答：**原来只在原地**——recover 只读、只列路径，从不搬运。所以新增「复制备份」：

| 项 | 实现 |
|---|---|
| CLI | `errwatch-recover.ps1 -SaveTo <目录>`（显式指定才复制；`-IncludeStale` 才连历史遗留一起复制） |
| UI | 右键「⚑ 开始应急救援」→ 结果窗口后问「要把候选文件备份一份吗？」→ 选目录 → 只复制 |
| 核心 | `core\opportunity.ps1` 的 `Copy-ErrwatchRescueCandidates`（唯一实现） |

### 边界（写操作必须说死）

- ✓ **只复制**，原文件不动、不删、不改名
- ✓ **不覆盖**：同名自动加 `(1)`、`(2)`
- ✓ **目标=原目录** → 跳过（复制到自己没意义）
- ✓ **默认不复制「历史遗留」**（旧文件太多，只救本次会话/今天早些时候）
- ✗ **不改扩展名** —— 实测把 `.asd` 改成 `.docx`，Word 报「文件格式与文件扩展名不匹配」，打不开

### 实测：副本的打开方式有硬限制

| 位置 | Word 能否直接打开 |
|---|---|
| `%APPDATA%\Microsoft\Word\`（原恢复目录） | ✅ 能（61 字符，内容对） |
| `%TEMP%\…`（副本） | ❌ 「命令失败」 |
| `Documents\…`（副本） | ❌ 「命令失败」 |
| 哈希 | 三处**完全一致**（复制没坏，是 Word 的路径限制） |

**所以副本的定位是「保险」不是「双击即开」**：防程序自己清理恢复文件；要打开必须走程序自己的恢复入口，或把副本复制回恢复目录。界面文案就是这么写的（不吹成「救回来了」）。

## 三、踩到并修掉的坑

1. **`Split-Path -LiteralPath … -Leaf` 是非法组合**：`-Leaf` 只属于 `-Path` 参数集，
   组合使用抛「无法使用指定的命名参数解析参数集」。我一开始以为是候选数据（含中文引号的路径）有问题，
   `Set-PSDebug -Trace` 才定位到函数体这一行。已改用 `[System.IO.Path]::GetFileName / GetDirectoryName`。
2. **`-IncludeStale:$IncludeStale`** 把 switch 对象当值传，同样报参数集错 → 改 splatting。
3. **edit 之后丢 BOM**：本轮又出现 4 个文件（`errwatch-ui.ps1` / `errwatch-recover.ps1` /
   `core\opportunity.ps1` / `tests\test-recover.ps1`）在 5.1 下报 61 处乱码语法错。
   `ensure-bom.ps1` 修复后 5.1 解析干净。**教训：改完 `.ps1` 必须跑 ensure-bom，不能等打包才想起来。**

## 四、测试（15/15）

`tests\test-recover.ps1` 新增 4 条：

| 用例 | 证明 |
|---|---|
| L | `-SaveTo` 复制成功、**原文件还在**、副本内容一致 |
| M | 同名**不覆盖**（生成 `(1)`，目录里 2 份） |
| N | 保存目录=原目录 → 跳过并说明原因 |
| O | STALE 默认**不复制**；`-IncludeStale` 才复制（两个方向都测） |

## 五、剩余（诚实记录）

1. **「恢复未保存的文档」对话框能否打开任意路径的 `.asd`** 没有用 UI 验证（COM 直接打开是失败的）。
   用户在界面里可能仍要走「复制回恢复目录」这条路——文案已经写明。
2. 第二轮只验证了 **Word**；CAD（`.sv$` 改名 `.dwg`）、Blender（`.blend1`）的「改扩展名能不能开」
   没有实测（`.sv$ → .dwg` 历来是 CAD 社区的通行做法，但没有在本机验过）。
3. 副本保存没有「一键恢复回原目录」的按钮（目前要用户手动复制回去）。
