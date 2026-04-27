//! Websocket server demonstrating minimal websocket connection over HTTP 1.1
const std = @import("std");
const linux = std.os.linux;
const ws = @import("ws.zig");
const Io = std.Io;

const SERVER_PORT: u16 = 5001;
const IPv4 = linux.AF.INET;
const STREAM = linux.SOCK.STREAM;
const LOCALHOST: u32 = 0x7F000001;

// WS Opcodes supported in minimal impl
const OP_TEXT: u8 = 0x1;
const OP_BINARY: u8 = 0x2;
const OP_CLOSE: u8 = 0x8;
const OP_PING: u8 = 0x9;
const OP_PONG: u8 = 0xA;

fn handleClient(fd: i32, stdout: *Io.Writer) !void {
    var buf: [4096]u8 = undefined;

    try ws.handshake(fd, &buf);
    try stdout.writeAll("[server] handshake complete\n");
    try stdout.flush();

    // WS echo loop, very minimal impl
    while (true) {
        const frame: ws.Frame = ws.recvFrame(fd, &buf) catch |err| switch (err) {
            error.ConnectionClosed => {
                try stdout.writeAll("[server] client disconnected\n");
                try stdout.flush();
                return;
            },
            else => return err,
        };

        switch (frame.opcode) {
            OP_TEXT, OP_BINARY => {
                try stdout.print("[server] echo {d} bytes\n", .{frame.payload.len});
                try stdout.flush();
                try ws.sendFrame(fd, frame.opcode, frame.payload);
            },
            OP_PING => {
                try ws.sendFrame(fd, OP_PONG, frame.payload);
            },
            OP_CLOSE => {
                // Echo the close frame back then hang up
                try ws.sendFrame(fd, OP_CLOSE, frame.payload);
                try stdout.writeAll("[server] close handshake done\n");
                try stdout.flush();
                return;
            },
            else => {
                // unknown opcode ignore for now
                std.log.err("unknown opcode {any}\n", .{frame.opcode});
            },
        }
    }
}

// main server entrypoint
pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

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
        defer _ = linux.close(@intCast(clientfd));

        try stdout.writeAll("[server] client connected\n");
        try stdout.flush();

        // handoff to websocket handler
        handleClient(@intCast(clientfd), stdout) catch |err| {
            try stdout.print("[server] client error: {}\n", .{err});
            try stdout.flush();
        };
    }
}
