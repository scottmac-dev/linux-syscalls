// Helpers to wrap inotify syscall
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const MAX_EVENT_BUF_LEN = 4096; // 4KB

// inotify_init1 flags.
// IN.NONBLOCK = O_NONBLOCK = 0o4000
// IN.CLOEXEC  = O_CLOEXEC  = 0o2000000
pub const InotifyInitFlags = struct {
    nonblock: bool = false,
    cloexec: bool = false,

    pub fn toFlags(self: @This()) u32 {
        var flags: u32 = 0;
        if (self.nonblock) flags |= linux.IN.NONBLOCK;
        if (self.cloexec) flags |= linux.IN.CLOEXEC;
        return flags;
    }
};

/// Wraps inotify_init1(2).
/// Returns a file descriptor referring to the new inotify event queue.
pub fn inotifyInit(flags: InotifyInitFlags) !posix.fd_t {
    const rc = linux.syscall1(
        linux.SYS.inotify_init1,
        @as(usize, flags.toFlags()),
    );
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc), // rc holds the fd on success
        .INVAL => error.InvalidFlags,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}

// inotify event mask bits (from inotify(7)).
pub const InotifyWatchMask = struct {
    // fs event bits
    access: bool = false, // 0x00000001
    modify: bool = false, // 0x00000002
    attrib: bool = false, // 0x00000004
    close_write: bool = false, // 0x00000008
    close_nowrite: bool = false, // 0x00000010
    open: bool = false, // 0x00000020
    moved_from: bool = false, // 0x00000040
    moved_to: bool = false, // 0x00000080
    create: bool = false, // 0x00000100
    delete: bool = false, // 0x00000200
    delete_self: bool = false, // 0x00000400
    move_self: bool = false, // 0x00000800
    // behaviour flags (non-contiguous — jump to 0x01000000+)
    onlydir: bool = false, // 0x01000000
    dont_follow: bool = false, // 0x02000000
    excl_unlink: bool = false, // 0x04000000
    mask_create: bool = false, // 0x10000000
    mask_add: bool = false, // 0x20000000
    oneshot: bool = false, // 0x80000000

    pub fn toMask(self: @This()) u32 {
        var mask: u32 = 0;
        if (self.access) mask |= linux.IN.ACCESS;
        if (self.modify) mask |= linux.IN.MODIFY;
        if (self.attrib) mask |= linux.IN.ATTRIB;
        if (self.close_write) mask |= linux.IN.CLOSE_WRITE;
        if (self.close_nowrite) mask |= linux.IN.CLOSE_NOWRITE;
        if (self.open) mask |= linux.IN.OPEN;
        if (self.moved_from) mask |= linux.IN.MOVED_FROM;
        if (self.moved_to) mask |= linux.IN.MOVED_TO;
        if (self.create) mask |= linux.IN.CREATE;
        if (self.delete) mask |= linux.IN.DELETE;
        if (self.delete_self) mask |= linux.IN.DELETE_SELF;
        if (self.move_self) mask |= linux.IN.MOVE_SELF;
        if (self.onlydir) mask |= linux.IN.ONLYDIR;
        if (self.dont_follow) mask |= linux.IN.DONT_FOLLOW;
        if (self.excl_unlink) mask |= linux.IN.EXCL_UNLINK;
        if (self.mask_create) mask |= linux.IN.MASK_CREATE;
        if (self.mask_add) mask |= linux.IN.MASK_ADD;
        if (self.oneshot) mask |= linux.IN.ONESHOT;
        return mask;
    }
};

/// Wraps inotify_add_watch(2).
/// Returns a watch descriptor (wd) — a non-negative i32.
/// The wd is used to identify events and to call inotify_rm_watch later.
pub fn addWatch(
    fd: posix.fd_t,
    path: [*:0]const u8,
    mask: InotifyWatchMask,
) !i32 {
    const rc = linux.syscall3(
        linux.SYS.inotify_add_watch,
        @as(usize, @bitCast(@as(isize, fd))),
        @intFromPtr(path),
        @as(usize, mask.toMask()),
    );
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc), // wd fits in i32 per the man page
        .ACCES => error.AccessDenied,
        .BADF => error.InvalidFileDescriptor,
        .EXIST => error.WatchAlreadyExists, // only with IN_MASK_CREATE
        .FAULT => unreachable, // path is a valid pointer
        .INVAL => error.InvalidMask,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .NOSPC => error.WatchLimitReached,
        .NOTDIR => error.NotADirectory, // only with IN_ONLYDIR
        else => |err| posix.unexpectedErrno(err),
    };
}

/// Iterates over packed inotify_event structs in a raw read buffer.
/// Pass `prev = null` to get the first event.
/// Returns null when the buffer is exhausted.
pub fn inotifyYield(
    buf: []u8,
    prev: ?*const linux.inotify_event,
) ?*const linux.inotify_event {
    const offset: usize = if (prev) |p| blk: {
        const base = @intFromPtr(p) - @intFromPtr(buf.ptr);
        break :blk base + @sizeOf(linux.inotify_event) + p.len;
    } else 0;

    if (offset >= buf.len) return null;

    return @ptrCast(@alignCast(buf.ptr + offset));
}

/// Calls inotify_rm_watch to cleanup whe watch descriptor
/// Removes the watch descriptor `wd` from the inotify instance `fd`.
pub fn clearWd(fd: i32, wd: i32) !void {
    const rc = linux.syscall2(
        linux.SYS.inotify_rm_watch,
        @bitCast(@as(isize, fd)),
        @bitCast(@as(isize, wd)),
    );
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .BADF => error.InvalidFileDescriptor,
        .INVAL => error.InvalidWatchDescriptor, // wd not valid for this fd
        else => |err| posix.unexpectedErrno(err),
    };
}

/// Wraps poll(2). Blocks until one of the fds in `fds` is ready or `timeout_ms` elapses.
/// Pass timeout_ms = -1 to block indefinitely.
pub fn pollFds(fds: []linux.pollfd, timeout_ms: i32) !usize {
    const rc = linux.syscall3(
        linux.SYS.poll,
        @intFromPtr(fds.ptr),
        @as(usize, fds.len),
        @bitCast(@as(isize, timeout_ms)),
    );
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .INTR => 0, // interrupted by signal, treat as timeout
        .BADF => error.InvalidFileDescriptor,
        .FAULT => unreachable,
        .INVAL => error.InvalidArguments,
        .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}
