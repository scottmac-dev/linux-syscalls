const std = @import("std");
const linux = std.os.linux;

const MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"; // server magic key

pub const Frame = struct {
    opcode: u8,
    payload: []u8, // points into caller's buffer, already unmasked
};

// crypto helper
fn computeAcceptKey(client_key: []const u8, out: []u8) ![]const u8 {
    var concat_buf: [256]u8 = undefined;
    const concat = try std.fmt.bufPrint(&concat_buf, "{s}{s}", .{ client_key, MAGIC });

    var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(concat, &hash, .{});

    const encoder = std.base64.standard.Encoder;
    return encoder.encode(out, &hash);
}

// apply mask for clinet -> server
fn unmask(payload: []u8, mask: [4]u8) void {
    for (payload, 0..) |*b, i| {
        b.* ^= mask[i % 4];
    }
}

// reads until \r\n\r\n into buf. returns the slice of headers received.
// errors if headers exceed buf or connection closes early.
fn recvHeaders(fd: i32, buf: []u8) ![]u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = linux.recvfrom(fd, buf[total..].ptr, buf.len - total, 0, null, null);
        if (n == 0) return error.ConnectionClosed;
        if (linux.errno(n) != .SUCCESS) return error.RecvFailed;
        total += n;
        // Search for the end-of-headers sentinel
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
    }
    return buf[0..total];
}

// extracts the value of a header line
// e.g. "Sec-WebSocket-Key: abc\r\n" -> "abc"
fn extractHeader(headers: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, name)) {
            const rest = line[name.len..];
            // expect ": value"
            if (rest.len < 2 or rest[0] != ':') continue;
            return std.mem.trim(u8, rest[1..], " ");
        }
    }
    return null;
}

// receive exactly `buf.len` bytes, looping over short reads.
fn recvExact(fd: i32, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = linux.recvfrom(fd, buf[total..].ptr, buf.len - total, 0, null, null);
        if (n == 0) return error.ConnectionClosed;
        if (linux.errno(n) != .SUCCESS) return error.RecvFailed;
        total += n;
    }
}

// perform upgrade handshake
pub fn handshake(fd: i32, buf: []u8) !void {
    const headers = try recvHeaders(fd, buf);
    std.debug.print("[debug] raw headers:\n{s}\n---\n", .{headers});

    const ws_key = extractHeader(headers, "Sec-WebSocket-Key") orelse
        return error.MissingWebSocketKey;

    // Trim any trailing whitespace/CR the split may have left
    const key = std.mem.trim(u8, ws_key, " \r\n");

    var accept_buf: [64]u8 = undefined;
    const accept_key = try computeAcceptKey(key, &accept_buf);

    var response_buf: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(
        &response_buf,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "\r\n",
        .{accept_key},
    );
    std.debug.print("[debug] response:\n{s}\n", .{response});

    const sent = linux.sendto(fd, response.ptr, response.len, 0, null, 0);
    if (linux.errno(sent) != .SUCCESS) return error.SendFailed;
}

/// read one complete WebSocket frame.
/// handles 7-bit and 16-bit payload lengths.
pub fn recvFrame(fd: i32, buf: []u8) !Frame {
    // Read the 2-byte header
    var header: [2]u8 = undefined;
    try recvExact(fd, &header);

    const fin = (header[0] & 0x80) != 0;
    const opcode = header[0] & 0x0F;
    const masked = (header[1] & 0x80) != 0;
    var payload_len: usize = header[1] & 0x7F;

    // don't support fragmented frames in this minimal impl
    if (!fin) return error.FragmentedFrameUnsupported;

    // extended payload length
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        try recvExact(fd, &ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        return error.PayloadTooLarge;
    }

    if (payload_len > buf.len) return error.PayloadTooLarge;

    // Read masking key (clients always send masked frames)
    var mask: [4]u8 = undefined;
    if (masked) try recvExact(fd, &mask);

    // Read payload
    try recvExact(fd, buf[0..payload_len]);
    if (masked) unmask(buf[0..payload_len], mask);

    return Frame{ .opcode = opcode, .payload = buf[0..payload_len] };
}

// send a single unfragmented, unmasked server frame.
pub fn sendFrame(fd: i32, opcode: u8, payload: []const u8) !void {
    var header: [4]u8 = undefined;
    var header_len: usize = 2;

    header[0] = 0x80 | (opcode & 0x0F); // FIN=1 + opcode
    if (payload.len < 126) {
        header[1] = @intCast(payload.len); // no mask bit
    } else if (payload.len <= 0xFFFF) {
        header[1] = 126;
        const ext = std.mem.bytesAsValue(u16, header[2..4]);
        ext.* = std.mem.nativeToBig(u16, @intCast(payload.len));
        header_len = 4;
    } else {
        return error.PayloadTooLarge;
    }

    const h = linux.sendto(fd, &header, header_len, 0, null, 0);
    if (linux.errno(h) != .SUCCESS) return error.SendFailed;

    if (payload.len > 0) {
        const p = linux.sendto(fd, payload.ptr, payload.len, 0, null, 0);
        if (linux.errno(p) != .SUCCESS) return error.SendFailed;
    }
}
