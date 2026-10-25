#!/usr/bin/env sh
set -eu

odin test ap -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test ap-tui -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test ap-web -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
