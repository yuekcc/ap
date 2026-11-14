// assistant 文本的 Markdown 渲染。工具输出/用户输入仍走 textContent，
// 只有这里产出的 HTML 交给 x-html，所以必须挡住模型输出里的原始 HTML：
// html:false 会把标签转义，链接校验沿用 markdown-it 的 validateLink
// （javascript:/data: 不会变成可点的链接）。
import { MarkdownExit } from "markdown-exit";

const CACHE_LIMIT = 128;
const cache = new Map();

export const MERMAID_BLOCK_CLASS = "mermaid-block";
export const MERMAID_PENDING_STATE = "pending";

const md = new MarkdownExit({
	html: false,
	linkify: true,
	breaks: true,
});

// 围栏语言名，忽略 ```mermaid 后面的 meta。
export function fenceLanguage(info) {
	return String(info ?? "").trim().split(/\s+/, 1)[0].toLowerCase();
}

// ```mermaid 先渲染成占位块：mermaid 本体单独打包在 dist/mermaid.js，页面真的
// 出现图表时才加载（见 mermaid-blocks.js）。源码留在 <code> 里，渲染成功前就是
// 普通代码块，渲染失败也能直接看到原文；源码同样经过 HTML 转义。
const renderFence = md.renderer.rules.fence;
md.renderer.rules.fence = (tokens, idx, options, env, self) => {
	const token = tokens[idx];
	if (fenceLanguage(token.info) !== "mermaid") {
		return renderFence(tokens, idx, options, env, self);
	}
	return `<div class="${MERMAID_BLOCK_CLASS}" data-mermaid-state="${MERMAID_PENDING_STATE}"><pre class="${MERMAID_BLOCK_CLASS}__source"><code class="language-mermaid">${md.utils.escapeHtml(token.content)}</code></pre></div>`;
};

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
