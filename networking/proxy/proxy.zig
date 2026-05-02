//! 0 copy TCP fan out proxy server using splice and tee syscalls
//! Uses single TCP listener on :5001 and forawrds every byte to two downstream
//! subsciber ports 5002, 5003 simultaneously.
//! Kernel buffers move bytes directly between sockets and pipe buffers
const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;

const LISTEN_PORT: u16 = 5001;
const SUB_0_PORT: u16 = 5002;
const SUB_1_PORT: u16 = 5003;

const IPv4 = linux.AF.INET;
const STREAM = linux.SOCK.STREAM;
const LOCALHOST: u32 = 0x7F000001;
const CHUNK = (1 << 16); // 64KB — matches default kernel pipe buffer size

const READ: usize = 0;
const WRITE: usize = 1;

// helper to connect to a sub port
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

pub fn main() !void {
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

    // bind listener socket to local host port
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

    std.debug.print("[proxy] listening on 127.0.0.1:{d}\n", .{LISTEN_PORT});

    // accept connections
    const source = linux.accept(
        @intCast(l_sockfd),
        null,
        null,
    );
    if (linux.errno(source) != .SUCCESS) return error.AcceptFailed;
    defer _ = linux.close(@intCast(source));

    // connect to both downstream sub servers before entering the forwarding loop
    const sub0 = try connect_to(SUB_0_PORT);
    const sub1 = try connect_to(SUB_1_PORT);
    defer _ = linux.close(@intCast(sub0));
    defer _ = linux.close(@intCast(sub1));

    var main_p: [2]i32 = undefined; // main pipe: source → sub0
    var sub_p: [2]i32 = undefined; // sub pipe:  tee'd copy → sub1
    _ = linux.pipe(&main_p);
    _ = linux.pipe(&sub_p);

    // use splice and tee to transfer data with no user space alloc
    // splice and tee only work with pipe, using kernel buffers
    while (true) {
        // move up to CHUNK bytes from the source socket into main_p.
        const rc_splice = linux.syscall6(
            .splice,
            @intCast(source),
            0,
            @intCast(main_p[WRITE]),
            0,
            CHUNK,
            0,
        );
        if (linux.errno(rc_splice) != .SUCCESS) return error.SpliceFailed;
        if (rc_splice == 0) break;

        const n_bytes = rc_splice; // bytes received

        // tee n_bytes from main_p into sub_p
        // tee duplicates the kernel buffer references
        // both pipes now point at the same underlying pages, no data is copied
        const rc_tee = linux.syscall4(
            .tee,
            @intCast(main_p[READ]),
            @intCast(sub_p[WRITE]),
            n_bytes,
            0,
        );
        if (linux.errno(rc_tee) != .SUCCESS) return error.TeeFailed;

        // splice main_p → sub0 (consumes main_p)
        const rc_splice_sub0 = linux.syscall6(
            .splice,
            @intCast(main_p[READ]),
            0,
            @intCast(sub0),
            0,
            n_bytes,
            0,
        );
        if (linux.errno(rc_splice_sub0) != .SUCCESS) return error.SpliceSub0Failed;

        // splice sub_p → sub1 (consumes the tee'd branch)
        const rc_splice_sub1 = linux.syscall6(
            .splice,
            @intCast(sub_p[READ]),
            0,
            @intCast(sub1),
            0,
            n_bytes,
            0,
        );
        if (linux.errno(rc_splice_sub1) != .SUCCESS) return error.SpliceSub1Failed;
    }

    // report kernel-measured CPU time for this process
    var ru: linux.rusage = undefined;
    const rc_usage = linux.getrusage(linux.rusage.SELF, &ru);
    if (linux.errno(rc_usage) != .SUCCESS) return error.RusageFailed;
    const u: f64 = @as(f64, @floatFromInt(ru.utime.sec)) + @as(f64, @floatFromInt(ru.utime.usec)) / 1_000_000.0;
    const s: f64 = @as(f64, @floatFromInt(ru.stime.sec)) + @as(f64, @floatFromInt(ru.stime.usec)) / 1_000_000.0;
    const t = u + s;
    std.debug.print("[proxy] cpu user={d:.3}s sys={d:.3}s total={d:.3}s\n", .{ u, s, t });
}
