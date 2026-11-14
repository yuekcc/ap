// 把 Markdown 产出的 `.mermaid-block` 占位块换成 SVG。
//
// mermaid 本体有 5MB 左右，单独打包成 dist/mermaid.js，只有页面真的出现图表时
// 才加载（见 build.mjs 的第二个 entry）。渲染是异步的，流式 delta 每次都会重写
// 整段 Markdown，所以这里用 MutationObserver + 防抖，并且等消息结束（去掉
// data-streaming）后才渲染；渲染失败的块保留源码并标成 error，不会反复重试。
import { MERMAID_BLOCK_CLASS, MERMAID_PENDING_STATE } from "./markdown.js";

export const MERMAID_SCRIPT_PATH = "/mermaid.js";
export const RENDER_DEBOUNCE_MS = 250;

const PENDING_SELECTOR = `.${MERMAID_BLOCK_CLASS}[data-mermaid-state="${MERMAID_PENDING_STATE}"]`;
const MAX_ERROR_CHARS = 200;

// mermaid 的 %%{init: ...}%% 指令和 frontmatter 能覆盖全局 config，包括
// securityLevel。图表内容是模型输出，不能让它把 strict 改成 loose。
const CONFIG_DIRECTIVE_RE = /%%\{[\s\S]*?\}%%/g;
const FRONTMATTER_RE = /^\s*---\s*\n([\s\S]*?)\n---/;

export function overridesSecurityLevel(source) {
	const text = String(source ?? "");
	const chunks = text.match(CONFIG_DIRECTIVE_RE) ?? [];
	const frontmatter = FRONTMATTER_RE.exec(text);
	if (frontmatter) chunks.push(frontmatter[1]);
	return chunks.some((chunk) => /securitylevel/i.test(chunk));
}

export function mermaidSource(block) {
	const code = block?.querySelector("code");
	return code ? code.textContent : "";
}

function errorMessage(error) {
	const message = String(error?.message ?? error ?? "").split("\n")[0].trim();
	if (!message) return "未知错误";
	return message.length > MAX_ERROR_CHARS ? `${message.slice(0, MAX_ERROR_CHARS)}…` : message;
}

function markFailed(block, text) {
	if (!block.isConnected) return;
	block.dataset.mermaidState = "error";
	const note = document.createElement("p");
	note.className = `${MERMAID_BLOCK_CLASS}__error`;
	note.textContent = text;
	block.append(note);
}

let loaderPromise = null;

function loadRenderer() {
	if (typeof window !== "undefined" && window.apMermaid) {
		return Promise.resolve(window.apMermaid);
	}
	if (!loaderPromise) {
		loaderPromise = new Promise((resolve, reject) => {
			const script = document.createElement("script");
			script.src = MERMAID_SCRIPT_PATH;
			script.async = true;
			script.onload = () => resolve(window.apMermaid);
			script.onerror = () => reject(new Error("无法加载 mermaid 渲染器"));
			document.head.append(script);
		})
			.then((renderer) => {
				if (!renderer) throw new Error("mermaid 渲染器未就绪");
				return renderer;
			})
			.catch((error) => {
				// 加载失败不永久锁死，下一批图表可以再试一次。
				loaderPromise = null;
				throw error;
			});
	}
	return loaderPromise;
}

async function renderBlock(block, renderer, loadError) {
	if (!block.isConnected) return false;
	block.dataset.mermaidState = "loading";

	if (loadError) {
		markFailed(block, `mermaid 渲染器加载失败：${errorMessage(loadError)}`);
		return false;
	}

	const source = mermaidSource(block);
	if (overridesSecurityLevel(source)) {
		markFailed(block, "mermaid 图表不允许覆盖 securityLevel");
		return false;
	}

	try {
		const svg = await renderer.render(source);
		if (!block.isConnected) return false;
		block.innerHTML = svg;
		block.dataset.mermaidState = "done";
		return true;
	} catch (error) {
		console.warn("ap-web: mermaid 渲染失败", error);
		markFailed(block, `mermaid 渲染失败：${errorMessage(error)}`);
		return false;
	}
}

// 监听消息区，把出现的 mermaid 占位块渲染掉。返回停止函数。
export function watchMermaid(root, { onRendered } = {}) {
	if (!root || typeof MutationObserver !== "function") return () => {};

	let disposed = false;
	let active = false;
	let timer = 0;

	// 流式中的消息还在变化，半截图表只会渲染失败；等 message_end 去掉
	// data-streaming 后再渲染。
	const pendingBlocks = () =>
		Array.from(root.querySelectorAll(PENDING_SELECTOR)).filter(
			(block) => !block.closest('[data-streaming="true"]'),
		);

	const flush = async () => {
		timer = 0;
		if (disposed || active) return;
		const blocks = pendingBlocks();
		if (blocks.length === 0) return;

		active = true;
		let renderer = null;
		let loadError = null;
		try {
			renderer = await loadRenderer();
		} catch (error) {
			loadError = error;
		}

		let rendered = false;
		try {
			for (const block of blocks) {
				if (disposed) return;
				if (block.dataset.mermaidState !== MERMAID_PENDING_STATE) continue;
				rendered = (await renderBlock(block, renderer, loadError)) || rendered;
			}
		} finally {
			active = false;
			if (rendered && !disposed) onRendered?.();
			// 渲染期间 Markdown 又被重写过时，这里会留下新的 pending 块。
			if (!disposed && pendingBlocks().length > 0) schedule();
		}
	};

	const schedule = () => {
		if (disposed) return;
		clearTimeout(timer);
		timer = setTimeout(flush, RENDER_DEBOUNCE_MS);
	};

	const observer = new MutationObserver(schedule);
	observer.observe(root, {
		childList: true,
		subtree: true,
		attributes: true,
		attributeFilter: ["data-streaming"],
	});
	schedule();

	return () => {
		disposed = true;
		clearTimeout(timer);
		observer.disconnect();
	};
}
