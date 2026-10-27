# Upload the signing certificate to GitHub Secrets (run on your own computer).
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\setup-signing.ps1 -P12 "C:\path\cert.p12" -Profile "C:\path\app.mobileprovision"
# The p12 password is typed by you when gh asks for it; it is never stored in any file.
param(
  [Parameter(Mandatory = $true)][string]$P12,
  [Parameter(Mandatory = $true)][string]$Profile,
  [string]$Repo = 'drynwd2rzd-beep/xuyu'
)

$gh = 'C:\Program Files\GitHub CLI\gh.exe'
foreach ($f in @($P12, $Profile)) {
  if (-not (Test-Path $f)) { Write-Host "File not found: $f" -ForegroundColor Red; exit 1 }
}

$p12b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $P12)))
$profb64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $Profile)))

$p12b64 | & $gh secret set P12_BASE64 -R $Repo
$profb64 | & $gh secret set PROFILE_BASE64 -R $Repo
Write-Host ''
Write-Host 'Now type the p12 password and press Enter (input is hidden):' -ForegroundColor Cyan
& $gh secret set P12_PASSWORD -R $Repo

Write-Host ''
Write-Host 'Done. Secrets in the repo:' -ForegroundColor Green
& $gh secret list -R $Repo
