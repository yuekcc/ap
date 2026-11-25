// 组装根：创建 store → 恢复本地偏好 → 创建 controller → 挂载 ui/* → boot()。
// ui/* 只从参数里拿 store / controller，互不 import，controller 也不 import ui。
import "./styles.css";
import { createController } from "./controller.js";
import {
	RAIL_STORAGE_KEY,
	SORT_STORAGE_KEY,
	SPLIT_STORAGE_KEY,
	readLocal,
} from "./prefs.js";
import { parseSplitPrefs } from "./render.js";
import { createStore } from "./store.js";
import { mountComposer } from "./ui/composer.js";
import { mountRail } from "./ui/rail.js";
import { mountSessions } from "./ui/sessions.js";
import { mountShell } from "./ui/shell.js";
import { mountSplitter } from "./ui/splitter.js";
import { mountThread } from "./ui/thread.js";

const store = createStore();
const controller = createController(store);

// 先恢复偏好再挂载：首帧就是用户上次的宽度、排序和折叠状态，不闪一下默认布局。
store.setRailCollapsed(readLocal(RAIL_STORAGE_KEY) === "1");
store.setSortOrder(readLocal(SORT_STORAGE_KEY));
const split = parseSplitPrefs(readLocal(SPLIT_STORAGE_KEY));
store.setRailWidth(split.rail);
store.setSessionsWidth(split.sessions);

const disposers = [
	mountShell({ store, controller }),
	mountRail({ store, controller }),
	mountSessions({ store, controller }),
	mountThread({ store, controller }),
	mountComposer({ store, controller }),
	mountSplitter({ store }),
];

function dispose() {
	for (const stop of disposers) stop();
}

// 浏览器控制台调试入口：store 的字段是函数，controller 是动作集合。
window.apWeb = { store, controller, dispose };

controller.boot();
