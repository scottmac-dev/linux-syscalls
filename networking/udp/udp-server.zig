//! UDP echo server demonstrating the `socket` syscall
//! Syscalls used:
//!     socket, bind, sendto, recvfrom, close
const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;

const SERVER_PORT: u16 = 5001;
const IPv4 = linux.AF.INET;
const DATAGRAM = linux.SOCK.DGRAM;
const LOCALHOST: u32 = 0x7F000001;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    // set up socket
    const sockfd = linux.socket(IPv4, DATAGRAM, 0);
    if (linux.errno(sockfd) != .SUCCESS) return error.SocketFailed;
    defer _ = linux.close(@intCast(sockfd));

    // bind socket to local host port
    const addr = linux.sockaddr.in{
        .family = IPv4,
        .port = std.mem.nativeToBig(u16, SERVER_PORT),
        .addr = std.mem.nativeToBig(u32, LOCALHOST),
        .zero = [_]u8{0} ** 8,
    };
    const rc_bind = linux.bind(
        @intCast(sockfd),
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.in),
    );
    if (linux.errno(rc_bind) != .SUCCESS) return error.BindFailed;

    try stdout.writeAll("[server] listening on 127.0.0.1:5001\n");
    try stdout.flush();

    // super loop, accept and echo
    while (true) {
        var client_addr: linux.sockaddr.in = undefined;
        var client_addrlen: linux.socklen_t = @sizeOf(linux.sockaddr.in);

        // echo loop: recv then send back
        var buf: [1024]u8 = undefined;
        while (true) {
            const received = linux.recvfrom(
                @intCast(sockfd),
                &buf,
                buf.len,
                0,
                @ptrCast(&client_addr),
                &client_addrlen,
            );

            // recvfrom returns 0 when client closes connection
            if (received == 0) {
                try stdout.writeAll("[server] recvfrom failed\n");
                try stdout.flush();
                break;
            }
            if (linux.errno(received) != .SUCCESS) return error.RecvFailed;

            try stdout.writeAll("[server] message: ");
            try stdout.writeAll(buf[0..received]);
            try stdout.writeAll("\n");
            try stdout.flush();
            // const sent = linux.sendto(
            //     @intCast(clientfd),
            //     buf[0..received].ptr,
            //     received,
            //     0,
            //     null,
            //     0,
            // );
            // if (linux.errno(sent) != .SUCCESS) return error.SendFailed;
        }
    }
}
