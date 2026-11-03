package magi

import platform "../ap-core/platform"

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// 投票与聚合是纯逻辑：不调用模型、不写 transcript，方便单测。
// 成员票里的 veto 直接表示「是否行使否决权」；任意 veto=true 或投票失败都触发否决。

DECISION_SCHEMA :: "magi.decision.v1"

Member_Vote :: struct {
	agent:       string `json:"agent"`,
	veto:        bool   `json:"veto"`,
	reason:      string `json:"reason"`,
	status:      string `json:"status"`, // ok | error
	session_id:  string `json:"session_id,omitempty"`,
	stop_reason: string `json:"stop_reason,omitempty"`,
}

Decision :: struct {
	schema:   string        `json:"schema"`,
	approved: bool          `json:"approved"`,
	summary:  string        `json:"summary"`,
	votes:    []Member_Vote `json:"votes"`,
}

Parsed_Vote :: struct {
	veto:   bool,
	reason: string,
}

// 从模型输出中提取第一个平衡的 JSON 对象。允许模型在 JSON 前后夹带少量文字，
// 但花括号配对要跳过字符串内部，避免 reason 里的括号破坏截取。
extract_json_object :: proc(text: string) -> (string, bool) {
	start := strings.index_byte(text, '{')
	if start < 0 {
		return "", false
	}
	depth := 0
	in_string := false
	escaped := false
	for i in start ..< len(text) {
		ch := text[i]
		if in_string {
			if escaped {
				escaped = false
			} else if ch == '\\' {
				escaped = true
			} else if ch == '"' {
				in_string = false
			}
			continue
		}
		switch ch {
		case '"':
			in_string = true
		case '{':
			depth += 1
		case '}':
			depth -= 1
			if depth == 0 {
				return text[start : i + 1], true
			}
		}
	}
	return "", false
}

parse_vote_response :: proc(text: string) -> (Parsed_Vote, bool) {
	object_text, found := extract_json_object(text)
	if !found {
		return {}, false
	}
	value, err := json.parse_string(object_text, .JSON, true)
	if err != nil {
		return {}, false
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return {}, false
	}

	veto_value, has_veto := obj["veto"]
	if !has_veto {
		return {}, false
	}
	veto, is_bool := veto_value.(json.Boolean)
	if !is_bool {
		return {}, false
	}

	parsed := Parsed_Vote {
		veto = bool(veto),
	}
	if reason_value, has_reason := obj["reason"]; has_reason {
		if reason, is_string := reason_value.(json.String); is_string {
			parsed.reason = string(reason)
		}
	}
	return parsed, true
}

flatten_reason :: proc(reason: string) -> string {
	trimmed := strings.trim_space(reason)
	if len(trimmed) == 0 {
		return "未给出理由"
	}
	b := strings.builder_make()
	wrote_space := false
	for ch in trimmed {
		if ch == '\r' || ch == '\n' || ch == '\t' {
			if !wrote_space {
				strings.write_byte(&b, ' ')
				wrote_space = true
			}
			continue
		}
		strings.write_rune(&b, ch)
		wrote_space = ch == ' '
	}
	return strings.trim_space(strings.to_string(b))
}

decide :: proc(votes: []Member_Vote) -> Decision {
	decision := Decision {
		schema = DECISION_SCHEMA,
		votes  = votes,
	}
	if len(votes) == 0 {
		decision.approved = false
		decision.summary = "MAGI 没有任何有效投票，按否决处理。"
		return decision
	}

	vetoes := make([dynamic]string, 0, len(votes))
	for vote in votes {
		if vote.status != "ok" {
			append(&vetoes, fmt.tprintf("%s 未能完成投票（%s）", vote.agent, flatten_reason(vote.reason)))
		} else if vote.veto {
			append(&vetoes, fmt.tprintf("%s 否决：%s", vote.agent, flatten_reason(vote.reason)))
		}
	}

	if len(vetoes) == 0 {
		decision.approved = true
		decision.summary = fmt.aprintf(
			"MAGI 一致通过（%d/%d 名成员未行使否决权）。",
			len(votes),
			len(votes),
		)
		return decision
	}

	b := strings.builder_make()
	fmt.sbprintf(
		&b,
		"MAGI 否决（%d/%d 名成员未否决）：",
		len(votes) - len(vetoes),
		len(votes),
	)
	for value, i in vetoes {
		if i > 0 {
			strings.write_string(&b, "；")
		}
		strings.write_string(&b, value)
	}
	decision.approved = false
	decision.summary = strings.to_string(b)
	return decision
}

format_text_decision :: proc(decision: Decision) -> string {
	b := strings.builder_make()
	verdict := "通过" if decision.approved else "否决"
	fmt.sbprintf(&b, "MAGI 决议：%s\n", verdict)
	fmt.sbprintf(&b, "理由：%s\n", decision.summary)
	strings.write_string(&b, "\n成员投票：\n")
	for vote in decision.votes {
		if vote.status == "ok" {
			vote_text := "否决" if vote.veto else "通过"
			fmt.sbprintf(&b, "- %s：%s — %s\n", vote.agent, vote_text, flatten_reason(vote.reason))
		} else {
			fmt.sbprintf(&b, "- %s：投票失败 — %s\n", vote.agent, flatten_reason(vote.reason))
		}
	}
	return strings.to_string(b)
}

marshal_decision :: proc(decision: Decision) -> ([]byte, bool) {
	data, err := platform.json_marshal_utf8(decision)
	return data, err == nil
}
