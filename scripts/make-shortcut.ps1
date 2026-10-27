# 在桌面放一个「絮语中继」快捷方式，图标用 App 图标
# 用法：powershell -ExecutionPolicy Bypass -File scripts\make-shortcut.ps1
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$png = Join-Path $root 'App\Assets.xcassets\AppIcon.appiconset\AppIcon.png'
$ico = Join-Path $root 'relay\xuyu.ico'
$bat = Join-Path $root 'relay\start-relay.bat'

# 1. 把 App 图标缩成几种尺寸，裁成和 iPhone 一样的圆角，写成 .ico（每个尺寸内嵌一张 PNG）
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

# 2. 桌面快捷方式：双击启动中继
$desktop = [Environment]::GetFolderPath('Desktop')
$link = Join-Path $desktop '絮语中继.lnk'
$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($link)
$sc.TargetPath = $bat
$sc.WorkingDirectory = Join-Path $root 'relay'
$sc.IconLocation = "$ico,0"
$sc.Description = '启动絮语中继：开着它，手机才能聊天'
$sc.Save()

Write-Host "桌面快捷方式已创建：$link"
