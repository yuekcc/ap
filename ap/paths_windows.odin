#+build windows
package ap

import "core:strings"
import win32 "core:sys/windows"

real_path :: proc(path: string) -> (string, Error) {
	wpath := win32.utf8_to_wstring(path, context.temp_allocator)
	handle := win32.CreateFileW(
		wpath,
		win32.FILE_READ_ATTRIBUTES,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_BACKUP_SEMANTICS,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {
		return "", make_error(.Usage, "cannot open path for realpath: %s", path)
	}
	defer win32.CloseHandle(handle)

	n := win32.GetFinalPathNameByHandleW(handle, nil, 0, win32.VOLUME_NAME_DOS)
	if n == 0 {
		return "", make_error(.Usage, "GetFinalPathNameByHandleW failed: %s", path)
	}
	buf := make([]u16, n + 1, context.temp_allocator)
	n = win32.GetFinalPathNameByHandleW(handle, cstring16(raw_data(buf)), u32(len(buf)), win32.VOLUME_NAME_DOS)
	if n == 0 {
		return "", make_error(.Usage, "GetFinalPathNameByHandleW failed: %s", path)
	}
	s := win32.utf16_to_utf8(buf[:n], context.temp_allocator) or_else ""
	unc_prefix := `\\?\UNC\`
	win_prefix := `\\?\`
	switch {
	case strings.has_prefix(s, unc_prefix):
		s = strings.concatenate([]string{`\\`, s[len(unc_prefix):]})
	case strings.has_prefix(s, win_prefix):
		s = s[4:]
	}
	return s, ok_error()
}
