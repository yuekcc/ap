$ErrorActionPreference = "Stop"

$odin = Get-Command odin -ErrorAction Stop
& odin test ap-core/protocol -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& odin test ap-core/platform -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& odin test ap-core/client -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& odin test ap-core/engine -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& odin test ap-core -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& odin test ap-tui -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& odin test ap-web -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& ./tools/check-deps.ps1
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
