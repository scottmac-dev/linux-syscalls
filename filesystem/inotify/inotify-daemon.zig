// linux daemon that watches a file or dir and logs events
// Syscalls used
//  - inotify_init1 (in inotify.zig)
//  - inotify_add_watch (in inotify.zig)
//  - inotify_rm_watch (in inotify.zig)
//  - poll (in infotify.zig)
//  - open
//  - close
//  - write
const std = @import("std");
const inotify = @import("inotify.zig");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const LOG_FILE = "/tmp/inotify-log";
const PERM_RW: u32 = 0o644; // create log with read/write permissions
var interrupted: bool = false; // handle SIGINT

pub const WatchEntry = struct {
    path: [:0]const u8,
};

/// Override crtl + C SIGINT
fn sigintHandler(sig: linux.SIG) callconv(.c) void {
    _ = sig;
    interrupted = true;
}

/// expands a null-terminated path to absolute path
pub fn expandPathToAbsZ(
    allocator: Allocator,
    path: [*:0]const u8,
) ![:0]const u8 {
    const path_slice = std.mem.span(path);

    // Absolute path: starts with '/' on posix or e.g. "C:\" on windows
    const is_absolute = std.fs.path.isAbsolute(path_slice);

    if (is_absolute) {
        return try allocator.dupeZ(u8, path_slice);
    }

    // Relative path
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.os.linux.getcwd(&buf, buf.len);
    const cwd_str = buf[0 .. cwd_len - 1]; // trim null terminator

    const rest = if (path_slice.len >= 2 and path_slice[0] == '.' and
        (path_slice[1] == '/' or path_slice[1] == '\\'))
        path_slice[2..]
    else
        path_slice;

    const joined = try std.fs.path.join(allocator, &.{ cwd_str, rest });
    defer allocator.free(joined);
    return try allocator.dupeZ(u8, joined);
}

/// Formats a Timestamp as "YYYY-MM-DD HH:MM:SS.mmm"
pub fn fmtTimestamp(ts: linux.timespec, buf: []u8) ![]u8 {
    // seconds since epoch -> broken down time via crude calculation
    const secs_per_min = 60;
    const secs_per_hour = 3600;
    const secs_per_day = 86400;

    var remaining: u64 = @intCast(ts.sec);

    // days since epoch (1970-01-01)
    const days = remaining / secs_per_day;
    remaining %= secs_per_day;

    const hour = remaining / secs_per_hour;
    remaining %= secs_per_hour;
    const min = remaining / secs_per_min;
    const sec = remaining % secs_per_min;

    // Gregorian calendar calculation from days since epoch
    const z = days + 719468;
    const era = z / 146097;
    const doe = z - era * 146097;
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const yr = if (m <= 2) y + 1 else y;

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ yr, m, d, hour, min, sec });
}

// Main daemon entry point
pub fn main(init: std.process.Init) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    //const io = init.io;

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 2) {
        std.log.err("Requires one file path to run example.zig\n", .{});
        return 1;
    }

    const resources = args[1..];

    // single event queue
    const event_queue_fd = try inotify.inotifyInit(.{ .nonblock = false, .cloexec = true });
    defer _ = linux.close(@intCast(event_queue_fd));

    // map wd -> resource path
    var watches = std.AutoHashMap(i32, WatchEntry).init(alloc);

    for (resources) |r| {
        const path = try expandPathToAbsZ(alloc, r);
        std.debug.print("Watching: {s}\n", .{path});

        const event_wd = try inotify.addWatch(event_queue_fd, path, .{
            .access = true,
            .create = true,
            .delete = true,
            .close_write = true,
            .modify = true,
            .move_self = true,
        });
        try watches.put(event_wd, .{ .path = path });
    }

    var buf align(@alignOf(linux.inotify_event)) = [_]u8{0} ** inotify.MAX_EVENT_BUF_LEN;

    // open log file
    const log_file_path_z = try alloc.dupeZ(u8, LOG_FILE);
    const log_fd = linux.open(log_file_path_z.ptr, .{
        .CREAT = true,
        .APPEND = true,
        .ACCMODE = .WRONLY,
    }, PERM_RW);

    //if (linux.errno(log_fd) != .SUCCESS) return error.OpenLogfileFailed;
    defer _ = linux.close(@intCast(log_fd));

    // register SIGINT handler before the main loop
    const sa = linux.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.INT, &sa, null);

    // use poll syscall to avoid spinning in super loop
    // loop will only move forward when poll detects new events
    var poll_fds = [_]linux.pollfd{
        .{ .fd = event_queue_fd, .events = linux.POLL.IN, .revents = 0 },
    };

    // main daemon loop, runs indefinetly to watch and notify until err or sig EXIT
    // poll() blocks until data ready (or 500ms timeout)
    //  → data ready: read() is guaranteed to return immediately with events
    //  → timeout: loop back, check !interrupted, poll again
    while (!interrupted) {
        const ready = try inotify.pollFds(&poll_fds, 500); // 500ms timeout
        if (ready == 0) continue; // timeout, loop back to check interrupted

        if (poll_fds[0].revents & linux.POLL.IN != 0) {
            // safe to read
            const len = linux.read(event_queue_fd, &buf, buf.len);

            if (len == 0 or len > std.math.maxInt(isize)) {
                std.log.err("Failed to read from inotify queue.\n", .{});
                return error.ReadFailed;
            }

            var i_event: ?*const linux.inotify_event = null;

            while (inotify.inotifyYield(buf[0..len], i_event)) |next_event| {
                i_event = next_event;
                const entry = watches.get(next_event.wd) orelse continue;

                var log_buf: [2048]u8 = undefined;

                // get timestamp
                var ts: linux.timespec = undefined;
                const time_rc = linux.clock_gettime(linux.CLOCK.REALTIME, &ts);

                if (linux.errno(time_rc) != .SUCCESS) return error.GetTimeFailed;
                var ts_buf: [32]u8 = undefined;
                const timestamp = try fmtTimestamp(ts, &ts_buf);

                // Log different events
                if (next_event.mask & linux.IN.CREATE != 0) {
                    const event = try std.fmt.bufPrint(&log_buf, "[{s}] [CREATE] {s}\n", .{ timestamp, entry.path });
                    const write_rc = linux.write(@intCast(log_fd), event.ptr, event.len);
                    if (linux.errno(write_rc) != .SUCCESS) return error.WriteLogFailed;
                    std.debug.print("{s} created.\n", .{entry.path});
                }
                if (next_event.mask & linux.IN.DELETE != 0) {
                    const event = try std.fmt.bufPrint(&log_buf, "[{s}] [DEL] {s}\n", .{ timestamp, entry.path });
                    const write_rc = linux.write(@intCast(log_fd), event.ptr, event.len);
                    if (linux.errno(write_rc) != .SUCCESS) return error.WriteLogFailed;
                    std.debug.print("{s} deleted.\n", .{entry.path});
                }
                if (next_event.mask & linux.IN.ACCESS != 0) {
                    const event = try std.fmt.bufPrint(&log_buf, "[{s}] [ACCESS] {s}\n", .{ timestamp, entry.path });
                    const write_rc = linux.write(@intCast(log_fd), event.ptr, event.len);
                    if (linux.errno(write_rc) != .SUCCESS) return error.WriteLogFailed;
                    std.debug.print("{s} accessed.\n", .{entry.path});
                }
                if (next_event.mask & linux.IN.CLOSE_WRITE != 0) {
                    const event = try std.fmt.bufPrint(&log_buf, "[{s}] [WR/CLOSE] {s}\n", .{ timestamp, entry.path });
                    const write_rc = linux.write(@intCast(log_fd), event.ptr, event.len);
                    if (linux.errno(write_rc) != .SUCCESS) return error.WriteLogFailed;
                    std.debug.print("{s} written, then closed.\n", .{entry.path});
                }
                if (next_event.mask & linux.IN.MODIFY != 0) {
                    const event = try std.fmt.bufPrint(&log_buf, "[{s}] [MODIFY] {s}\n", .{ timestamp, entry.path });
                    const write_rc = linux.write(@intCast(log_fd), event.ptr, event.len);
                    if (linux.errno(write_rc) != .SUCCESS) return error.WriteLogFailed;
                    std.debug.print("{s} modified.\n", .{entry.path});
                }
                if (next_event.mask & linux.IN.MOVE_SELF != 0) {
                    const event = try std.fmt.bufPrint(&log_buf, "[{s}] [MOVE] {s}\n", .{ timestamp, entry.path });
                    const write_rc = linux.write(@intCast(log_fd), event.ptr, event.len);
                    if (linux.errno(write_rc) != .SUCCESS) return error.WriteLogFailed;
                    std.debug.print("{s} moved.\n", .{entry.path});
                }
            }
        }
    }
    // post interrupt cleanup
    var wd_iter = watches.keyIterator();
    while (wd_iter.next()) |wd| {
        //std.debug.print("clearing wd: {d}\n", .{wd.*});
        try inotify.clearWd(event_queue_fd, wd.*);
    }

    return 0;
}
