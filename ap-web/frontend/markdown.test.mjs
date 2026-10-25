// assistant 文本的 Markdown 渲染规则。这里同时守住安全边界：
// 模型输出里的原始 HTML 必须被转义，危险协议的链接不能变成可点链接。
import test from "node:test";
import assert from "node:assert/strict";
import { renderMarkdown } from "./markdown.js";

test("标题、列表与围栏代码块按 GitHub 风格渲染", () => {
	const html = renderMarkdown("# 标题\n\n- 一\n- 二\n\n```js\nconsole.log(1)\n```");
	assert.match(html, /<h1>标题<\/h1>/);
	assert.match(html, /<li>一<\/li>/);
	assert.match(html, /<pre><code class="language-js">/);
});

test("行内代码、强调与换行", () => {
	const html = renderMarkdown("**粗** 和 `code`\n第二行");
	assert.match(html, /<strong>粗<\/strong>/);
	assert.match(html, /<code>code<\/code>/);
	assert.match(html, /<br>/);
});

test("原始 HTML 被转义而不是执行", () => {
	const html = renderMarkdown('<img src=x onerror="alert(1)">\n\n<script>alert(2)</script>');
	assert.ok(!html.includes("<img"), "raw img tag must not survive");
	assert.ok(!html.includes("<script"), "raw script tag must not survive");
	assert.ok(html.includes("&lt;img"), "html should be escaped");
});

test("javascript: 与 data: 链接不会变成可点链接", () => {
	for (const url of ["javascript:alert(1)", "data:text/html,<script>alert(1)</script>"]) {
		const html = renderMarkdown(`[点我](${url})`);
		assert.ok(!html.includes("<a "), `${url} must not become an anchor`);
	}
});

test("外链带 target 与 rel，自动链接同样处理", () => {
	const html = renderMarkdown("[示例](https://example.com) 与 https://auto.example");
	assert.match(html, /href="https:\/\/example\.com" target="_blank" rel="noopener noreferrer"/);
	assert.match(html, /href="https:\/\/auto\.example" target="_blank" rel="noopener noreferrer"/);
});

test("图片延迟加载且不带 referrer", () => {
	const html = renderMarkdown("![图](https://example.com/a.png)");
	assert.match(html, /loading="lazy"/);
	assert.match(html, /referrerpolicy="no-referrer"/);
});

test("空输入返回空串", () => {
	assert.equal(renderMarkdown(""), "");
	assert.equal(renderMarkdown(null), "");
	assert.equal(renderMarkdown(undefined), "");
});

test("流式过程中的半截 Markdown 不会抛错", () => {
	const partials = ["**粗", "`code", "```js\nconst", "[链接](https://exa", "| a | b |\n| -"];
	for (const text of partials) {
		assert.doesNotThrow(() => renderMarkdown(text), `partial: ${text}`);
	}
});

test("重复渲染同一段文本走缓存且结果一致", () => {
	const text = "## 缓存\n\n- a";
	assert.equal(renderMarkdown(text), renderMarkdown(text));
});
