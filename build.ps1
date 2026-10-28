$ErrorActionPreference = "Stop"

$odin = Get-Command odin -ErrorAction Stop
$version = & odin version
Write-Host "odin: $version"

# 有 npx 就先刷新 ap-web/dist（esbuild）；没有则用仓库里已提交的 dist。
# #load_directory("dist") 在编译期读取，前端构建必须先于 odin build。
$npx = Get-Command npx -ErrorAction SilentlyContinue
if ($npx) {
    Write-Host "npx found: rebuilding ap-web/dist"
    & npm --prefix ap-web run build
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
} else {
    Write-Host "npx not found: using committed ap-web/dist"
}

& ./tools/check-deps.ps1
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$out = "bin"
New-Item -ItemType Directory -Force -Path $out | Out-Null
Set-Location $out

& odin build ../cmd/ap -out:ap.exe -vet
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& odin build ../cmd/ap-tui -out:ap-tui.exe -vet
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& odin build ../cmd/ap-web -out:ap-web.exe -vet
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
Write-Host "built $out\ap.exe $out\ap-tui.exe $out\ap-web.exe"
