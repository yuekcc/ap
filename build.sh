#!/usr/bin/env sh
set -eu

version=$(odin version)
echo "odin: $version"

# 有 npx 就先刷新 ap-web/dist（esbuild）；没有则用仓库里已提交的 dist。
# #load_directory("dist") 在编译期读取，前端构建必须先于 odin build。
if command -v npx >/dev/null 2>&1; then
  echo "npx found: rebuilding ap-web/dist"
  npm --prefix ap-web run build
else
  echo "npx not found: using committed ap-web/dist"
fi

ext=""
out="bin"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ext=".exe" ;;
esac

mkdir -p $out
cd $out

odin build ../cmd/ap -out:ap$ext -vet
odin build ../ap-tui -out:ap-tui$ext -vet
odin build ../ap-web -out:ap-web$ext -vet
echo "built ${out}/ap$ext ${out}/ap-tui$ext ${out}/ap-web$ext"
