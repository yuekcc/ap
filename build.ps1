$ErrorActionPreference = "Stop"

$odin = Get-Command odin -ErrorAction Stop
$version = & odin version
Write-Host "odin: $version"
if ($version -notlike "*dev-2026-09-nightly*") {
    Write-Warning "本项目在 dev-2026-09-nightly 上验证；当前编译器版本不同，nightly stdlib 可能不兼容。"
}

& odin build src -out:ap.exe -vet
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& odin build tui -out:ap-tui.exe -vet
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
Write-Host "built ap.exe ap-tui.exe"
