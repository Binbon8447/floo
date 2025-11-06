const std = @import("std");
const posix = std.posix;

/// Lightweight trace helper that compiles away when `enabled` is false.
pub inline fn tracePrint(comptime enabled: bool, comptime fmt: []const u8, args: anytype) void {
    if (enabled) {
        std.debug.print(fmt, args);
    }
}

pub const TcpOptions = struct {
    nodelay: bool,
    keepalive: bool,
    keepalive_idle: u32,
    keepalive_interval: u32,
    keepalive_count: u32,
};

/// Build a `TcpOptions` struct from any config that exposes the TCP tuning fields.
pub fn tcpOptionsFromConfig(cfg_ptr: anytype) TcpOptions {
    return switch (@typeInfo(@TypeOf(cfg_ptr))) {
        .pointer => |pointer_info| blk: {
            const child_type = pointer_info.child;
            comptime for ([_][]const u8{
                "tcp_nodelay",
                "tcp_keepalive",
                "tcp_keepalive_idle",
                "tcp_keepalive_interval",
                "tcp_keepalive_count",
            }) |field_name| {
                if (!@hasField(child_type, field_name)) {
                    @compileError("Config type missing field: " ++ field_name);
                }
            };

            break :blk TcpOptions{
                .nodelay = cfg_ptr.*.tcp_nodelay,
                .keepalive = cfg_ptr.*.tcp_keepalive,
                .keepalive_idle = cfg_ptr.*.tcp_keepalive_idle,
                .keepalive_interval = cfg_ptr.*.tcp_keepalive_interval,
                .keepalive_count = cfg_ptr.*.tcp_keepalive_count,
            };
        },
        else => @compileError("tcpOptionsFromConfig expects a pointer to a config struct"),
    };
}

/// Apply TCP socket options (Nagle/keepalive) with best-effort error reporting.
pub fn applyTcpOptions(fd: posix.fd_t, opts: TcpOptions) void {
    if (opts.nodelay) {
        const nodelay_value: c_int = 1;
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(nodelay_value)) catch |err| {
            std.debug.print("[TCP] Failed to set TCP_NODELAY: {}\n", .{err});
        };
    }

    if (!opts.keepalive) return;

    const keepalive_value: c_int = 1;
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, &std.mem.toBytes(keepalive_value)) catch |err| {
        std.debug.print("[TCP] Failed to set SO_KEEPALIVE: {}\n", .{err});
    };

    if (@hasDecl(posix.TCP, "KEEPIDLE")) {
        const idle_value: c_int = @intCast(opts.keepalive_idle);
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPIDLE, &std.mem.toBytes(idle_value)) catch {};
    }
    if (@hasDecl(posix.TCP, "KEEPINTVL")) {
        const intvl_value: c_int = @intCast(opts.keepalive_interval);
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, &std.mem.toBytes(intvl_value)) catch {};
    }
    if (@hasDecl(posix.TCP, "KEEPCNT")) {
        const cnt_value: c_int = @intCast(opts.keepalive_count);
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, &std.mem.toBytes(cnt_value)) catch {};
    }
}

/// Default socket buffer size for high-throughput networking.
pub const DEFAULT_SOCKET_BUFFER_BYTES: u32 = 4 * 1024 * 1024;

/// Tune socket buffers for high throughput.
pub fn tuneSocketBuffers(fd: posix.fd_t, buffer_size: u32) void {
    const size: c_int = @intCast(buffer_size);
    const bytes = std.mem.toBytes(size);
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, &bytes) catch |err| {
        std.debug.print("[SOCKET] Failed to grow RCVBUF to {}: {}\n", .{ buffer_size, err });
    };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, &bytes) catch |err| {
        std.debug.print("[SOCKET] Failed to grow SNDBUF to {}: {}\n", .{ buffer_size, err });
    };
}
