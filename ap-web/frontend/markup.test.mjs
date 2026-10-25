// 布局约定是 docs/web.md 的硬性要求：目录选择入口在输入框旁（composer），
// 不在顶栏。这里直接读 index.html 做结构断言，不引入 DOM 依赖。
import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const indexPath = fileURLToPath(new URL("../index.html", import.meta.url));

test("目录选择入口位于输入区，与发送/取消同一行", async () => {
	const html = await readFile(indexPath, "utf8");
	const headerEnd = html.indexOf("</header>");
	const footerStart = html.indexOf('<footer class="composer">');
	assert.ok(headerEnd > 0, "index.html must have a header");
	assert.ok(footerStart > headerEnd, "composer must follow the header");

	const header = html.slice(0, headerEnd);
	assert.ok(!header.includes("pickDirectory"), "pick action must not live in the topbar");
	assert.ok(!header.includes("选择目录"), "pick button must not live in the topbar");

	const composer = html.slice(footerStart);
	const pickIndex = composer.indexOf('@click="pickDirectory"');
	const actionsIndex = composer.indexOf('class="composer__actions"');
	const inputIndex = composer.indexOf('class="composer__input"');
	assert.ok(inputIndex >= 0 && actionsIndex > inputIndex, "composer row is textarea + actions");
	assert.ok(pickIndex > actionsIndex, "pick button must be inside composer__actions");
	assert.ok(
		composer.includes('x-show="$store.ap.isWindows"'),
		"pick button stays Windows-only",
	);
});
