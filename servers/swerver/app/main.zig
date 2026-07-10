//! swerver benchmark application for HttpArena/swerver-benchmarks.
//!
//! The bare `swerver` binary is a server engine with no routes, so it 404s
//! every request (including the harness health check). This tiny app registers
//! exactly the endpoints the k6 scenarios drive, mirroring servers/nginx's
//! nginx.conf contract so swerver and nginx answer the same requests:
//!
//!   GET  /health -> 200, empty body
//!   GET  /echo   -> 200, {"status":"ok"} (application/json)
//!   POST /echo   -> 200, echoes the request body back
//!   GET  /blob   -> 200, 8 KiB octet-stream
//!   (anything else -> 404, the router default)
//!
//! Built against the swerver library as a dependency (../swerver), so it tracks
//! whatever swerver source the Dockerfile checked out (local working tree, a
//! git ref, or the pinned baseline).
//!
//! Lifecycle (config loading, reverse-proxy construction from the config's
//! upstreams/routes, Master vs single-process dispatch) is
//! swerver.bootstrap.run - the exact path the swerver binary takes, so the
//! benchmark measures the shipped bootstrap, not a hand-rolled copy.
//! Requires a swerver checkout that has swerver.bootstrap (>= alpha.26).

const std = @import("std");
const swerver = @import("swerver");

const router = swerver.router;
const response_mod = swerver.response;

// 8 KiB payload for the /blob (payload) profile, matching nginx's blob.bin.
const BLOB: [8192]u8 = [_]u8{'x'} ** 8192;

fn handleHealth(_: *router.HandlerContext) response_mod.Response {
    return .{ .status = 200, .headers = &[_]response_mod.Header{}, .body = .none };
}

fn handleEchoGet(_: *router.HandlerContext) response_mod.Response {
    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{.{ .name = "Content-Type", .value = "application/json" }},
        .body = .{ .bytes = "{\"status\":\"ok\"}" },
    };
}

fn handleEchoPost(ctx: *router.HandlerContext) response_mod.Response {
    if (ctx.request.body.len() == 0) return handleEchoGet(ctx);
    const body_slice = ctx.request.body.sliceOrNull() orelse {
        const buf = ctx.request.body.copyTo(ctx.response_buf) orelse return .{
            .status = 413,
            .headers = &[_]response_mod.Header{},
            .body = .{ .bytes = "Body too large to echo" },
        };
        return .{
            .status = 200,
            .headers = &[_]response_mod.Header{.{ .name = "Content-Type", .value = "application/json" }},
            .body = .{ .bytes = buf },
        };
    };
    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{.{ .name = "Content-Type", .value = "application/json" }},
        .body = .{ .bytes = body_slice },
    };
}

// A representative (and compressible) JSON payload for the /json profile
// (h2-json-compressed exercises gzip over h2 + valid-JSON checks).
const JSON_BODY =
    \\{"status":"ok","count":10,"items":[
    \\{"id":1,"name":"item-one","category":"widgets","price":1299,"quantity":42,"active":true},
    \\{"id":2,"name":"item-two","category":"widgets","price":1499,"quantity":17,"active":true},
    \\{"id":3,"name":"item-three","category":"gadgets","price":2599,"quantity":8,"active":false},
    \\{"id":4,"name":"item-four","category":"gadgets","price":999,"quantity":63,"active":true},
    \\{"id":5,"name":"item-five","category":"widgets","price":1799,"quantity":21,"active":true},
    \\{"id":6,"name":"item-six","category":"gizmos","price":3499,"quantity":5,"active":false},
    \\{"id":7,"name":"item-seven","category":"gadgets","price":1199,"quantity":34,"active":true},
    \\{"id":8,"name":"item-eight","category":"widgets","price":1399,"quantity":29,"active":true},
    \\{"id":9,"name":"item-nine","category":"gizmos","price":2799,"quantity":12,"active":false},
    \\{"id":10,"name":"item-ten","category":"gadgets","price":1599,"quantity":48,"active":true}
    \\]}
;

fn handleJson(_: *router.HandlerContext) response_mod.Response {
    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{.{ .name = "Content-Type", .value = "application/json" }},
        .body = .{ .bytes = JSON_BODY },
    };
}

fn handleBlob(_: *router.HandlerContext) response_mod.Response {
    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{.{ .name = "Content-Type", .value = "application/octet-stream" }},
        .body = .{ .bytes = &BLOB },
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try swerver.bootstrap.parseArgs(init.minimal.args, allocator);

    var app_router = router.Router.init(.{});
    try app_router.get("/health", handleHealth);
    try app_router.get("/echo", handleEchoGet);
    try app_router.post("/echo", handleEchoPost);
    try app_router.get("/json", handleJson);
    try app_router.get("/blob", handleBlob);

    var opts = swerver.bootstrap.optionsFromArgs(&args);
    opts.router = app_router;
    try swerver.bootstrap.run(allocator, opts);
}
