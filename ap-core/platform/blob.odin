package platform

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

sha256_hex :: proc(data: []byte) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	hash: [32]byte
	sha2.final(&ctx, hash[:])
	encoded, _ := hex.encode(hash[:], context.allocator)
	return string(encoded)
}

// 读取内容寻址 blob，并校验 sha256；调用方负责释放返回的字节。
blob_read :: proc(project: Project, sha256: string, allocator := context.allocator) -> ([]byte, Error) {
	if len(sha256) != 64 {
		return nil, errorf("invalid blob reference %q", sha256)
	}
	for ch in sha256 {
		if !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')) {
			return nil, errorf("invalid blob reference %q", sha256)
		}
	}
	path := blob_file(project, sha256)
	data, derr := os.read_entire_file_from_path(path, allocator)
	if derr != nil {
		return nil, errorf("blob %s is missing (%s); cannot restore session", sha256, path)
	}
	actual := sha256_hex(data)
	if !strings.equal_fold(actual, sha256) {
		return nil, errorf("blob %s is corrupt: sha256 mismatch (%s)", sha256, actual)
	}
	return data, ok_error()
}

// 内容寻址写入；已存在时直接复用。
blob_write :: proc(project: Project, data: []byte) -> (string, Error) {
	sha := sha256_hex(data)
	path := blob_file(project, sha)
	if os.exists(path) {
		return sha, ok_error()
	}
	if err := blob_write_at(project, path, data); !is_ok(err) {
		return "", err
	}
	return sha, ok_error()
}

// 把完整工具输出写成模型可直接用 read_file 读取的 .txt 文件。
// 返回绝对路径；文件名使用内容 sha256，重复输出自动去重。
blob_write_text :: proc(project: Project, data: []byte) -> (string, Error) {
	sha := sha256_hex(data)
	path := fmt.tprintf("%s/%s.txt", project.blobs_dir, sha)
	if os.exists(path) {
		return path, ok_error()
	}
	if err := blob_write_at(project, path, data); !is_ok(err) {
		return "", err
	}
	return path, ok_error()
}

blob_write_at :: proc(project: Project, path: string, data: []byte) -> Error {
	tmp := fmt.tprintf("%s/.tmp-%d-%d", project.blobs_dir, os.get_pid(), time.time_to_unix_nano(time.now()))
	perm := os.Permissions{.Read_User, .Write_User}
	file, ferr := os.open(tmp, {.Write, .Create, .Excl, .Trunc}, perm)
	if ferr != nil {
		return errorf("failed to persist output blob: cannot create %s: %v", tmp, ferr)
	}
	ok_write := write_all(file, data)
	sync_err := os.sync(file)
	close_err := os.close(file)
	if !ok_write || sync_err != nil || close_err != nil {
		os.remove(tmp)
		return errorf("failed to persist output blob: write error")
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		os.remove(tmp)
		return errorf("failed to persist output blob: rename failed: %v", rerr)
	}
	return ok_error()
}
