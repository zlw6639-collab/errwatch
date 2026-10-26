# make-icon.ps1 — 生成 errwatch 自己的托盘图标（2026-10-26）
#
# 为什么要有这个文件：
#   托盘一直用 `[System.Drawing.SystemIcons]::Application` —— 那是 Windows 的
#   通用"应用程序"灰图标。用户原话：「托盘的图标是默认的 不是我们的这个
#   可以换一个你喜好的吗 现在这个给人感觉怪怪的」。
#
# 设计（小尺寸也能认出来，这是硬约束）：
#   · 深色圆角方底（#1F2937）：在浅色/深色任务栏上都有对比度
#   · 中间一只**眼睛**：这个工具做的事就是"看着"程序有没有挂
#   · 瞳孔用绿色（#22C55E）：表示"在看、正常"——出故障时由托盘代码换成琥珀色
#   · 16×16 时退化成"圆 + 中心点"也能看出是个眼睛，不做细节
#
# 输出：多尺寸 ICO（16/24/32/48/64/128/256），Vista+ 用 PNG 压缩存
#
# 用法：pwsh -File tools\make-icon.ps1 -OutFile errwatch.ico

[CmdletBinding()]
param(
    [string]$OutFile = '',
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
$root = if ($Root) { $Root } else { Split-Path -Parent $PSScriptRoot }
if (-not $OutFile) { $OutFile = Join-Path $root 'errwatch.ico' }

Add-Type -AssemblyName System.Drawing

# 画一只眼睛（给定尺寸）
function New-EyeBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear([System.Drawing.Color]::Transparent)

    $bg = [System.Drawing.Color]::FromArgb(31, 41, 55)      # #1F2937
    $white = [System.Drawing.Color]::FromArgb(243, 244, 246) # #F3F4F6
    $green = [System.Drawing.Color]::FromArgb(34, 197, 94)   # #22C55E

    $pad = [Math]::Max(1, [int]($size * 0.06))
    $rect = New-Object System.Drawing.Rectangle($pad, $pad, ($size - 2 * $pad), ($size - 2 * $pad))

    # 圆角底
    $radius = [int]($size * 0.22)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $path.AddArc(($rect.Right - $d), $rect.Y, $d, $d, 270, 90)
    $path.AddArc(($rect.Right - $d), ($rect.Bottom - $d), $d, $d, 0, 90)
    $path.AddArc($rect.X, ($rect.Bottom - $d), $d, $d, 90, 90)
    $path.CloseFigure()
    $bgBrush = New-Object System.Drawing.SolidBrush($bg)
    $g.FillPath($bgBrush, $path)

    if ($size -le 40) {
        # 小尺寸（16/24/32）：按像素现实设计，别指望保留眼形曲线。
        # 实测：v1 直接用大图的贝塞尔眼形缩到 16px → 糊成"深色方块里一颗绿点"；
        #       32px 也只有"方块里一个白椭圆"，不像眼睛。
        # 这里改成「圆形深底 + 更大的眼白 + 明确瞳孔」，牺牲曲线换辨识度：
        # 圆底在小尺寸比圆角方更像图标；眼白给到 92% 宽度才看得见。
        $g.Clear([System.Drawing.Color]::Transparent)
        $cb = New-Object System.Drawing.SolidBrush($bg)
        $g.FillEllipse($cb, 0, 0, $size, $size)

        $ew = $size * 0.92
        $eh = $size * 0.62
        $ex = ($size - $ew) / 2
        $ey = ($size - $eh) / 2
        $wb = New-Object System.Drawing.SolidBrush($white)
        $g.FillEllipse($wb, [float]$ex, [float]$ey, [float]$ew, [float]$eh)

        # 瞳孔：在 16px 上至少要 5px 直径才看得出来
        $pr = [Math]::Max(2.2, $size * 0.16)
        $gb = New-Object System.Drawing.SolidBrush($green)
        $g.FillEllipse($gb, [float]($size / 2 - $pr), [float]($size / 2 - $pr), [float]($pr * 2), [float]($pr * 2))

        $cb.Dispose(); $wb.Dispose(); $gb.Dispose()
    } else {
        # 大尺寸：眼形 = 两段圆弧拼的杏仁状，中间加瞳孔
        $w = $rect.Width * 0.82
        $h = $rect.Height * 0.62
        $cx = $rect.X + $rect.Width / 2
        $cy = $rect.Y + $rect.Height / 2
        $left = $cx - $w / 2
        $top = $cy - $h / 2

        $eye = New-Object System.Drawing.Drawing2D.GraphicsPath
        # 上弧：左端 → 右端
        $eye.AddBezier($left, $cy, ($left + $w * 0.25), $top, ($left + $w * 0.75), $top, ($left + $w), $cy)
        # 下弧：右端 → 左端
        $eye.AddBezier(($left + $w), $cy, ($left + $w * 0.75), ($cy + $h / 2), ($left + $w * 0.25), ($cy + $h / 2), $left, $cy)
        $eye.CloseFigure()

        $wb = New-Object System.Drawing.SolidBrush($white)
        $g.FillPath($wb, $eye)
        $penW = [Math]::Max(1.0, $size * 0.035)
        $wpen = New-Object System.Drawing.Pen($white, [float]$penW)
        $g.DrawPath($wpen, $eye)   # 描边让边缘更实

        # 瞳孔
        $pr = $rect.Width * 0.17
        $gb = New-Object System.Drawing.SolidBrush($green)
        $g.FillEllipse($gb, [float]($cx - $pr), [float]($cy - $pr * 0.92), [float]($pr * 2), [float]($pr * 1.84))
        # 高光（大尺寸才画，小尺寸会变脏）
        if ($size -ge 48) {
            $hl = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200, 255, 255, 255))
            $hr = $pr * 0.34
            $g.FillEllipse($hl, [float]($cx - $pr * 0.55), [float]($cy - $pr * 0.62), [float]($hr * 2), [float]($hr * 2))
            $hl.Dispose()
        }
        $wb.Dispose(); $gb.Dispose(); $wpen.Dispose(); $eye.Dispose()
    }

    $bgBrush.Dispose(); $path.Dispose(); $g.Dispose()
    return $bmp
}

# ── 打包成 ICO（多尺寸，PNG 压缩）─────────────────────────────────────────
# ICO 结构：ICONDIR(6) + N×ICONDIRENTRY(16) + 各图像数据
# Vista 起允许图像数据是 PNG 原样（省空间，且 256 必须用 PNG）
$sizes = @(16, 24, 32, 48, 64, 128, 256)
$images = @()
foreach ($s in $sizes) {
    $bmp = New-EyeBitmap $s
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $images += [pscustomobject]@{ Size = $s; Bytes = $ms.ToArray() }
    $ms.Dispose(); $bmp.Dispose()
}

$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($out)
$bw.Write([uint16]0)                 # reserved
$bw.Write([uint16]1)                 # type = icon
$bw.Write([uint16]$images.Count)     # count

$offset = 6 + 16 * $images.Count
foreach ($img in $images) {
    $dim = if ($img.Size -ge 256) { 0 } else { $img.Size }   # 256 记作 0
    $bw.Write([byte]$dim)            # width
    $bw.Write([byte]$dim)            # height
    $bw.Write([byte]0)               # color count
    $bw.Write([byte]0)               # reserved
    $bw.Write([uint16]1)             # planes
    $bw.Write([uint16]32)            # bit count
    $bw.Write([uint32]$img.Bytes.Length)
    $bw.Write([uint32]$offset)
    $offset += $img.Bytes.Length
}
foreach ($img in $images) { $bw.Write($img.Bytes) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($OutFile, $out.ToArray())
$bw.Dispose(); $out.Dispose()

$fi = Get-Item $OutFile
"图标已生成: $($fi.FullName)"
"  尺寸: $($sizes -join ' / ')  共 $($images.Count) 层"
"  大小: $([math]::Round($fi.Length / 1KB, 1)) KB"
