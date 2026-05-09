//! Traceroute cli that sends ICMP packets to track network hops
//! to a destination address
const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;

const IPv4 = linux.AF.INET;
const ICMP = linux.IPPROTO.ICMP;
const RAW = linux.SOCK.RAW;

const ICMP_ECHO: u8 = 8;
const ICMP_TIME_EXCEEDED: u8 = 11;
const ICMP_ECHO_REPLY: u8 = 0;
const ICMP_DEST_UNREACH: u8 = 3;
const MAX_HOPS: u32 = 32;
const TIMEOUT_SECS: u32 = 2;

var send_packet: SendPacket = undefined;
var raw_recv: RawRecvPacket = undefined; // raw

var start_time: linux.timespec = undefined;
var current_sequence: u16 = 1;

var interrupted: bool = false; // handle SIGINT

const IpHdr = extern struct {
    version_ihl: u8,
    tos: u8,
    tot_len: u16,
    id: u16,
    frag_off: u16,
    ttl: u8,
    protocol: u8,
    check: u16,
    saddr: u32,
    daddr: u32,
};

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

// Only need ICMP header for sending (DGRAM socket, kernel adds IP header)
const SendPacket = struct {
    icmp: IcmpHdr,
};

// If using RAW sock
const RawRecvPacket = extern struct {
    ip: IpHdr,
    icmp: IcmpHdr,
};

const RecvResult = enum { time_exceeded, echo_reply, dest_unreach, other };

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

fn sendProbe(sock: usize, dest_addr: *const linux.sockaddr, dest_addr_len: linux.socklen_t) !void {
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
        @sizeOf(SendPacket),
        0,
        dest_addr,
        dest_addr_len,
    );

    if (linux.errno(sent) != .SUCCESS)
        return error.SendFailed;

    const rc = linux.clock_gettime(.MONOTONIC, &start_time);
    if (linux.errno(rc) != .SUCCESS)
        return error.GetTimeFailed;

    current_sequence += 1;
}

fn formatIp(addr: u32) [16:0]u8 {
    var buf: [16:0]u8 = std.mem.zeroes([16:0]u8);
    const bytes: [4]u8 = @bitCast(addr);
    _ = std.fmt.bufPrintZ(&buf, "{d}.{d}.{d}.{d}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
    }) catch unreachable;
    return buf;
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    if (args.len < 2) {
        std.debug.print("Usage: traceroute <address>\n", .{});
        return error.EmptyArgs;
    }

    const dest_addr_str = args[1];

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
            },
        }
    } else |err| switch (err) {
        error.Closed => {}, // lookup closes the queue when done
        else => return err,
    }

    const sockaddr = dest_sockaddr orelse return error.NoAddressFound;

    // create socket
    const sock = linux.socket(IPv4, RAW, ICMP);
    if (linux.errno(sock) != .SUCCESS) {
        std.debug.print("socket failed: {}\n", .{linux.errno(sock)});
        return error.SocketFailed;
    }

    defer _ = linux.close(@intCast(sock));

    // set receive timeout so we don't block forever on unresponsive hops
    const tv = linux.timeval{
        .sec = TIMEOUT_SECS,
        .usec = 0,
    };
    const rc_tv = linux.setsockopt(
        @intCast(sock),
        linux.SOL.SOCKET,
        linux.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
        @sizeOf(linux.timeval),
    );
    if (linux.errno(rc_tv) != .SUCCESS) return error.SetSockOptFailed;

    std.debug.print("traceroute to {s} ({s}), {d} hops max\n", .{
        dest_addr_str, canonical_name, MAX_HOPS,
    });

    var ttl: u32 = 1;
    while (ttl <= 32 and !interrupted) {
        // set TTL for hop
        const rc = linux.setsockopt(
            @intCast(sock),
            linux.IPPROTO.IP,
            linux.IP.TTL,
            std.mem.asBytes(&ttl),
            @sizeOf(u32),
        );
        if (linux.errno(rc) != .SUCCESS) return error.SetSockOptFailed;

        // send probe
        try sendProbe(sock, &sockaddr, dest_sockaddr_len);

        // receive response just an IcmpHdr, DGRAM strips the IP header
        var recv_sockaddr: linux.sockaddr = undefined;
        var recv_sockaddr_len: linux.socklen_t = @sizeOf(linux.sockaddr);

        // raw
        const received = linux.recvfrom(
            @intCast(sock),
            std.mem.asBytes(&raw_recv),
            @sizeOf(RawRecvPacket),
            0,
            @ptrCast(&recv_sockaddr),
            &recv_sockaddr_len,
        );

        // recvfrom returns -1 (EINTR) when interrupted by a signal
        if (linux.errno(received) == .INTR) break;

        // timeout or error print * and continue to next hop
        if (linux.errno(received) == .AGAIN) {
            std.debug.print("{d:>2}  *\n", .{ttl});
            ttl += 1;
            continue;
        }

        if (linux.errno(received) != .SUCCESS) return error.RecvFailed;

        // Compute RTT
        var end_time: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &end_time);
        const sec_diff = end_time.sec - start_time.sec;
        const nsec_diff = end_time.nsec - start_time.nsec;
        const time_ms: f64 = @as(f64, @floatFromInt(sec_diff)) * 1000.0 +
            @as(f64, @floatFromInt(nsec_diff)) / 1_000_000.0;

        // Extract source IP from the reply sockaddr
        const src_in: *const linux.sockaddr.in = @ptrCast(@alignCast(&recv_sockaddr));
        const ip_str = formatIp(src_in.addr);

        const result: RecvResult = switch (raw_recv.icmp.type) {
            ICMP_TIME_EXCEEDED => .time_exceeded,
            ICMP_ECHO_REPLY => .echo_reply,
            ICMP_DEST_UNREACH => .dest_unreach,
            else => .other,
        };

        switch (result) {
            .time_exceeded => {
                std.debug.print("{d:>2}  {s}  {d:.2} ms\n", .{ ttl, ip_str, time_ms });
            },
            .echo_reply => {
                std.debug.print("{d:>2}  {s}  {d:.2} ms  (destination reached)\n", .{ ttl, ip_str, time_ms });
                break;
            },
            .dest_unreach => {
                std.debug.print("{d:>2}  {s}  {d:.2} ms  (destination unreachable)\n", .{ ttl, ip_str, time_ms });
                break;
            },
            .other => {
                std.debug.print("{d:>2}  {s}  {d:.2} ms  (icmp type={})\n", .{ ttl, ip_str, time_ms, raw_recv.icmp.type });
            },
        }

        ttl += 1;
    }
}
