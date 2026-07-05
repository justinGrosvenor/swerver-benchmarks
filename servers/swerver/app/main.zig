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

fn handleBlob(_: *router.HandlerContext) response_mod.Response {
    return .{
        .status = 200,
        .headers = &[_]response_mod.Header{.{ .name = "Content-Type", .value = "application/octet-stream" }},
        .body = .{ .bytes = &BLOB },
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try parseArgs(init.minimal.args, allocator);

    var loaded_config: ?swerver.config_file.LoadedConfig = null;
    defer if (loaded_config) |*lc| lc.deinit();

    var cfg: swerver.config.ServerConfig = blk: {
        if (args.config_path) |path| {
            loaded_config = swerver.config_file.loadConfigFile(allocator, path) catch |err| {
                std.log.err("failed to load config: {}", .{err});
                return err;
            };
            break :blk loaded_config.?.server_config;
        }
        break :blk swerver.config.ServerConfig.default();
    };
    try cfg.validate();

    var app_router = router.Router.init(.{});
    try app_router.get("/health", handleHealth);
    try app_router.get("/echo", handleEchoGet);
    try app_router.post("/echo", handleEchoPost);
    try app_router.get("/blob", handleBlob);

    if (cfg.workers != 1) {
        var master = try swerver.Master.init(allocator, cfg, app_router, null);
        defer master.deinit();
        try master.run(null);
    } else {
        const srv = try swerver.ServerBuilder
            .config(cfg)
            .router(app_router)
            .build(allocator);
        defer {
            srv.deinit();
            allocator.destroy(srv);
        }
        try srv.run(null);
    }
}

const Args = struct { config_path: ?[]const u8 = null };

fn parseArgs(args: std.process.Args, allocator: std.mem.Allocator) !Args {
    var result: Args = .{};
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next();
    while (it.next()) |arg_z| {
        const arg = std.mem.sliceTo(arg_z, 0);
        if (std.mem.eql(u8, arg, "--config")) {
            const value = it.next() orelse return error.MissingValue;
            result.config_path = std.mem.sliceTo(value, 0);
        }
    }
    return result;
}
