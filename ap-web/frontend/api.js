// ap-web HTTP API 封装。统一错误形状：{error: {code, message}}。
// 调用方拿到的是 ApiError，带 status / code，便于区分 409 cancelled、501 等语义。

export class ApiError extends Error {
	constructor(message, { status = 0, code = "error", body = null, cause = null } = {}) {
		super(message);
		this.name = "ApiError";
		this.status = status;
		this.code = code;
		this.body = body;
		this.cause = cause;
	}
}

const TURN_OPTION_KEYS = ["model", "agent", "max_steps", "max_tokens"];

// 带 session_key 的端点统一拼 query；空 key 保持旧行为（当前 session / 订阅全部）。
function sessionPath(path, sessionKey) {
	const key = String(sessionKey ?? "").trim();
	if (!key) return path;
	return `${path}?session_key=${encodeURIComponent(key)}`;
}

// cwd 是 project 身份（不是 session key），history/sessions 用它定位目录。
export function cwdPath(path, cwd) {
	const value = String(cwd ?? "").trim();
	if (!value) return path;
	const separator = path.includes("?") ? "&" : "?";
	return `${path}${separator}cwd=${encodeURIComponent(value)}`;
}

// 标题请求体：服务端按 session_key 找回运行态，缺省用当前 session。
export function sessionTitleBody(sessionKey) {
	return { session_key: sessionKey ?? "" };
}

// 导出的纯函数便于单元测试；session_key/cwd 只在非空时进入请求体。
export function turnBody(payload) {
	const body = { prompt: payload.prompt ?? "" };
	if (payload.handoff) body.handoff = true;
	if (payload.session_key) body.session_key = payload.session_key;
	if (payload.cwd) body.cwd = payload.cwd;
	for (const key of TURN_OPTION_KEYS) {
		if (payload[key] !== undefined && payload[key] !== null && payload[key] !== "") {
			body[key] = payload[key];
		}
	}
	return body;
}

export function eventsUrl(sessionKey) {
	return sessionPath("/api/events", sessionKey);
}

async function request(path, { method = "GET", body } = {}) {
	const init = { method, headers: {} };
	if (body !== undefined) {
		init.headers["Content-Type"] = "application/json";
		init.body = JSON.stringify(body);
	}

	let response;
	try {
		response = await fetch(path, init);
	} catch (cause) {
		throw new ApiError("无法连接到 ap-web 服务", { code: "network", cause });
	}

	const text = await response.text();
	let data = null;
	if (text.length > 0) {
		try {
			data = JSON.parse(text);
		} catch {
			data = null;
		}
	}

	if (!response.ok) {
		const rawError = data && data.error;
		const error = rawError && typeof rawError === "object" ? rawError : null;
		const fallbackCode = typeof rawError === "string" ? rawError : "http_error";
		throw new ApiError(error?.message || fallbackCode || `HTTP ${response.status}`, {
			status: response.status,
			code: error?.code || fallbackCode,
			body: data,
		});
	}
	return data;
}

export const api = {
	health: () => request("/api/health"),
	config: () => request("/api/config"),
	currentSession: (sessionKey) => request(sessionPath("/api/session/current", sessionKey)),
	newSession: (cwd) =>
		request("/api/session/new", {
			method: "POST",
			body: cwd ? { cwd } : undefined,
		}),
	resumeSession: (sessionId, cwd) =>
		request("/api/session/resume", {
			method: "POST",
			body: cwd ? { session_id: sessionId, cwd } : { session_id: sessionId },
		}),
	projects: () => request("/api/projects"),
	sessions: (cwd) => request(cwdPath("/api/sessions", cwd)),
	history: (sessionId, cwd) =>
		request(
			cwdPath(`/api/history?session_id=${encodeURIComponent(sessionId)}`, cwd),
		),
	cwd: () => request("/api/cwd"),
	pickCwd: () => request("/api/cwd/pick", { method: "POST" }),
	// 打开外部程序：cwd 为空时由服务端回落到默认 project。
	openFiles: (cwd) =>
		request("/api/cwd/reveal", { method: "POST", body: cwd ? { cwd } : undefined }),
	openTerminal: (cwd) =>
		request("/api/cwd/terminal", { method: "POST", body: cwd ? { cwd } : undefined }),
	startTurn: (payload) => request("/api/turn", { method: "POST", body: turnBody(payload) }),
	// 生成/刷新会话标题：服务端同步跑一次 ap --session-title。
	sessionTitle: (sessionKey) =>
		request("/api/session/title", { method: "POST", body: sessionTitleBody(sessionKey) }),
	cancelTurn: (sessionKey) =>
		request(sessionPath("/api/turn", sessionKey), { method: "DELETE" }),
};
