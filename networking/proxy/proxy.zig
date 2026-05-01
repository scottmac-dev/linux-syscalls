//!
const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;

const LISTEN_PORT: u16 = 5001;
const SUB_0_PORT: u16 = 5002;
const SUB_1_PORT: u16 = 5003;

const IPv4 = linux.AF.INET;
const STREAM = linux.SOCK.STREAM;
const LOCALHOST: u32 = 0x7F000001;
const CHUNK = (1 << 16);

fn connect_to(port: u16) !usize {
    const fd = linux.socket(IPv4, STREAM, 0);
    if (linux.errno(fd) != .SUCCESS) return error.SocketFailed;

    const sock_addr = linux.sockaddr.in{
        .family = IPv4,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, LOCALHOST),
        .zero = [_]u8{0} ** 8,
    };

    const rc = linux.connect(
        @intCast(fd),
        @ptrCast(&sock_addr),
        @sizeOf(linux.sockaddr.in),
    );
    if (linux.errno(rc) != .SUCCESS) return error.ConnectFailed;
    return fd;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    // set up socket
    const l_sockfd = linux.socket(IPv4, STREAM, 0);
    if (linux.errno(l_sockfd) != .SUCCESS) return error.SocketFailed;
    defer _ = linux.close(@intCast(l_sockfd));

    // configure socket
    const enable: i32 = 1;
    const rc_opt = linux.setsockopt(
        @intCast(l_sockfd),
        linux.SOL.SOCKET,
        linux.SO.REUSEADDR, // can reuse immediately, no TIME_WAIT debounce
        std.mem.asBytes(&enable),
        @sizeOf(i32),
    );
    if (linux.errno(rc_opt) != .SUCCESS) return error.SetSockOptFailed;

    // bind socket to local host port
    const l_addr = linux.sockaddr.in{
        .family = IPv4,
        .port = std.mem.nativeToBig(u16, LISTEN_PORT),
        .addr = std.mem.nativeToBig(u32, LOCALHOST),
        .zero = [_]u8{0} ** 8,
    };
    const rc_bind = linux.bind(
        @intCast(l_sockfd),
        @ptrCast(&l_addr),
        @sizeOf(linux.sockaddr.in),
    );
    if (linux.errno(rc_bind) != .SUCCESS) return error.BindFailed;

    // listen for messages
    const rc_listen = linux.listen(@intCast(l_sockfd), 1);
    if (linux.errno(rc_listen) != .SUCCESS) return error.ListenFailed;

    try stdout.writeAll("[server] listening on 127.0.0.1:5001\n");
    try stdout.flush();

    // accept connections
    const source = linux.accept(
        @intCast(l_sockfd),
        null,
        null,
    );
    if (linux.errno(source) != .SUCCESS) return error.AcceptFailed;

    const sub0 = try connect_to(SUB_0_PORT);
    const sub1 = try connect_to(SUB_1_PORT);

    var main_p: [2]i32 = undefined;
    var sub_p: [2]i32 = undefined;

    _ = linux.pipe(&main_p);
    _ = linux.pipe(&sub_p);

    // use splice and tee to transfer data with no user space alloc
    // splice and tee only work with pipe, using kernel buffers
    while (true) {
        // splice, moves data from source into pipe buffer
        const rc_splice = linux.syscall6(
            .splice,
            @intCast(source),
            null,
            @intCast(main_p[1]),
            null,
            CHUNK,
            0,
        );
        if (linux.errno(rc_splice) != .SUCCESS) return error.SpliceFailed;
        if (rc_splice == 0) break;
    }
}
