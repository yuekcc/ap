#+build windows
package main

import "../internal"
import "core:fmt"
import "core:net"
import win32 "core:sys/windows"

setup_console :: proc() {
	internal.setup_console()
}

normalize_args :: proc(args: []string) -> []string {
	return internal.normalize_args(args)
}

Listener :: struct {
	socket: net.TCP_Socket,
}

// Windows 的 SO_REUSEADDR 会允许其他进程抢占同一端口；stdlib 的 listen_tcp 也
// 选择 SO_EXCLUSIVEADDRUSE。Unix 侧则用 SO_REUSEADDR 以便崩溃后立刻重启。
open_listener :: proc(endpoint: net.Endpoint) -> (Listener, string) {
	any_socket, create_err := net.create_socket(net.family_from_endpoint(endpoint), .TCP)
	if create_err != nil {
		return {}, fmt.tprintf("cannot create socket: %v", create_err)
	}
	socket := any_socket.(net.TCP_Socket)
	listener := Listener {
		socket = socket,
	}

	if option_err := net.set_option(socket, .Exclusive_Addr_Use, true); option_err != nil {
		net.close(socket)
		return {}, fmt.tprintf("cannot set SO_EXCLUSIVEADDRUSE: %v", option_err)
	}
	if bind_err := net.bind(socket, endpoint); bind_err != nil {
		net.close(socket)
		return {}, fmt.tprintf("cannot bind %v: %v", endpoint, bind_err)
	}
	if win32.listen(win32.SOCKET(socket), 128) == win32.SOCKET_ERROR {
		net.close(socket)
		return {}, fmt.tprintf("cannot listen on %v", endpoint)
	}
	return listener, ""
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
