//! Static file server example.
//!
//!   zig build -Doptimize=ReleaseFast
//!   ./zig-out/bin/fileserver ./public

const std = @import("std");
const zuring = @import("zuring");
const linux = std.os.linux;
const Io = std.Io;

var serve_dir: Io.Dir = undefined;
var file_read_buf: [512 * 1024]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const server_allocator = std.heap.page_allocator;
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    const dir_path = if (args.len > 1) args[1] else "./public";
    serve_dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer serve_dir.close(io);

    std.log.info("serving files from: {s}", .{dir_path});

    var server = try zuring.Server.init(io, server_allocator, .{
        .port = 5001,
        .address = zuring.Server.LOCAL_HOST,
        .idle_timeout_ms = 2000, // 2 sec timeout for demo purposes
        .ring_entries = 256,
        .write_buf_size = 1024 * 1024, // 1 MiB for file content
        //.write_buf_size = 64, // for testing file too large err handling
    });
    defer server.deinit();

    try server.listen(handle);
}

fn handle(io: Io, req: *zuring.Request, res: *zuring.Response) !void {
    if (req.method != .GET and req.method != .HEAD) {
        _ = res.status(405).body("Method Not Allowed\n");
        return;
    }

    // Sanitise path — reject traversal attempts.
    const path = req.path;
    if (std.mem.indexOf(u8, path, "..") != null) {
        _ = res.status(403).body("Forbidden\n");
        return;
    }

    // Strip leading slash.
    const rel = if (path.len > 0 and path[0] == '/') path[1..] else path;
    const file_path = if (rel.len == 0) "index.html" else rel;

    // Read file into a stack buffer (see note on sendfile below).
    // TODO(v0.3): replace with io_uring splice/sendfile for zero-copy delivery.
    var file: Io.File = serve_dir.openFile(io, file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            _ = res.status(404).body("Not Found\n");
            return;
        },
        else => {
            _ = res.status(500).body("Internal Server Error\n");
            return;
        },
    };
    defer file.close(io);

    const stat = try file.stat(io);
    // Limit file size to what our write buffer can hold.
    if (stat.size > 512 * 1024) {
        _ = res.status(413).body("File Too Large\n");
        return;
    }

    // Read file — this is a placeholder; v0.3 will use sendfile via io_uring.
    const n = linux.read(file.handle, &file_read_buf, file_read_buf.len);
    if (linux.errno(n) != .SUCCESS) return error.ReadHandleFailed;

    _ = res.status(200).contentType(mimeType(file_path));
    if (req.method == .HEAD) {
        _ = res.contentLength(@intCast(n)).body("");
    } else {
        _ = res.body(file_read_buf[0..n]);
    }
}

fn mimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    return "application/octet-stream";
}
