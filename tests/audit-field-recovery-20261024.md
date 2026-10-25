# 审计：用「现场软件」验证恢复能力（2026-10-24）

> 背景：CAD 只是例子。用户指出「可以用现场的」——于是这一轮不再用合成夹具，
> 而是**盘点本机真实安装的软件，用真实存在的文件走一遍救援**。

## 一、现场盘点（注册表 + 目录实测）

本机注册表可见 86 个程序。有「未保存工作」语义的，实测恢复目录：

| 软件 | 恢复目录实测 | 结论 |
|---|---|---|
| Microsoft Office 2021 | `%APPDATA%\Microsoft\Word` **有真实 `.asd`**（108 KB，8-12） | ✅ 可现场验证 |
| Adobe Photoshop 2025 | `%APPDATA%\Adobe\Adobe Photoshop 2025\AutoRecover` **目录在、空** | ✅ 可加条目（机制可探针） |
| 嘉立创EDA 专业版 | `Documents\LCEDA-Pro\projects\*.eprj2` 是**已保存工程**；专业版靠云端保存 | ⚠️ 不套「未保存恢复」，会给误导指引 |
| Visual Studio 2022/2026 | `Documents\Visual Studio *\Backup Files` **不存在** | 条目保留但不现场验证 |
| VS Code / Notepad++ / JetBrains / Blender | 恢复目录**都不存在**（本机没装） | doctor 已诚实报「没装，或路径表过时」 |
| Unity / VRChat / Cherry Studio | 有数据目录，但「未保存工作」语义弱（场景/聊天记录） | 暂不加 |

## 二、真实现场演练（Word）

```
pwsh -File errwatch-recover.ps1 -App winword -Json
```

结果（**真实文件，不是夹具**）：

- 找到 `wzl简历((Unsaved-312715023730911408)).asd`（110,592 字节）
- 新鲜度判为 **STALE**（8-12 的旧文件，`sessionKnown=false`）
- 给的引导是「先复制副本再改名」「用 Word 的『恢复未保存的文档』打开」
- 同时列出「路径不存在：`%LOCALAPPDATA%\Microsoft\Office\UnsavedFiles`」——诚实地说明那条候选没命中

**这次演练证明的是**：路径表在真实机器上能把文件找出来、能分清新旧、不会替你改文件。
它**不能**证明「恢复出来的内容一定是完整的」——那需要真的打开看，属于用户自己的判断。

## 三、新增：Photoshop 条目（按真实路径）

- 路径：`%APPDATA%\Adobe\Adobe Photoshop 2025\AutoRecover`（本机真实存在）
- 另加 `%TEMP%\Photoshop Temp*`（暂存盘，标 `generic`，文案明确说「不是成品」）
- 机制检查用 `behavior`（近 7 天 AutoRecover 目录有没有文件），不用注册表 —— 版本间位置不稳
- 版本号写死在路径里：**升级到 2026 后会报「路径不存在」，那是提醒更新这一条，不是故障**（已写进 `_note`）

现场验证：

```
status       : NOT_FOUND
probeVerdict : EMPTY
candidates   : 0
notes        : 恢复目录在，但里面没有文件 —— 最常见的原因是「自动保存没开」…
```

doctor 的恢复机会段现在会列出：

```
[空] photoshop   Photoshop 自动恢复（AutoRecover） —— 目录在，但从没产生过恢复文件（很可能没开）
     · 开法：Photoshop → 编辑 → 首选项 → 文件处理 → 勾选「自动存储恢复信息时间间隔」
```

## 四、一个必须说清的限制

**「找得到文件」≠「救得回来」。** 这一轮验证的是前半段（定位 + 分档 + 引导），
后半段（内容是否完整、自动保存间隔丢了多少）只能在用户真崩一次之后才知道。

这也是为什么方案里 Gate 5 仍然重要 —— 只不过**不必等到 CAD**，
用本机已有的 Word/Photoshop 就能演练；EDA 这类云同步软件则应另立语义，不硬套本地恢复。

## 五、门禁

`test-opportunity` 13/13 · `test-recover` 7/7（新增条目未破坏既有行为）· doctor exit 0。
