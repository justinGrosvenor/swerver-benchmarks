const std = @import("std");
const posix = std.posix;

const BlobSize = 8 * 1024;
const HeaderBufSize = 16 * 1024;

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

    var socklen = address.getOsSockLen();
    try posix.bind(sockfd, &address.any, socklen);
    try posix.listen(sockfd, 128);
    try posix.getsockname(sockfd, &listener.listen_address.any, &socklen);
    return listener;
}

pub fn main() !void {
    var page_allocator = std.heap.page_allocator;
    const allocator = &page_allocator;
    const address = try std.net.Address.parseIp4("0.0.0.0", 8080);
    var listener = try listen(address);
    defer listener.deinit();

    var blob = try allocator.alloc(u8, BlobSize);
    for (blob) |*byte| {
        byte.* = 0;
    }

    while (true) {
        const connection = try listener.accept();
        const task = try allocator.create(ConnectionTask);
        task.allocator = allocator;
        task.stream = connection.stream;
        task.blob = blob[0..];

        var thread = try std.Thread.spawn(.{}, connectionRoutine, .{task});
        thread.detach();
    }
}

const ConnectionTask = struct {
    allocator: *std.mem.Allocator,
    stream: std.net.Stream,
    blob: []const u8,
};

fn connectionRoutine(task: *ConnectionTask) void {
    defer task.allocator.destroy(task);
    defer task.stream.close();

    handleConnection(task) catch {
        return;
    };
}

fn handleConnection(task: *ConnectionTask) !void {
    var reader = task.stream.reader();
    var writer = task.stream.writer();

    // Keep-alive loop: handle multiple requests per connection
    while (true) {
        var header_buf: [HeaderBufSize]u8 = undefined;
        const header_result = readHeaders(&reader, &header_buf) catch |err| {
            switch (err) {
                Errors.unexpectedEOF => return, // client closed connection
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

        var body: []u8 = undefined;
        var owned_body: ?[]u8 = null;
        if (content_length > 0) {
            const req_body = try task.allocator.alloc(u8, content_length);
            owned_body = req_body;
            body = req_body;

            if (leftover > 0) {
                var left_idx: usize = 0;
                const copied = header_buf[header_result.end .. header_result.end + leftover];
                while (left_idx < copied.len) : (left_idx += 1) {
                    body[left_idx] = copied[left_idx];
                }
            }

            _ = try reader.readAll(body[leftover..]);
        } else {
            const scratch: [0]u8 = undefined;
            body = scratch[0..0];
        }
        defer if (owned_body) |buf| task.allocator.free(buf);

        if (std.mem.eql(u8, method, "GET")) {
            if (std.mem.eql(u8, path, "/health")) {
                try writer.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n");
                try writer.writeAll(conn_header);
                try writer.writeAll("\r\n");
            } else if (std.mem.eql(u8, path, "/echo")) {
                const payload = "{\"status\":\"ok\"}";
                try writer.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n");
                try writer.print("Content-Length: {d}\r\n", .{payload.len});
                try writer.writeAll(conn_header);
                try writer.writeAll("\r\n");
                try writer.writeAll(payload);
            } else if (std.mem.eql(u8, path, "/blob")) {
                try writer.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n");
                try writer.print("Content-Length: {d}\r\n", .{task.blob.len});
                try writer.writeAll(conn_header);
                try writer.writeAll("\r\n");
                try writer.writeAll(task.blob);
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
