//! Client that receives file from sendfile and outputs to stdout
const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;

const SERVER_PORT: u16 = 5001;
const IPv4 = linux.AF.INET; // IPv4
const STREAM = linux.SOCK.STREAM; // TCP
const LOCAL_HOST: u32 = 0x7F000001; // 127.0.0.1

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const sockfd = linux.socket(IPv4, STREAM, 0);
    if (linux.errno(sockfd) != .SUCCESS) return error.SocketFailed;
    defer _ = linux.close(@intCast(sockfd));

    // hardcode socket addr struct
    const sockaddr_in = linux.sockaddr.in{
        .family = IPv4,
        .port = std.mem.nativeToBig(u16, SERVER_PORT),
        .addr = std.mem.nativeToBig(u32, LOCAL_HOST),
        .zero = [_]u8{0} ** 8,
    };

    // connect syscall should prompt server to send file data
    const rc = linux.connect(
        @intCast(sockfd),
        @ptrCast(&sockaddr_in),
        @sizeOf(linux.sockaddr.in),
    );
    if (linux.errno(rc) != .SUCCESS) return error.ConnectFailed;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    // recv the file data
    var buf: [4096]u8 = undefined;

    // receive in loop incase file data exceeds buffer size
    while (true) {
        const received = linux.recvfrom(@intCast(sockfd), &buf, buf.len, 0, null, null);
        if (received == 0) break; // server closed connection, transfer complete
        if (linux.errno(received) != .SUCCESS) return error.RecvFailed;
        try stdout.writeAll(buf[0..received]);
    }
    try stdout.flush();
}
