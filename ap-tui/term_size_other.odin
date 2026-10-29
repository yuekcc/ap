#+build netbsd, openbsd
package aptui

// stdlib 没有这两个平台的 ioctl 封装；退化为默认尺寸，编辑功能仍然可用。
term_platform_size :: proc(t: ^Term) -> (cols, rows: int) {
	return 0, 0
}
