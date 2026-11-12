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

// 补全菜单状态。items/text/description 的所有权属于 Line_Editor。
Completion_Menu :: struct {
	active:      bool,
	items:       [dynamic]Completion,
	selected:    int,
	token_start: int,
}
