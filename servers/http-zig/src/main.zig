const std = @import("std");
const posix = std.posix;

const BlobSize = 8 * 1024;
const HeaderBufSize = 16 * 1024;
const WorkerCount = 64;

const Errors = error{
    unexpectedEOF,
    headersTooLarge,
    notFound,
};

fn listen(address: std.net.Address) !std.net.Server {
    const flags = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
    var proto: u32 = 0;
    if (address.any.family != posix.AF.UNIX) {
        proto = posix.IPPROTO.TCP;
    }
    const sockfd = try posix.socket(address.any.family, flags, proto);
    var listener: std.net.Server = .{
        .listen_address = undefined,
        .stream = .{ .handle = sockfd },
    };
    errdefer listener.stream.close();

    posix.setsockopt(sockfd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};

    var socklen = address.getOsSockLen();
    try posix.bind(sockfd, &address.any, socklen);
    try posix.listen(sockfd, 1024);
    try posix.getsockname(sockfd, &listener.listen_address.any, &socklen);
    return listener;
}

const WorkerContext = struct {
    listener: *std.net.Server,
    blob: []const u8,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const address = try std.net.Address.parseIp4("0.0.0.0", 8080);
    var listener = try listen(address);
    defer listener.deinit();

    const blob = try allocator.alloc(u8, BlobSize);
    @memset(blob, 0);

    var ctx = WorkerContext{
        .listener = &listener,
        .blob = blob,
    };

    // Spawn N-1 worker threads, use main thread as Nth worker
    var threads: [WorkerCount - 1]std.Thread = undefined;
    var spawned: usize = 0;
    for (&threads) |*t| {
        t.* = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, workerLoop, .{&ctx}) catch break;
        spawned += 1;
    }

    // Main thread also accepts
    workerLoop(&ctx);

    // Unreachable in practice, but clean up if workerLoop ever returns
    for (threads[0..spawned]) |t| t.join();
}

fn workerLoop(ctx: *WorkerContext) void {
    while (true) {
        const connection = ctx.listener.accept() catch continue;
        handleConnection(connection.stream, ctx.blob) catch {};
        connection.stream.close();
    }
}

fn handleConnection(stream: std.net.Stream, blob: []const u8) !void {
    var reader = stream.reader();
    var writer = stream.writer();

    // Keep-alive loop: handle multiple requests per connection
    while (true) {
        var header_buf: [HeaderBufSize]u8 = undefined;
        const header_result = readHeaders(&reader, &header_buf) catch |err| {
            switch (err) {
                Errors.unexpectedEOF => return,
                else => return err,
            }
        };
        const header_bytes = header_buf[0..header_result.end];
        const leftover = header_result.total - header_result.end;

        const first_line_end = try indexOf(header_bytes, '\n');
        var first_line = header_bytes[0..first_line_end];
        if (first_line.len > 0 and first_line[first_line.len - 1] == '\r') {
            first_line = first_line[0 .. first_line.len - 1];
        }

        const method_end = try indexOf(first_line, ' ');
        const path_start = method_end + 1;
        const path_part = first_line[path_start..];
        const path_end = try indexOf(path_part, ' ');
        const method = first_line[0..method_end];
        const path = path_part[0..path_end];

        // Check for Connection: close header
        var lower_buf: [HeaderBufSize]u8 = undefined;
        const header_len = header_bytes.len;
        var idx: usize = 0;
        while (idx < header_len) : (idx += 1) {
            const c = header_bytes[idx];
            if (c >= 'A' and c <= 'Z') {
                lower_buf[idx] = c + 32;
            } else {
                lower_buf[idx] = c;
            }
        }

        const keep_alive = !hasConnectionClose(lower_buf[0..header_len]);
        const content_length = findContentLength(lower_buf[0..header_len]);
        const conn_header = if (keep_alive) "Connection: keep-alive\r\n" else "Connection: close\r\n";

        // Read body onto stack (max 64KB to avoid stack overflow)
        var body_stack: [65536]u8 = undefined;
        var body: []u8 = body_stack[0..0];
        if (content_length > 0) {
            if (content_length > body_stack.len) return; // reject oversized
            body = body_stack[0..content_length];

            if (leftover > 0) {
                const to_copy = @min(leftover, content_length);
                @memcpy(body[0..to_copy], header_buf[header_result.end .. header_result.end + to_copy]);
            }

            const remaining = content_length -| leftover;
            if (remaining > 0) {
                _ = try reader.readAll(body[leftover..]);
            }
        }

        if (std.mem.eql(u8, method, "GET")) {
            if (std.mem.eql(u8, path, "/health")) {
                try writer.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n" ++ "Connection: keep-alive\r\n\r\n");
            } else if (std.mem.eql(u8, path, "/echo")) {
                const payload = "{\"status\":\"ok\"}";
                try writer.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n" ++ "Connection: keep-alive\r\n\r\n" ++ payload);
            } else if (std.mem.eql(u8, path, "/blob")) {
                try writer.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 8192\r\n");
                try writer.writeAll(conn_header);
                try writer.writeAll("\r\n");
                try writer.writeAll(blob);
            } else {
                try writer.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n");
                try writer.writeAll(conn_header);
                try writer.writeAll("\r\n");
            }
        } else if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/echo")) {
            try writer.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n");
            try writer.print("Content-Length: {d}\r\n", .{body.len});
            try writer.writeAll(conn_header);
            try writer.writeAll("\r\n");
            try writer.writeAll(body);
        } else {
            try writer.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n");
            try writer.writeAll(conn_header);
            try writer.writeAll("\r\n");
        }

        if (!keep_alive) return;
    }
}

const HeaderResult = struct {
    end: usize,
    total: usize,
};

fn readHeaders(reader: anytype, buf: []u8) !HeaderResult {
    var total: usize = 0;
    while (true) {
        const read = try reader.read(buf[total..]);
        if (read == 0) return Errors.unexpectedEOF;
        total += read;
        if (total > buf.len) return Errors.headersTooLarge;
        const maybe_pos = indexOfSequence(buf[0..total], "\r\n\r\n");
        if (maybe_pos) |pos| {
            return HeaderResult{
                .end = pos + 4,
                .total = total,
            };
        }
    }
}

fn findContentLength(headers: []const u8) usize {
    const needle = "content-length:";
    var i: usize = 0;
    while (i + needle.len <= headers.len) {
        if (std.mem.eql(u8, headers[i .. i + needle.len], needle)) {
            i += needle.len;
            while (i < headers.len and (headers[i] == ' ' or headers[i] == '\t')) i += 1;
            const start = i;
            while (i < headers.len and headers[i] != '\r' and headers[i] != '\n') i += 1;
            const slice = headers[start..i];
            return std.fmt.parseInt(usize, slice, 10) catch 0;
        }
        i += 1;
    }
    return 0;
}

fn hasConnectionClose(headers: []const u8) bool {
    const needle = "connection:";
    var i: usize = 0;
    while (i + needle.len <= headers.len) {
        if (std.mem.eql(u8, headers[i .. i + needle.len], needle)) {
            i += needle.len;
            while (i < headers.len and (headers[i] == ' ' or headers[i] == '\t')) i += 1;
            const start = i;
            while (i < headers.len and headers[i] != '\r' and headers[i] != '\n') i += 1;
            const value = headers[start..i];
            if (std.mem.indexOf(u8, value, "close") != null) return true;
            return false;
        }
        i += 1;
    }
    return false;
}

fn indexOf(buf: []const u8, byte: u8) !usize {
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == byte) return i;
    }
    return Errors.notFound;
}

fn indexOfSequence(buf: []const u8, seq: []const u8) ?usize {
    if (seq.len == 0) return 0;
    var i: usize = 0;
    while (i + seq.len <= buf.len) {
        if (std.mem.eql(u8, buf[i .. i + seq.len], seq)) return i;
        i += 1;
    }
    return null;
}
