//! HTTP/1.1 request parser.
//!
//! Zero-allocation: parses directly from a caller-owned byte slice.
//! Returns slices into the original buffer, no copying.

const std = @import("std");

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    PATCH,
    TRACE,
    CONNECT,

    pub fn fromSlice(s: []const u8) ?Method {
        const map = std.StaticStringMap(Method).initComptime(.{
            .{ "GET", .GET },
            .{ "POST", .POST },
            .{ "PUT", .PUT },
            .{ "DELETE", .DELETE },
            .{ "HEAD", .HEAD },
            .{ "OPTIONS", .OPTIONS },
            .{ "PATCH", .PATCH },
            .{ "TRACE", .TRACE },
            .{ "CONNECT", .CONNECT },
        });
        return map.get(s);
    }
};

/// A single parsed header (name and value are slices into the raw buffer).
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const ParseError = error{
    InvalidRequestLine,
    InvalidMethod,
    InvalidVersion,
    TooManyHeaders,
    Incomplete,
};

/// Maximum headers we'll parse per request.
pub const MAX_HEADERS = 64;

pub const Request = struct {
    method: Method,
    /// Raw path, e.g. "/api/v1/users?page=2"
    path: []const u8,
    /// Query string portion (everything after '?'), or empty slice.
    query: []const u8,
    /// HTTP version as parsed, e.g. "HTTP/1.1"
    version: []const u8,
    /// Keep-alive semantics derived from version + Connection header.
    keep_alive: bool,
    /// Parsed headers (slices into original buffer).
    headers: []const Header,
    /// Body (everything after the blank line), may be empty.
    body: []const u8,

    /// Internal storage, callers dont not touch this directly.
    _header_buf: [MAX_HEADERS]Header = undefined,

    /// Parse an HTTP/1.1 request from `raw`.
    ///
    /// Returns the number of bytes consumed (header section + blank line),
    /// so callers can determine where the body starts.
    pub fn parse(raw: []const u8, out: *Request) ParseError!usize {
        var pos: usize = 0;

        // ── Request line
        const rl_end = std.mem.indexOf(u8, raw[pos..], "\r\n") orelse
            return ParseError.Incomplete;

        const request_line = raw[pos .. pos + rl_end];
        pos += rl_end + 2;

        var rl_it = std.mem.splitScalar(u8, request_line, ' ');
        const method_str = rl_it.next() orelse return ParseError.InvalidRequestLine;
        const raw_path = rl_it.next() orelse return ParseError.InvalidRequestLine;
        const version = rl_it.next() orelse return ParseError.InvalidRequestLine;

        if (!std.mem.startsWith(u8, version, "HTTP/"))
            return ParseError.InvalidVersion;

        const method = Method.fromSlice(method_str) orelse return ParseError.InvalidMethod;

        // Split path from query string.
        const path, const query = if (std.mem.indexOfScalar(u8, raw_path, '?')) |qi|
            .{ raw_path[0..qi], raw_path[qi + 1 ..] }
        else
            .{ raw_path, raw_path[raw_path.len..] };

        // ── Headers
        var n_headers: usize = 0;
        var keep_alive = std.mem.eql(u8, version, "HTTP/1.1"); // default for 1.1

        while (true) {
            if (std.mem.startsWith(u8, raw[pos..], "\r\n")) {
                pos += 2;
                break;
            }
            if (n_headers >= MAX_HEADERS) return ParseError.TooManyHeaders;

            const hdr_end = std.mem.indexOf(u8, raw[pos..], "\r\n") orelse
                return ParseError.Incomplete;

            const hdr_line = raw[pos .. pos + hdr_end];
            pos += hdr_end + 2;

            const colon = std.mem.indexOfScalar(u8, hdr_line, ':') orelse continue;
            const name = std.mem.trim(u8, hdr_line[0..colon], " \t");
            const value = std.mem.trim(u8, hdr_line[colon + 1 ..], " \t");

            out._header_buf[n_headers] = .{ .name = name, .value = value };
            n_headers += 1;

            // Check Connection header to determine keep-alive.
            if (std.ascii.eqlIgnoreCase(name, "connection")) {
                if (std.ascii.eqlIgnoreCase(value, "keep-alive")) {
                    keep_alive = true;
                } else if (std.ascii.eqlIgnoreCase(value, "close")) {
                    keep_alive = false;
                }
            }
        }

        out.* = .{
            .method = method,
            .path = path,
            .query = query,
            .version = version,
            .keep_alive = keep_alive,
            .headers = out._header_buf[0..n_headers],
            .body = raw[pos..],
        };

        return pos;
    }

    /// Look up a header value by name (case-insensitive). Returns null if absent.
    pub fn getHeader(self: *const Request, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// Content-Length as parsed from headers, or 0.
    pub fn contentLength(self: *const Request) usize {
        const val = self.getHeader("content-length") orelse return 0;
        return std.fmt.parseInt(usize, val, 10) catch 0;
    }
};

// ── Tests
test "parse simple GET" {
    const raw = "GET /hello?foo=bar HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
    var req: Request = undefined;
    _ = try Request.parse(raw, &req);

    try std.testing.expectEqual(Method.GET, req.method);
    try std.testing.expectEqualStrings("/hello", req.path);
    try std.testing.expectEqualStrings("foo=bar", req.query);
    try std.testing.expect(req.keep_alive);
    try std.testing.expectEqualStrings("localhost", req.getHeader("host").?);
}

test "parse POST with body" {
    const raw = "POST /submit HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    var req: Request = undefined;
    _ = try Request.parse(raw, &req);
    try std.testing.expectEqual(Method.POST, req.method);
    try std.testing.expectEqualStrings("hello", req.body);
    try std.testing.expectEqual(@as(usize, 5), req.contentLength());
}

test "incomplete request returns error" {
    const raw = "GET /foo HTTP/1.1\r\nHost: x";
    var req: Request = undefined;
    try std.testing.expectError(ParseError.Incomplete, Request.parse(raw, &req));
}

test "keep-alive semantics across versions and headers" {
    {
        const raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
        var req: Request = undefined;
        _ = try Request.parse(raw, &req);
        try std.testing.expect(req.keep_alive);
    }

    {
        const raw = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        var req: Request = undefined;
        _ = try Request.parse(raw, &req);
        try std.testing.expect(!req.keep_alive);
    }

    {
        const raw = "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n";
        var req: Request = undefined;
        _ = try Request.parse(raw, &req);
        try std.testing.expect(!req.keep_alive);
    }

    {
        const raw = "GET / HTTP/1.0\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
        var req: Request = undefined;
        _ = try Request.parse(raw, &req);
        try std.testing.expect(req.keep_alive);
    }
}

test "header lookup is case-insensitive" {
    const raw = "POST /submit HTTP/1.1\r\nhOsT: localhost\r\nCoNtEnT-LeNgTh: 5\r\n\r\nhello";
    var req: Request = undefined;
    _ = try Request.parse(raw, &req);

    try std.testing.expectEqualStrings("localhost", req.getHeader("HOST").?);
    try std.testing.expectEqualStrings("5", req.getHeader("content-length").?);
    try std.testing.expectEqual(@as(usize, 5), req.contentLength());
}
