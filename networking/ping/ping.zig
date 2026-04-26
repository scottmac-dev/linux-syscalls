//! Ping cli that sends ICMP packets to a specified address to test connectivity
//! Note this just uses a 8 byte header, no payload like ping
const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;

const PORT: u16 = 5001;
const IPv4 = linux.AF.INET;
const DATAGRAM = linux.SOCK.DGRAM; // datagrams, connecionless unreliable messages
const ICMP = linux.IPPROTO.ICMP;
const ICMP_ECHO: u8 = 8;

var ttl: u32 = 64;
var min_time_ms: f64 = std.math.inf(f64);
var max_time_ms: f64 = -std.math.inf(f64);
var sum_time_ms: f64 = 0;

var send_count: usize = 0;
var recv_count: usize = 0;
var current_sequence: u16 = 1;

var send_packet: PingPacket = undefined;
var recv_packet: PingPacket = undefined;
var start_time: linux.timespec = undefined;

var interrupted: bool = false; // handle SIGINT

const IcmpHdr = extern struct {
    type: u8,
    code: u8,
    checksum: u16,
    un: extern union {
        echo: extern struct {
            id: u16,
            sequence: u16,
        },
        gateway: u32,
        frag: extern struct {
            __unused: u16,
            mtu: u16,
        },
    },
};

const PingPacket = struct {
    icmp: IcmpHdr,
};

fn checksum(data: []const u16) u16 {
    var sum: u32 = 0;
    for (data) |word| {
        sum += word;
    }
    return ~@as(u16, @truncate(sum)) +% @as(u16, @truncate(sum >> 16));
}

fn sigintHandler(sig: linux.SIG) callconv(.c) void {
    _ = sig;
    interrupted = true;
}

fn printStats(addr_str: []const u8) void {
    std.debug.print("\n--- {s} ping statistics ---\n", .{addr_str});
    const loss = 100 - ((recv_count / send_count) * 100);
    std.debug.print("{d} packets transmitted, {d} received, {d}% packet loss\n", .{ send_count, recv_count, loss });
    const avg = if (recv_count > 0) sum_time_ms / @as(f64, @floatFromInt(recv_count)) else 0.0;
    std.debug.print("rtt min/avg/max/mdev = {d:.3}/{d:.3}/{d:.3}/{d:.3} ms\n", .{
        min_time_ms,
        avg,
        max_time_ms,
        0.0,
    });
}

fn ping(sock: usize, dest_addr: *const linux.sockaddr, dest_addr_len: linux.socklen_t) !void {
    send_packet.icmp.type = ICMP_ECHO;
    send_packet.icmp.code = 0;
    send_packet.icmp.checksum = 0;
    send_packet.icmp.un.echo.id = 0;
    send_packet.icmp.un.echo.sequence = std.mem.nativeToBig(u16, current_sequence);

    const icmp_bytes = std.mem.asBytes(&send_packet.icmp);
    const icmp_words = std.mem.bytesAsSlice(u16, icmp_bytes);
    send_packet.icmp.checksum = checksum(icmp_words);

    const send_bytes = std.mem.asBytes(&send_packet);
    const sent = linux.sendto(
        @intCast(sock),
        send_bytes,
        @sizeOf(PingPacket),
        0,
        dest_addr,
        dest_addr_len,
    );
    send_count += 1;

    if (linux.errno(sent) != .SUCCESS)
        return error.PingSendFailed;

    const rc_time = linux.clock_gettime(.MONOTONIC, &start_time);
    if (linux.errno(rc_time) != .SUCCESS)
        return error.GetTimeFailed;

    current_sequence += 1;
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    if (args.len < 2) {
        std.debug.print("Usage: ping <address>", .{});
        return error.EmptyArgs;
    }

    // get address arg
    const dest_addr_str = args[1];

    // use SIGINT handler before doing anything else
    const sa = linux.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.INT, &sa, null);

    // resolve hostname
    const host_name = try Io.net.HostName.init(dest_addr_str);
    var name_buf: [255]u8 = undefined;

    var results_buf: [16]std.Io.net.HostName.LookupResult = undefined;
    var resolved = std.Io.Queue(std.Io.net.HostName.LookupResult).init(&results_buf);

    const options = std.Io.net.HostName.LookupOptions{
        .port = 0, // ICMP doesn't use a port, 0 is fine
        .canonical_name_buffer = &name_buf,
    };

    try host_name.lookup(io, &resolved, options);

    // Drain the queue - results are a tagged union of .address or .canonical_name
    var dest_sockaddr: ?linux.sockaddr = null;
    var dest_sockaddr_len: linux.socklen_t = 0;
    var canonical_name: []const u8 = dest_addr_str; // fallback to input

    while (resolved.getOne(io)) |result| {
        switch (result) {
            .address => |addr| {
                switch (addr) {
                    .ip4 => |ip4| {
                        if (dest_sockaddr == null) {
                            const sin = linux.sockaddr.in{
                                .family = linux.AF.INET,
                                .port = std.mem.nativeToBig(u16, ip4.port),
                                .addr = @bitCast(ip4.bytes),
                                .zero = [_]u8{0} ** 8,
                            };
                            dest_sockaddr = @bitCast(sin);
                            dest_sockaddr_len = @sizeOf(linux.sockaddr.in);
                        }
                    },
                    .ip6 => {},
                }
            },
            .canonical_name => |name| {
                canonical_name = name.bytes;
                std.debug.print("PING {s} ({s})\n", .{ dest_addr_str, name.bytes });
            },
        }
    } else |err| switch (err) {
        error.Closed => {}, // lookup closes the queue when done
        else => return err,
    }

    const sockaddr = dest_sockaddr orelse return error.NoAddressFound;

    // create socket
    const sock = linux.socket(IPv4, DATAGRAM, ICMP);
    // handle failure
    if (linux.errno(sock) != .SUCCESS) {
        std.debug.print("socket failed: {}\n", .{linux.errno(sock)});
        return error.SocketFailed;
    }

    defer _ = linux.close(@intCast(sock));

    // configure socket and set TTL
    const rc_opt = linux.setsockopt(
        @intCast(sock),
        linux.IPPROTO.IP,
        linux.IP.TTL,
        std.mem.asBytes(&ttl),
        @sizeOf(u32),
    );
    if (linux.errno(rc_opt) != .SUCCESS) return error.SetSockOptFailed;

    // ping
    try ping(sock, &sockaddr, dest_sockaddr_len);

    // receive loop
    while (!interrupted) {
        var recv_sockaddr: linux.sockaddr = undefined;
        var recv_sockaddr_len: linux.socklen_t = @sizeOf(linux.sockaddr);
        const recv_bytes = std.mem.asBytes(&recv_packet);

        const received = linux.recvfrom(
            @intCast(sock),
            recv_bytes,
            @sizeOf(PingPacket),
            0,
            @ptrCast(&recv_sockaddr),
            &recv_sockaddr_len,
        );

        // recvfrom returns -1 (EINTR) when interrupted by a signal
        if (linux.errno(received) == .INTR) break;

        // recvfrom returns 0 when client closes connection
        if (received == 0) {
            std.debug.print("recvfrom failed\n", .{});
            break;
        }
        if (linux.errno(received) != .SUCCESS) return error.RecvFailed;

        var end_time: linux.timespec = undefined;
        const rc_time = linux.clock_gettime(.MONOTONIC, &end_time);
        if (linux.errno(rc_time) != .SUCCESS) return error.GetTimeFailed;

        const sec_diff = end_time.sec - start_time.sec;
        const nsec_diff = end_time.nsec - start_time.nsec;
        const time_ms: f64 = @as(f64, @floatFromInt(sec_diff)) * 1000.0 +
            @as(f64, @floatFromInt(nsec_diff)) / 1_000_000.0;

        const seq = std.mem.bigToNative(u16, recv_packet.icmp.un.echo.sequence);
        std.debug.print("{d} bytes from {s}: icmp_seq={d} ttl={d} time={d:.1} ms\n", .{
            @sizeOf(PingPacket),
            canonical_name,
            seq,
            ttl,
            time_ms,
        });

        recv_count += 1;
        if (time_ms > max_time_ms) max_time_ms = time_ms;
        if (time_ms < min_time_ms) min_time_ms = time_ms;
        sum_time_ms += time_ms;

        // Wait interval then send next
        try Io.sleep(io, .fromSeconds(1), .real);

        if (!interrupted) {
            try ping(sock, &sockaddr, dest_sockaddr_len);
        }
    }
    printStats(dest_addr_str);
}
