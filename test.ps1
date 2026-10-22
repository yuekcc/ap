$ErrorActionPreference = "Stop"

$odin = Get-Command odin -ErrorAction Stop
& odin test cli -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& odin test tui -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
