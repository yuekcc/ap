$ErrorActionPreference = "Stop"

$odin = Get-Command odin -ErrorAction Stop
$version = & odin version
Write-Host "odin: $version"

$out = "bin"
New-Item -ItemType Directory -Force -Path $out | Out-Null
Set-Location $out

& odin build ../ap -out:ap.exe -vet
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& odin build ../ap-tui -out:ap-tui.exe -vet
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& odin build ../ap-web -out:ap-web.exe -vet
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
Write-Host "built $out\ap.exe $out\ap-tui.exe $out\ap-web.exe"
