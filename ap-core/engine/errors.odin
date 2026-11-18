package engine

import "../platform"
import "../protocol"
import "../tool"
import "core:fmt"

// engine 的错误类型不依赖 CLI 退出码；ap 在边界处映射成 Exit_Code。
Project :: platform.Project
SCHEMA_VERSION :: protocol.SCHEMA_VERSION
PROVIDER_NAME :: protocol.PROVIDER_NAME

// 产品版本：用于 provider 的 User-Agent 与 CLI 的 --version。与
// SCHEMA_VERSION（transcript/stream 的 wire 兼容版本）不是一回事。
VERSION :: "0.1.0"

Tool_Def :: tool.Tool_Def
Function_Def :: tool.Function_Def
Error_Kind :: enum int {
	None     = 0,
	Usage    = 1,
	Internal = 2,
	Provider = 3,
	Tool     = 4,
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
}

ok_error :: proc() -> Error {
	return {kind = .None, message = ""}
}

make_error :: proc(kind: Error_Kind, format: string, args: ..any) -> Error {
	return {kind = kind, message = fmt.tprintf(format, ..args)}
}

is_ok :: proc(err: Error) -> bool {
	return err.kind == .None
}

// 把 platform 的纯消息错误提升为 engine 错误；kind 由调用方按场景指定。
from_platform :: proc(err: platform.Error, kind := Error_Kind.Usage) -> Error {
	if platform.is_ok(err) {
		return ok_error()
	}
	return {kind = kind, message = err.message}
}
