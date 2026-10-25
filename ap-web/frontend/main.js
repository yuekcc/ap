// 入口：样式由 esbuild 抽成 dist/styles.css，脚本打成含 Alpine 的 dist/app.js。
import Alpine from "alpinejs";
import "./styles.css";
import { createStore } from "./store.js";
import { registerApp } from "./app.js";

const store = createStore();
Alpine.store("ap", store);
registerApp(Alpine);

// 浏览器控制台调试入口（只暴露 store，没有其他全局可变状态）。
window.apWeb = { store };

Alpine.start();
