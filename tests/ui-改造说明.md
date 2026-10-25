# UI 改造说明（给帮忙改界面的人）

> 目标文件：`errwatch-ui.ps1`（WinForms 图形界面）。
> **可以只改这一个文件**，改完替换回去就能用 —— 但下面 3 条必须遵守，否则会坏。

## 一、能改什么（安全区）

- 颜色、字体、行高、列宽、间距、按钮位置与文字
- 布局：上下分区、详情区高度、按钮顺序
- 表格样式：交替行色、列头样式、边框
- 文案措辞（除下列"不要动"的图标/字段名）
- 右键菜单项（增删改文字；调用已有按钮用 `PerformClick()`）

## 二、不要动（动了我这边跑不起来）

1. **文件编码必须保持 UTF-8 带 BOM**。
   - 用记事本/VS Code 保存时选「UTF-8 with BOM」。
   - 不带 BOM 的 `.ps1` 在 Windows PowerShell 5.1 下会直接语法崩（本项目踩过，P0 级）。
   - 检查：文件头三个字节是 `EF BB BF`。
2. **这 7 个调用必须保留原签名**（来自 `core\analyze.ps1`，由界面 dot-source 进来）：
   - `Initialize-ErrwatchCore -Root $PSScriptRoot`
   - `TranslateForApp <provider> <hay>`（`hay` 由 `New-ErrwatchHay <code> <msg>` 生成）
   - `New-ErrwatchHay <code> <msg>`
   - `Get-ErrwatchEventRule <id> <provider>`
   - `Get-ErrwatchRouteText <route>`
   - `Get-ErrwatchVerifyHint <hit>`
   - `Get-ErrwatchCoreInfo`
3. **不要改这几个路径/文件名**：`core\analyze.ps1`、`history.jsonl`、`feedback.jsonl`、`errwatch.ps1`、`errwatch-evidence.ps1`、`errwatch-query.ps1`、`errwatch-fix.ps1`。

## 三、改完怎么自测（对方能做）

**没有完整目录也行**：只发 `errwatch-ui.ps1` 过去时，界面仍能打开（只是没有数据、不能扫描）。

```powershell
# 语法 + 构造自检（不弹窗，只初始化）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\errwatch-ui.ps1 -Check
```

输出应包含：

```
UI 初始化 OK
列宽: 时间=... 程序=... ...
右键菜单: ...
```

如果它报 `ParserError` 或「Missing closing」，99% 是 **BOM 丢了或引号写坏**。

**有完整目录时**，还能跑：

```powershell
pwsh -File tests\run.ps1        # 冒烟会解析全部 .ps1，能抓语法问题
```

## 四、回传要求

- 回传 **改完的 `errwatch-ui.ps1`** 本身（不要截图代替）
- 附一句改了什么（颜色/布局/文案）
- 我会在本地验证：`-Check` → 5.1 语法解析 → 基线重建

## 五、我这边替换后的 4 步验收

```powershell
cd E:\ai\_tools\errwatch
copy <新文件> .\errwatch-ui.ps1 -Force
pwsh -File tools\ensure-bom.ps1                 # 1. 补 BOM（若丢了）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\errwatch-ui.ps1 -Check   # 2. 构造自检
pwsh -File tests\run.ps1                        # 3. 回归+冒烟
pwsh -File errwatch-baseline.ps1 -Create        # 4. 重建基线（哈希会变，属正常）
```

> 注意：替换后 `baseline.json` 会报「变更」——这是防篡改设计，不是错误；确认是有意修改后重建基线即可。

## 六、更省事的替代方案

- **只改样式** → 发一个文件够了（对方截图确认，你替换后跑上面 4 步）
- **要改交互逻辑、或对方需要真实数据试效果** → 发整包（`E:\ai\_dist\errwatch-20261022-送审包.zip`），对方解压后改，回传时只给 `errwatch-ui.ps1`
