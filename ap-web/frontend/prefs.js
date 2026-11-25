// 浏览器存储的安全读写。隐私模式、禁用存储、配额满都只让本次偏好失效，
// 不能影响当前会话，所以每个入口自己吞掉异常。
//
// 键名是升级契约：旧版把工作空间折叠存在 ap-web:sidebar-collapsed、
// 排序存在 ap-web:sort、栏宽存在 ap-web:split、本标签页会话存在
// ap-web:session，迁移到 alien-signals 后原样保留，用户偏好不丢。

export const SESSION_STORAGE_KEY = "ap-web:session";
export const RAIL_STORAGE_KEY = "ap-web:sidebar-collapsed";
export const SORT_STORAGE_KEY = "ap-web:sort";
export const SPLIT_STORAGE_KEY = "ap-web:split";

function storage(kind) {
	try {
		return kind === "session" ? globalThis.sessionStorage : globalThis.localStorage;
	} catch {
		// 某些浏览器在禁用存储时连属性访问都会抛错。
		return null;
	}
}

export function readLocal(key) {
	try {
		return storage("local")?.getItem(key) ?? null;
	} catch {
		return null;
	}
}

export function writeLocal(key, value) {
	try {
		storage("local")?.setItem(key, value);
	} catch {
		// 不记忆也不影响本次操作。
	}
}

// 本标签页的会话指针：{key, id, cwd}。缺一段就整体作废，避免恢复出半个状态。
export function readSessionPrefs() {
	const raw = (() => {
		try {
			return storage("session")?.getItem(SESSION_STORAGE_KEY) ?? null;
		} catch {
			return null;
		}
	})();
	if (!raw) return null;
	let saved = null;
	try {
		saved = JSON.parse(raw);
	} catch {
		return null;
	}
	if (!saved || typeof saved !== "object") return null;
	const key = typeof saved.key === "string" ? saved.key : "";
	const id = typeof saved.id === "string" ? saved.id : "";
	const cwd = typeof saved.cwd === "string" ? saved.cwd : "";
	return key || id ? { key, id, cwd } : null;
}

export function writeSessionPrefs({ key = "", id = "", cwd = "" } = {}) {
	try {
		storage("session")?.setItem(
			SESSION_STORAGE_KEY,
			JSON.stringify({ key: key ?? "", id: id ?? "", cwd: cwd ?? "" }),
		);
	} catch {
		// 隐私模式/禁用存储不影响当前会话。
	}
}

export function clearSessionPrefs() {
	try {
		storage("session")?.removeItem(SESSION_STORAGE_KEY);
	} catch {
		// 同上。
	}
}
