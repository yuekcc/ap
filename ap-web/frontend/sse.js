// EventSource 封装：/api/events 上有三种事件
//   ap        ap 的 stream-json 事件（transcript 事件带 seq，流式事件不带）
//   turn_done turn 结束信封
//   ping      心跳
// 浏览器原生 EventSource 会自己重连，但失败后不会给 UI 状态；这里手动 close + 指数退避，
// 重连成功后由调用方决定是否用 history 补齐断线期间落盘的 transcript 事件。

const MIN_RETRY_MS = 800;
const MAX_RETRY_MS = 10000;

function parseData(raw) {
	if (typeof raw !== "string" || raw.length === 0) return null;
	try {
		return JSON.parse(raw);
	} catch {
		return null;
	}
}

export function createEventStream({
	url = "/api/events",
	getLastSeq = () => 0,
	onEvent,
	onTurnDone,
	onState,
} = {}) {
	let source = null;
	let retryTimer = null;
	let attempt = 0;
	let closed = false;

	function teardown() {
		if (retryTimer !== null) {
			clearTimeout(retryTimer);
			retryTimer = null;
		}
		if (source) {
			source.close();
			source = null;
		}
	}

	function scheduleReconnect() {
		if (closed) return;
		const delay = Math.min(MAX_RETRY_MS, MIN_RETRY_MS * 2 ** attempt);
		attempt += 1;
		onState?.("reconnecting");
		teardown();
		retryTimer = setTimeout(() => {
			retryTimer = null;
			open();
		}, delay);
	}

	function open() {
		if (closed) return;
		onState?.(attempt === 0 ? "connecting" : "reconnecting");
		const current = new EventSource(url);
		source = current;

		current.addEventListener("open", () => {
			if (closed || source !== current) return;
			attempt = 0;
			onState?.("open");
		});

		current.addEventListener("ap", (message) => {
			if (closed || source !== current) return;
			const event = parseData(message.data);
			if (!event) return;
			// history 已经渲染过的 transcript 事件按 seq 跳过；流式事件没有 seq，放行。
			if (
				typeof event.seq === "number" &&
				event.seq > 0 &&
				event.seq <= getLastSeq()
			) {
				return;
			}
			onEvent?.(event);
		});

		current.addEventListener("turn_done", (message) => {
			if (closed || source !== current) return;
			const payload = parseData(message.data);
			if (payload) onTurnDone?.(payload);
		});

		current.addEventListener("ping", () => {
			// 心跳只需要浏览器保持连接，不做额外处理。
		});

		current.onerror = () => {
			if (closed || source !== current) return;
			scheduleReconnect();
		};
	}

	open();

	return {
		close() {
			closed = true;
			teardown();
			onState?.("closed");
		},
	};
}
