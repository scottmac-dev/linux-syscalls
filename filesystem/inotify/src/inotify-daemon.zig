// linux daemon that watches a file or dir and logs events
const std = @import("std");
const inotify = @import("inotify.zig");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const LOG_FILE = "/tmp/inotify-log";

pub const WatchEntry = struct {
    path: [:0]const u8,
};

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

pub fn main(init: std.process.Init) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 2) {
        std.log.err("Requires one file path to run example.zig\n", .{});
        return 1;
    }

    const resources = args[1..];

    // single event queue
    const event_queue_fd = try inotify.inotifyInit(.{ .nonblock = false, .cloexec = false });
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
    }, 0);
    defer _ = linux.close(@intCast(log_fd));

    // main daemon loop, runs indefinetly to watch and notify until err or sig EXIT
    while (true) {
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

            if (next_event.mask & linux.IN.CREATE != 0) {
                const event = try std.fmt.bufPrint(&log_buf, "[CREATE] {s}\n", .{entry.path});
                const write_rc = linux.write(@intCast(log_fd), event.ptr, event.len);
                if (linux.errno(write_rc) != .SUCCESS) return error.WriteLogFailed;
                std.debug.print("{s} created.\n", .{entry.path});
            }
            if (next_event.mask & linux.IN.DELETE != 0) {
                const event = try std.fmt.bufPrint(&log_buf, "[DEL] {s}\n", .{entry.path});
                const write_rc = linux.write(@intCast(log_fd), event.ptr, event.len);
                if (linux.errno(write_rc) != .SUCCESS) return error.WriteLogFailed;
                std.debug.print("{s} deleted.\n", .{entry.path});
            }
            if (next_event.mask & linux.IN.ACCESS != 0) {
                const event = try std.fmt.bufPrint(&log_buf, "[ACCESS] {s}\n", .{entry.path});
                const write_rc = linux.write(@intCast(log_fd), event.ptr, event.len);
                if (linux.errno(write_rc) != .SUCCESS) return error.WriteLogFailed;
                std.debug.print("{s} accessed.\n", .{entry.path});
            }
            if (next_event.mask & linux.IN.CLOSE_WRITE != 0) {
                const event = try std.fmt.bufPrint(&log_buf, "[WR/CLOSE] {s}\n", .{entry.path});
                const write_rc = linux.write(@intCast(log_fd), event.ptr, event.len);
                if (linux.errno(write_rc) != .SUCCESS) return error.WriteLogFailed;
                std.debug.print("{s} written, then closed.\n", .{entry.path});
            }
            if (next_event.mask & linux.IN.MODIFY != 0) {
                const event = try std.fmt.bufPrint(&log_buf, "[MOD] {s}\n", .{entry.path});
                const write_rc = linux.write(@intCast(log_fd), event.ptr, event.len);
                if (linux.errno(write_rc) != .SUCCESS) return error.WriteLogFailed;
                std.debug.print("{s} modified.\n", .{entry.path});
            }
            if (next_event.mask & linux.IN.MOVE_SELF != 0) {
                const event = try std.fmt.bufPrint(&log_buf, "[MOVE] {s}\n", .{entry.path});
                const write_rc = linux.write(@intCast(log_fd), event.ptr, event.len);
                if (linux.errno(write_rc) != .SUCCESS) return error.WriteLogFailed;
                std.debug.print("{s} moved.\n", .{entry.path});
            }
        }
    }
}
