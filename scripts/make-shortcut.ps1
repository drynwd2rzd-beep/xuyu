# 放一个「絮语中继」快捷方式，图标用 App 图标。中继的「开机自动启动」也调用这个脚本（relay/src/autostart.js），建快捷方式只在这里写一份
# 用法：powershell -ExecutionPolicy Bypass -File scripts\make-shortcut.ps1
#   不带参数：重新生成图标，在桌面放快捷方式
#   -Link 路径 -Minimized：在指定位置放一个最小化启动的快捷方式（开机自动启动用），不重新生成图标
param(
    [string]$Link = '',
    [switch]$Minimized
)

$root = Split-Path -Parent $PSScriptRoot
$png = Join-Path $root 'App\Assets.xcassets\AppIcon.appiconset\AppIcon.png'
$ico = Join-Path $root 'relay\xuyu.ico'
$bat = Join-Path $root 'relay\start-relay.bat'

# 1. 把 App 图标缩成几种尺寸，裁成和 iPhone 一样的圆角，写成 .ico（每个尺寸内嵌一张 PNG）
function New-Icon {
    Add-Type -AssemblyName System.Drawing
    $source = [System.Drawing.Image]::FromFile($png)
    $sizes = 16, 24, 32, 48, 64, 128, 256
    $images = foreach ($size in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap $size, $size
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.Clear([System.Drawing.Color]::Transparent)
        $r = [Math]::Max(2, $size * 0.225)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = $r * 2
        $path.AddArc(0, 0, $d, $d, 180, 90)
        $path.AddArc($size - $d, 0, $d, $d, 270, 90)
        $path.AddArc($size - $d, $size - $d, $d, $d, 0, 90)
        $path.AddArc(0, $size - $d, $d, $d, 90, 90)
        $path.CloseFigure()
        $g.SetClip($path)
        $g.DrawImage($source, 0, 0, $size, $size)
        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        , @{ Size = $size; Bytes = $ms.ToArray() }
    }
    $source.Dispose()

    $out = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $out
    $w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$images.Count)
    $offset = 6 + 16 * $images.Count
    foreach ($img in $images) {
        $s = if ($img.Size -ge 256) { 0 } else { $img.Size }
        $w.Write([Byte]$s); $w.Write([Byte]$s); $w.Write([Byte]0); $w.Write([Byte]0)
        $w.Write([UInt16]1); $w.Write([UInt16]32)
        $w.Write([UInt32]$img.Bytes.Length); $w.Write([UInt32]$offset)
        $offset += $img.Bytes.Length
    }
    foreach ($img in $images) { $w.Write($img.Bytes) }
    $w.Flush()
    [System.IO.File]::WriteAllBytes($ico, $out.ToArray())
}

if (-not $Link) { New-Icon }

# 2. 快捷方式：双击启动中继
if (-not $Link) { $Link = Join-Path ([Environment]::GetFolderPath('Desktop')) '絮语中继.lnk' }
$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($Link)
$sc.TargetPath = $bat
$sc.WorkingDirectory = Join-Path $root 'relay'
if (Test-Path $ico) { $sc.IconLocation = "$ico,0" }
$sc.Description = '启动絮语中继：开着它，手机才能聊天'
# 7：最小化启动
if ($Minimized) { $sc.WindowStyle = 7 }
$sc.Save()

Write-Host "快捷方式已创建：$Link"
