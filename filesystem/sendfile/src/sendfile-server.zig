//! Using the sendfile linux syscall
//! high performance data trasfer call, copies data between two
//! fd within the kernel, no user space middle ground allocations
//!
//! This example runs a sendfile server which uses sendfile to
//! transfer text file to a receiver socket
const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;

const SERVER_PORT: u16 = 5001;
const IPv4 = linux.AF.INET;
const STREAM = linux.SOCK.STREAM;
const LOCALHOST: u32 = 0x7F000001;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var allocator = std.heap.page_allocator;

    const DATA_FILE = try allocator.dupeZ(u8, "/tmp/data.txt");

    // open the file once up front in read only, O_RDONLY = 0
    const filefd = linux.open(DATA_FILE.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(filefd) != .SUCCESS) return error.OpenFailed;
    defer _ = linux.close(@intCast(filefd));

    // Get file size so sendfile knows how many bytes to transfer
    var stat: linux.STATX = undefined;
    const rc_stat = linux.statx(@intCast(filefd), &stat);
    if (linux.errno(rc_stat) != .SUCCESS) return error.StatFailed;
    const file_size: usize = @intCast(stat.size);

    // set up socket
    const sockfd = linux.socket(IPv4, STREAM, 0);
    if (linux.errno(sockfd) != .SUCCESS) return error.SocketFailed;
    defer _ = linux.close(@intCast(sockfd));

    // configure socket
    const enable: i32 = 1;
    const rc_opt = linux.setsockopt(
        @intCast(sockfd),
        linux.SOL.SOCKET,
        linux.SO.REUSEADDR, // can reuse immediately, no TIME_WAIT debounce
        std.mem.asBytes(&enable),
        @sizeOf(i32),
    );
    if (linux.errno(rc_opt) != .SUCCESS) return error.SetSockOptFailed;

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

    // listen for messages, max backlog of 128
    const rc_listen = linux.listen(@intCast(sockfd), 128);
    if (linux.errno(rc_listen) != .SUCCESS) return error.ListenFailed;

    try stdout.writeAll("[server] listening on 127.0.0.1:5001\n");
    try stdout.flush();

    // super loop, accept and echo
    while (true) {
        var client_addr: linux.sockaddr.in = undefined;
        var client_addrlen: linux.socklen_t = @sizeOf(linux.sockaddr.in);

        const clientfd = linux.accept(
            @intCast(sockfd),
            @ptrCast(&client_addr),
            &client_addrlen,
        );
        if (linux.errno(clientfd) != .SUCCESS) return error.AcceptFailed;
        defer _ = linux.close(@intCast(clientfd));

        try stdout.writeAll("[server] client connected\n");
        try stdout.flush();

        // echo loop: recv then send back
        var buf: [1024]u8 = undefined;
        while (true) {
            const received = linux.recvfrom(
                @intCast(clientfd),
                &buf,
                buf.len,
                0,
                null,
                null,
            );

            // recvfrom returns 0 when client closes connection
            if (received == 0) {
                try stdout.writeAll("[server] client disconnected\n");
                try stdout.flush();
                break;
            }
            if (linux.errno(received) != .SUCCESS) return error.RecvFailed;

            const sent = linux.sendto(
                @intCast(clientfd),
                buf[0..received].ptr,
                received,
                0,
                null,
                0,
            );
            if (linux.errno(sent) != .SUCCESS) return error.SendFailed;
        }
    }
}
