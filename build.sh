#!/usr/bin/env bash
set -eux

version=$(odin version)
echo "odin: $version"

FLAGS=(-o:speed)

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

mkdir -p $out
cd $out

odin build ../cmd/ap -out:ap$ext -vet "${FLAGS[@]}"
odin build ../cmd/ap-tui -out:ap-tui$ext -vet "${FLAGS[@]}"
odin build ../cmd/ap-web -out:ap-web$ext -vet "${FLAGS[@]}"
odin build ../cmd/magi-cli -out:magi-cli$ext -vet "${FLAGS[@]}"
built="${out}/ap$ext ${out}/ap-tui$ext ${out}/ap-web$ext ${out}/magi-cli$ext"

# ap-tray 只支持 Windows，用 GUI subsystem 编译，避免启动时弹出控制台。
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    odin build ../cmd/ap-tray -out:ap-tray$ext -vet -subsystem:windows "${FLAGS[@]}"
    built="$built ${out}/ap-tray$ext"
    ;;
esac

echo "built $built"
