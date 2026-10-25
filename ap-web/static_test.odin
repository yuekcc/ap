package main

import "core:strings"
import "core:testing"

test_get_request :: proc(path: string) -> Http_Request {
	return Http_Request {
		method = .Get,
		path = path,
		keep_alive = true,
	}
}

@(test)
test_serve_static_index :: proc(t: ^testing.T) {
	assets, _ := make_assets("")
	request := test_get_request("/")
	response := Http_Response {
		status = 200,
	}
	serve_static(&assets, &request, &response)

	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, len(response.body) > 0, true)
	content_type, has_type := header_value(response.headers[:], "content-type")
	testing.expect(t, has_type)
	testing.expect_value(t, content_type, "text/html; charset=utf-8")
	_, has_etag := header_value(response.headers[:], "etag")
	testing.expect(t, has_etag)
}

@(test)
test_serve_static_not_found :: proc(t: ^testing.T) {
	assets, _ := make_assets("")
	request := test_get_request("/missing.js")
	response := Http_Response {
		status = 200,
	}
	serve_static(&assets, &request, &response)
	testing.expect_value(t, response.status, 404)
	testing.expect(t, strings.contains(string(response.body), "Not Found"))
}

@(test)
test_serve_static_etag_hit_304 :: proc(t: ^testing.T) {
	assets, _ := make_assets("")
	first := Http_Response {
		status = 200,
	}
	request := test_get_request("/index.html")
	serve_static(&assets, &request, &first)
	testing.expect_value(t, first.status, 200)
	etag, _ := header_value(first.headers[:], "etag")

	conditional := test_get_request("/index.html")
	conditional.headers = []Http_Header{{"If-None-Match", etag}}
	second := Http_Response {
		status = 200,
	}
	serve_static(&assets, &conditional, &second)
	testing.expect_value(t, second.status, 304)
	testing.expect_value(t, len(second.body), 0)
}

@(test)
test_serve_static_etag_miss_200 :: proc(t: ^testing.T) {
	assets, _ := make_assets("")
	request := test_get_request("/index.html")
	request.headers = []Http_Header{{"If-None-Match", `"other"`}}
	response := Http_Response {
		status = 200,
	}
	serve_static(&assets, &request, &response)
	testing.expect_value(t, response.status, 200)
	testing.expect(t, len(response.body) > 0)
}

@(test)
test_serve_static_rejects_post :: proc(t: ^testing.T) {
	assets, _ := make_assets("")
	request := Http_Request {
		method = .Post,
		path = "/",
		keep_alive = true,
	}
	response := Http_Response {
		status = 200,
	}
	serve_static(&assets, &request, &response)
	testing.expect_value(t, response.status, 405)
	testing.expect(t, response.close)
}

test_route_handler :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	response_text(response, 200, "routed")
}

@(test)
test_router_exact_match :: proc(t: ^testing.T) {
	router := Http_Router{}
	router_add(&router, .Post, "/api/turn", test_route_handler)

	request := Http_Request {
		method = .Post,
		path = "/api/turn",
	}
	response := Http_Response{}
	testing.expect(t, router_dispatch(&router, nil, &request, &response))
	testing.expect_value(t, string(response.body), "routed")
}

@(test)
test_router_method_and_path_mismatch :: proc(t: ^testing.T) {
	router := Http_Router{}
	router_add(&router, .Post, "/api/turn", test_route_handler)

	get := Http_Request {
		method = .Get,
		path = "/api/turn",
	}
	testing.expect(t, !router_dispatch(&router, nil, &get, &Http_Response{}))
	other := Http_Request {
		method = .Post,
		path = "/api/other",
	}
	testing.expect(t, !router_dispatch(&router, nil, &other, &Http_Response{}))
}

@(test)
test_router_prefix_match :: proc(t: ^testing.T) {
	router := Http_Router{}
	router_add(&router, .Get, "/api/sessions/", test_route_handler, true)

	request := Http_Request {
		method = .Get,
		path = "/api/sessions/ses_1",
	}
	response := Http_Response{}
	testing.expect(t, router_dispatch(&router, nil, &request, &response))
}

@(test)
test_router_exact_beats_prefix :: proc(t: ^testing.T) {
	router := Http_Router{}
	router_add(&router, .Get, "/api/", test_route_handler, true)
	router_add(&router, .Get, "/api/turn", test_route_handler_exact)

	request := Http_Request {
		method = .Get,
		path = "/api/turn",
	}
	response := Http_Response{}
	testing.expect(t, router_dispatch(&router, nil, &request, &response))
	testing.expect_value(t, string(response.body), "exact")
}

test_route_handler_exact :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	response_text(response, 200, "exact")
}

@(test)
test_app_unknown_api_returns_json_404 :: proc(t: ^testing.T) {
	assets, _ := make_assets("")
	app := App {
		assets = assets,
	}
	api_register_routes()
	request := Http_Request {
		method = .Get,
		path = "/api/definitely-not-an-endpoint",
		keep_alive = true,
	}
	response := Http_Response {
		status = 200,
	}
	app_handle_request(&app, &request, &response)
	testing.expect_value(t, response.status, 404)
	testing.expect(t, strings.contains(string(response.body), `"code":"not_found"`))
}

@(test)
test_app_static_route :: proc(t: ^testing.T) {
	assets, _ := make_assets("")
	app := App {
		assets = assets,
	}
	request := test_get_request("/")
	response := Http_Response {
		status = 200,
	}
	app_handle_request(&app, &request, &response)
	testing.expect_value(t, response.status, 200)
	testing.expect(t, len(response.body) > 0)
}

@(test)
test_app_unknown_path_404 :: proc(t: ^testing.T) {
	assets, _ := make_assets("")
	app := App {
		assets = assets,
	}
	request := test_get_request("/nope.html")
	response := Http_Response {
		status = 200,
	}
	app_handle_request(&app, &request, &response)
	testing.expect_value(t, response.status, 404)
}
