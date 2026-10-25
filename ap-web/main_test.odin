package main

import "core:testing"

@(test)
test_is_loopback_host :: proc(t: ^testing.T) {
	testing.expect(t, is_loopback_host("127.0.0.1"))
	testing.expect(t, is_loopback_host("127.9.8.7"))
	testing.expect(t, is_loopback_host("localhost"))
	testing.expect(t, is_loopback_host("LOCALHOST"))
	testing.expect(t, is_loopback_host("::1"))
	testing.expect(t, !is_loopback_host("0.0.0.0"))
	testing.expect(t, !is_loopback_host("192.168.1.10"))
	testing.expect(t, !is_loopback_host("example.com"))
}
