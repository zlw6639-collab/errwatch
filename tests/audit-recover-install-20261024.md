# 审计：recover 分清「没装」和「没开自动保存」（2026-10-24）

> 用户原话：「`recover` 分清『没装』和『没开自动保存』—— 现在 acad 没装却说『自动保存没开』」。
> 这不是文案问题，是**两个判定错误叠在一起**：数据层把通用目录当成程序专属目录，判定层又没有「装没装」这个维度。

## 一、复现（先跑，不猜）

```
pwsh -File errwatch-recover.ps1 -App acad.exe -NonInteractive
```

修改前输出：

```
结果：没找到恢复文件
【注意】
  - 恢复目录在，但里面没有文件 —— 最常见的原因是「自动保存没开」，其次是崩溃后已被程序清理
  - 查过的位置：%TEMP% / *.sv$ → 0 个；%LOCALAPPDATA%\Temp / *.sv$ → 0 个；
                %USERPROFILE%\Documents / *.sv$ → 0 个；%USERPROFILE%\Documents / *.bak → 0 个
```

**破绽就在「查过的位置」里**：全是 `%TEMP%`、`%LOCALAPPDATA%\Temp`、`Documents` —— 这些目录**任何机器上都有**，
不能证明 CAD 装了。而结论却说「自动保存没开」，等于让用户去一个不存在的程序里改设置。

## 二、根因（两条，缺一不可）

### 根因 1（数据层）：通用目录没标 `generic`

`core\recover.json` 里 autocad 的两条 `Documents` 路径漏了 `"generic": true`：

```json
{ "path": "%USERPROFILE%\\Documents", "filter": "*.sv$", "recurse": true }        // 缺 generic
{ "path": "%USERPROFILE%\\Documents", "filter": "*.bak", "recurse": true }        // 缺 generic
```

`Invoke-ErrwatchRecoveryProbe` 的判定是：

```powershell
$verdict = 'NO_DIR'
if ($dirExistsCount -gt 0)    { $verdict = 'GENERIC_ONLY' }
if ($specificDirCount -gt 0)  { $verdict = 'EMPTY' }        # ← Documents 存在就算「专属目录在」
if ($total -gt 0)             { $verdict = 'HAS_FILES' }
```

`Documents` 永远存在 → `$specificDirCount>0` → `EMPTY` → 文案「自动保存没开」。

**修**：autocad 两条 + blender 一条 `Documents` 补 `"generic": true`。判据是「这个目录是不是人人都有」：
`%TEMP%`、`%LOCALAPPDATA%\Temp`、`%USERPROFILE%\Documents` 都是。

### 根因 2（判定层）：没有「装没装」维度

即使 generic 标对了，`EMPTY` 也只能推出「目录在但空」，**推不出「装了什么、该不该来开自动保存」**。
所以新增安装探测，返回三态 `yes / no / unknown`：

| state | 含义 | 界面上怎么说 |
|---|---|---|
| `yes` | 有安装证据 | 「装了（已安装程序列表里有：Adobe Photoshop 2025）」 |
| `no` | 核对了证据，全没命中 | 「没找到安装痕迹 —— 大概率没装；没装就谈不上自动保存没开」 |
| `unknown` | 探测本身不可用 | 「无法确认是否安装，按『可能没装』理解」——**绝不猜成没装** |

证据来源（任一命中即 `yes`）：
1. 策略 `install.files` 的通配路径存在（便携版也能命中）；
2. 卸载项 `DisplayName` 命中 `install.words`；
3. 探测失败（读不到注册表 / 没声明）→ `unknown`。

## 三、一个差点埋进去的坑：子串匹配会误判

第一版用 `-match [regex]::Escape($word)` 做子串匹配，实测：

| 关键词 | 命中项 | 结果 |
|---|---|---|
| `acad` | `Windows SDK Facade Windows WinMD Versioned` | **误判为装了**（"F-acad-e"） |

所以改成**词边界**匹配：`(^|[^\w])词([^\w]|$)`。`AutoCAD 2024` 命中 ✅，`Facade` 不命中 ✅，
`微软OfficePLUS` 里的 `Office` 也不命中（中文算 `\w`），而 `Microsoft Office 家庭和学生版` 命中 ✅。

## 四、实测（本机真实数据）

| 程序 | installed | 证据 | probeVerdict | 人话结论 |
|---|---|---|---|---|
| `acad.exe` | **no** | 核对了 4 类证据都没命中 | GENERIC_ONLY | 没装 → 别去改设置 ✅ |
| `winword.exe` | **yes** | 文件：`C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE` | HAS_FILES | 装了且找到恢复文件 |
| `photoshop.exe` | **yes** | 已安装程序列表：`Adobe Photoshop 2025` | EMPTY | 真·自动保存没开 |

> Photoshop 装在 `D:\photoshop\Adobe Photoshop 2025` —— 这正好证明**不能硬编码 `Program Files`**，
> 注册表卸载项才是可靠证据来源。

## 五、测试（11/11）

`tests\test-recover.ps1`，新增四个用例，其中 H/I 互为反证：

| 用例 | 证明 |
|---|---|
| H | 只有通用目录存在 → `GENERIC_ONLY`，且**不得**出现「自动保存没开」 |
| I | **反证**：同样的目录去掉 `generic` → 必须变 `EMPTY`（证明 generic 是判据，不是碰巧） |
| J | 安装证据：文件在 → `yes`；删掉 → `no` + 说明「没找到安装痕迹」 |
| K | 无安装声明 → `unknown`，**不得**说成「大概率没装」 |

## 六、门禁

28/28 · 应急恢复 **11/11**（本轮新接入 `run.ps1`，之前只在发布时单跑）· 其余专项无回归。
`run.ps1` 新增一条：recover 测试失败时**整个门禁 exit 1**（此前专项测试失败只打印不拦）。

## 七、剩余（诚实记录）

1. **卸载项残留**：程序卸了但注册表没清 → 会判 `yes`。只影响文案，不影响「不动文件」的边界。
2. **绿色版/便携版**：只靠 `install.files` 里的通配路径；不在这些路径的便携版会被判 `no`（所以文案留了「绿色版除外」）。
3. **`install` 数据要随版本更新**：`photoshop` 的注册表词写的是 `Adobe Photoshop`（不带年份，故意写宽），
   路径表里的版本号仍会随版本变；变了会报「目录不存在」，那是在提醒更新这一条。
4. **词边界对短词仍有风险**：`code` 这类短词没有放进 `words`（会命中一堆），只用了 `Visual Studio Code`。
