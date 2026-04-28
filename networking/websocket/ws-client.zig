//! Logic for handling client connections to ws-server
const std = @import("std");
const ws = @import("ws.zig");
const linux = std.os.linux;
const Io = std.Io;

const MAX_CLIENTS = 8;

pub const ClientArgs = struct {
    io: *Io,
    fd: i32,
    idx: usize,
    state: *State,
};

pub const Client = struct {
    fd: i32,
    name: [32]u8 = undefined,
    name_len: usize = 0,
    mu: Io.Mutex = .{ .state = .{ .raw = .unlocked } }, // guards sendFrame calls to this fd

    // display chat name if set
    pub fn displayName(self: *const Client) []const u8 {
        if (self.name_len == 0) return "anon";
        return self.name[0..self.name_len];
    }

    /// thread-safe send to this client only
    pub fn send(self: *Client, io: Io, opcode: u8, payload: []const u8) void {
        self.mu.lock(io) catch {};
        defer self.mu.unlock(io);
        ws.sendFrame(self.fd, opcode, payload) catch {};
    }
};

pub const State = struct {
    slots: [MAX_CLIENTS]?Client = [_]?Client{null} ** MAX_CLIENTS, // connections
    mu: Io.Mutex = .{ .state = .{ .raw = .unlocked } }, // guards clients array
    stdout_mu: Io.Mutex = .{ .state = .{ .raw = .unlocked } }, // guards stdout writer

    // broadcast text to every client except sender
    pub fn broadcast(self: *State, io: Io, sender_idx: usize, msg: []const u8) void {
        self.mu.lock(io) catch {};
        defer self.mu.unlock(io);
        for (&self.slots, 0..) |*slot, i| {
            if (i == sender_idx) continue;
            if (slot.*) |*c| c.send(io, ws.OP_TEXT, msg);
        }
    }

    // thread-safe add client, returns slot index or error if full
    pub fn add(self: *State, io: Io, fd: i32) !usize {
        try self.mu.lock(io);
        defer self.mu.unlock(io);
        for (&self.slots, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = .{ .fd = fd };
                return i;
            }
        }
        return error.ServerFull;
    }

    // thread-safe remove client
    pub fn remove(self: *State, io: Io, idx: usize) void {
        self.mu.lock(io) catch {};
        defer self.mu.unlock(io);
        self.slots[idx] = null;
    }

    pub fn printLocked(self: *State, io: Io, comptime fmt: []const u8, args: anytype) void {
        self.stdout_mu.lock(io) catch {};
        defer self.stdout_mu.unlock(io);
        std.debug.print(fmt, args); // unbuffered, goes straight to stderr/stdout
    }
};

// client thread handler handles connection lifetime per client on ws
pub fn clientThread(args: ClientArgs) void {
    defer _ = linux.close(args.fd); // fd lifetime owned by thread
    defer args.state.remove(args.io.*, args.idx);

    var buf: [4096]u8 = undefined;
    var msg_buf: [4096 + 64]u8 = undefined; // name: payload

    const state = args.state;
    const idx = args.idx;
    const io = args.io.*;

    // handshake
    ws.handshake(args.fd, &buf) catch |err| {
        state.printLocked(io, "[server] handshake failed: {}\n", .{err});
        return;
    };
    state.printLocked(io, "[server] client {} connected (slot {})\n", .{ args.fd, idx });

    // first message is the username
    const name_frame = ws.recvFrame(args.fd, &buf) catch {
        state.printLocked(io, "[server] client {} dropped before naming\n", .{args.fd});
        return;
    };

    {
        state.mu.lock(io) catch {};
        defer state.mu.unlock(io);
        if (state.slots[idx]) |*c| {
            const name_len = @min(name_frame.payload.len, 32);
            c.name_len = name_len;
            @memcpy(c.name[0..name_len], name_frame.payload[0..name_len]);
        }
    }

    // announce join chat
    const join_msg = std.fmt.bufPrint(&msg_buf, ">> {s} joined", .{
        state.slots[idx].?.displayName(),
    }) catch return;

    state.printLocked(io, "{s}\n", .{join_msg});
    state.broadcast(io, idx, join_msg);

    // main receive loop
    while (true) {
        const frame = ws.recvFrame(args.fd, &buf) catch |err| switch (err) {
            error.ConnectionClosed => break,
            else => {
                state.printLocked(io, "[server] recv error on {}: {}\n", .{ args.fd, err });
                break;
            },
        };

        switch (frame.opcode) {
            ws.OP_TEXT, ws.OP_BINARY => {
                // Format: ">> name: message"
                const name = state.slots[idx].?.displayName();
                const chat_msg = std.fmt.bufPrint(&msg_buf, ">> {s}: {s}", .{
                    name, frame.payload,
                }) catch continue;

                state.printLocked(io, "{s}\n", .{chat_msg});
                state.broadcast(io, idx, chat_msg);
            },
            ws.OP_PING => {
                state.slots[idx].?.send(io, ws.OP_PONG, frame.payload);
            },
            ws.OP_CLOSE => {
                ws.sendFrame(args.fd, ws.OP_CLOSE, frame.payload) catch {};
                break;
            },
            else => {},
        }
    }

    // Announce leave
    const name = if (state.slots[idx]) |c| c.displayName() else "anon";
    const leave_msg = std.fmt.bufPrint(&msg_buf, ">> {s} left", .{name}) catch return;
    state.printLocked(io, "{s}\n", .{leave_msg});
    state.broadcast(io, idx, leave_msg);
}

// Old single threaded ws handler for reference
// fn handleClient(fd: i32, stdout: *Io.Writer) !void {
//     var buf: [4096]u8 = undefined;
//
//     try ws.handshake(fd, &buf);
//     try stdout.writeAll("[server] handshake complete\n");
//     try stdout.flush();
//
//     // WS echo loop, very minimal impl
//     while (true) {
//         const frame: ws.Frame = ws.recvFrame(fd, &buf) catch |err| switch (err) {
//             error.ConnectionClosed => {
//                 try stdout.writeAll("[server] client disconnected\n");
//                 try stdout.flush();
//                 return;
//             },
//             else => return err,
//         };
//
//         switch (frame.opcode) {
//             ws.OP_TEXT, ws.OP_BINARY => {
//                 try stdout.print("[server] echo {d} bytes\n", .{frame.payload.len});
//                 try stdout.flush();
//                 try ws.sendFrame(fd, frame.opcode, frame.payload);
//             },
//             ws.OP_PING => {
//                 try ws.sendFrame(fd, ws.OP_PONG, frame.payload);
//             },
//             ws.OP_CLOSE => {
//                 // Echo the close frame back then hang up
//                 try ws.sendFrame(fd, ws.OP_CLOSE, frame.payload);
//                 try stdout.writeAll("[server] close handshake done\n");
//                 try stdout.flush();
//                 return;
//             },
//             else => {
//                 // unknown opcode ignore for now
//                 std.log.err("unknown opcode {any}\n", .{frame.opcode});
//             },
//         }
//     }
// }
