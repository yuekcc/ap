#+build !windows
package main

import "../internal"
import "base:runtime"
import "core:fmt"
import "core:net"
import "core:sys/posix"
import "core:time"

setup_console :: proc() {
	internal.setup_console()
}

normalize_args :: proc(args: []string) -> []string {
	return internal.normalize_args(args)
}

Listener :: struct {
	socket: net.TCP_Socket,
}

// core:net 的 listen_tcp 在 Unix 上会设置 SO_REUSEADDR（崩溃后立刻重启不撞端口）。
open_listener :: proc(endpoint: net.Endpoint) -> (Listener, string) {
	socket, err := net.listen_tcp(endpoint)
	if err != nil {
		return {}, fmt.tprintf("cannot listen on %v: %v", endpoint, err)
	}
	return Listener{socket = socket}, ""
}

accept_client :: proc(listener: ^Listener) -> (client: net.TCP_Socket, source: net.Endpoint, ok: bool) {
	accepted, from, err := net.accept_tcp(listener.socket)
	if err != nil {
		return 0, {}, false
	}
	return accepted, from, true
}

close_listener :: proc(listener: ^Listener) {
	net.close(listener.socket)
}

// SO_RCVTIMEO：阻塞 recv 到点返回错误，连接线程据此断连（docs/web.md「风险与对策」）。
socket_set_read_timeout :: proc(socket: net.TCP_Socket, timeout: time.Duration) -> bool {
	return net.set_option(socket, .Receive_Timeout, timeout) == nil
}

// SIGINT/SIGTERM 时先做收尾（终止运行中的 turn），再退出。
g_shutdown_handler: proc(user: rawptr)
g_shutdown_user:    rawptr

shutdown_signal_handler :: proc "c" (signal: posix.Signal) {
	if handler := g_shutdown_handler; handler != nil {
		context = runtime.default_context()
		handler(g_shutdown_user)
	}
}

install_shutdown_handler :: proc(handler: proc(user: rawptr), user: rawptr) {
	g_shutdown_handler = handler
	g_shutdown_user = user
	action: posix.sigaction_t
	action.sa_handler = shutdown_signal_handler
	posix.sigemptyset(&action.sa_mask)
	action.sa_flags = {}
	posix.sigaction(.SIGINT, &action, nil)
	posix.sigaction(.SIGTERM, &action, nil)
}
