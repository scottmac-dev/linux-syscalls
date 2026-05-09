//! Entry point to zuring public library api
const builtin = @import("builtin");

// Enforce Linux-only at compile time.
comptime {
    if (builtin.os.tag != .linux) {
        @compileError("zuring only supports Linux");
    }
}

// ── Public re-exports
pub const Server = @import("server.zig").Server;
pub const ServerConfig = @import("server.zig").ServerConfig;
pub const HandlerFn = @import("server.zig").HandlerFn;
pub const Request = @import("internal/request.zig").Request;
pub const Response = @import("internal/response.zig").Response;
pub const Method = @import("internal/request.zig").Method;

// Low-level ring access for advanced users who want to submit their own SQEs.
pub const Ring = @import("linux/ring.zig").Ring;

test {
    _ = @import("internal/request.zig");
    _ = @import("internal/response.zig");
}
