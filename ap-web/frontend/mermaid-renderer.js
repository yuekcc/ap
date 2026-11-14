// mermaid 图表渲染器。单独打包成 dist/mermaid.js，由 mermaid-blocks.js 在第一次
// 出现图表时按需加载：mermaid 有好几 MB，不能跟着 app.js 每次打开页面都解析。
import mermaid from "mermaid";

// securityLevel 必须保持 strict：图表文本来自模型输出，strict 会转义标签并关掉
// click 交互。图表里的 %%{init}%% 覆盖由 mermaid-blocks.js 在调用前拦下。
mermaid.initialize({
	startOnLoad: false,
	theme: "default",
	securityLevel: "strict",
	suppressErrorRendering: true,
	fontFamily:
		'-apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Noto Sans SC", "Microsoft YaHei", sans-serif',
});

let sequence = 0;

export async function render(source) {
	// id 要在页面内唯一：mermaid 用它建临时节点，并在 render 过程中按 id 查找。
	const id = `ap-mermaid-${(sequence += 1)}`;
	const { svg } = await mermaid.render(id, source);
	return svg;
}
