//! Demonstrates usage of the getrandom syscall for the use case of a uuid v4 generator
//! getrandom = fills buffer with random bytes, often used to seed random generators
//! or in cryptographic puposes
const std = @import("std");
const linux = std.os.linux;

// wraps getrandom syscall
fn getrandom(buf: []u8, flags: u32) !void {
    const rc = linux.syscall3(.getrandom, @intFromPtr(buf.ptr), buf.len, flags);
    if (linux.errno(rc) != .SUCCESS) return error.GetrandomFailed;
}

// generates a uuid v4 string
// format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
// example output:
//  f47ac10b-58cc-4372-a567-0e02b2c3d479
//  9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d
fn uuid_v4() ![36]u8 {
    var bytes: [16]u8 = undefined;
    try getrandom(&bytes, 0); // fill buf with random bytes from getrandom

    // UUID v4 spec (RFC 4122):
    // byte 6: top 4 bits = 0100 (version 4)
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    // byte 8: top 2 bits = 10   (variant 1)
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    var out: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0],  bytes[1],  bytes[2],  bytes[3],
        bytes[4],  bytes[5],  bytes[6],  bytes[7],
        bytes[8],  bytes[9],  bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15],
    }) catch unreachable; // fixed size, cannot fail

    return out;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const id = try uuid_v4();
    try stdout.writeAll(&id);
    try stdout.writeByte('\n');
    try stdout.flush();
}
