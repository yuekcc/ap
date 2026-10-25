#+build !windows
package main

import "../internal"
import "core:fmt"
import "core:net"

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
