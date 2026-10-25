package main

import "../internal"
import "core:fmt"
import "core:os"
import "core:strings"

// dist/ 在编译期被读进 exe；dist 必须提交进仓库（见 docs/web.md「构建与运行」）。
EMBEDDED_FILES := #load_directory("dist")

MAX_ASSET_BYTES :: 8 * 1024 * 1024

Asset :: struct {
	name:  string,
	data:  []byte,
	etag:  string,
}

Assets :: struct {
	web_root: string, // 空 = 用内置表
	embedded: []Asset,
}

Asset_Lookup :: struct {
	status:       int,
	data:         []byte,
	content_type: string,
	etag:         string,
}

asset_etag :: proc(data: []byte, allocator := context.temp_allocator) -> string {
	// ETag 是纯内容 hash：静态资源没有修改时间，内容就是唯一缓存键。
	hash: u32 = 2166136261
	for b in data {
		hash = (hash ~ u32(b)) * 16777619
	}
	return strings.clone(fmt.tprintf("\"%08x\"", hash), allocator)
}

normalize_asset_name :: proc(name: string, allocator := context.allocator) -> string {
	return internal.normalize_slashes(name, allocator)
}

make_assets :: proc(web_root: string) -> (Assets, string) {
	if len(web_root) == 0 {
		assets := Assets {
			embedded = make([]Asset, len(EMBEDDED_FILES)),
		}
		for file, i in EMBEDDED_FILES {
			assets.embedded[i] = Asset {
				name = normalize_asset_name(file.name),
				data = file.data,
				etag = asset_etag(file.data, context.allocator),
			}
		}
		return assets, ""
	}

	root, err := internal.canonicalize_path(web_root, true)
	if !internal.is_ok(err) {
		return {}, err.message
	}
	if !os.is_dir(root) {
		return {}, fmt.tprintf("web root is not a directory: %s", web_root)
	}
	return Assets{web_root = root}, ""
}

// 把 URL path 变成资源名："/" -> index.html，"/sub/" -> sub/index.html。
// 返回非 0 status 表示应直接拒绝（403 路径穿越）。
asset_name_from_path :: proc(path: string, allocator := context.temp_allocator) -> (string, int) {
	if len(path) == 0 || path[0] != '/' {
		return "", 404
	}
	name := normalize_asset_name(strings.trim_left(path, "/"), allocator)
	if len(name) == 0 {
		name = "index.html"
	} else if strings.has_suffix(name, "/") {
		name = strings.concatenate({name, "index.html"}, allocator)
	}
	if strings.contains_rune(name, '\x00') {
		return "", 403
	}
	for segment in strings.split(name, "/", allocator) {
		if segment == ".." {
			return "", 403
		}
		if segment == "." {
			return "", 403
		}
	}
	return name, 0
}

lookup_asset :: proc(assets: ^Assets, path: string) -> Asset_Lookup {
	// path 已由 server.odin 解析时 percent-decode 过一次，这里不再解码。
	name, status := asset_name_from_path(path)
	if status != 0 {
		return {status = status}
	}
	if len(assets.web_root) == 0 {
		return lookup_embedded(assets, name)
	}
	return lookup_disk(assets.web_root, name)
}

lookup_embedded :: proc(assets: ^Assets, name: string) -> Asset_Lookup {
	for asset in assets.embedded {
		if asset.name == name {
			if len(asset.data) > MAX_ASSET_BYTES {
				return {status = 413}
			}
			return {
				status = 200,
				data = asset.data,
				content_type = mime_type_for(name),
				etag = asset.etag,
			}
		}
	}
	return {status = 404}
}

within_root :: proc(root, target: string) -> bool {
	if target == root {
		return true
	}
	prefix := root
	if !strings.has_suffix(prefix, "/") {
		prefix = fmt.tprintf("%s/", prefix)
	}
	return strings.has_prefix(target, prefix)
}

// internal.canonicalize_path 用 context.allocator；磁盘模式每个请求都要调用，
// 临时把 allocator 指向 temp，避免静态文件服务持续泄漏。
canonicalize_temp :: proc(path: string) -> (string, internal.Error) {
	old_allocator := context.allocator
	context.allocator = context.temp_allocator
	result, err := internal.canonicalize_path(path, true)
	context.allocator = old_allocator
	return result, err
}

lookup_disk :: proc(root, name: string) -> Asset_Lookup {
	joined, _ := os.join_path([]string{root, name}, context.temp_allocator)
	info, err := os.stat(joined, context.temp_allocator)
	if err != nil {
		return {status = 404}
	}
	candidate := joined
	if info.type == .Directory {
		candidate, _ = os.join_path([]string{joined, "index.html"}, context.temp_allocator)
		info, err = os.stat(candidate, context.temp_allocator)
		if err != nil {
			return {status = 404}
		}
	}
	if info.type != .Regular {
		return {status = 404}
	}

	// 解析符号链接后再检查是否仍在 web-root 内，防止 web-root 里的链接指向外部。
	canonical, cerr := canonicalize_temp(candidate)
	if !internal.is_ok(cerr) || !within_root(root, canonical) {
		return {status = 403}
	}
	stat, serr := os.stat(canonical, context.temp_allocator)
	if serr != nil {
		return {status = 404}
	}
	if stat.size > MAX_ASSET_BYTES {
		return {status = 413}
	}
	data, rerr := os.read_entire_file(canonical, context.temp_allocator)
	if rerr != nil {
		return {status = 404}
	}
	if len(data) > MAX_ASSET_BYTES {
		return {status = 413}
	}
	return {
		status = 200,
		data = data,
		content_type = mime_type_for(name),
		etag = asset_etag(data),
	}
}

// 静态资源 handler：内置表与磁盘模式共用同一套查找、MIME、ETag、兜底逻辑。
serve_static :: proc(assets: ^Assets, request: ^Http_Request, response: ^Http_Response) {
	if request.method != .Get {
		response_set_header(response, "Content-Type", "text/plain; charset=utf-8")
		response_text(response, 405, status_text(405))
		response.close = true
		return
	}

	result := lookup_asset(assets, request.path)
	switch result.status {
	case 200:
		response_set_header(response, "Content-Type", result.content_type)
		response_set_header(response, "ETag", result.etag)
		response_set_header(response, "Cache-Control", "no-cache")
		if if_none_match, ok := header_value(request.headers, "If-None-Match");
		   ok && etag_matches(if_none_match, result.etag) {
			response.status = 304
			response.body = nil
			return
		}
		response.status = 200
		response.body = result.data
	case:
		response_set_header(response, "Content-Type", "text/plain; charset=utf-8")
		response_text(response, result.status, status_text(result.status))
	}
}
