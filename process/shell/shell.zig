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

// Expand exe to abs path
pub fn toAbs(
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
        return allocator.dupeZ(u8, buf.items);
    }

    return error.CommandNotFound;
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;
    _ = io;
    const environ = init.minimal.environ;

    if (args.len < 2) return error.NoCommand;

    const path_env = try environ.getAlloc(arena, "PATH");
    //std.debug.print("{s}\n", .{path});

    // args[0] is the executable name
    const pipeline = try parsePipeline(arena, args[1..]);

    // TODO:
    // - fork each command
    // - setup pipes
    // - connect pipes and handle fd closure
    // - potentially include signal handling here

    for (pipeline.commands) |cmd| {
        const full_path = try toAbs(arena, cmd.args[0], path_env);
        std.debug.print("resolved: {s}\n", .{full_path});
        _ = linux.execve(full_path.ptr, @ptrCast(cmd.args.ptr), @ptrCast(&environ));
    }

    //for (pipeline.commands) |cmd| {
    //    _ = linux.execve(full_path_z, @ptrCast(cmd.args.ptr), @ptrCast(envp.ptr));
    //}
    linux.exit(0);
}
