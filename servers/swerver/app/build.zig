const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;

    // h1-only: the k6 scenarios are plaintext HTTP on :8080, so we skip
    // tls/http2/http3 (and their OpenSSL/QUIC link deps). io_uring is always-on
    // in swerver regardless of the build flag.
    // Full protocol support so ONE binary serves every suite: h1 plaintext,
    // TLS + HTTP/2 (tls-http2), HTTP/3/QUIC (http3), and reverse proxy (gateway/
    // load-balancer). Each scenario's config selects the listeners it needs.
    const swerver_dep = b.dependency("swerver", .{
        .target = target,
        .optimize = optimize,
        .@"enable-tls" = true,
        .@"enable-http2" = true,
        .@"enable-http3" = true,
        .@"enable-proxy" = true,
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_module.addImport("swerver", swerver_dep.module("swerver"));

    const exe = b.addExecutable(.{
        .name = "swerver",
        .root_module = exe_module,
    });
    b.installArtifact(exe);
}
