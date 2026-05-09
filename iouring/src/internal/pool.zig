//! Connection pool — tracks per-connection I/O state.
//!
//! Each accepted fd gets a slot. The slot lives until the connection closes.
//! Indexed by a compact connection ID (u16) so the ID fits in the upper bits
//! of a u64 user_data tag without losing the op type in the lower bits.

const std = @import("std");
const linux = std.os.linux;

/// How SQE user_data is tagged so CQEs can be routed back.
/// Layout: [ conn_id: 16 | op: 8 | pad: 40 ]
pub const Tag = packed struct(u64) {
    pad: u40 = 0,
    op: Op = .accept,
    conn_id: u16 = 0,

    pub fn toU64(self: Tag) u64 {
        return @bitCast(self);
    }

    pub fn fromU64(v: u64) Tag {
        return @bitCast(v);
    }
};

pub const Op = enum(u8) {
    accept = 0,
    read = 1,
    write = 2,
    close = 3,
    timeout = 4,
};

pub const ConnState = enum {
    free,
    reading,
    processing,
    writing,
    closing,
};

pub const WritePhase = enum {
    headers,
    body,
};

pub const Conn = struct {
    pub const error_buf_size = 256;

    fd: i32 = -1,
    state: ConnState = .free,
    close_queued: bool = false,
    keep_alive: bool = false,
    /// Read buffer, allocated lazily and retained with the slot for reuse.
    read_buf: []u8 = &.{},
    read_len: usize = 0,
    timeout_ts: linux.kernel_timespec = std.mem.zeroes(linux.kernel_timespec),
    /// Full write buffer allocation, retained with the slot for reuse.
    write_buf_mem: []u8 = &.{},
    /// Dedicated buffer for small fallback error responses.
    error_buf_mem: [error_buf_size]u8 = undefined,
    /// Current output slice being written: headers first, then optional body.
    write_buf: []const u8 = &.{},
    /// Body slice held separately so small in-memory bodies can later be
    /// coalesced, and future file-backed bodies can plug into the same flow.
    write_body: []const u8 = &.{},
    write_phase: WritePhase = .headers,
    write_offset: usize = 0,
};

pub fn Pool(comptime max_conns: usize) type {
    return struct {
        const Self = @This();

        slots: [max_conns]Conn = [_]Conn{.{}} ** max_conns,

        // Simple free-list via a bitmask for up to 64K connections.
        // For larger pools a bitset would be used; 1024 covers embedded targets well.
        len: usize = max_conns,

        pub fn acquire(self: *Self, limit: usize) ?struct { id: u16, conn: *Conn } {
            for (self.slots[0..@min(limit, self.slots.len)], 0..) |*slot, i| {
                if (slot.state == .free) {
                    slot.state = .reading;
                    slot.close_queued = false;
                    return .{ .id = @intCast(i), .conn = slot };
                }
            }
            return null;
        }

        pub fn get(self: *Self, id: u16) *Conn {
            return &self.slots[id];
        }

        pub fn release(self: *Self, id: u16) void {
            var slot = &self.slots[id];
            slot.fd = -1;
            slot.state = .free;
            slot.close_queued = false;
            slot.keep_alive = false;
            slot.read_len = 0;
            slot.timeout_ts = std.mem.zeroes(linux.kernel_timespec);
            slot.write_buf = &.{};
            slot.write_body = &.{};
            slot.write_phase = .headers;
            slot.write_offset = 0;
        }

        pub fn activeCount(self: *const Self) usize {
            var n: usize = 0;
            for (&self.slots) |*s| {
                if (s.state != .free) n += 1;
            }
            return n;
        }
    };
}
