#!/usr/bin/env sh
set -eu

version=$(odin version)
echo "odin: $version"
case "$version" in
  *dev-2026-09-nightly*) ;;
  *) echo "warning: 本项目在 dev-2026-09-nightly 上验证；当前编译器版本不同，nightly stdlib 可能不兼容。" >&2 ;;
esac

odin build src -out:ap -vet
echo "built ap"
