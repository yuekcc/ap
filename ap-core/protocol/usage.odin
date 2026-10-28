package protocol

usage_add :: proc(a, b: Usage) -> Usage {
	out := Usage{}
	add_field :: proc(x, y: Maybe(int)) -> Maybe(int) {
		xv, xok := x.?
		yv, yok := y.?
		if !xok && !yok {
			return nil
		}
		sum := 0
		if xok {
			sum += xv
		}
		if yok {
			sum += yv
		}
		return sum
	}
	out.input_tokens = add_field(a.input_tokens, b.input_tokens)
	out.output_tokens = add_field(a.output_tokens, b.output_tokens)
	out.cached_tokens = add_field(a.cached_tokens, b.cached_tokens)
	out.reasoning_tokens = add_field(a.reasoning_tokens, b.reasoning_tokens)
	out.total_tokens = add_field(a.total_tokens, b.total_tokens)
	return out
}

usage_has_any :: proc(usage: Usage) -> bool {
	_, a := usage.input_tokens.?
	_, b := usage.output_tokens.?
	_, c := usage.cached_tokens.?
	_, d := usage.reasoning_tokens.?
	_, e := usage.total_tokens.?
	return a || b || c || d || e
}
