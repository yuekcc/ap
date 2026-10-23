package internal

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:os"
import "core:strings"

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
