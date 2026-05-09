//! Ring — owns a single io_uring instance.
//!
//! Handles:
//!   - io_uring_setup + mmap of SQ ring, CQ ring, and SQE array
//!   - SQE acquisition and submission
//!   - CQE iteration and head advancement
//!   - Clean teardown via munmap + close

const std = @import("std");
const linux = std.os.linux;
const DEF_PAGE_SIZE = 4096;

pub const RingConfig = struct {
    /// Number of SQ/CQ entries, must be a power of two.
    entries: u32 = 256,
    /// Extra setup flags OR'd into io_uring_params.flags.
    flags: u32 = 0,
};

pub const Ring = struct {
    fd: linux.fd_t,

    // SQ ring
    sq_ring: [*]u8,
    sq_ring_sz: usize,
    sq_head: *u32,
    sq_tail: *u32,
    sq_mask: *u32,
    sq_array: [*]u32,
    sq_flags: *u32,

    // SQE array
    sqes: [*]linux.io_uring_sqe,
    sqe_sz: usize,
    sq_entries: u32,
    sqe_tail: u32,

    // CQ ring
    cq_ring: [*]u8,
    cq_ring_sz: usize,
    cq_head: *u32,
    cq_tail: *u32,
    cq_mask: *u32,
    cqes: [*]linux.io_uring_cqe,

    /// Initialise an io_uring instance and map its rings into userspace.
    pub fn init(config: RingConfig) !Ring {
        var params = std.mem.zeroes(linux.io_uring_params);
        params.flags = config.flags;

        const fd = linux.io_uring_setup(config.entries, &params);
        errdefer _ = linux.close(@intCast(fd));
        if (linux.errno(fd) != .SUCCESS) return error.IoUringSetupFailed;

        // ── mmap SQ ring
        const sq_ring_sz = params.sq_off.array + params.sq_entries * @sizeOf(u32);
        const sq_ring_raw = linux.mmap(
            null,
            sq_ring_sz,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED, .POPULATE = true },
            @intCast(fd),
            linux.IORING_OFF_SQ_RING,
        );
        if (linux.errno(sq_ring_raw) != .SUCCESS) return error.MmapSqRingFailed;
        const sq_ring: [*]u8 = @ptrFromInt(sq_ring_raw);
        errdefer _ = linux.munmap(sq_ring, sq_ring_sz);

        // ── mmap SQE array
        const sqe_sz = params.sq_entries * @sizeOf(linux.io_uring_sqe);
        const sqe_raw = linux.mmap(
            null,
            sqe_sz,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED, .POPULATE = true },
            @intCast(fd),
            linux.IORING_OFF_SQES,
        );
        if (linux.errno(sqe_raw) != .SUCCESS) return error.MmapSqArrayFailed;
        const sqe_mmap: [*]u8 = @ptrFromInt(sqe_raw);
        errdefer _ = linux.munmap(sqe_mmap, sqe_sz);

        // ── mmap CQ ring
        // On modern kernels (IORING_FEAT_SINGLE_MMAP) SQ and CQ share the
        // same mapping. We track them separately for correctness on older kernels.
        const cq_ring_sz = params.cq_off.cqes + params.cq_entries * @sizeOf(linux.io_uring_cqe);
        const cq_ring_raw = linux.mmap(
            null,
            cq_ring_sz,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED, .POPULATE = true },
            @intCast(fd),
            linux.IORING_OFF_CQ_RING,
        );
        if (linux.errno(cq_ring_raw) != .SUCCESS) return error.MmapCqRingFailed;
        const cq_ring: [*]u8 = @ptrFromInt(cq_ring_raw);
        errdefer _ = linux.munmap(cq_ring, cq_ring_sz);

        return Ring{
            .fd = @intCast(fd),
            .sq_ring = sq_ring,
            .sq_ring_sz = sq_ring_sz,
            .sq_head = @ptrCast(@alignCast(sq_ring + params.sq_off.head)),
            .sq_tail = @ptrCast(@alignCast(sq_ring + params.sq_off.tail)),
            .sq_mask = @ptrCast(@alignCast(sq_ring + params.sq_off.ring_mask)),
            .sq_array = @ptrCast(@alignCast(sq_ring + params.sq_off.array)),
            .sq_flags = @ptrCast(@alignCast(sq_ring + params.sq_off.flags)),
            .sq_entries = params.sq_entries,
            .sqes = @ptrCast(@alignCast(sqe_mmap)),
            .sqe_sz = sqe_sz,
            .sqe_tail = @as(*u32, @ptrCast(@alignCast(sq_ring + params.sq_off.tail))).*,
            .cq_ring = cq_ring,
            .cq_ring_sz = cq_ring_sz,
            .cq_head = @ptrCast(@alignCast(cq_ring + params.cq_off.head)),
            .cq_tail = @ptrCast(@alignCast(cq_ring + params.cq_off.tail)),
            .cq_mask = @ptrCast(@alignCast(cq_ring + params.cq_off.ring_mask)),
            .cqes = @ptrCast(@alignCast(cq_ring + params.cq_off.cqes)),
        };
    }

    pub fn deinit(self: *Ring) void {
        _ = linux.munmap(@ptrCast(self.sqes), self.sqe_sz);
        _ = linux.munmap(self.sq_ring, self.sq_ring_sz);
        _ = linux.munmap(self.cq_ring, self.cq_ring_sz);
        _ = linux.close(@intCast(self.fd));
    }

    // ── SQE submission

    /// Acquire the next available SQE slot. Returns null if the SQ is full.
    /// The caller must fill the returned SQE and then call `flush`.
    pub fn getSqe(self: *Ring) ?*linux.io_uring_sqe {
        const tail = self.sqe_tail;
        const head = @atomicLoad(u32, self.sq_head, .acquire);
        if (tail -% head >= self.sq_entries) return null; // ring full

        const idx = tail & self.sq_mask.*;
        self.sq_array[idx] = idx; // indirect array: sq_array[n] = sqe index
        const sqe = &self.sqes[idx];
        sqe.* = std.mem.zeroes(linux.io_uring_sqe); // clear previous op
        self.sqe_tail +%= 1;
        return sqe;
    }

    /// Advance the SQ tail to make pending SQEs visible to the kernel.
    /// Returns the number of SQEs now pending.
    pub fn flush(self: *Ring) u32 {
        const pending = self.sqesPending();
        if (pending > 0) {
            @atomicStore(u32, self.sq_tail, self.sqe_tail, .release);
        }
        return pending;
    }

    fn sqesPending(self: *Ring) u32 {
        return self.sqe_tail -% self.sq_tail.*;
    }

    /// Submit all pending SQEs and optionally wait for `wait_nr` completions.
    pub fn submit(self: *Ring, wait_nr: u32) !u32 {
        const pending = self.flush();
        const flags: u32 = if (wait_nr > 0) linux.IORING_ENTER_GETEVENTS else 0;
        const rc = linux.io_uring_enter(@intCast(self.fd), pending, wait_nr, flags, null);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => return error.Interrupted,
            else => return error.IoUringEnterFailed,
        }
    }

    // ── CQE consumption

    /// Copy the next available CQE into `out`. Returns false if the CQ is empty.
    pub fn peekCqe(self: *Ring, out: *linux.io_uring_cqe) bool {
        const head = @atomicLoad(u32, self.cq_head, .acquire);
        const tail = @atomicLoad(u32, self.cq_tail, .acquire);
        if (head == tail) return false;
        out.* = self.cqes[head & self.cq_mask.*];
        return true;
    }

    /// Advance the CQ head, marking the CQE as consumed.
    pub fn seenCqe(self: *Ring) void {
        @atomicStore(u32, self.cq_head, self.cq_head.* +% 1, .release);
    }

    /// Block until at least one CQE is available, then copy it into `out`.
    pub fn waitCqe(self: *Ring, out: *linux.io_uring_cqe) !void {
        while (true) {
            if (self.peekCqe(out)) return;
            const rc = linux.io_uring_enter(@intCast(self.fd), 0, 1, linux.IORING_ENTER_GETEVENTS, null);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => return error.Interrupted,
                else => return error.IoUringEnterFailed,
            }
        }
    }

    // ── Convenience SQE helpers

    /// Prepare a multishot accept on `server_fd`. Each new connection posts a CQE.
    pub fn prepAcceptMultishot(self: *Ring, server_fd: linux.fd_t, user_data: u64) !void {
        const sqe = self.getSqe() orelse return error.SubmissionQueueFull;

        // pass 0 for flags unless you need specific socket flags like SOCK_CLOEXEC.
        sqe.prep_multishot_accept(server_fd, null, null, 0);
        sqe.user_data = user_data;
    }

    /// Prepare a read into a caller-supplied buffer with connection timeout.
    pub fn prepReadWithTimeout(
        self: *Ring,
        fd: linux.fd_t,
        buf: []u8,
        user_data: u64,
        timeout_user_data: u64,
        timeout_ts: *const linux.kernel_timespec,
        offset: ?u64,
    ) !void {
        const sqe = self.getSqe() orelse return error.SubmissionQueueFull;

        const off: u64 = if (offset) |o| o else 0;
        sqe.prep_read(fd, buf, off);
        sqe.flags |= linux.IOSQE_IO_LINK;
        sqe.user_data = user_data;

        const timeout_sqe = self.getSqe() orelse return error.SubmissionQueueFull;
        timeout_sqe.prep_link_timeout(timeout_ts, 0);
        timeout_sqe.user_data = timeout_user_data;
    }

    /// Prepare a write from a caller-supplied buffer with connection timeout.
    pub fn prepWriteWithTimeout(
        self: *Ring,
        fd: linux.fd_t,
        buf: []const u8,
        user_data: u64,
        timeout_user_data: u64,
        timeout_ts: *const linux.kernel_timespec,
        offset: ?u64,
    ) !void {
        const sqe = self.getSqe() orelse return error.SubmissionQueueFull;

        const off: u64 = if (offset) |o| o else 0;
        sqe.prep_write(fd, buf, off);
        sqe.flags |= linux.IOSQE_IO_LINK;
        sqe.user_data = user_data;

        const timeout_sqe = self.getSqe() orelse return error.SubmissionQueueFull;
        timeout_sqe.prep_link_timeout(timeout_ts, 0);
        timeout_sqe.user_data = timeout_user_data;
    }

    /// Prepare an async close of a file descriptor.
    pub fn prepClose(self: *Ring, fd: linux.fd_t, user_data: u64) !void {
        const sqe = self.getSqe() orelse return error.SubmissionQueueFull;

        sqe.prep_close(fd);

        sqe.user_data = user_data;
    }
};
