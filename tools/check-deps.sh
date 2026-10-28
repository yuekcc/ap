#!/usr/bin/env sh
# 检查包边界。Odin 没有 Go 的 internal 机制，只能靠构建期脚本约束。
# 用法：
#   tools/check-deps.sh            正常检查
#   tools/check-deps.sh --self-test 反向用例（临时加一条禁止 import，期望失败）

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

tmpdir=$(mktemp -d 2>/dev/null || echo "$root/tmp/check-deps-$$")
mkdir -p "$tmpdir"
trap 'rm -rf "$tmpdir"' EXIT

self_test=false
[ "${1:-}" = "--self-test" ] && self_test=true

# 返回 0 表示通过；打印每条违规。
check_imports() {
	fail=0
	for f in ap-web/*.odin ap-tui/*.odin; do
		[ -f "$f" ] || continue
		while IFS= read -r line; do
			t=${line#"${line%%[![:space:]]*}"}
			case "$t" in
			import\ *)
				rest=${t#*\"}
				[ "$rest" = "$t" ] && continue
				path=${rest%%\"*}
				case "$path" in
				core:* | base:* | vendor:* | ../ap-core/client | ../ap-core/protocol) ;;
				*)
					echo "check-deps: $f: 前端不允许 import \"$path\"（只允许 ap-core/client、ap-core/protocol）"
					fail=1
					;;
				esac
				;;
			esac
		done <"$f"
	done

	for f in ap-core/client/*.odin; do
		[ -f "$f" ] || continue
		while IFS= read -r line; do
			t=${line#"${line%%[![:space:]]*}"}
			case "$t" in
			import\ *)
				rest=${t#*\"}
				[ "$rest" = "$t" ] && continue
				path=${rest%%\"*}
				case "$path" in
				core:* | base:* | vendor:* | ../platform | ../protocol) ;;
				*)
					echo "check-deps: $f: ap-core/client 不允许 import \"$path\"（只允许 ap-core/platform、ap-core/protocol）"
					fail=1
					;;
				esac
				;;
			esac
		done <"$f"
	done

	for f in ap-core/engine/*.odin; do
		[ -f "$f" ] || continue
		while IFS= read -r line; do
			t=${line#"${line%%[![:space:]]*}"}
			case "$t" in
			import\ *)
				rest=${t#*\"}
				[ "$rest" = "$t" ] && continue
				path=${rest%%\"*}
				case "$path" in
				core:* | base:* | vendor:* | ../platform | ../protocol) ;;
				*)
					echo "check-deps: $f: ap-core/engine 不允许 import \"$path\""
					fail=1
					;;
				esac
				;;
			esac
		done <"$f"
	done

	for f in ap-core/platform/*.odin ap-core/protocol/*.odin; do
		[ -f "$f" ] || continue
		while IFS= read -r line; do
			t=${line#"${line%%[![:space:]]*}"}
			case "$t" in
			import\ *)
				rest=${t#*\"}
				[ "$rest" = "$t" ] && continue
				path=${rest%%\"*}
				case "$path" in
				core:* | base:* | vendor:*) ;;
				*)
					echo "check-deps: $f: 不允许 import 本地包 \"$path\""
					fail=1
					;;
				esac
				;;
			esac
		done <"$f"
	done

	for f in ap-core/*.odin; do
		[ -f "$f" ] || continue
		while IFS= read -r line; do
			t=${line#"${line%%[![:space:]]*}"}
			case "$t" in
			import\ *)
				rest=${t#*\"}
				[ "$rest" = "$t" ] && continue
				path=${rest%%\"*}
				case "$path" in
				core:* | base:* | vendor:* | engine | platform | protocol) ;;
				*)
					echo "check-deps: $f: apcore 根包不允许 import \"$path\""
					fail=1
					;;
				esac
				;;
			esac
		done <"$f"
	done

	# apcore 根包必须是可导入库，不能带入口。
	case "$(cat ap-core/*.odin 2>/dev/null)" in
	*"main :: proc"*)
		echo "check-deps: apcore 根包不允许定义 main（入口在 cmd/ap）"
		fail=1
		;;
	esac

	# cmd/* 是薄入口：只能 import 对应的库包与 apcore。
	for f in cmd/*/*.odin; do
		[ -f "$f" ] || continue
		while IFS= read -r line; do
			t=${line#"${line%%[![:space:]]*}"}
			case "$t" in
			import\ *)
				rest=${t#*\"}
				[ "$rest" = "$t" ] && continue
				path=${rest%%\"*}
				case "$path" in
				core:* | base:* | vendor:* | ../../ap-core | ../../ap-tui | ../../ap-web) ;;
				*)
					echo "check-deps: $f: cmd 入口只允许 import \"../../ap-core\"、\"../../ap-tui\"、\"../../ap-web\""
					fail=1
					;;
				esac
				;;
			esac
		done <"$f"
	done

	return $fail
}

check_build() {
	fail=0
	for name in ap-web ap-tui; do
		dir="cmd/$name"
		json="$tmpdir/$name.json"
		exe="$tmpdir/$name.exe"
		if ! odin build "$dir" -out:"$exe" -export-dependencies:json -export-dependencies-file:"$json" >/dev/null 2>&1; then
			echo "check-deps: odin build $dir 失败"
			fail=1
			continue
		fi
		case "$(cat "$json")" in
		*"ap-core/engine/"*)
			echo "check-deps: $dir 的编译文件里出现了 ap-core/engine/（agent 被链进前端）"
			fail=1
			;;
		esac
	done
	return $fail
}

if $self_test; then
	probe=ap-web/__check_deps_probe.odin
	printf '%s\n' 'package apweb' '' 'import "../ap-core/engine"' >"$probe"
	if check_imports >/dev/null 2>&1; then
		rm -f "$probe"
		echo "check-deps: self-test 失败：禁止 import 没有被检出"
		exit 1
	fi
	rm -f "$probe"

	probe=cmd/ap-web/__check_deps_probe.odin
	printf '%s\n' 'package main' '' 'import "../../ap-core/engine"' >"$probe"
	if check_imports >/dev/null 2>&1; then
		rm -f "$probe"
		echo "check-deps: self-test 失败：cmd 入口的禁止 import 没有被检出"
		exit 1
	fi
	rm -f "$probe"
	echo "check-deps: self-test 通过"
	exit 0
fi

check_imports
check_build
echo "check-deps: ok"
