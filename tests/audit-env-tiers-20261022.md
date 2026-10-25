# 审计：环境指纹分层（2026-10-22 晚）

> 交接待办 **B-1**。目标：插耳机 / 插 U 盘不再触发「环境变了」，同时不丢真变化。

## 一、问题（三个独立的误报源）

环境指纹原本是**全字段一个哈希**，任何字段变化都算「换了硬件」：

| # | 误报源 | 真实数据（本机） | 后果 |
|---|---|---|---|
| 1 | 音频端点数量 | `audioEndpoints` = **38**（枚举的是全部 Render 设备，含已断开的） | 插拔耳机 → 报告顶部警告 + 历史分成两段 |
| 2 | 磁盘数 | `Disk\Enum` 把 **U 盘也算一块** | 插一次 U 盘 → 同上 |
| 3 | 虚拟网卡 / 虚拟显示 | `network` 共 **11** 项，其中 **9** 项是虚拟/共享：`Remote NDIS`×5、`Wintun`、`Kernel Debug`、`RAS Async`、`Bluetooth PAN`；`gpu` 里还混着 `GameViewer Virtual Display Adapter` | 开热点 / 开 VPN / 开投屏 → 警告「换了硬件」，而 GPU 那一项的措辞直接误导 |

证据取自 `env-last.json`（18:59:54 采集）与 `Get-ErrwatchEnvFingerprint` 实测输出。

## 二、改法

### 1. 分层（`core\analyze.ps1`，唯一实现）

- `$script:EwEnvCoreFields` = `system / cpu / gpu / disks / memoryGB / network`
- `Get-ErrwatchEnvTier`：在表里 → `core`，**其余一律 `peripheral`**（新增采集项默认不惊动用户）
- 指纹返回 `Hash`（全字段，旧口径）/ `CoreHash`（★ 分段依据）/ `PeripheralHash`

### 2. 消掉三个误报源

| 项 | 改法 |
|---|---|
| 磁盘 | 只数**固定磁盘**（`^USB` 开头的条目归外围层 `removableDisks`） |
| 显卡 / 网卡 | 新增 `Test-ErrwatchVirtualDevice`，过滤 `WAN Miniport / Virtual / TAP / Loopback / Remote NDIS / Wintun / RAS Async / Kernel Debug / Bluetooth Device / Hyper-V / VMware / VirtualBox / WireGuard / ZeroTier / IddCx / RDP / Remote Display / Mirror Driver / usbmmidd`；并通过 `Sort-Object -Unique` 让注册表枚举顺序不影响指纹 |

### 3. 顺带修掉两个真缺陷

| 缺陷 | 原因 | 修复 |
|---|---|---|
| `cpu` 维度从未取到 | `Get-ItemProperty` 整键读取时被同键下的 REG_BINARY（`Identifier`）拖垮：`can't cast Byte[] to Int32` | 改 `Get-Item` + `GetValue('ProcessorNameString')` |
| `memoryGB` 维度从未取到 | `.Translated` 是 REG_RESOURCE_LIST，`.NET GetValue` 返回 `null` | 先按 `byte[]` 解析页数，失败回退 `Get-CimInstance Win32_ComputerSystem`；都失败则**不写该字段** |

### 4. 消费端跟着分层

| 位置 | 变化 |
|---|---|
| `errwatch.ps1` 报告 | 顶部显示 `CoreHash`；**只有核心层差异**才警告并逐项列出；外围层变化刻意**不打印** |
| `errwatch.ps1` 历史 | `env` 写 `CoreHash`（不再写全字段 hash） |
| `errwatch-query.ps1 -CurrentEnv` | 按 `coreHash` 分段；旧口径（全字段 hash）记录一并算当前环境；**`env` 为空的旧记录保留并标注**（不知道环境 ≠ 不是当前环境） |

## 三、验证

| 项 | 结果 |
|---|---|
| 新增 `tests\env-tiers.ps1` | **30/30 PASS**（归层 4 + 虚拟设备 8 + 差异比较 9 + 旧格式/哈希 6 + 真实链路 3） |
| `tests\run.ps1` | 28/28，误诊 0、漏诊 0 |
| `tests\unknown-chain.ps1` | 9/9 |
| 真实报告 `errwatch.ps1` | 指纹 `da3f84e670ad`；**无「环境不同」警告**（升级前会对同一台机器误报 GPU/网卡变化） |
| 真实指纹内容 | `gpu` 1 项、`network` 2 项（Realtek 2.5GbE + RZ616 Wi-Fi）、`cpu` 已读到 `AMD Ryzen 7 9700X` |

## 四、口径变更与兼容

- 旧 `history.jsonl` 的 12 条记录 `env` **全是空**（指纹功能 18:59 才上线）→ 迁移无意义，按「环境未知」保留。
- `env-last.json` 已就地升级为分层结构（保留原 `time`），避免「升级口径」被自己误报成「换了硬件」。
- `Hash` 字段名保留（全字段口径），`CoreHash` 才是新分段依据 —— 旧工具读 `hash` 不会崩。

## 五、边界与未验证

1. **虚拟设备名单是黑名单**：新软件造出没见过的设备名仍会被当核心硬件（例如某个厂商的虚拟打印机）。宁可漏。
2. `audioEndpoints` = 38 这个数本身会随系统后台设备启停波动，现在只记录、不提示；要精确判断应改为「当前启用的默认输出设备」，未做。
3. `memoryGB` 在**当前受限环境**两级都失败（注册表 REG_RESOURCE_LIST + CIM 被拒），字段缺失属预期；普通用户机器上 CIM 通常可读，**未在真机验证**。
4. `cpu` 修复依赖 `ProcessorNameString` 存在，**未在无该值的机器上验证**。
5. 外围层变化完全不提示是刻意的取舍：透明性让位于「别吵」，数据仍在 `env-last.json`。

## 六、教训

- 「采集口径升级」本身就是一次环境变化，必须**先升级缓存再采集**，否则用户会看到一条莫名其妙的「你换硬件了」。
- 判断「什么算环境变化」不能只看「技术上变了没」，要看「变了会不会让旧结论失效」——插耳机不会，换显卡会。
