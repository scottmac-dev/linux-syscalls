//! Using the sendfile linux syscall
//! high performance data trasfer call, copies data between two
//! fd within the kernel, no user space middle ground allocations
//!
//! This example runs a sendfile server which uses sendfile to
//! transfer text file to a receiver socket
//!
//! Syscalls
//!     - sendfile: zero alloc data trasfer between fds
//!     - open: open file
//!     - statx: modern stat, get file metadata, only requesting size
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

    // get file size so sendfile knows how many bytes to transfer
    var stat: linux.Statx = undefined;
    const rc_stat = linux.statx(
        @intCast(filefd),
        "",
        linux.AT.EMPTY_PATH,
        linux.STATX.BASIC_STATS,
        &stat,
    );
    if (linux.errno(rc_stat) != .SUCCESS) return error.StatFailed;

    // extract from stat return
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
        linux.SO.REUSEADDR,
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

    // super loop, accept connections and send file data to client
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

        try stdout.writeAll("[server] client connected, sending file data.txt\n");
        try stdout.flush();

        var offset: linux.off_t = 0; // set to 0 so full file sent each time
        var remaining: usize = file_size; // bytes to send

        // sendfile transfer until all bytes sent
        // requires loop incase send is interrupted to guarantee full transfer
        while (remaining > 0) {
            const sent = linux.sendfile(
                @intCast(clientfd), // out = client socket
                @intCast(filefd), // in = data.txt
                &offset,
                remaining,
            );
            if (sent == 0) break; // socket closed
            if (linux.errno(sent) != .SUCCESS) return error.SendFileFailed;
            remaining -= sent;
        }

        try stdout.writeAll("[server] file sent\n");
        try stdout.flush();
    }
}
