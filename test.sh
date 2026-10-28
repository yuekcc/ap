#!/usr/bin/env sh
set -eu

odin test ap-core/protocol -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test ap-core/platform -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test ap-core/client -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test ap-core/engine -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test ap-core -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test ap-tui -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test ap-web -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false

tools/check-deps.sh
