#!/usr/bin/env sh
set -eu

version=$(odin version)
echo "odin: $version"
case "$version" in
  *dev-2026-09-nightly*) ;;
  *) echo "warning: 本项目在 dev-2026-09-nightly 上验证；当前编译器版本不同，nightly stdlib 可能不兼容。" >&2 ;;
esac

exe=""
out=""
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) exe=".exe" ;;
  *)
    # 源码目录 ap/ 与二进制 ap 同名，Unix 上不能都放在仓库根目录。
    exe=""
    out="bin/"
    mkdir -p bin
    ;;
esac

odin build ap -out:${out}ap$exe -vet
odin build ap-tui -out:${out}ap-tui$exe -vet
echo "built ${out}ap$exe ${out}ap-tui$exe"
