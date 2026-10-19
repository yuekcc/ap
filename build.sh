#!/usr/bin/env sh
set -eu

odin build src -out:ap -vet
echo "built ap"
