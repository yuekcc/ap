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

// 导出的纯函数便于单元测试；session_key 只在非空时进入请求体。
export function turnBody(payload) {
	const body = { prompt: payload.prompt };
	if (payload.session_key) body.session_key = payload.session_key;
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
	newSession: () => request("/api/session/new", { method: "POST" }),
	resumeSession: (sessionId) =>
		request("/api/session/resume", { method: "POST", body: { session_id: sessionId } }),
	sessions: () => request("/api/sessions"),
	history: (sessionId) =>
		request(`/api/history?session_id=${encodeURIComponent(sessionId)}`),
	cwd: () => request("/api/cwd"),
	pickCwd: () => request("/api/cwd/pick", { method: "POST" }),
	startTurn: (payload) => request("/api/turn", { method: "POST", body: turnBody(payload) }),
	cancelTurn: (sessionKey) =>
		request(sessionPath("/api/turn", sessionKey), { method: "DELETE" }),
};
