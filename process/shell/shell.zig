//! Very minimal shell impl to demonstrate fork, exec syscalls
//! For this scope assumes all commands are external commands in path seperated by |
//! Only supports piping commands and one shot execution
//! For the sake of simplicty assume arena alloc which frees post one shot pipeline exe
const std = @import("std");
const linux = std.os.linux;

// Single cmd
pub const Command = struct {
    args: []const [:0]const u8,
};

// Pipeline to run one shot
pub const Pipeline = struct {
    commands: []const Command,
};

// File handler pipe stdout -> stdin
pub const PipeFds = struct {
    read: linux.fd_t,
    write: linux.fd_t,
};

// Extract in minimal supported format
// expected: cmd arg1 arg2 | cmd2 | cmd3 arg1 ...
pub fn parsePipeline(allocator: std.mem.Allocator, args: []const [:0]const u8) !Pipeline {
    var commands = try std.ArrayList(Command).initCapacity(allocator, 4);
    var current_args = try std.ArrayList([:0]const u8).initCapacity(allocator, 4);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "|")) {
            if (current_args.items.len == 0) return error.EmptyCommand;
            try commands.append(allocator, .{
                .args = try current_args.toOwnedSlice(allocator),
            });
        } else {
            try current_args.append(allocator, arg);
        }
    }

    // flush final command
    if (current_args.items.len == 0) return error.EmptyCommand;
    try commands.append(allocator, .{
        .args = try current_args.toOwnedSlice(allocator),
    });

    return .{ .commands = try commands.toOwnedSlice(allocator) };
}

// Helper to build full path
fn appendPathJoin(
    alloc: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    dir: []const u8,
    file: []const u8,
) !void {
    buf.clearRetainingCapacity();
    try buf.appendSlice(alloc, dir);
    if (dir.len > 0 and dir[dir.len - 1] != '/') {
        try buf.append(alloc, '/');
    }
    try buf.appendSlice(alloc, file);
}

// Returns true when `path` can be executed by the current process.
pub fn isExecutablePath(io: std.Io, path: []u8) bool {
    if (path.len == 0) return false;
    std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch return false;
    return true;
}

// Expand exe to abs path
pub fn toAbs(
    io: std.Io,
    allocator: std.mem.Allocator,
    cmd: []const u8,
    path_env: []const u8,
) ![:0]const u8 {
    // Literal path — caller knows where it is
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        return allocator.dupeZ(u8, cmd);
    }

    var buf = try std.ArrayList(u8).initCapacity(allocator, 32);
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        try appendPathJoin(allocator, &buf, dir, cmd);
        if (isExecutablePath(io, buf.items))
            return allocator.dupeZ(u8, buf.items);
    }

    return error.CommandNotFound;
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;
    const environ = init.minimal.environ;

    if (args.len < 2) return error.NoCommand;

    const path_env = try environ.getAlloc(arena, "PATH");

    // args[0] is the executable name
    const pipeline = try parsePipeline(arena, args[1..]);

    const env_map = try environ.createMap(arena);
    const envp_buf = try arena.allocSentinel(?[*:0]u8, env_map.keys().len, null);
    {
        var it = env_map.iterator();
        var i: usize = 0;
        while (it.next()) |pair| {
            const val_str = pair.value_ptr;
            const env_buf = try arena.allocSentinel(u8, pair.key_ptr.len + val_str.*.len + 1, 0);
            @memcpy(env_buf[0..pair.key_ptr.len], pair.key_ptr.*);
            env_buf[pair.key_ptr.len] = '=';
            @memcpy(env_buf[pair.key_ptr.len + 1 ..], val_str.*);
            envp_buf[i] = env_buf.ptr;
            i += 1;
        }
    }

    const n = pipeline.commands.len;

    // n-1 pipes using PipeFds wrapper
    const pipes = try arena.alloc(PipeFds, if (n > 1) n - 1 else 0);
    for (pipes) |*p| {
        var fds: [2]i32 = undefined;
        const rc = linux.pipe2(@ptrCast(&fds), .{});
        if (linux.errno(rc) != .SUCCESS) return error.PipeFailed;
        p.* = .{ .read = fds[0], .write = fds[1] };
    }

    const pids = try arena.alloc(linux.pid_t, n);

    for (pipeline.commands, 0..) |cmd, i| {
        const full_path = try toAbs(io, arena, cmd.args[0], path_env);

        // Fork using your proven loop
        const pid: linux.pid_t = while (true) {
            const ret = linux.fork();
            switch (linux.errno(ret)) {
                .SUCCESS => break @intCast(ret),
                .INTR => continue,
                else => return error.ForkFailed,
            }
        };

        if (pid == 0) {
            // NOTE: very primitve pipe assumptions, only exe -> exe
            // stdin from previous pipe
            if (i > 0) _ = linux.dup2(pipes[i - 1].read, linux.STDIN_FILENO);
            // stdout to next pipe
            if (i < n - 1) _ = linux.dup2(pipes[i].write, linux.STDOUT_FILENO);

            // Close all pipe fds inherited by child
            for (pipes) |p| {
                _ = linux.close(p.read);
                _ = linux.close(p.write);
            }

            // Build argv and exec for each command
            const full_path_z = arena.dupeZ(u8, full_path) catch linux.exit(1);
            const argv = arena.allocSentinel(?[*:0]const u8, cmd.args.len, null) catch linux.exit(1);
            for (cmd.args, 0..) |arg, j| argv[j] = arg.ptr;

            _ = linux.execve(full_path_z.ptr, argv.ptr, @ptrCast(envp_buf.ptr));
            linux.exit(127);
        }

        pids[i] = pid;
    }

    // Parent closes all pipes
    for (pipes) |p| {
        _ = linux.close(p.read);
        _ = linux.close(p.write);
    }

    // Wait for all forked proceses
    for (pids) |pid| {
        while (true) {
            var status: i32 = 0;
            const rc = linux.waitpid(pid, &status, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => break,
                .INTR => continue,
                else => break,
            }
        }
    }

    linux.exit(0);
}
