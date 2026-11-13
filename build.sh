#!/usr/bin/env sh
set -eu

version=$(odin version)
echo "odin: $version"

# #load_directory("dist") 在编译期读取，前端构建必须先于 odin build。
# dist 不提交进仓库，缺少它时无法编译 ap-web。
if command -v npx >/dev/null 2>&1; then
  echo "npx found: rebuilding ap-web/dist"
  npm --prefix ap-web run build
elif [ -d ap-web/dist ]; then
  echo "npx not found: using existing ap-web/dist"
else
  echo "error: ap-web/dist missing and npx not found" >&2
  echo "run: npm --prefix ap-web install && npm --prefix ap-web run build" >&2
  exit 1
fi

ext=""
out="build"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ext=".exe" ;;
esac

tools/check-deps.sh

mkdir -p $out
cd $out

odin build ../cmd/ap -out:ap$ext -vet
odin build ../cmd/ap-tui -out:ap-tui$ext -vet
odin build ../cmd/ap-web -out:ap-web$ext -vet
odin build ../cmd/magi-cli -out:magi-cli$ext -vet
echo "built ${out}/ap$ext ${out}/ap-tui$ext ${out}/ap-web$ext ${out}/magi-cli$ext"
