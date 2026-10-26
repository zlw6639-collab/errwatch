# tools/pack-filter.ps1 — 「什么不能进交付物」的唯一一份判据  2026-10-24
#
# 为什么要有这个文件（外部审计 P2-2 的根因）：
#   打包（tools\pack.ps1）和哈希基线（errwatch-baseline.ps1）原来**各写一份排除清单**：
#     · baseline 是「扩展名白名单（*.ps1/*.json/*.jsonl/…）+ 名字黑名单」
#     · pack 是「目录全扫 + 名字黑名单 + glob 黑名单」
#   两套判据必然漂移。本轮就是这么漏的：`tray-fallback.jsonl` 是 fallback 功能**新引入**的
#   落盘文件，两处都没写它 —— 于是本机真实进程名（本机真实进程名，含第三方软件）和真实
#   时间戳进了送审包。而 `tests\_gate-b12.txt` 更典型：baseline 按扩展名根本不管 .txt，
#   pack 按目录扫就会打进去。
#
# 结论：**黑名单永远追不上「功能带来的新落盘文件」**。所以这里做两件事：
#   1. 状态文件名收成唯一一份（$EwStateFileNames），两个工具都 dot-source 本文件；
#   2. 加**白名单**：发行包里允许出现的 .jsonl/.log/.txt 只有 $EwShippableDataFiles
#      里那几个（测试夹具），新出现的运行时文件默认**进不了包**，必须显式加白名单。
#      守卫见 tests\test-pack-hygiene.ps1。
#
# 边界：本文件只做「判断」，不做任何删除/移动/写入。

# ── 运行时状态 / 本机记录：既不进基线，也不进发行包 ──────────────────────
# 判据：会被哨兵/托盘/界面在运行时改写，或承载本机真实数据（进程名、路径、时间戳）。
$script:EwStateFileNames = @(
    # 历史与报告缓存
    'history.jsonl', 'last-success.json', 'last-run.json', 'last-check.json',
    'env-last.json', 'fix-audit.jsonl', 'feedback.jsonl', 'opportunity.json',
    # 界面
    'ui-ignored.json', 'ui-crash.log', 'ui-out.log', 'ui-err.log',
    # ★ 2026-10-26（发布准备时发现）：界面单实例 / 托盘「关闭主界面」用的 PID 文件。
    #   2026-10-24 加它的时候没同步这份名单，于是它带着本机 PID 进了 cj 包
    #   （审计 P2-2 的第三例：状态文件名单追不上新功能）。
    'ui.pid',
    # 哨兵
    'sentinel-last.json', 'sentinel-status.json', 'sentinel-coverage.json',
    'sentinel-pending.json', 'sentinel-events.jsonl', 'sentinel-error.log',
    'sentinel-retention.jsonl', 'sentinel-dumplink.jsonl',
    # 托盘
    'tray-acks.jsonl', 'tray-error.log', 'tray-fallback.jsonl', 'tray-exit.json', 'tray-exit.jsonl',
    # ★ 2026-10-26：托盘自愈记录（explorer 重启后重挂图标 / 启动时就位提示）。
    #   它含本机 PID 与时间戳，属运行时记录 —— 显式写进名单，不靠".log 恰好没进白名单"。
    'tray-events.log',
    # ★ 2026-10-25（审计方向 02 新增的产物）：诊断追溯记录。每次采集都会写，
    #   内容含本机事件主题与规则指纹 —— 和 tray-fallback 同一类，绝不能进包。
    'diagnosis-traces.jsonl',
    # 用户设置（覆盖层）：用户自己的东西，改了不该让基线变红，也不该发给别人
    'settings.json',
    # ★ 2026-10-26（新增 errwatch-launch.ps1 时补的）：每次双击「报错看护」都会追加一行
    #   "这次是谁把谁拉起来的"。它现在靠白名单挡着（.log 默认不进包），但那属于"恰好没漏"——
    #   哪天有人给某项 .log 开白名单就会一起漏出去。显式写进名单，不留这个口子。
    'launch.log'
)

# ── 发行包里的 glob 排除（只对 pack 生效；baseline 按扩展名白名单，本来就不收这些）──
$script:EwPackExcludeGlobs = @(
    'report-*.md', 'unknown-chain-*.json', '*analysis*.md', '一键检查-*.cmd',
    '*.bak', '*.bak[0-9]',
    # ★ 2026-10-25（做 EventRecordID 时差点踩到）：手工备份常写成 `history.jsonl.bak-before-xxx`，
    #   既不是精确名 `history.jsonl`，也不匹配 `*.bak` —— 于是它带着本机真实进程名想进包。
    #   这是审计 P2-2 的同一类泄漏，只是换了后缀。任何「状态文件的带后缀备份」一律挡掉。
    '*.bak-*',
    '*.tmp', '*.corrupt-*', '*.verify.json', '*.sbom.json',
    # 门禁输出被重定向留下的残留（审计 P2-2 同类：tests\_gate-b12.txt）
    '_gate-*.txt'
)

# ── 允许进发行包的数据文件（**白名单**，新文件默认不许）────────────────────
# 只放「测试夹具」这类内容固定、不含本机数据的文件。
$script:EwShippableDataFiles = @(
    'tests\cases.jsonl'                    # 诊断回归用例（合成的）
    'tests\recommendation-safety.jsonl'    # 建议安全性用例（合成的）
    # 包根的中文说明（交付物的一部分，给用户双击看的，不是运行时产物）
    '★ 先看我.txt'
)

# ── 交付包类型（2026-10-25 审计回执：「交付包里混有过时的内部交接材料」）──────
# 审计原话：NEXT-SESSION.md 的交接基准、审计索引的「当前包」、HANDOFF.md 的旧状态、
# 送审说明-20261022.md —— 这些放在一起，下一位审阅者很容易把旧结论当成新结论。
#
# 所以分两种包，判据同样用**白名单**（黑名单追不上新加的文档）：
#   user（默认）—— 给拿到包的人：能用、能自查、合规材料齐。
#   dev          —— 给审阅者：user 的全部 + 开发过程材料（交接 / 遗留 / 审计归档 / 验收清单）。
#
# 默认选 user：**忘了传 -Profile 的结果是「包内容更少」，而不是「把内部材料发给用户」**。
$script:EwShippableDocs = @(
    'README.md'                 # 怎么用
    'CONTRIBUTING.md'           # 贡献政策（公开仓库需要）
    'THIRD-PARTY-NOTICES.md'    # 合规必须
    '免责声明.md'                # 合规必须
    # 这两张是**给用户看的操作卡**（不是开发材料）—— 第一版漏了它们，
    # 结果用 USB/L3 采集的人跑进包里找不到说明书。
    'runners\L3-操作卡.md'
    'runners\USB-自动采集.md'
    # 证据包格式说明：审阅者要看「证据包里有什么」，属格式规范不是交接材料。
    'core\schema\evidence-bundle.v1.md'
    # ★ 2026-10-25（user 包第一版被这条打红）：`STATE-CONTRACT.md` 被测试当作**规格**引用
    #   （test-sentinel J 查「契约 §十」、test-tray F 查「契约 §十一」）。它不是过期的交接材料，
    #   是产品的行为契约 —— 排掉它等于交付一个「自己跑门禁会红」的包。
    #   不是猜的：user 包解压后跑 tests\run.cmd → EXIT=1，两条用例报「找不到该路径」。
    'STATE-CONTRACT.md'
    # 注意：定位.md / 发布流程.md / 开源发布清单.md / core\sigma-convert-report.md
    #       属内部材料，只进 dev 包。
)

# 相对根目录的路径前缀（整棵不要）
$script:EwPackExcludePrefixes = @('_prune-Backup\', '_tmp\', '_dist\')

# 单个文件名是否属于「运行时状态」（两个工具共用这一条判据）
function Test-EwStateFileName {
    param([string]$Name)
    if (-not $Name) { return $false }
    return (@($script:EwStateFileNames) -contains $Name)
}

# .md 文档是否允许进 **user** 包（dev 包不调用这条）
function Test-EwShippableDoc {
    param([string]$RelativePath, [string]$Name)
    if (-not $Name) { return $true }
    if ($Name -notmatch '\.md$') { return $true }
    $norm = ([string]$RelativePath) -replace '/', '\'
    foreach ($ok in @($script:EwShippableDocs)) {
        if ($norm -ieq $ok) { return $true }
    }
    return $false
}

# 该文件是否允许出现在发行包里（白名单判据；运行时状态一律不允许）
function Test-EwShippableDataFile {
    param([string]$RelativePath, [string]$Name)
    if (-not $Name) { return $true }
    # 只有这些扩展名受白名单约束；其余（.ps1/.md/.json 规则文件）不受影响
    # ★ 2026-10-26：原来只管 .jsonl/.log/.txt —— ui.pid 正好落在这个盲区里：
    #   既不在状态名单、也不受白名单约束，于是大摇大摆进了包。
    #   现在把「运行期常见的杂项扩展名」也纳入白名单管辖：默认拒绝。
    if ($Name -notmatch '\.(jsonl|log|txt|pid|flag|tmp|dmp|dat)$') { return $true }
    $norm = ([string]$RelativePath) -replace '/', '\'
    foreach ($ok in @($script:EwShippableDataFiles)) {
        if ($norm -ieq $ok) { return $true }
    }
    return $false
}

# 发行包应当包含哪些文件（pack 与守卫测试共用，避免两份过滤逻辑漂移）
#
# -Profile user（默认）：给拿到包的人。内部交接 / 审计归档 / 验收清单都不进。
# -Profile dev          ：给审阅者。user 的全部 + 开发过程材料。
# 两种包**都**不许带运行时状态文件与含本机数据的文件 —— 那跟包类型无关。
function Get-EwPackFileList {
    param(
        [Parameter(Mandatory)][string]$Root,
        [ValidateSet('user', 'dev')][string]$Profile = 'user'
    )
    $rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($rootFull.Length + 1)
        $skip = $false
        foreach ($p in @($script:EwPackExcludePrefixes)) {
            if ($rel -like "$p*") { $skip = $true; break }
        }
        if ($skip) { continue }
        if (Test-EwStateFileName $f.Name) { continue }
        foreach ($g in @($script:EwPackExcludeGlobs)) {
            if ($f.Name -like $g) { $skip = $true; break }
        }
        if ($skip) { continue }
        if (-not (Test-EwShippableDataFile -RelativePath $rel -Name $f.Name)) { continue }
        # 文档白名单只在 user 包生效：dev 包要带上全部开发材料给审阅者
        if ($Profile -eq 'user' -and -not (Test-EwShippableDoc -RelativePath $rel -Name $f.Name)) { continue }
        $out += [pscustomobject]@{ FullName = $f.FullName; RelativePath = $rel; Name = $f.Name; Length = $f.Length }
    }
    return @($out | Sort-Object RelativePath)
}
