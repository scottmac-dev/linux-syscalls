//! Server — the primary public API.
//!
//! Sets up a TCP listener, initialises an io_uring Ring, and runs the
//! event loop: multishot accept → read → parse → handler → write.
//!
//! Designed for single-threaded use per ring. For multi-core throughput,
//! launch one Server per core and SO_REUSEPORT across them.

const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;

const Ring = @import("linux/ring.zig").Ring;
const RingConfig = @import("linux/ring.zig").RingConfig;
const pool_mod = @import("internal/pool.zig");
const Request = @import("internal/request.zig").Request;
const Response = @import("internal/response.zig").Response;

/// User-supplied request handler. Must be comptime-known (function pointer or
/// anytype implementing `fn(*Request, *Response) anyerror!void`).
pub const HandlerFn = *const fn (Io, *Request, *Response) anyerror!void;

pub const ServerConfig = struct {
    /// Port to listen on.
    port: u16 = 8080,
    /// Bind address
    address: u32 = 0x00000000, // 0.0.0.0
    /// io_uring submission queue depth (power of two).
    ring_entries: u32 = 256,
    /// Maximum concurrent connections.
    max_connections: u16 = 1024,
    /// Per-connection read buffer size in bytes.
    read_buf_size: usize = 8192,
    /// Per-connection response buffer size in bytes.
    write_buf_size: usize = 65536,
    /// Idle timeout for socket reads/writes in milliseconds.
    idle_timeout_ms: u32 = 30_000,
    /// Enable extra operational logging for request and timeout events.
    verbose: bool = false,
    /// TCP backlog.
    backlog: u31 = 128,
    /// Set SO_REUSEPORT — enable when running multiple server instances.
    reuse_port: bool = false,
};

/// Maximum connections is comptime so the pool is stack-allocated.
/// If you need a runtime limit, change Pool to heap-allocate.
const MAX_CONNS = 1024;
var shutdown_requested = std.atomic.Value(bool).init(false);

const ShutdownSignals = struct {
    old_int: linux.Sigaction,
    old_term: linux.Sigaction,

    fn install() ShutdownSignals {
        shutdown_requested.store(false, .seq_cst);

        const action: linux.Sigaction = .{
            .handler = .{ .sigaction = handleShutdownSignal },
            .mask = std.mem.zeroes(linux.sigset_t),
            .flags = linux.SA.SIGINFO,
        };

        var old_int: linux.Sigaction = undefined;
        var old_term: linux.Sigaction = undefined;
        _ = linux.sigaction(.INT, &action, &old_int);
        _ = linux.sigaction(.TERM, &action, &old_term);

        return .{
            .old_int = old_int,
            .old_term = old_term,
        };
    }

    fn restore(self: ShutdownSignals) void {
        _ = linux.sigaction(.INT, &self.old_int, null);
        _ = linux.sigaction(.TERM, &self.old_term, null);
    }
};

fn handleShutdownSignal(_: linux.SIG, _: *const linux.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}

pub const Server = struct {
    const Self = @This();
    pub const LOCAL_HOST: u32 = 0x7F000001; // 0x7F000001 for 127.0.0.1

    io: Io,
    allocator: std.mem.Allocator,
    config: ServerConfig,
    ring: Ring,
    listener_fd: linux.fd_t,
    pool: pool_mod.Pool(MAX_CONNS),

    pub fn init(io: Io, allocator: std.mem.Allocator, config: ServerConfig) !Self {
        if (config.max_connections == 0 or config.max_connections > MAX_CONNS) {
            return error.InvalidMaxConnections;
        }

        const listener_fd = try bindListener(config);
        errdefer _ = linux.close(listener_fd);

        const ring = try Ring.init(.{
            .entries = config.ring_entries,
        });

        return Self{
            .io = io,
            .allocator = allocator,
            .config = config,
            .ring = ring,
            .listener_fd = listener_fd,
            .pool = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.pool.slots, 0..) |conn, i| {
            if (conn.read_buf.len > 0 or conn.write_buf_mem.len > 0) {
                self.freeConnBuffers(@intCast(i));
            }
        }
        self.ring.deinit();
        if (self.listener_fd >= 0) _ = linux.close(self.listener_fd);
    }

    /// Start accepting connections and dispatching to `handler`.
    /// Blocks forever (or until an unrecoverable error).
    pub fn listen(self: *Self, handler: HandlerFn) !void {
        const shutdown_signals = ShutdownSignals.install();
        defer shutdown_signals.restore();
        defer self.shutdownNow();

        std.log.info("[zuring] listening on {d}.{d}.{d}.{d}:{d}", .{
            (self.config.address >> 24) & 0xFF,
            (self.config.address >> 16) & 0xFF,
            (self.config.address >> 8) & 0xFF,
            self.config.address & 0xFF,
            self.config.port,
        });

        // Kick off the multishot accept. One SQE, infinite CQEs.
        const accept_tag = pool_mod.Tag{
            .op = .accept,
            .conn_id = 0,
        };
        try self.ring.prepAcceptMultishot(self.listener_fd, accept_tag.toU64());
        _ = try self.ring.submit(0);

        // Event loop.
        var cqe: linux.io_uring_cqe = undefined;
        while (true) {
            self.ring.waitCqe(&cqe) catch |err| switch (err) {
                error.Interrupted => {
                    if (shutdown_requested.load(.seq_cst)) break;
                    continue;
                },
                else => return err,
            };
            self.ring.seenCqe();
            self.handleCqe(cqe, handler) catch |err| {
                std.log.err("[zuring] cqe handler error: {}", .{err});
            };
            _ = self.ring.submit(0) catch |err| switch (err) {
                error.Interrupted => {
                    if (shutdown_requested.load(.seq_cst)) break;
                    continue;
                },
                else => return err,
            };
            if (shutdown_requested.load(.seq_cst)) break;
        }
    }

    fn handleCqe(
        self: *Self,
        cqe: linux.io_uring_cqe,
        handler: HandlerFn,
    ) !void {
        const tag = pool_mod.Tag.fromU64(cqe.user_data);

        switch (tag.op) {
            .accept => try self.onAccept(cqe),
            .read => try self.onRead(cqe, tag, handler),
            .write => try self.onWrite(cqe, tag, handler),
            .close => self.onClose(tag),
            .timeout => try self.onTimeout(cqe, tag),
        }
    }

    // ── Accept

    fn onAccept(self: *Self, cqe: linux.io_uring_cqe) !void {
        try self.rearmAcceptIfNeeded(cqe);

        if (cqe.res < 0) {
            std.log.err("[zuring] accept error: {d}", .{cqe.res});
            return;
        }
        const client_fd: linux.fd_t = @intCast(cqe.res);

        const slot = self.pool.acquire(self.config.max_connections) orelse {
            // Pool full — close immediately.
            std.log.warn("[zuring] connection pool full, dropping fd {d}", .{client_fd});
            try self.ring.prepClose(client_fd, 0);
            return;
        };

        slot.conn.fd = client_fd;
        if (slot.conn.read_buf.len == 0) {
            slot.conn.read_buf = try self.allocator.alloc(u8, self.config.read_buf_size);
        }
        if (slot.conn.write_buf_mem.len == 0) {
            slot.conn.write_buf_mem = try self.allocator.alloc(u8, self.config.write_buf_size);
        }
        slot.conn.read_len = 0;
        slot.conn.timeout_ts = timeoutTimespec(self.config.idle_timeout_ms);

        // Every socket op is submitted with a linked timeout, so accepted
        // connections immediately enter the same "read or time out" flow.
        try self.queueRead(slot.id);
    }

    // ── Read

    fn onRead(
        self: *Self,
        cqe: linux.io_uring_cqe,
        tag: pool_mod.Tag,
        handler: HandlerFn,
    ) !void {
        const conn = self.pool.get(tag.conn_id);

        if (cqe.res <= 0) {
            // 0 = EOF, negative = error — either way, close.
            try self.closeConn(tag.conn_id);
            return;
        }

        const n: usize = @intCast(cqe.res);
        conn.read_len += n;
        try self.processBufferedRequest(tag.conn_id, handler);
    }

    // ── Write

    fn onWrite(
        self: *Self,
        cqe: linux.io_uring_cqe,
        tag: pool_mod.Tag,
        handler: HandlerFn,
    ) !void {
        const conn = self.pool.get(tag.conn_id);

        if (cqe.res < 0) {
            try self.closeConn(tag.conn_id);
            return;
        }

        const written: usize = @intCast(cqe.res);
        conn.write_offset += written;

        if (conn.write_offset < conn.write_buf.len) {
            // Partial write — resubmit the remainder.
            const remaining = conn.write_buf[conn.write_offset..];
            try self.queueWrite(tag.conn_id, remaining);
            return;
        }

        if (conn.write_phase == .headers and conn.write_body.len > 0) {
            // Normal responses write headers first, then advance to the body.
            // This keeps the current path simple while making room for future
            // body sources that are not already packed behind the headers.
            conn.write_phase = .body;
            conn.write_buf = conn.write_body;
            conn.write_offset = 0;
            try self.queueWrite(tag.conn_id, conn.write_buf);
            return;
        }

        // Write complete.
        if (conn.state == .closing or !self.lastRequestKeptAlive(conn)) {
            try self.closeConn(tag.conn_id);
        } else {
            conn.write_buf = &.{};
            conn.write_body = &.{};
            conn.write_phase = .headers;
            conn.write_offset = 0;
            if (conn.read_len > 0) {
                try self.processBufferedRequest(tag.conn_id, handler);
            } else {
                // Keep-alive: queue another read.
                conn.state = .reading;
                try self.queueRead(tag.conn_id);
            }
        }
    }

    // ── Helpers

    fn onClose(self: *Self, tag: pool_mod.Tag) void {
        self.pool.release(tag.conn_id);
    }

    fn onTimeout(
        self: *Self,
        cqe: linux.io_uring_cqe,
        tag: pool_mod.Tag,
    ) !void {
        const conn = self.pool.get(tag.conn_id);
        if (conn.state == .free) return;

        // Linked timeout CQEs commonly report ALREADY/CANCELED when the socket
        // op completed or the chain was otherwise torn down first.
        if (cqe.res == -@as(i32, @intFromEnum(linux.E.ALREADY))) return;
        if (cqe.res == -@as(i32, @intFromEnum(linux.E.CANCELED))) return;
        if (cqe.res == -@as(i32, @intFromEnum(linux.E.TIME))) {
            if (self.config.verbose) {
                std.log.debug("[zuring] idle timeout on conn {d}", .{tag.conn_id});
            }
            try self.closeConn(tag.conn_id);
            return;
        }

        if (cqe.res < 0) {
            std.log.err("[zuring] timeout op error {d} on conn {d}", .{ cqe.res, tag.conn_id });
        }
    }

    fn closeConn(self: *Self, id: u16) !void {
        const conn = self.pool.get(id);
        if (conn.state == .free or conn.close_queued) return;
        conn.state = .closing;
        conn.close_queued = true;
        const close_tag = pool_mod.Tag{ .op = .close, .conn_id = id };
        try self.ring.prepClose(conn.fd, close_tag.toU64());
    }

    fn sendError(self: *Self, id: u16, code: u16, msg: []const u8) !void {
        const conn = self.pool.get(id);
        var res = Response{};
        _ = res.status(code).header("Connection", "close").body(msg);
        const serialised = res.serialize(&conn.error_buf_mem) catch {
            try self.closeConn(id);
            return;
        };
        conn.write_buf = serialised;
        conn.write_body = &.{};
        conn.write_phase = .headers;
        conn.write_offset = 0;
        conn.state = .closing; // close after sending the error
        try self.queueWrite(id, serialised);
    }

    fn lastRequestKeptAlive(_: *Self, conn: *pool_mod.Conn) bool {
        return conn.keep_alive;
    }

    fn freeConnBuffers(self: *Self, id: u16) void {
        const conn = self.pool.get(id);
        if (conn.read_buf.len > 0) self.allocator.free(conn.read_buf);
        if (conn.write_buf_mem.len > 0) self.allocator.free(conn.write_buf_mem);
    }

    fn processBufferedRequest(self: *Self, id: u16, handler: HandlerFn) !void {
        const conn = self.pool.get(id);
        const raw = conn.read_buf[0..conn.read_len];

        // Requests may already be buffered here either because the latest read
        // completed with a full request, or because a keep-alive connection
        // left extra pipelined bytes behind after the previous response.
        var req: Request = undefined;
        const header_len = Request.parse(raw, &req) catch |err| switch (err) {
            error.Incomplete => {
                if (conn.read_len == conn.read_buf.len) {
                    try self.sendError(id, 413, "Request Too Large");
                    return;
                }

                conn.state = .reading;
                try self.queueReadRemaining(id);
                return;
            },
            else => {
                if (self.config.verbose) {
                    std.log.debug("[zuring] parse error {}: closing conn {d}", .{ err, id });
                }
                try self.sendError(id, 400, "Bad Request");
                return;
            },
        };

        const content_len = req.contentLength();
        const request_len = header_len + content_len;
        if (raw.len < request_len) {
            if (conn.read_len == conn.read_buf.len) {
                try self.sendError(id, 413, "Request Too Large");
                return;
            }

            conn.state = .reading;
            try self.queueReadRemaining(id);
            return;
        }

        req.body = raw[header_len..request_len];
        conn.keep_alive = req.keep_alive;

        if (self.config.verbose) {
            std.log.info("[zuring] {s} {s}", .{ @tagName(req.method), req.path });
        }

        var res = Response{};
        handler(self.io, &req, &res) catch |err| {
            std.log.err("[zuring] handler error {}: conn {d}", .{ err, id });
            _ = res.status(500).body("Internal Server Error");
        };

        if (!conn.keep_alive) _ = res.header("Connection", "close");

        const remaining_len = conn.read_len - request_len;
        if (remaining_len > 0) {
            // Compact any pipelined bytes to the front of the buffer so the
            // next request can be parsed without waiting for another read.
            std.mem.copyForwards(u8, conn.read_buf[0..remaining_len], conn.read_buf[request_len..conn.read_len]);
        }
        conn.read_len = remaining_len;

        try self.beginResponseWrite(id, &res);
    }

    fn beginResponseWrite(self: *Self, id: u16, res: *const Response) !void {
        const conn = self.pool.get(id);

        // For small in-memory responses, pack headers and body into the same
        // buffer so the common case stays a single socket write.
        const packed_response = res.serialize(conn.write_buf_mem) catch null;
        if (packed_response) |serialised| {
            conn.write_buf = serialised;
            conn.write_body = &.{};
            conn.write_phase = .headers;
            conn.write_offset = 0;
            conn.state = .writing;
            try self.queueWrite(id, serialised);
            return;
        }

        const serialised_headers = res.serializeHeaders(conn.write_buf_mem) catch {
            std.log.warn("[zuring] response too large for conn {d}", .{id});
            try self.sendError(id, 500, "Response Too Large");
            return;
        };

        conn.write_buf = serialised_headers;
        conn.write_body = res.bodyBytes();
        conn.write_phase = .headers;
        conn.write_offset = 0;
        conn.state = .writing;

        try self.queueWrite(id, serialised_headers);
    }

    fn queueRead(self: *Self, id: u16) !void {
        const conn = self.pool.get(id);
        const read_tag = pool_mod.Tag{ .op = .read, .conn_id = id };
        const timeout_tag = pool_mod.Tag{ .op = .timeout, .conn_id = id };
        try self.ring.prepReadWithTimeout(
            conn.fd,
            conn.read_buf,
            read_tag.toU64(),
            timeout_tag.toU64(),
            &conn.timeout_ts,
            null,
        );
    }

    fn queueReadRemaining(self: *Self, id: u16) !void {
        const conn = self.pool.get(id);
        const read_tag = pool_mod.Tag{ .op = .read, .conn_id = id };
        const timeout_tag = pool_mod.Tag{ .op = .timeout, .conn_id = id };
        try self.ring.prepReadWithTimeout(
            conn.fd,
            conn.read_buf[conn.read_len..],
            read_tag.toU64(),
            timeout_tag.toU64(),
            &conn.timeout_ts,
            null,
        );
    }

    fn queueWrite(self: *Self, id: u16, buf: []const u8) !void {
        const conn = self.pool.get(id);
        const write_tag = pool_mod.Tag{ .op = .write, .conn_id = id };
        const timeout_tag = pool_mod.Tag{ .op = .timeout, .conn_id = id };
        try self.ring.prepWriteWithTimeout(
            conn.fd,
            buf,
            write_tag.toU64(),
            timeout_tag.toU64(),
            &conn.timeout_ts,
            null,
        );
    }

    fn shutdownNow(self: *Self) void {
        std.log.warn("[zuring] shutting down...", .{});
        if (self.listener_fd >= 0) {
            _ = linux.close(self.listener_fd);
            self.listener_fd = -1;
        }

        for (&self.pool.slots) |*conn| {
            if (conn.state == .free) continue;
            if (conn.fd >= 0) {
                _ = linux.close(conn.fd);
                conn.fd = -1;
            }
        }
        std.log.info("[zuring] shut down complete", .{});
    }

    fn rearmAcceptIfNeeded(self: *Self, cqe: linux.io_uring_cqe) !void {
        if ((cqe.flags & linux.IORING_CQE_F_MORE) != 0) return;

        const accept_tag = pool_mod.Tag{
            .op = .accept,
            .conn_id = 0,
        };
        try self.ring.prepAcceptMultishot(self.listener_fd, accept_tag.toU64());
    }
};

fn timeoutTimespec(timeout_ms: u32) linux.kernel_timespec {
    return .{
        .sec = @intCast(timeout_ms / 1000),
        .nsec = @as(isize, @intCast(timeout_ms % 1000)) * std.time.ns_per_ms,
    };
}

// ── TCP listener setup

const SOCKET = linux.SOL.SOCKET;

const IPv4 = linux.AF.INET;

const TCP = linux.IPPROTO.TCP;
const NODERELAY = linux.TCP.NODELAY;

const STREAM = linux.SOCK.STREAM;
const NONBLOCK = linux.SOCK.NONBLOCK;
const CLOEXEC = linux.SOCK.CLOEXEC;

const REUSEADDR = linux.SO.REUSEADDR;
const REUSEPORT = linux.SO.REUSEPORT;

fn bindListener(config: ServerConfig) !linux.fd_t {
    const addr = linux.sockaddr.in{
        .family = IPv4,
        .port = std.mem.nativeToBig(u16, config.port),
        .addr = std.mem.nativeToBig(u32, config.address),
        .zero = [_]u8{0} ** 8,
    };

    // set up socket
    const sockfd = linux.socket(
        IPv4,
        STREAM | NONBLOCK | CLOEXEC,
        TCP,
    );
    if (linux.errno(sockfd) != .SUCCESS) return error.TcpSocketFailed;
    errdefer _ = linux.close(@intCast(sockfd));

    // configure socket
    // reuse address
    {
        const enable: i32 = 1;
        const rc_opt = linux.setsockopt(
            @intCast(sockfd),
            SOCKET,
            REUSEADDR, // can reuse immediately, no TIME_WAIT debounce
            std.mem.asBytes(&enable),
            @sizeOf(i32),
        );
        if (linux.errno(rc_opt) != .SUCCESS) return error.SetSockOptFailed;
    }

    // reuse port
    if (config.reuse_port) {
        const enable: i32 = 1;
        const rc_opt = linux.setsockopt(
            @intCast(sockfd),
            SOCKET,
            REUSEPORT, // can reuse immediately, no TIME_WAIT debounce
            std.mem.asBytes(&enable),
            @sizeOf(i32),
        );
        if (linux.errno(rc_opt) != .SUCCESS) return error.SetSockOptFailed;
    }

    // TCP_NODELAY reduce latency for small responses
    {
        const enable: i32 = 1;
        const rc_opt = linux.setsockopt(
            @intCast(sockfd),
            TCP,
            NODERELAY,
            std.mem.asBytes(&enable),
            @sizeOf(i32),
        );
        if (linux.errno(rc_opt) != .SUCCESS) return error.SetSockOptFailed;
    }

    // bind
    const rc_bind = linux.bind(
        @intCast(sockfd),
        @ptrCast(&addr),
        @sizeOf(linux.sockaddr.in),
    );
    if (linux.errno(rc_bind) != .SUCCESS) return error.BindFailed;

    // listen
    const rc_listen = linux.listen(@intCast(sockfd), @as(u32, config.backlog));
    if (linux.errno(rc_listen) != .SUCCESS) return error.ListenFailed;

    return @intCast(sockfd);
}
