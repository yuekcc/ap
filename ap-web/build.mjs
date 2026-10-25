// ap-web 前端构建：frontend/main.js -> dist/app.js（含 Alpine，bundle + minify），
// 从同一个 bundle 抽出 dist/styles.css，并把 index.html 拷进 dist/。
// dist/ 是提交进仓库的产物，Odin 侧 #load_directory("dist") 在编译期直接读它。
import { build, context } from "esbuild";
import { copyFile, mkdir, rename, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(root, "dist");
const watch = process.argv.includes("--watch");

async function copyIndex() {
	await mkdir(dist, { recursive: true });
	await copyFile(path.join(root, "index.html"), path.join(dist, "index.html"));
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
