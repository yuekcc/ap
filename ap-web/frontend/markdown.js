// assistant 文本的 Markdown 渲染。工具输出/用户输入仍走 textContent，
// 只有这里产出的 HTML 交给 x-html，所以必须挡住模型输出里的原始 HTML：
// html:false 会把标签转义，链接校验沿用 markdown-it 的 validateLink
// （javascript:/data: 不会变成可点的链接）。
import { MarkdownExit } from "markdown-exit";

const CACHE_LIMIT = 128;
const cache = new Map();

const md = new MarkdownExit({
	html: false,
	linkify: true,
	breaks: true,
});

md.renderer.rules.link_open = (tokens, idx, options, _env, self) => {
	tokens[idx].attrSet("target", "_blank");
	tokens[idx].attrSet("rel", "noopener noreferrer");
	return self.renderToken(tokens, idx, options);
};

// 图片是模型可控的远程请求：延迟加载且不带 referrer。
md.renderer.rules.image = (tokens, idx, options, _env, self) => {
	tokens[idx].attrSet("loading", "lazy");
	tokens[idx].attrSet("referrerpolicy", "no-referrer");
	return self.renderToken(tokens, idx, options);
};

// 流式 delta 每来一段都会重渲染同一段文本，用有界缓存挡住重复解析。
export function renderMarkdown(text) {
	const value = String(text ?? "");
	if (!value) return "";
	const cached = cache.get(value);
	if (cached !== undefined) return cached;

	const html = md.render(value);
	if (cache.size >= CACHE_LIMIT) cache.delete(cache.keys().next().value);
	cache.set(value, html);
	return html;
}
