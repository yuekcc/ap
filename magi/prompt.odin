package magi

import "core:fmt"
import "core:strings"

// 三名成员的人格来自 agent-things/magi 的 agent 定义；这里在编译期内嵌，
// 运行时不依赖外部目录。三份角色文件只保留正文，公共投票规则在 constitution.md。

Member_Role :: struct {
	id:         string, // 展示名，同时写入最终结果的 agent 字段
	agent_name: string, // 写入 session_start.agent_name，便于审计
	prompt:     string,
}

MEMBER_ROLES := [3]Member_Role {
	{
		id = "BALTHASAR-2",
		agent_name = "magi-balthasar-2",
		prompt = #load("prompts/balthasar-2.md", string),
	},
	{
		id = "CASPER-3",
		agent_name = "magi-casper-3",
		prompt = #load("prompts/casper-3.md", string),
	},
	{
		id = "MELCHIOR-1",
		agent_name = "magi-melchior-1",
		prompt = #load("prompts/melchior-1.md", string),
	},
}

MAGI_CONSTITUTION :: #load("prompts/constitution.md", string)

REPAIR_PROMPT :: `你上一条回答不是合法的投票 JSON。请严格只输出一个 JSON 对象，不要 Markdown 代码块，不要任何前后缀文字：

{"veto": true|false, "reason": "一两句话说明理由"}`

// 角色正文作为 system prompt 的一份，投票语义与输出契约放在前面，
// 避免角色人格把结构化输出要求稀释掉。
build_base_prompt :: proc(role: Member_Role) -> string {
	b := strings.builder_make()
	strings.write_string(&b, MAGI_CONSTITUTION)
	if !strings.has_suffix(MAGI_CONSTITUTION, "\n") {
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, "\n## 你的角色\n\n")
	strings.write_string(&b, role.prompt)
	return strings.to_string(b)
}

build_member_prompt :: proc(role_id, question, material_text: string) -> string {
	material := material_text
	if len(material) == 0 {
		material = "（未提供材料）"
	}
	return fmt.aprintf(
		"## 问题\n\n%s\n\n## 材料\n\n%s\n\n请以 %s 的身份独立投票。只输出 JSON。",
		question,
		material,
		role_id,
	)
}
