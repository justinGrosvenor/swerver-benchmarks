const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize: std.builtin.OptimizeMode = .ReleaseFast;

    // h1-only: the k6 scenarios are plaintext HTTP on :8080, so we skip
    // tls/http2/http3 (and their OpenSSL/QUIC link deps). io_uring is always-on
    // in swerver regardless of the build flag.
    const swerver_dep = b.dependency("swerver", .{
        .target = target,
        .optimize = optimize,
        // h1 plaintext only: no tls/h2/h3, and no compression (drops the zlib
        // link dep). io_uring stays always-on in swerver regardless.
        .@"enable-compression" = false,
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_module.addImport("swerver", swerver_dep.module("swerver"));

    const exe = b.addExecutable(.{
        .name = "swerver-bench",
        .root_module = exe_module,
    });
    b.installArtifact(exe);
}
