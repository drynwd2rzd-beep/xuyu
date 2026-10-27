# Upload the signing certificate to GitHub Secrets (run on your own computer).
# Usage: powershell -ExecutionPolicy Bypass -File scripts\setup-signing.ps1
# A file picker opens for the .p12 and the .mobileprovision.
# The p12 password is typed by you when gh asks for it; it is never stored in any file.
param(
  [string]$P12 = '',
  [string]$Profile = '',
  [string]$Repo = 'drynwd2rzd-beep/xuyu'
)

Add-Type -AssemblyName System.Windows.Forms

function Pick-File([string]$title, [string]$filter) {
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Title = $title
  $dialog.Filter = $filter
  $dialog.InitialDirectory = [Environment]::GetFolderPath('UserProfile') + '\Downloads'
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
  return ''
}

if (-not $P12) {
  Write-Host 'Step 1/3: choose your .p12 certificate file' -ForegroundColor Cyan
  $P12 = Pick-File 'Choose the .p12 certificate' 'Certificate (*.p12)|*.p12|All files (*.*)|*.*'
}
if (-not $Profile) {
  Write-Host 'Step 2/3: choose your .mobileprovision file' -ForegroundColor Cyan
  $Profile = Pick-File 'Choose the .mobileprovision profile' 'Provisioning profile (*.mobileprovision)|*.mobileprovision|All files (*.*)|*.*'
}

foreach ($f in @($P12, $Profile)) {
  if (-not $f -or -not (Test-Path $f)) { Write-Host "File not chosen or not found: $f" -ForegroundColor Red; exit 1 }
}
Write-Host "  p12:     $P12"
Write-Host "  profile: $Profile"

$gh = 'C:\Program Files\GitHub CLI\gh.exe'
$p12b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $P12)))
$profb64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $Profile)))

$p12b64 | & $gh secret set P12_BASE64 -R $Repo
$profb64 | & $gh secret set PROFILE_BASE64 -R $Repo
Write-Host ''
Write-Host 'Step 3/3: type the p12 password and press Enter (nothing shows while typing, that is normal):' -ForegroundColor Cyan
& $gh secret set P12_PASSWORD -R $Repo

Write-Host ''
Write-Host 'Done. Secrets in the repo:' -ForegroundColor Green
& $gh secret list -R $Repo
