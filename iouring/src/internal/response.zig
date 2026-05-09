//! HTTP/1.1 response builder.

const std = @import("std");

pub const Response = struct {
    _status: u16 = 200,
    _reason: []const u8 = "OK",
    _headers: [32]Header = undefined,
    _header_count: usize = 0,
    _body: Body = .empty,
    _content_length: ?usize = null,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Keep the body representation small for now. The key change is that the
    /// response no longer assumes "one contiguous byte slice" forever.
    pub const Body = union(enum) {
        empty,
        bytes: []const u8,
    };

    pub fn status(self: *Response, code: u16) *Response {
        self._status = code;
        self._reason = reasonPhrase(code);
        return self;
    }

    pub fn header(self: *Response, name: []const u8, value: []const u8) *Response {
        if (self._header_count < self._headers.len) {
            self._headers[self._header_count] = .{ .name = name, .value = value };
            self._header_count += 1;
        }
        return self;
    }

    pub fn body(self: *Response, data: []const u8) *Response {
        self._body = if (data.len == 0) .empty else .{ .bytes = data };
        return self;
    }

    pub fn contentLength(self: *Response, len: usize) *Response {
        self._content_length = len;
        return self;
    }

    pub fn contentType(self: *Response, ct: []const u8) *Response {
        return self.header("Content-Type", ct);
    }

    fn hasHeader(self: *const Response, name: []const u8) bool {
        for (self._headers[0..self._header_count]) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
        }
        return false;
    }

    pub fn bodyBytes(self: *const Response) []const u8 {
        return switch (self._body) {
            .empty => "",
            .bytes => |bytes| bytes,
        };
    }

    pub fn bodyLen(self: *const Response) usize {
        return self._content_length orelse self.bodyBytes().len;
    }

    pub fn reasonPhrase(code: u16) []const u8 {
        return switch (code) {
            100 => "Continue",
            101 => "Switching Protocols",
            200 => "OK",
            201 => "Created",
            204 => "No Content",
            206 => "Partial Content",
            301 => "Moved Permanently",
            302 => "Found",
            304 => "Not Modified",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            408 => "Request Timeout",
            409 => "Conflict",
            413 => "Content Too Large",
            422 => "Unprocessable Content",
            429 => "Too Many Requests",
            500 => "Internal Server Error",
            501 => "Not Implemented",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            else => "Unknown",
        };
    }

    /// Serialise only the response headers into `buf`. The server may then
    /// write the body in a second phase, which is what enables future
    /// non-inline body sources such as files.
    pub fn serializeHeaders(self: *const Response, buf: []u8) ![]u8 {
        var pos: usize = 0;

        // Helper to "write" to the buffer and track position
        const print = struct {
            fn execute(b: []u8, p: *usize, comptime fmt: []const u8, args: anytype) !void {
                const slice = try std.fmt.bufPrint(b[p.*..], fmt, args);
                p.* += slice.len;
            }
        }.execute;

        // Status line
        try print(buf, &pos, "HTTP/1.1 {d} {s}\r\n", .{ self._status, self._reason });

        // Mandatory headers
        try print(buf, &pos, "Content-Length: {d}\r\n", .{self.bodyLen()});

        if (!self.hasHeader("Content-Type")) {
            const ct = "Content-Type: text/plain; charset=utf-8\r\n";
            @memcpy(buf[pos .. pos + ct.len], ct);
            pos += ct.len;
        }

        if (!self.hasHeader("Connection")) {
            const conn = "Connection: keep-alive\r\n";
            @memcpy(buf[pos .. pos + conn.len], conn);
            pos += conn.len;
        }

        // Custom headers
        for (self._headers[0..self._header_count]) |h| {
            try print(buf, &pos, "{s}: {s}\r\n", .{ h.name, h.value });
        }

        // End of headers, double \r\n
        if (pos + 2 > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[pos .. pos + 2], "\r\n");
        pos += 2;

        return buf[0..pos];
    }

    /// Serialise the response into `buf`.
    pub fn serialize(self: *const Response, buf: []u8) ![]u8 {
        const headers = try self.serializeHeaders(buf);
        const body_bytes = self.bodyBytes();
        var pos = headers.len;

        if (pos + body_bytes.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[pos .. pos + body_bytes.len], body_bytes);
        pos += body_bytes.len;

        return buf[0..pos];
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "basic response serialization" {
    var res = Response{};
    _ = res.status(200).body("hello");

    var buf: [512]u8 = undefined;
    const out = try res.serialize(&buf);

    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length: 5\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\r\nhello"));
}

test "404 response" {
    var res = Response{};
    _ = res.status(404).body("not found");
    var buf: [512]u8 = undefined;
    const out = try res.serialize(&buf);
    try std.testing.expect(std.mem.startsWith(u8, out, "HTTP/1.1 404 Not Found\r\n"));
}

test "explicit headers override defaults" {
    var res = Response{};
    _ = res
        .status(200)
        .header("Content-Type", "application/json")
        .header("Connection", "close")
        .body("{}");

    var buf: [512]u8 = undefined;
    const out = try res.serialize(&buf);

    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Type: application/json\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Type: text/plain; charset=utf-8\r\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Connection: keep-alive\r\n") == null);
}

test "content length override supports HEAD-style responses" {
    var res = Response{};
    _ = res.status(200).contentLength(41).body("");

    var buf: [512]u8 = undefined;
    const out = try res.serialize(&buf);

    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length: 41\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n"));
}

test "serialize headers excludes body bytes" {
    var res = Response{};
    _ = res.status(200).body("hello");

    var buf: [512]u8 = undefined;
    const out = try res.serializeHeaders(&buf);

    try std.testing.expect(std.mem.indexOf(u8, out, "\r\n\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") == null);
}
