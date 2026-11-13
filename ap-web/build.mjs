// ap-web 前端构建：frontend/main.js -> dist/app.js（含 Alpine，bundle + minify），
// 从同一个 bundle 抽出 dist/styles.css，并把 index.html 写进 dist/（图标在这一步内联）。
// dist/ 是提交进仓库的产物，Odin 侧 #load_directory("dist") 在编译期直接读它。
import { build, context } from "esbuild";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(root, "dist");
const watch = process.argv.includes("--watch");

// index.html 里的图标写成空的 <svg ... data-icon="NAME"></svg>（NAME 是
// bootstrap-icons 的文件名），构建时把对应 SVG 的内层路径塞进去：图标随 dist
// 一起编进二进制，运行时不请求字体或 sprite，也不依赖 CDN。
const ICON_TAG_RE = /<svg\b[^>]*\bdata-icon="([^"]+)"[^>]*><\/svg>/g;
const iconCache = new Map();

function iconInner(name) {
	const cached = iconCache.get(name);
	if (cached !== undefined) return cached;
	const file = path.join(root, "node_modules", "bootstrap-icons", "icons", `${name}.svg`);
	if (!existsSync(file)) {
		throw new Error(`找不到图标 ${name}：${path.relative(root, file)} 不存在（bootstrap-icons 是否已安装？）`);
	}
	const raw = readFileSync(file, "utf8");
	const start = raw.indexOf(">");
	const end = raw.lastIndexOf("</svg>");
	if (start < 0 || end <= start) throw new Error(`${name}.svg 不是预期的 SVG 结构`);
	const inner = raw.slice(start + 1, end).trim();
	iconCache.set(name, inner);
	return inner;
}

function inlineIcons(html) {
	return html.replace(ICON_TAG_RE, (tag, name) =>
		tag.replace("></svg>", `>${iconInner(name)}</svg>`),
	);
}

async function copyIndex() {
	await mkdir(dist, { recursive: true });
	const source = await readFile(path.join(root, "index.html"), "utf8");
	await writeFile(path.join(dist, "index.html"), inlineIcons(source));
}

// esbuild 把 main.js import 的 CSS 抽成 app.css（旧版本命名可能是 app.js.css），
// 统一改名为 styles.css，index.html 只引用这三个产物。
async function collectCss() {
	for (const name of ["app.css", "app.js.css"]) {
		const from = path.join(dist, name);
		if (!existsSync(from)) continue;
		await rm(path.join(dist, "styles.css"), { force: true });
		await rename(from, path.join(dist, "styles.css"));
	}
}

const staticAssets = {
	name: "ap-web-static-assets",
	setup(api) {
		api.onEnd(async (result) => {
			if (result.errors.length > 0) return;
			await collectCss();
			await copyIndex();
			console.log("[ap-web] dist 已更新：index.html + app.js + styles.css");
		});
	},
};

const options = {
	absWorkingDir: root,
	entryPoints: ["frontend/main.js"],
	bundle: true,
	format: "iife",
	target: ["chrome110", "edge110", "firefox110", "safari16"],
	outfile: path.join(dist, "app.js"),
	minify: !watch,
	sourcemap: false,
	legalComments: "none",
	logLevel: "info",
	plugins: [staticAssets],
};

await mkdir(dist, { recursive: true });

if (watch) {
	const ctx = await context(options);
	await ctx.watch();
	console.log("[ap-web] watching frontend/（Ctrl+C 退出）");
} else {
	await build(options);
}
