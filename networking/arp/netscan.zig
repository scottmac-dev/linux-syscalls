//! ARP scanner discovers live hosts on the local LAN
//! Sends ARP requests to every IP in the subnet and collects replies
const std = @import("std");
const linux = std.os.linux;

// Ethernet + ARP constants
const ETH_P_ARP: u16 = linux.ETH.P.ARP;
const ARP_REQUEST: u16 = 1;
const ARP_REPLY: u16 = 2;
const HTYPE_ETHERNET: u16 = 1;
const ETH_P_IP: u16 = linux.ETH.P.IP;
const BROADCAST_MAC = [6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };

// ioctls we need
const SIOCGIFINDEX: u32 = linux.SIOCGIFINDEX;
const SIOCGIFHWADDR: u32 = linux.SIOCGIFHWADDR;
const SIOCGIFADDR: u32 = linux.SIOCGIFADDR;

const EthernetHdr = extern struct {
    dst_mac: [6]u8,
    src_mac: [6]u8,
    ethertype: u16, // big-endian
};

const ArpHdr = extern struct {
    htype: u16, // hardware type (1 = ethernet)
    ptype: u16, // protocol type (0x0800 = IPv4)
    hlen: u8, // hardware addr length (6)
    plen: u8, // protocol addr length (4)
    op: u16, // 1 = request, 2 = reply
    sha: [6]u8, // sender hardware (MAC)
    sip: [4]u8, // sender IP
    tha: [6]u8, // target hardware (MAC) - zeros for request
    tip: [4]u8, // target IP
};
const ArpPacket = extern struct {
    eth: EthernetHdr,
    arp: ArpHdr,
};

fn formatIp(ip: [4]u8) void {
    std.debug.print("{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
}

fn formatMac(mac: [6]u8) void {
    std.debug.print("{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    });
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const iface: []const u8 = if (args.len >= 2) args[1] else "eth0";

    // open AF_PACKET raw socket
    const sock = linux.socket(
        linux.AF.PACKET,
        linux.SOCK.RAW,
        std.mem.nativeToBig(u16, ETH_P_ARP),
    );
    if (linux.errno(sock) != .SUCCESS) {
        std.debug.print("socket failed - are you running as root?\n", .{});
        return error.SocketFailed;
    }
    defer _ = linux.close(@intCast(sock));

    // ioctl: get interface index
    var ifreq_idx = std.mem.zeroes(linux.ifreq);
    @memcpy(ifreq_idx.ifrn.name[0..iface.len], iface);
    const rc_idx = linux.ioctl(@intCast(sock), SIOCGIFINDEX, @intFromPtr(&ifreq_idx));
    if (linux.errno(rc_idx) != .SUCCESS) {
        std.debug.print("ioctl SIOCGIFINDEX failed - is '{s}' the right interface? (try: ip link)\n", .{iface});
        return error.IoctlIndexFailed;
    }
    const ifindex = ifreq_idx.ifru.ivalue;

    // ioctl: get our MAC address
    var ifreq_hw = std.mem.zeroes(linux.ifreq);
    @memcpy(ifreq_hw.ifrn.name[0..iface.len], iface);
    const rc_hw = linux.ioctl(@intCast(sock), SIOCGIFHWADDR, @intFromPtr(&ifreq_hw));
    if (linux.errno(rc_hw) != .SUCCESS) return error.IoctlHwAddrFailed;
    var our_mac: [6]u8 = undefined;
    @memcpy(&our_mac, ifreq_hw.ifru.hwaddr.data[0..6]);

    // ioctl: get our IP address
    var ifreq_addr = std.mem.zeroes(linux.ifreq);
    @memcpy(ifreq_addr.ifrn.name[0..iface.len], iface);
    const rc_addr = linux.ioctl(@intCast(sock), SIOCGIFADDR, @intFromPtr(&ifreq_addr));
    if (linux.errno(rc_addr) != .SUCCESS) return error.IoctlAddrFailed;
    const sin: *const linux.sockaddr.in = @ptrCast(@alignCast(&ifreq_addr.ifru.addr));
    const our_ip: [4]u8 = @bitCast(sin.addr);

    std.debug.print("Scanning on {s} - our IP: ", .{iface});
    formatIp(our_ip);
    std.debug.print("  MAC: ", .{});
    formatMac(our_mac);
    std.debug.print("\n", .{});

    // sockaddr_ll for sendto
    var dest_ll = std.mem.zeroes(linux.sockaddr.ll);
    dest_ll.family = linux.AF.PACKET;
    dest_ll.protocol = std.mem.nativeToBig(u16, ETH_P_ARP);
    dest_ll.ifindex = ifindex;
    dest_ll.halen = 6;
    dest_ll.addr = BROADCAST_MAC ++ [_]u8{ 0, 0 };

    // send ARP request to every host in /24
    const subnet = [3]u8{ our_ip[0], our_ip[1], our_ip[2] };
    var target_host: u8 = 1;
    while (target_host < 255) : (target_host += 1) {
        const target_ip = [4]u8{ subnet[0], subnet[1], subnet[2], target_host };

        const pkt = ArpPacket{
            .eth = .{
                .dst_mac = BROADCAST_MAC,
                .src_mac = our_mac,
                .ethertype = std.mem.nativeToBig(u16, ETH_P_ARP),
            },
            .arp = .{
                .htype = std.mem.nativeToBig(u16, HTYPE_ETHERNET),
                .ptype = std.mem.nativeToBig(u16, ETH_P_IP),
                .hlen = 6,
                .plen = 4,
                .op = std.mem.nativeToBig(u16, ARP_REQUEST),
                .sha = our_mac,
                .sip = our_ip,
                .tha = std.mem.zeroes([6]u8),
                .tip = target_ip,
            },
        };

        _ = linux.sendto(
            @intCast(sock),
            std.mem.asBytes(&pkt),
            @sizeOf(ArpPacket),
            0,
            @ptrCast(&dest_ll),
            @sizeOf(linux.sockaddr.ll),
        );
    }

    std.debug.print("Sent 254 ARP requests, collecting replies for 3s...\n\n", .{});

    // set 3s receive timeout then drain
    const tv = linux.timeval{ .sec = 3, .usec = 0 };
    _ = linux.setsockopt(
        @intCast(sock),
        linux.SOL.SOCKET,
        linux.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
        @sizeOf(linux.timeval),
    );

    var recv_pkt: ArpPacket = undefined;
    var found: usize = 0;

    while (true) {
        const n = linux.recvfrom(
            @intCast(sock),
            std.mem.asBytes(&recv_pkt),
            @sizeOf(ArpPacket),
            0,
            null,
            null,
        );

        if (linux.errno(n) != .SUCCESS) break;

        // only care about ARP replies
        const op = std.mem.bigToNative(u16, recv_pkt.arp.op);
        if (op != ARP_REPLY) continue;

        // ignore replies from ourselves
        if (std.mem.eql(u8, &recv_pkt.arp.sip, &our_ip)) continue;

        formatIp(recv_pkt.arp.sip);
        std.debug.print("\t", .{});
        formatMac(recv_pkt.arp.sha);
        std.debug.print("\n", .{});
        found += 1;
    }

    std.debug.print("\nFound {d} host(s)\n", .{found});
}
