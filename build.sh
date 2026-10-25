#!/usr/bin/env sh
set -eu

version=$(odin version)
echo "odin: $version"

ext=""
out="bin"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ext=".exe" ;;
esac

mkdir -p $out
cd $out

odin build ../ap -out:ap$ext -vet
odin build ../ap-tui -out:ap-tui$ext -vet
odin build ../ap-web -out:ap-web$ext -vet
echo "built ${out}/ap$ext ${out}/ap-tui$ext ${out}/ap-web$ext"
