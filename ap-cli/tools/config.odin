package aptools

// 应用层工具配置。每个内置 Tool 的 user 指针都指向同一个 Tool_Config，
// 由 apcli 在 session 存活期间持有。

Tool_Config :: struct {
	config_dir:        string,
	bash_path:         string,
	self_exe:          string,
	model:             string,
	max_steps:         int,
	tool_timeout_ms:   int,
	max_capture_bytes: int,
	max_agent_depth:   int,
	no_agents_md:      bool,
	no_skills:         bool,
	tools_set:         bool,
	tools:             []string, // tools_set 时用于子代理传播
}
