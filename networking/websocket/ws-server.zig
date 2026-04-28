//! Websocket server demonstrating minimal websocket connection over HTTP 1.1
const std = @import("std");
const linux = std.os.linux;
const client = @import("ws-client.zig");
const ws = @import("ws.zig");
const Io = std.Io;

const SERVER_PORT: u16 = 5001;
const IPv4 = linux.AF.INET;
const STREAM = linux.SOCK.STREAM;
const LOCALHOST: u32 = 0x7F000001;

// main server entrypoint
pub fn main(init: std.process.Init) !void {
    var io = init.io;
    var state = client.State{};

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

    std.debug.print("[server] listening on 127.0.0.1:{d}\n", .{SERVER_PORT});

    // super loop
    while (true) {
        var client_addr: linux.sockaddr.in = undefined;
        var client_addrlen: linux.socklen_t = @sizeOf(linux.sockaddr.in);

        const clientfd = linux.accept(
            @intCast(sockfd),
            @ptrCast(&client_addr),
            &client_addrlen,
        );
        if (linux.errno(clientfd) != .SUCCESS) return error.AcceptFailed;

        const idx = state.add(io, @intCast(clientfd)) catch {
            std.debug.print("[server] full, rejecting fd {}\n", .{clientfd});
            _ = linux.close(@intCast(clientfd));
            continue;
        };

        const thread = std.Thread.spawn(.{}, client.clientThread, .{client.ClientArgs{
            .io = &io,
            .fd = @intCast(clientfd),
            .idx = idx,
            .state = &state,
        }}) catch {
            state.remove(io, idx);
            _ = linux.close(@intCast(clientfd));
            continue;
        };
        thread.detach();
    }
}
