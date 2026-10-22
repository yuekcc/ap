#!/usr/bin/env sh
set -eu

odin test cli -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test tui -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false

