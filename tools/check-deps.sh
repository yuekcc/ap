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
	for f in ap-web/*.odin; do
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
					echo "check-deps: $f: ap-web 不允许 import \"$path\"（只允许 ap-core/client、ap-core/protocol）"
					fail=1
					;;
				esac
				;;
			esac
		done <"$f"
	done

	for f in ap-tui/*.odin; do
		[ -f "$f" ] || continue
		while IFS= read -r line; do
			t=${line#"${line%%[![:space:]]*}"}
			case "$t" in
			import\ *)
				rest=${t#*\"}
				[ "$rest" = "$t" ] && continue
				path=${rest%%\"*}
				case "$path" in
				core:* | base:* | vendor:* | ../ap-core/client | ../ap-core/protocol | ../lineedit) ;;
				*)
					echo "check-deps: $f: ap-tui 不允许 import \"$path\"（只允许 ap-core/client、ap-core/protocol、lineedit）"
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

	for f in ap-cli/*.odin; do
		[ -f "$f" ] || continue
		while IFS= read -r line; do
			t=${line#"${line%%[![:space:]]*}"}
			case "$t" in
			import\ *)
				rest=${t#*\"}
				[ "$rest" = "$t" ] && continue
				path=${rest%%\"*}
				case "$path" in
				core:* | base:* | vendor:* | ../ap-core | ../ap-core/platform | ../ap-core/protocol | ../ap-core/tool | tools | skills) ;;
				*)
					echo "check-deps: $f: ap-cli 不允许 import \"$path\"（只允许 apcore、tool、platform、protocol、tools、skills）"
					fail=1
					;;
				esac
				;;
			esac
		done <"$f"
	done

	for f in ap-cli/tools/*.odin; do
		[ -f "$f" ] || continue
		while IFS= read -r line; do
			t=${line#"${line%%[![:space:]]*}"}
			case "$t" in
			import\ *)
				rest=${t#*\"}
				[ "$rest" = "$t" ] && continue
				path=${rest%%\"*}
				case "$path" in
				core:* | base:* | vendor:* | ../../ap-core/tool | ../../ap-core/platform | ../../ap-core/protocol) ;;
				*)
					echo "check-deps: $f: ap-cli/tools 不允许 import \"$path\"（只允许 tool、platform、protocol）"
					fail=1
					;;
				esac
				;;
			esac
		done <"$f"
	done

	for f in ap-cli/skills/*.odin; do
		[ -f "$f" ] || continue
		while IFS= read -r line; do
			t=${line#"${line%%[![:space:]]*}"}
			case "$t" in
			import\ *)
				rest=${t#*\"}
				[ "$rest" = "$t" ] && continue
				path=${rest%%\"*}
				case "$path" in
				core:* | base:* | vendor:* | ../../ap-core/platform) ;;
				*)
					echo "check-deps: $f: ap-cli/skills 不允许 import \"$path\"（只允许 platform）"
					fail=1
					;;
				esac
				;;
			esac
		done <"$f"
	done

	for f in magi/*.odin; do
		[ -f "$f" ] || continue
		while IFS= read -r line; do
			t=${line#"${line%%[![:space:]]*}"}
			case "$t" in
			import\ *)
				rest=${t#*\"}
				[ "$rest" = "$t" ] && continue
				path=${rest%%\"*}
				case "$path" in
				core:* | base:* | vendor:* | ../ap-core | ../ap-core/platform) ;;
				*)
					echo "check-deps: $f: magi 不允许 import \"$path\"（只允许 apcore、platform）"
					fail=1
					;;
				esac
				;;
			esac
		done <"$f"
	done

	for f in lineedit/*.odin; do
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
					echo "check-deps: $f: lineedit 不允许 import 本地包 \"$path\"（只允许 core:/base:/vendor:）"
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
				core:* | base:* | vendor:* | ../platform | ../protocol | ../tool) ;;
				*)
					echo "check-deps: $f: ap-core/engine 不允许 import \"$path\""
					fail=1
					;;
				esac
				;;
			esac
		done <"$f"
	done

	for f in ap-core/tool/*.odin; do
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
					echo "check-deps: $f: ap-core/tool 不允许 import \"$path\"（只允许 platform、protocol）"
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
				core:* | base:* | vendor:* | engine | platform | protocol | tool) ;;
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

	# cmd/* 是薄入口：每个入口只允许 import 自己对应的库包。
	for f in cmd/*/*.odin; do
		[ -f "$f" ] || continue
		entry=${f#cmd/}
		entry=${entry%%/*}
		case "$entry" in
		ap) own="../../ap-cli" ;;
		magi-cli) own="../../magi" ;;
		*) own="../../$entry" ;;
		esac
		while IFS= read -r line; do
			t=${line#"${line%%[![:space:]]*}"}
			case "$t" in
			import\ *)
				rest=${t#*\"}
				[ "$rest" = "$t" ] && continue
				path=${rest%%\"*}
				case "$path" in
				core:* | base:* | vendor:* | "$own") ;;
				*)
					echo "check-deps: $f: cmd/$entry 入口只允许 import \"$own\""
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

	probe=ap-web/__check_deps_probe.odin
	printf '%s\n' 'package apweb' '' 'import "../lineedit"' >"$probe"
	if check_imports >/dev/null 2>&1; then
		rm -f "$probe"
		echo "check-deps: self-test 失败：ap-web import lineedit 没有被检出"
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

	probe=ap-cli/__check_deps_probe.odin
	printf '%s\n' 'package apcli' '' 'import "../ap-core/engine"' >"$probe"
	if check_imports >/dev/null 2>&1; then
		rm -f "$probe"
		echo "check-deps: self-test 失败：ap-cli 直接 import engine 没有被检出"
		exit 1
	fi
	rm -f "$probe"

	probe=ap-core/engine/__check_deps_probe.odin
	printf '%s\n' 'package engine' '' 'import "../../ap-cli/tools"' >"$probe"
	if check_imports >/dev/null 2>&1; then
		rm -f "$probe"
		echo "check-deps: self-test 失败：engine 反向 import ap-cli/tools 没有被检出"
		exit 1
	fi
	rm -f "$probe"

	probe=lineedit/__check_deps_probe.odin
	printf '%s\n' 'package lineedit' '' 'import "../ap-core"' >"$probe"
	if check_imports >/dev/null 2>&1; then
		rm -f "$probe"
		echo "check-deps: self-test 失败：lineedit 依赖本地包没有被检出"
		exit 1
	fi
	rm -f "$probe"

	echo "check-deps: self-test 通过"
	exit 0
fi

check_imports
check_build
echo "check-deps: ok"
