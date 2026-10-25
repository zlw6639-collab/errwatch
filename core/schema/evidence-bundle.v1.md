# errwatch 证据包格式 v1（evidence bundle）

> 这是 errwatch 的**跨环境接口**。
> 采集器（任何等级、任何环境）只负责产出证据包；分析器只负责读证据包。
> 两边互不知道对方是怎么跑的 —— 这就是「核心能力与运行入口分离」的落点。

## 一、为什么要有这个格式

errwatch 过去的诊断逻辑和「采集动作」缠在一起：脚本既读事件日志、又翻译、又写报告。
后果是 —— **采集环境一坏，能力全没**：

| 场景 | 旧形态会发生什么 |
|---|---|
| Windows 起不来（引导/驱动损坏） | 脚本在磁盘上，但跑不起来 → 什么都拿不到 |
| 磁盘出现坏道 | 脚本本身可能读不出来 |
| 安全模式 | 能跑但能力受限，取到的证据留在本机，出不去 |

把「证据」变成一种**自描述、可搬运、可在别处解读**的东西之后：

- L3 可以在 **WinRE / WinPE（只有 cmd）** 里采集 → 存到 U 盘 → 拿到**另一台健康机器**上分析
- 磁盘坏了也能做：先只读镜像/取关键文件，分析在别处进行
- 采集器坏了不影响分析器，分析器坏了不影响已有证据包

## 二、目录结构

```
<bundle>/
  manifest.json        ← 唯一入口，自描述清单（分析器只读这个文件）
  README.txt           ← 给"在 WinRE 里用记事本看的人"的纯文本说明
  items/
    System.evtx        ← 事件日志原件（直接文件拷贝，不是本机 wevtutil 导出）
    Application.evtx
    SrtTrail.txt       ← 启动修复日志（Windows 起不来时的第一手证据）
    bcd.txt            ← bcdedit /enum all
    services.txt       ← 离线 hive 里的服务启动类型
    disk.txt           ← diskpart list disk/volume/partition
    packages.txt       ← dism /get-packages（最近更新的包）
    ...
```

**约定**：条目名只允许 `[A-Za-z0-9._-]`，`items/` 下不建子目录。所有引用用**相对路径 + 正斜杠**。

## 三、manifest.json 字段

```json
{
  "schema": "errwatch-evidence-bundle",
  "schemaVersion": 1,
  "bundleId": "20261022-153000-C",
  "collectedAt": "2026-10-22T15:30:00+08:00",
  "level": 3,
  "collector": "runners/L3-collect.cmd",
  "collectorVersion": "1.0",
  "host": {
    "computerName": "DESKTOP-X",
    "environment": "winre",
    "systemRoot": "X:\\Windows",
    "readOnlyTarget": true
  },
  "target": {
    "systemDrive": "C:",
    "windowsDir": "C:\\Windows",
    "detected": true
  },
  "items": [
    {
      "name": "System.evtx",
      "file": "items/System.evtx",
      "kind": "eventlog",
      "bytes": 20971520,
      "sha256": "AB12...",
      "note": "离线拷贝自目标系统"
    }
  ],
  "commands": [
    { "cmd": "bcdedit /enum all", "exit": 0, "output": "items/bcd.txt" },
    { "cmd": "chkdsk C: /scan", "exit": 1, "output": "items/chkdsk.txt", "note": "只读扫描" }
  ],
  "missing": [
    { "what": "MEMORY.DMP", "why": "不存在" },
    { "what": "Minidump", "why": "目录不存在或为空" }
  ]
}
```

`kind` 取值（v1）：`eventlog` / `wer` / `dump-list` / `registry` / `boot` / `disk` / `package` / `log` / `text` / `other`。

## 四、五条硬规矩

1. **自描述** —— 分析器只读 `manifest.json`，不猜文件名、不遍历目录、不依赖采集器的目录习惯。
2. **不依赖采集环境** —— 所有引用是相对路径 + 哈希；分析器不需要知道采集时用的是 cmd 还是 PowerShell。
3. **采集不判断** —— 采集器**不下结论**（不写"磁盘坏了"），只如实记录"取到了什么、没取到什么"。
   判断属于分析层 —— 这样同一份证据可以被反复质疑、用新规则重跑。
4. **失败也是证据** —— 取不到的东西必须进 `missing` 或 `commands`（exit≠0）。
   "取不到"本身是信息，静默跳过会让分析器误以为系统正常。
5. **只读优先** —— L3 采集默认不改动被检查的系统（不 chkdsk /f、不 sfc、不写注册表）。
   任何修复动作必须显式开关，且属于"恢复"而不是"取证"。

## 五、与分级的对应关系

| 等级 | 采集入口 | 分析在哪做 | 典型产物 |
|---|---|---|---|
| L1 正常看护 | `errwatch.ps1` | 本机 | 报告 + `history.jsonl` |
| L2 安全模式诊断 | `errwatch.ps1`（安全模式降级） | 本机，证据可打包外带 | 报告 + 证据包 |
| L3 恢复环境取证 | `runners/L3-collect.cmd`（cmd / WinRE） | **另一台机器**或恢复后的系统 | 证据包 → `errwatch-bundle-analyze.ps1` |

`history.jsonl` 与证据包不是一回事：前者是本机时间线（要看趋势），后者是**一次故障的现场**（要能搬走）。
