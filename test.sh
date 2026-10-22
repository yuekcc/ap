#!/usr/bin/env sh
set -eu

odin test src -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false
odin test tui -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false

