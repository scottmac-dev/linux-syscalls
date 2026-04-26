//! Client that streams TCP data to the tcp server socket
const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;

const SERVER_PORT: u16 = 5001;
const IPv4 = linux.AF.INET; // IPv4
const STREAM = linux.SOCK.STREAM; // TCP over reliable two way connection
const LOCAL_HOST: u32 = 0x7F000001; // 127.0.0.1

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("Usage: client <msg...>", .{});
        return error.EmptyArgs;
    }

    const msg = args[1..];

    // socket syscall
    const sockfd = linux.socket(IPv4, STREAM, 0);

    // handle failure
    if (linux.errno(sockfd) != .SUCCESS) {
        return error.SocketFailed;
    }

    defer _ = linux.close(@intCast(sockfd));

    // hardcode socket addr struct
    const sockaddr_in = linux.sockaddr.in{
        .family = IPv4,
        .port = std.mem.nativeToBig(u16, SERVER_PORT),
        .addr = std.mem.nativeToBig(u32, LOCAL_HOST),
        .zero = [_]u8{0} ** 8,
    };

    // connect syscall
    const rc = linux.connect(
        @intCast(sockfd),
        @ptrCast(&sockaddr_in),
        @sizeOf(linux.sockaddr.in),
    );

    // handle failure
    if (linux.errno(rc) != .SUCCESS) {
        return error.ConnectFailed;
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    // send each word in the message and receive the echo
    for (msg) |word| {

        // send
        const sent = linux.sendto(
            @intCast(sockfd),
            word.ptr,
            word.len,
            0,
            null,
            0,
        );

        // handle failure
        if (linux.errno(sent) != .SUCCESS) {
            return error.SendFailed;
        }

        // recv the echo
        var buf: [1024]u8 = undefined;
        const received = linux.recvfrom(
            @intCast(sockfd),
            &buf,
            buf.len,
            0,
            null,
            null,
        );

        // handle failure
        if (linux.errno(received) != .SUCCESS) {
            return error.RecvFailed;
        }

        try stdout.writeAll("[client] received: ");
        try stdout.writeAll(buf[0..received]);
        try stdout.writeAll("\n");
        try stdout.flush();
    }
}
