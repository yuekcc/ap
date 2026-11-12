package lineedit

// 补全候选由回调分配、由编辑器在用完后释放（text/description 都要 delete）。
Completion :: struct {
	text:        string,
	description: string,
}

Completer :: struct {
	ctx:      rawptr,
	complete: proc(ctx: rawptr, line: string, cursor: int, out: ^[dynamic]Completion),
}
