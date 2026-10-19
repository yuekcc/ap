$ErrorActionPreference = "Stop"

$odin = Get-Command odin -ErrorAction Stop
$version = & odin version
Write-Host "odin: $version"

& odin build src -out:ap.exe -vet
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
Write-Host "built ap.exe"
