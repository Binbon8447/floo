const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const build_options = @import("build_options");
const protocol = @import("protocol.zig");
const tunnel = @import("tunnel.zig");
const config = @import("config.zig");
const noise = @import("noise.zig");
const udp_server = @import("udp_server.zig");
const diagnostics = @import("diagnostics.zig");
const common = @import("common.zig");

const tracePrint = common.tracePrint;
const tcpOptionsFromSettings = common.tcpOptionsFromSettings;
const tuneSocketBuffers = common.tuneSocketBuffers;
const applyTcpOptions = common.applyTcpOptions;
const formatAddress = common.formatAddress;
const resolveHostPort = common.resolveHostPort;

const CheckStatus = diagnostics.CheckStatus;

const DEFAULT_CONFIG_PATH = "floos.toml";
const enable_stream_trace = false;
const enable_tunnel_trace = false;

var global_allocator: std.mem.Allocator = undefined;
var shutdown_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var config_path_global: []const u8 = undefined; // Store config path for reload
var encrypt_total_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var encrypt_calls: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

const CliMode = enum { run, help, version, doctor, ping };

const CliOptions = struct {
    mode: CliMode = .run,
    config_path: []const u8 = DEFAULT_CONFIG_PATH,
    config_path_set: bool = false,
    port_override: ?u16 = null,
};

const ParseError = error{ UnknownFlag, MissingValue, ConflictingMode, TooManyPositionals, InvalidValue };

const ParseContext = struct {
    arg: []const u8 = "",
};

const SERVER_USAGE =
    \\Usage: floos [options] [config_path]
    \\Options:
    \\  -h, --help                 Show this help message and exit
    \\  -V, --version              Show version information and exit
    \\      --doctor              Run diagnostics for the server configuration and exit
    \\      --ping                Probe configured target services and exit
    \\  -p, --port PORT           Override listening port
    \\  config_path               Optional path to floos.toml (defaults to ./floos.toml)
    \\Examples:
    \\  floos --doctor
    \\  floos -p 9000 --ping configs/floos.toml
    \\
;

fn printServerUsage() void {
    std.debug.print("{s}", .{SERVER_USAGE});
}

fn setMode(opts: *CliOptions, new_mode: CliMode, ctx: *ParseContext, arg: []const u8) ParseError!void {
    if (opts.mode != .run and opts.mode != new_mode) {
        ctx.arg = arg;
        return ParseError.ConflictingMode;
    }
    opts.mode = new_mode;
}

fn parseServerArgs(args_list: [][:0]u8, ctx: *ParseContext) ParseError!CliOptions {
    var opts = CliOptions{};
    var idx: usize = 1;
    while (idx < args_list.len) : (idx += 1) {
        const arg = std.mem.sliceTo(args_list[idx], 0);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try setMode(&opts, .help, ctx, arg);
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            try setMode(&opts, .version, ctx, arg);
        } else if (std.mem.eql(u8, arg, "--doctor")) {
            try setMode(&opts, .doctor, ctx, arg);
        } else if (std.mem.eql(u8, arg, "--ping")) {
            try setMode(&opts, .ping, ctx, arg);
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (idx + 1 >= args_list.len) {
                ctx.arg = arg;
                return ParseError.MissingValue;
            }
            idx += 1;
            const port_str = std.mem.sliceTo(args_list[idx], 0);
            const port = std.fmt.parseInt(u16, port_str, 10) catch {
                ctx.arg = arg;
                return ParseError.InvalidValue;
            };
            opts.port_override = port;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            ctx.arg = arg;
            return ParseError.UnknownFlag;
        } else {
            if (!opts.config_path_set) {
                opts.config_path = arg;
                opts.config_path_set = true;
            } else {
                ctx.arg = arg;
                return ParseError.TooManyPositionals;
            }
        }
    }
    return opts;
}

fn applyServerOverrides(cfg: *config.ServerConfig, opts: *CliOptions) void {
    if (opts.port_override) |port| {
        cfg.port = port;
    }
}

fn loadServerConfigWithOverrides(allocator: std.mem.Allocator, opts: *CliOptions) !config.ServerConfig {
    var cfg = try config.ServerConfig.loadFromFile(allocator, opts.config_path);
    errdefer cfg.deinit();
    applyServerOverrides(&cfg, opts);
    return cfg;
}

fn probeTcpTarget(host: []const u8, port: u16) !i128 {
    const addr = try resolveHostPort(host, port);
    const fd = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);

    const start = std.time.nanoTimestamp();
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch |err| {
        return err;
    };
    const done = std.time.nanoTimestamp();
    posix.close(fd);
    return done - start;
}

fn runServerPing(allocator: std.mem.Allocator, opts: *CliOptions) !bool {
    var cfg = try loadServerConfigWithOverrides(allocator, opts);
    defer cfg.deinit();

    std.debug.print("Probing configured services...\n", .{});
    var had_fail = false;
    var service_iter = cfg.services.valueIterator();
    var service_count: usize = 0;
    while (service_iter.next()) |service| {
        service_count += 1;
        if (service.transport == .tcp) {
            const duration = probeTcpTarget(service.address, service.port) catch |err| {
                diagnostics.reportCheck(.fail, "Service '{s}' ({}) unreachable at {s}:{d}: {}", .{
                    service.name,
                    service.id,
                    service.address,
                    service.port,
                    err,
                });
                had_fail = true;
                continue;
            };
            const ms = @as(f64, @floatFromInt(duration)) / @as(f64, std.time.ns_per_ms);
            diagnostics.reportCheck(.ok, "Service '{s}' ({}) reachable ({s}:{d}) - connect {d:.2} ms", .{
                service.name,
                service.id,
                service.address,
                service.port,
                ms,
            });
        } else {
            _ = std.net.Address.resolveIp(service.address, service.port) catch |err| {
                diagnostics.reportCheck(.fail, "Service '{s}' ({}) UDP target {s}:{d} not resolvable: {}", .{
                    service.name,
                    service.id,
                    service.address,
                    service.port,
                    err,
                });
                had_fail = true;
                continue;
            };
            diagnostics.reportCheck(.ok, "Service '{s}' ({}) UDP target {s}:{d} resolves successfully", .{
                service.name,
                service.id,
                service.address,
                service.port,
            });
        }
    }

    if (service_count == 0) {
        diagnostics.reportCheck(.warn, "No services configured; nothing to probe", .{});
    }

    return !had_fail;
}

fn runServerDoctor(allocator: std.mem.Allocator, opts: *CliOptions) !bool {
    std.debug.print("Floo Server Doctor\n===================\n", .{});

    var config_exists = true;
    std.fs.cwd().access(opts.config_path, .{}) catch {
        config_exists = false;
    };
    if (config_exists) {
        diagnostics.reportCheck(.ok, "Config file accessible at {s}", .{opts.config_path});
    } else {
        diagnostics.reportCheck(.warn, "Config file {s} not found; defaults will be used", .{opts.config_path});
    }

    var cfg = loadServerConfigWithOverrides(allocator, opts) catch |err| {
        diagnostics.reportCheck(.fail, "Failed to load config: {}", .{err});
        return false;
    };
    defer cfg.deinit();

    var had_fail = false;
    diagnostics.reportCheck(.ok, "Configuration parsed (services: {})", .{cfg.services.count()});
    diagnostics.reportCheck(.ok, "Server version: {s}", .{build_options.version});

    const canonical_cipher = config.canonicalCipher(&cfg);
    if (std.mem.eql(u8, canonical_cipher, "none")) {
        diagnostics.reportCheck(.warn, "Encryption disabled; relying solely on tokens", .{});
    } else if (cfg.psk.len == 0) {
        diagnostics.reportCheck(.fail, "PSK is empty; clients cannot authenticate", .{});
        had_fail = true;
    } else if (std.mem.eql(u8, cfg.psk, config.DEFAULT_PSK)) {
        diagnostics.reportCheck(.warn, "Using default PSK; replace before production", .{});
    }

    var require_default_token = false;
    var svc_iter = cfg.services.valueIterator();
    while (svc_iter.next()) |service| {
        if (service.token.len == 0) {
            require_default_token = true;
            break;
        }
    }
    if ((require_default_token or cfg.services.count() == 0) and cfg.token.len == 0) {
        diagnostics.reportCheck(.warn, "Default token is empty; unauthenticated clients may connect", .{});
    } else if (cfg.token.len > 0 and std.mem.eql(u8, cfg.token, config.DEFAULT_TOKEN)) {
        diagnostics.reportCheck(.warn, "Default token uses placeholder value; update to a secret", .{});
    }

    const listen_addr = resolveHostPort(cfg.bind, cfg.port) catch |err| {
        diagnostics.reportCheck(.fail, "Invalid listen address {s}:{d}: {}", .{ cfg.bind, cfg.port, err });
        return false;
    };

    const listen_fd = posix.socket(listen_addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    if (listen_fd) |fd| {
        defer posix.close(fd);
        const reuse: c_int = 1;
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(reuse)) catch {};
        const bind_result = posix.bind(fd, &listen_addr.any, listen_addr.getOsSockLen());
        if (bind_result) |_| {
            diagnostics.reportCheck(.ok, "Bind check succeeded on {s}:{d}", .{ cfg.bind, cfg.port });
        } else |err| {
            if (err == error.AddressInUse) {
                diagnostics.reportCheck(.warn, "Port {d} already in use on {s}", .{ cfg.port, cfg.bind });
                had_fail = true;
            } else {
                diagnostics.reportCheck(.fail, "Failed to bind {s}:{d}: {}", .{ cfg.bind, cfg.port, err });
                return false;
            }
        }
    } else |err| {
        diagnostics.reportCheck(.fail, "Unable to create socket for bind check: {}", .{err});
        return false;
    }

    // Probe configured services (reuse ping logic)
    const ping_ok = try runServerPing(allocator, opts);
    if (!ping_ok) {
        had_fail = true;
    }

    if (had_fail) {
        std.debug.print("\nDiagnostics complete (with warnings/failures).\n", .{});
    } else {
        std.debug.print("\nDiagnostics complete.\n", .{});
    }
    return !had_fail;
}
/// Composite key for routing streams in multi-service mode
const StreamKey = struct {
    service_id: tunnel.ServiceId,
    stream_id: tunnel.StreamId,
};

const StreamKeyContext = struct {
    pub fn hash(_: StreamKeyContext, key: StreamKey) u64 {
        // Fast hash: combine service_id (16 bits) and stream_id (32 bits) into u64
        // This is much faster than Wyhash for such small keys
        return (@as(u64, key.service_id) << 32) | @as(u64, key.stream_id);
    }

    pub fn eql(_: StreamKeyContext, a: StreamKey, b: StreamKey) bool {
        return a.service_id == b.service_id and a.stream_id == b.stream_id;
    }
};

fn handleSignal(sig: c_int) callconv(.c) void {
    if (sig == posix.SIG.INT or sig == posix.SIG.TERM) {
        std.debug.print("\n[SHUTDOWN] Received interrupt, stopping server...\n", .{});
        shutdown_flag.store(true, .release);
    } else if (sig == posix.SIG.HUP) {
        std.debug.print("\n[INFO] Configuration reload via SIGHUP is currently disabled; restart floos to apply changes.\n", .{});
    } else if (@hasDecl(posix.SIG, "USR1") and sig == posix.SIG.USR1) {
        diagnostics.flushEncryptStats("server", &encrypt_total_ns, &encrypt_calls);
    }
}

/// Reverse service listener - accepts connections and forwards through tunnel to client
const ReverseListener = struct {
    allocator: std.mem.Allocator,
    service: config.Service,
    listen_fd: posix.fd_t,
    thread: std.Thread,
    running: std.atomic.Value(bool),
    tunnel_conn: *TunnelConnection,
    thread_joined: std.atomic.Value(bool),

    fn create(
        allocator: std.mem.Allocator,
        service: config.Service,
        tunnel_conn: *TunnelConnection,
    ) !*ReverseListener {
        const addr = try resolveHostPort(service.address, service.port);
        const listen_fd = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(listen_fd);

        const reuse: c_int = 1;
        try posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(reuse));
        try posix.bind(listen_fd, &addr.any, addr.getOsSockLen());
        try posix.listen(listen_fd, common.LISTEN_BACKLOG);

        const listener = try allocator.create(ReverseListener);
        listener.* = .{
            .allocator = allocator,
            .service = service,
            .listen_fd = listen_fd,
            .thread = undefined,
            .running = std.atomic.Value(bool).init(true),
            .tunnel_conn = tunnel_conn,
            .thread_joined = std.atomic.Value(bool).init(false),
        };

        listener.thread = try std.Thread.spawn(.{
            .stack_size = common.DEFAULT_THREAD_STACK,
        }, acceptorThread, .{listener});

        std.debug.print("[REVERSE] Listening on {s}:{} for service '{s}' (id={})\n", .{
            service.address,
            service.port,
            service.name,
            service.id,
        });

        return listener;
    }

    fn acceptorThread(self: *ReverseListener) void {
        while (self.running.load(.acquire)) {
            if (!self.tunnel_conn.running.load(.acquire)) break;
            const client_fd = posix.accept(self.listen_fd, null, null, posix.SOCK.CLOEXEC) catch |err| {
                if (err == error.Interrupted) continue;
                std.debug.print("[REVERSE] Accept error on {s}:{}: {}\n", .{ self.service.address, self.service.port, err });
                break;
            };

            std.debug.print("[REVERSE] Accepted connection on {s}:{}\n", .{ self.service.address, self.service.port });

            // Allocate stream ID
            const stream_id = self.tunnel_conn.next_stream_id.fetchAdd(1, .acq_rel);

            // Send REVERSE_CONNECT to client
            const msg = tunnel.ReverseConnectMsg{
                .service_id = self.service.id,
                .stream_id = stream_id,
            };

            var encode_buf: [64]u8 = undefined;
            const encoded_len = msg.encodeInto(&encode_buf) catch {
                std.debug.print("[REVERSE] Failed to encode REVERSE_CONNECT\n", .{});
                posix.close(client_fd);
                continue;
            };

            self.tunnel_conn.sendEncryptedMessage(encode_buf[0..encoded_len]) catch |err| {
                std.debug.print("[REVERSE] Failed to send REVERSE_CONNECT: {}\n", .{err});
                posix.close(client_fd);
                continue;
            };

            std.debug.print("[REVERSE] Sent REVERSE_CONNECT service_id={} stream_id={}\n", .{ self.service.id, stream_id });

            // Create Stream for this connection
            const stream = Stream.create(self.allocator, self.service.id, stream_id, client_fd, self.tunnel_conn) catch |err| {
                std.debug.print("[REVERSE] Failed to create stream: {}\n", .{err});
                posix.close(client_fd);
                continue;
            };

            // Add stream to tunnel's streams map (CRITICAL for reverse routing)
            const key = StreamKey{ .service_id = self.service.id, .stream_id = stream_id };
            self.tunnel_conn.streams_mutex.lock();
            defer self.tunnel_conn.streams_mutex.unlock();

            stream.acquireRef(); // map reference
            self.tunnel_conn.streams.put(key, stream) catch |err| {
                std.debug.print("[REVERSE] Failed to register stream: {}\n", .{err});
                stream.releaseRef(); // undo map reference
                stream.stop();
                continue;
            };

            std.debug.print("[REVERSE] Stream {} registered and ready\n", .{stream_id});
        }

        std.debug.print("[REVERSE] Acceptor thread for {s}:{} exiting\n", .{ self.service.address, self.service.port });
    }

    fn stop(self: *ReverseListener) void {
        if (self.thread_joined.swap(true, .acq_rel)) return;
        self.running.store(false, .release);
        posix.shutdown(self.listen_fd, .recv) catch {};
        self.thread.join();
        posix.close(self.listen_fd);
    }

    fn destroy(self: *ReverseListener) void {
        self.allocator.destroy(self);
    }
};

fn stopAllReverseListeners(list: *std.ArrayListUnmanaged(*ReverseListener)) void {
    for (list.items) |listener| {
        listener.stop();
        listener.destroy();
    }
    list.clearRetainingCapacity();
}

/// Represents a forwarding stream (tunnel -> target)
const Stream = struct {
    service_id: tunnel.ServiceId,
    stream_id: tunnel.StreamId,
    target_fd: posix.fd_t,
    tunnel: *TunnelConnection,
    thread: std.Thread,
    running: std.atomic.Value(bool),
    fd_closed: std.atomic.Value(bool), // Track if target_fd is closed
    ref_count: std.atomic.Value(usize),
    thread_joined: std.atomic.Value(bool),

    fn create(allocator: std.mem.Allocator, service_id: tunnel.ServiceId, stream_id: tunnel.StreamId, target_fd: posix.fd_t, tunnel_conn: *TunnelConnection) !*Stream {
        const stream = try allocator.create(Stream);
        stream.* = .{
            .service_id = service_id,
            .stream_id = stream_id,
            .target_fd = target_fd,
            .tunnel = tunnel_conn,
            .thread = undefined,
            .running = std.atomic.Value(bool).init(true),
            .fd_closed = std.atomic.Value(bool).init(false),
            .ref_count = std.atomic.Value(usize).init(1), // owned by worker thread
            .thread_joined = std.atomic.Value(bool).init(false),
        };

        // Spawn thread to handle target -> tunnel forwarding
        stream.thread = try std.Thread.spawn(.{
            .stack_size = common.DEFAULT_THREAD_STACK,
        }, streamThreadMain, .{stream});

        return stream;
    }

    fn acquireRef(self: *Stream) void {
        _ = self.ref_count.fetchAdd(1, .acq_rel);
    }

    fn releaseRef(self: *Stream) void {
        const previous = self.ref_count.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous == 1) {
            self.destroyInternal();
        }
    }

    fn destroyInternal(self: *Stream) void {
        global_allocator.destroy(self);
    }

    fn streamThreadMain(self: *Stream) void {
        var buf: [common.SOCKET_BUFFER_SIZE]u8 align(64) = undefined;
        var frame_buf: [70016]u8 align(64) = undefined; // Buffer for framing + tag
        const message_header_len: usize = 7;

        std.debug.print("[STREAM {}] Thread started, reading from target fd={}\n", .{ self.stream_id, self.target_fd });

        // Ensure we remove ourselves from the HashMap on exit and drop references
        defer {
            const key = StreamKey{ .service_id = self.service_id, .stream_id = self.stream_id };
            var released_map_ref = false;
            self.tunnel.streams_mutex.lock();
            if (self.tunnel.streams.remove(key)) {
                released_map_ref = true;
            }
            self.tunnel.streams_mutex.unlock();
            if (released_map_ref) {
                self.releaseRef(); // drop map-held reference
            }
            std.debug.print("[STREAM {}] Removed from streams map\n", .{self.stream_id});
            self.releaseRef(); // drop worker-thread reference
        }

        while (self.running.load(.acquire)) {
            // Blocking read from target
            const recv_slice: []u8 = if (self.tunnel.encryption_enabled) &buf else frame_buf[message_header_len..];
            const n = posix.recv(self.target_fd, recv_slice, 0) catch |err| {
                std.debug.print("[STREAM {}] recv() error: {}\n", .{ self.stream_id, err });
                break;
            };
            tracePrint(enable_stream_trace, "[STREAM {}] recv() returned {} bytes\n", .{ self.stream_id, n });
            if (n == 0) {
                std.debug.print("[STREAM {}] EOF from target, sending CLOSE\n", .{self.stream_id});
                // Send CLOSE message to peer (no allocation - use stack buffer)
                const close_msg = tunnel.CloseMsg{ .service_id = self.service_id, .stream_id = self.stream_id };

                var encode_buf: [16]u8 = undefined; // CLOSE is 7 bytes
                const encoded_len = close_msg.encodeInto(&encode_buf) catch break;
                self.tunnel.sendEncryptedMessage(encode_buf[0..encoded_len]) catch |err| {
                    self.tunnel.handleSendFailure(err);
                };
                break; // EOF
            }

            if (!self.tunnel.encryption_enabled) {
                frame_buf[0] = @intFromEnum(tunnel.MessageType.data);
                std.mem.writeInt(u16, frame_buf[1..3], self.service_id, .big);
                std.mem.writeInt(u32, frame_buf[3..7], self.stream_id, .big);

                self.tunnel.sendPlainFrame(frame_buf[0 .. message_header_len + n]) catch |err| {
                    std.debug.print("[STREAM {}] send() error: {}\n", .{ self.stream_id, err });
                    self.tunnel.handleSendFailure(err);
                    break;
                };
                continue;
            }

            // Encode DATA message directly into frame buffer
            const data_msg = tunnel.DataMsg{ .service_id = self.service_id, .stream_id = self.stream_id, .data = buf[0..n] };
            const encoded_len = data_msg.encodeInto(frame_buf[0..]) catch break;

            self.tunnel.send_mutex.lock();
            const encrypted_len = encoded_len + noise.TAG_LEN;

            if (self.tunnel.send_cipher) |*cipher| {
                const start_ns = std.time.nanoTimestamp();
                cipher.encrypt(frame_buf[0..encoded_len], frame_buf[0..encrypted_len]) catch |err| {
                    std.debug.print("[STREAM {}] Encryption error: {}\n", .{ self.stream_id, err });
                    self.tunnel.send_mutex.unlock();
                    break;
                };
                const end_ns = std.time.nanoTimestamp();
                const delta = @as(u64, @intCast(end_ns - start_ns));
                _ = encrypt_total_ns.fetchAdd(delta, .acq_rel);
                _ = encrypt_calls.fetchAdd(1, .acq_rel);
            } else {
                std.debug.print("[STREAM {}] Missing send cipher, closing stream\n", .{self.stream_id});
                self.tunnel.send_mutex.unlock();
                break;
            }

            self.tunnel.writeFrameLocked(frame_buf[0..encrypted_len]) catch |err| {
                std.debug.print("[STREAM {}] send() error: {}\n", .{ self.stream_id, err });
                self.tunnel.handleSendFailure(err);
                self.tunnel.send_mutex.unlock();
                break;
            };
            self.tunnel.send_mutex.unlock();
        }

        // Cleanup
        std.debug.print("[STREAM {}] Thread exiting\n", .{self.stream_id});

        // Atomically mark fd as closed before actually closing it
        self.fd_closed.store(true, .release);
        posix.close(self.target_fd);
    }

    fn stop(self: *Stream) void {
        if (self.thread_joined.swap(true, .acq_rel)) return;
        self.running.store(false, .release);
        // Shutdown socket to unblock recv() call in thread (only if not already closed)
        if (!self.fd_closed.load(.acquire)) {
            posix.shutdown(self.target_fd, .recv) catch {};
        }
        self.thread.join();
    }
};

/// Tunnel connection handler (one per client connection)
const TunnelConnection = struct {
    tunnel_fd: posix.fd_t,
    streams: std.HashMap(StreamKey, *Stream, StreamKeyContext, 80),
    streams_mutex: std.Thread.Mutex,
    send_mutex: std.Thread.Mutex, // Protect tunnel sends from multiple stream threads
    send_cipher: ?noise.TransportCipher,
    recv_cipher: ?noise.TransportCipher,
    encryption_enabled: bool,
    decrypt_buffer: []u8,
    running: std.atomic.Value(bool),

    // Pre-allocated buffer for control messages (avoid per-frame allocation)
    control_msg_buffer: [common.CONTROL_MSG_BUFFER_SIZE]u8,
    control_msg_mutex: std.Thread.Mutex,

    // UDP support (only one forwarder per tunnel connection)
    udp_forwarder: ?*udp_server.UdpForwarder,
    udp_service_id: ?tunnel.ServiceId,

    // Heartbeat support
    heartbeat_interval_ms: u32, // Heartbeat interval in milliseconds (0 = disabled)
    heartbeat_thread: ?std.Thread, // Heartbeat sender thread

    // Stream ID allocation for reverse services
    next_stream_id: std.atomic.Value(u32),

    // Config reference for TCP tuning
    cfg: *const config.ServerConfig,

    /// Heartbeat thread: periodically sends heartbeat messages to client
    fn heartbeatThreadMain(self: *TunnelConnection) void {
        std.debug.print("[HEARTBEAT] Thread started (interval: {}ms)\n", .{self.heartbeat_interval_ms});

        while (self.running.load(.acquire)) {
            // Sleep in 100ms increments to allow quick shutdown
            const total_sleep_ms = self.heartbeat_interval_ms;
            const sleep_increment_ms = 100;
            var slept_ms: u32 = 0;

            while (slept_ms < total_sleep_ms and self.running.load(.acquire)) {
                const remaining_ms = total_sleep_ms - slept_ms;
                const this_sleep_ms = @min(sleep_increment_ms, remaining_ms);
                std.Thread.sleep(@as(u64, this_sleep_ms) * std.time.ns_per_ms);
                slept_ms += this_sleep_ms;
            }

            // Check if still running (may have been stopped during sleep)
            if (!self.running.load(.acquire)) break;

            // Send heartbeat message
            const timestamp = std.time.milliTimestamp();
            const heartbeat_msg = tunnel.HeartbeatMsg{ .timestamp = timestamp };

            var encode_buf: [16]u8 = undefined; // Heartbeat is 9 bytes
            const encoded_len = heartbeat_msg.encodeInto(&encode_buf) catch {
                std.debug.print("[HEARTBEAT] Encode error\n", .{});
                continue;
            };

            self.sendEncryptedMessage(encode_buf[0..encoded_len]) catch |err| {
                std.debug.print("[HEARTBEAT] Send error: {}\n", .{err});
                // Continue trying even if send fails
            };

            tracePrint(enable_tunnel_trace, "[HEARTBEAT] Sent at timestamp {}\n", .{timestamp});
        }

        std.debug.print("[HEARTBEAT] Thread exiting\n", .{});
    }

    fn create(allocator: std.mem.Allocator, tunnel_fd: posix.fd_t, cfg: *const config.ServerConfig, static_keypair: std.crypto.dh.X25519.KeyPair) !*TunnelConnection {
        setSockOpts(tunnel_fd, cfg);

        const canonical_cipher = config.canonicalCipher(cfg);
        const encryption_enabled = !std.mem.eql(u8, canonical_cipher, "none");

        var tunnel_fd_owned = true;
        errdefer if (tunnel_fd_owned) posix.close(tunnel_fd);

        var send_cipher: ?noise.TransportCipher = null;
        var recv_cipher: ?noise.TransportCipher = null;
        var decrypt_buffer: []u8 = &[_]u8{};
        errdefer if (decrypt_buffer.len != 0) allocator.free(decrypt_buffer);

        if (encryption_enabled) {
            const cipher_type = noise.CipherType.fromString(canonical_cipher) catch {
                std.debug.print("[NOISE] Invalid cipher '{s}' in configuration\n", .{cfg.cipher});
                return error.InvalidCipher;
            };

            // Perform Noise_XX handshake (server is responder, uses persistent static key)
            const handshake = noise.noiseXXHandshake(tunnel_fd, cipher_type, false, static_keypair, cfg.psk) catch |err| switch (err) {
                error.MissingPsk => {
                    std.debug.print("[NOISE] PSK must be configured when encryption is enabled\n", .{});
                    return err;
                },
                else => return error.HandshakeFailed,
            };

            send_cipher = handshake.send_cipher;
            recv_cipher = handshake.recv_cipher;

            decrypt_buffer = try allocator.alloc(u8, protocol.MAX_FRAME_SIZE);

            // Exchange version information after successful handshake
            // Server receives client version first
            var frame_buf: [256]u8 = undefined;
            var frame_offset: usize = 0;

            // Read frame header (4 bytes)
            while (frame_offset < 4) {
                const n = try posix.recv(tunnel_fd, frame_buf[frame_offset..], 0);
                if (n == 0) return error.ConnectionClosed;
                frame_offset += n;
            }

            const frame_len = std.mem.readInt(u32, frame_buf[0..4], .big);
            if (frame_len > frame_buf.len - 4) return error.FrameTooLarge;

            // Read frame payload
            while (frame_offset < 4 + frame_len) {
                const n = try posix.recv(tunnel_fd, frame_buf[frame_offset..], 0);
                if (n == 0) return error.ConnectionClosed;
                frame_offset += n;
            }

            // Decrypt client version
            var decrypted_version: [128]u8 = undefined;
            const decrypted_len = frame_len - noise.TAG_LEN;
            try recv_cipher.?.decrypt(frame_buf[4 .. 4 + frame_len], decrypted_version[0..decrypted_len]);

            // Parse version message
            const client_version_msg = try tunnel.VersionMsg.decode(decrypted_version[0..decrypted_len], allocator);
            defer allocator.free(client_version_msg.version);

            // Check version compatibility
            if (!std.mem.eql(u8, client_version_msg.version, build_options.version)) {
                std.debug.print("[ERROR] Version mismatch: server={s}, client={s}\n", .{ build_options.version, client_version_msg.version });
                std.debug.print("[ERROR] Rejecting connection - versions must match\n", .{});
                return error.VersionMismatch;
            }

            std.debug.print("[SERVER] Version check passed: {s}\n", .{build_options.version});

            // Send our version to client
            const server_version_msg = tunnel.VersionMsg{ .version = build_options.version };
            var version_buf: [64]u8 = undefined;
            const version_len = try server_version_msg.encodeInto(&version_buf);

            // Encrypt and send our version
            var encrypted_version: [128]u8 = undefined;
            const encrypted_len = version_len + noise.TAG_LEN;
            try send_cipher.?.encrypt(version_buf[0..version_len], encrypted_version[0..encrypted_len]);

            // Write frame directly (no mutex needed during handshake)
            var frame_header: [4]u8 = undefined;
            std.mem.writeInt(u32, &frame_header, @intCast(encrypted_len), .big);
            try common.sendAllToFd(tunnel_fd, &frame_header);
            try common.sendAllToFd(tunnel_fd, encrypted_version[0..encrypted_len]);
        }

        const conn = try allocator.create(TunnelConnection);

        // Initialize struct with cipher state
        conn.* = .{
            .tunnel_fd = tunnel_fd,
            .streams = std.HashMap(StreamKey, *Stream, StreamKeyContext, 80).init(allocator),
            .streams_mutex = .{},
            .send_mutex = .{},
            .send_cipher = send_cipher,
            .recv_cipher = recv_cipher,
            .encryption_enabled = encryption_enabled,
            .decrypt_buffer = decrypt_buffer,
            .running = std.atomic.Value(bool).init(true),
            .control_msg_buffer = undefined, // Pre-allocated buffer for control messages
            .control_msg_mutex = .{},
            .udp_forwarder = null,
            .udp_service_id = null,
            .heartbeat_interval_ms = cfg.advanced.heartbeat_interval_seconds * 1000, // Convert to milliseconds
            .heartbeat_thread = null,
            .next_stream_id = std.atomic.Value(u32).init(1),
            .cfg = cfg,
        };
        tunnel_fd_owned = false;
        decrypt_buffer = &[_]u8{};

        // Spawn heartbeat thread if enabled
        if (conn.heartbeat_interval_ms > 0) {
            conn.heartbeat_thread = std.Thread.spawn(.{}, heartbeatThreadMain, .{conn}) catch |err| {
                conn.destroy();
                return err;
            };
            std.debug.print("[TUNNEL] Heartbeat enabled: sending every {} seconds\n", .{cfg.advanced.heartbeat_interval_seconds});
        }

        return conn;
    }

    fn setSockOpts(fd: posix.fd_t, cfg: *const config.ServerConfig) void {
        const tcp_options = common.TcpOptions{
            .nodelay = cfg.advanced.tcp_nodelay,
            .keepalive = cfg.advanced.tcp_keepalive,
            .keepalive_idle = cfg.advanced.tcp_keepalive_idle,
            .keepalive_interval = cfg.advanced.tcp_keepalive_interval,
            .keepalive_count = cfg.advanced.tcp_keepalive_count,
        };
        applyTcpOptions(fd, tcp_options);
        tuneSocketBuffers(fd, cfg.advanced.socket_buffer_size);
    }

    fn run(self: *TunnelConnection) void {
        var buf: [256 * 1024]u8 align(64) = undefined; // 256KB for better batching
        var decoder = protocol.FrameDecoder.init(global_allocator);
        defer decoder.deinit();

        // Check if decoder buffer was allocated
        if (decoder.buffer.len == 0) {
            std.debug.print("[TUNNEL] Failed to allocate decoder buffer!\n", .{});
            self.cleanup();
            self.running.store(false, .release);
            return;
        }

        std.debug.print("[TUNNEL] Connection handler started (buffer size: {})\n", .{decoder.buffer.len});

        while (self.running.load(.acquire) and !shutdown_flag.load(.acquire)) {
            // Blocking read from tunnel
            const n = posix.recv(self.tunnel_fd, &buf, 0) catch |err| {
                std.debug.print("[TUNNEL] Recv error: {}\n", .{err});
                break;
            };

            if (n == 0) {
                std.debug.print("[TUNNEL] Client disconnected\n", .{});
                break;
            }

            tracePrint(enable_tunnel_trace, "[TUNNEL] Received {} bytes from client\n", .{n});

            // Feed decoder
            decoder.feed(buf[0..n]) catch |err| {
                std.debug.print("[TUNNEL] Decoder feed error: {}\n", .{err});
                break;
            };

            // Process all complete frames
            while (decoder.decode() catch null) |frame_payload| {
                self.handleMessage(frame_payload) catch |err| {
                    std.debug.print("[TUNNEL] Handle message error: {}\n", .{err});
                    self.running.store(false, .release);
                    break;
                };
                if (!self.running.load(.acquire)) break;
            }

            if (!self.running.load(.acquire)) break;
        }

        std.debug.print("[TUNNEL] Connection handler stopping\n", .{});
        self.cleanup();
        self.running.store(false, .release);
    }

    fn handleMessage(self: *TunnelConnection, payload: []const u8) !void {
        if (payload.len == 0) return;

        var message_slice: []const u8 = payload;

        if (self.encryption_enabled) {
            if (payload.len < noise.TAG_LEN) return error.InvalidPayload;

            const decrypted_len = payload.len - noise.TAG_LEN;
            if (decrypted_len > self.decrypt_buffer.len) {
                return error.InvalidPayload;
            }

            // Decrypt with atomic nonce (no mutex needed) - use pointer capture
            const target = self.decrypt_buffer[0..decrypted_len];
            if (self.recv_cipher) |*cipher| {
                cipher.decrypt(payload, target) catch |err| {
                    std.debug.print("[TUNNEL] Decryption error: {} (len={})\n", .{ err, payload.len });
                    return err;
                };
            } else return error.CipherUnavailable;

            message_slice = target;
        }

        if (message_slice.len == 0) return;

        const msg_type: tunnel.MessageType = @enumFromInt(message_slice[0]);

        switch (msg_type) {
            .connect_ack => {
                // REVERSE MODE: Client acknowledged connection to local target
                const ack = try tunnel.ConnectAckMsg.decode(message_slice);
                tracePrint(enable_tunnel_trace, "[TUNNEL-REVERSE] CONNECT_ACK from client stream_id={}\n", .{ack.stream_id});
                // Connection established, stream thread will start forwarding
            },
            .connect => {
                const connect_msg = try tunnel.ConnectMsg.decode(message_slice, global_allocator);
                defer global_allocator.free(connect_msg.token);

                tracePrint(enable_tunnel_trace, "[TUNNEL] CONNECT request: service_id={} stream_id={}\n", .{
                    connect_msg.service_id,
                    connect_msg.stream_id,
                });

                self.handleConnect(connect_msg) catch |err| {
                    std.debug.print("[TUNNEL] Failed to connect: {}\n", .{err});
                    // Map error to error code
                    const error_code: tunnel.ErrorCode = switch (err) {
                        error.UnknownService => .unknown_service,
                        error.AuthenticationFailed => .authentication_failed,
                        error.ConnectionRefused => .connection_refused,
                        error.ConnectionTimedOut => .connection_timeout,
                        else => .internal_error,
                    };
                    // Send error response (no allocation - use stack buffer)
                    const error_msg = tunnel.ConnectErrorMsg{
                        .service_id = connect_msg.service_id,
                        .stream_id = connect_msg.stream_id,
                        .error_code = error_code,
                        .error_msg = "Connection failed",
                    };

                    var encode_buf: [128]u8 = undefined; // ERROR message with text
                    const encoded_len = error_msg.encodeInto(&encode_buf) catch return;

                    self.sendEncryptedMessage(encode_buf[0..encoded_len]) catch |send_err| {
                        self.handleSendFailure(send_err);
                    };
                };
            },
            .data => {
                const data_msg = try tunnel.DataMsg.decode(message_slice);

                const key = StreamKey{ .service_id = data_msg.service_id, .stream_id = data_msg.stream_id };
                var stream_ref: ?*Stream = null;

                self.streams_mutex.lock();
                if (self.streams.get(key)) |s| {
                    s.acquireRef();
                    stream_ref = s;
                }
                self.streams_mutex.unlock();

                if (stream_ref) |s| {
                    defer s.releaseRef();
                    if (!s.fd_closed.load(.acquire)) {
                        sendAllToFd(s.target_fd, data_msg.data) catch |err| {
                            std.debug.print("[STREAM {}] Send to target failed: {}\n", .{ data_msg.stream_id, err });
                        };
                    }
                }
            },
            .close => {
                const close_msg = try tunnel.CloseMsg.decode(message_slice);
                tracePrint(enable_tunnel_trace, "[TUNNEL] CLOSE service_id={} stream_id={}\n", .{ close_msg.service_id, close_msg.stream_id });

                const key = StreamKey{ .service_id = close_msg.service_id, .stream_id = close_msg.stream_id };
                self.streams_mutex.lock();
                const maybe_stream = self.streams.fetchRemove(key);
                self.streams_mutex.unlock();

                if (maybe_stream) |entry| {
                    // Stream still exists, stop and destroy it
                    // Note: The stream may have already removed itself, in which case this won't execute
                    entry.value.stop();
                    entry.value.releaseRef(); // drop map reference
                    std.debug.print("[TUNNEL] Stream {} cleaned up after CLOSE message\n", .{close_msg.stream_id});
                } else {
                    // Stream already cleaned itself up
                    tracePrint(enable_tunnel_trace, "[TUNNEL] Stream {} already removed (self-cleanup)\n", .{close_msg.stream_id});
                }
            },
            .udp_data => {
                const udp_msg = try tunnel.UdpDataMsg.decode(message_slice, global_allocator);
                defer global_allocator.free(udp_msg.source_addr);

                if (self.udp_forwarder) |forwarder| {
                    forwarder.handleUdpData(udp_msg) catch |err| {
                        std.debug.print("[UDP] Failed to forward: {}\n", .{err});
                    };
                } else {
                    std.debug.print("[UDP] Received UDP data but no forwarder exists\n", .{});
                }
            },
            .connect_error => {
                // REVERSE MODE: Client failed to connect to local target
                const err_msg = try tunnel.ConnectErrorMsg.decode(message_slice, global_allocator);
                defer global_allocator.free(err_msg.error_msg);
                std.debug.print("[TUNNEL-REVERSE] CONNECT_ERROR from client: stream_id={} error={s}\n", .{ err_msg.stream_id, err_msg.error_msg });

                const key = StreamKey{ .service_id = err_msg.service_id, .stream_id = err_msg.stream_id };
                self.streams_mutex.lock();
                const maybe_stream = self.streams.fetchRemove(key);
                self.streams_mutex.unlock();

                if (maybe_stream) |entry| {
                    entry.value.stop();
                    entry.value.releaseRef();
                    std.debug.print("[TUNNEL-REVERSE] Stream {} cleaned up after CONNECT_ERROR\n", .{err_msg.stream_id});
                }
            },
            .heartbeat => {
                // Server doesn't need to process heartbeat responses from client
                // (client -> server heartbeat is handled by client-side timeout logic)
                const heartbeat_msg = try tunnel.HeartbeatMsg.decode(message_slice);
                tracePrint(enable_tunnel_trace, "[HEARTBEAT] Received from client: timestamp={}\n", .{heartbeat_msg.timestamp});
            },
            .version => {
                // Version exchange happens during handshake only
                // Receiving it here would be unexpected, just ignore
                tracePrint(enable_tunnel_trace, "[SERVER] Unexpected VERSION message during operation (ignoring)\n", .{});
            },
            .reverse_connect => {
                // Server sends REVERSE_CONNECT, doesn't receive it
                // If we receive it, something is wrong - just ignore
                tracePrint(enable_tunnel_trace, "[SERVER] Unexpected REVERSE_CONNECT from client (ignoring)\n", .{});
            },
        }
    }

    fn handleConnect(self: *TunnelConnection, msg: tunnel.ConnectMsg) !void {
        const service_ptr = self.cfg.getServiceById(msg.service_id) orelse {
            std.debug.print("[AUTH] Unknown service_id={} stream_id={}\n", .{ msg.service_id, msg.stream_id });
            return error.UnknownService;
        };
        const service = service_ptr.*;

        // Verify authentication token
        const expected_token = if (service.token.len > 0) service.token else self.cfg.token;
        if (expected_token.len > 0) {
            // Use constant-time comparison to prevent timing attacks
            if (!common.constantTimeEqual(msg.token, expected_token)) {
                std.debug.print("[AUTH] Invalid token for service_id={} stream_id={}\n", .{ msg.service_id, msg.stream_id });
                return error.AuthenticationFailed;
            }
            std.debug.print("[AUTH] Token validated for service_id={} stream_id={}\n", .{ msg.service_id, msg.stream_id });
        }

        switch (service.transport) {
            .tcp => {
                const address = try resolveHostPort(service.address, service.port);
                const target_fd = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
                var target_fd_guard = true;
                defer if (target_fd_guard) posix.close(target_fd);

                setSockOpts(target_fd, self.cfg);

                try posix.connect(target_fd, &address.any, address.getOsSockLen());

                tracePrint(enable_stream_trace, "[STREAM {}] Connected to {s}:{}\n", .{ msg.stream_id, service.address, service.port });

                const stream = try Stream.create(global_allocator, msg.service_id, msg.stream_id, target_fd, self);
                target_fd_guard = false; // ownership transferred to Stream

                self.streams_mutex.lock();
                defer self.streams_mutex.unlock();

                const key = StreamKey{ .service_id = msg.service_id, .stream_id = msg.stream_id };
                stream.acquireRef(); // map reference
                self.streams.put(key, stream) catch |err| {
                    // Drop map ref before shutting down thread
                    stream.releaseRef();
                    stream.stop();
                    return err;
                };
            },
            .udp => {
                if (self.udp_forwarder == null) {
                    std.debug.print("[UDP] Creating UDP forwarder for target {s}:{}\n", .{ service.address, service.port });

                    const forwarder = try udp_server.UdpForwarder.create(
                        global_allocator,
                        msg.service_id,
                        service.address,
                        service.port,
                        @ptrCast(self),
                        sendEncryptedMessageWrapper,
                        self.cfg.advanced.udp_timeout_seconds,
                    );
                    self.udp_forwarder = forwarder;
                    self.udp_service_id = msg.service_id;
                } else if (self.udp_service_id) |service_id| {
                    if (service_id != msg.service_id) {
                        std.debug.print("[UDP] Forwarder already active for service_id={}, rejecting service_id={}\n", .{ service_id, msg.service_id });
                        return error.UdpForwarderBusy;
                    }
                } else {
                    self.udp_service_id = msg.service_id;
                }
            },
        }

        // Send ACK (no allocation - use stack buffer)
        const ack_msg = tunnel.ConnectAckMsg{ .service_id = msg.service_id, .stream_id = msg.stream_id };

        var encode_buf: [16]u8 = undefined; // ACK is 7 bytes
        const encoded_len = try ack_msg.encodeInto(&encode_buf);

        try self.sendEncryptedMessage(encode_buf[0..encoded_len]);
    }

    // Wrapper for UDP forwarder callback (converts opaque pointer back to TunnelConnection)
    fn sendEncryptedMessageWrapper(conn: *anyopaque, payload: []const u8) anyerror!void {
        const self: *TunnelConnection = @ptrCast(@alignCast(conn));
        try self.sendEncryptedMessage(payload);
    }

    /// Send plaintext frame (framing only, no encryption).
    /// NOTE: Similar implementation exists in client.zig. Consider unifying.
    fn sendPlainFrame(self: *TunnelConnection, payload: []const u8) !void {
        self.send_mutex.lock();
        defer self.send_mutex.unlock();

        self.writeFrameLocked(payload) catch |err| {
            self.handleSendFailure(err);
            return err;
        };
    }

    fn handleSendFailure(self: *TunnelConnection, err: anyerror) void {
        if (!self.running.load(.acquire)) return;
        std.debug.print("[TUNNEL] Send failure: {}\n", .{err});
        self.running.store(false, .release);
        posix.shutdown(self.tunnel_fd, .both) catch {};
    }

    /// Send all data to a file descriptor, looping until complete.
    /// Extracted to common.zig to eliminate duplication with client.zig.
    const sendAllToFd = common.sendAllToFd;

    /// Write length-prefixed frame using writev() for scatter-gather I/O.
    /// Extracted to common.zig to eliminate duplication with client.zig.
    fn writeFrameLocked(self: *TunnelConnection, payload: []const u8) !void {
        return common.writeFrameLocked(self.tunnel_fd, payload);
    }

    /// Encrypt a message payload and send it with frame length prefix.
    /// NOTE: Similar implementation exists in client.zig. Consider unifying.
    fn sendEncryptedMessage(self: *TunnelConnection, payload: []const u8) !void {
        if (!self.encryption_enabled) {
            try self.sendPlainFrame(payload);
            return;
        }

        self.control_msg_mutex.lock();
        defer self.control_msg_mutex.unlock();

        const encrypted_len = payload.len + noise.TAG_LEN;
        if (encrypted_len > self.control_msg_buffer.len) {
            return error.ControlMessageTooLarge;
        }

        @memcpy(self.control_msg_buffer[0..payload.len], payload);

        if (self.send_cipher) |*cipher| {
            const start_ns = std.time.nanoTimestamp();
            cipher.encrypt(self.control_msg_buffer[0..payload.len], self.control_msg_buffer[0..encrypted_len]) catch |err| {
                return err;
            };
            const end_ns = std.time.nanoTimestamp();
            const delta = @as(u64, @intCast(end_ns - start_ns));
            _ = encrypt_total_ns.fetchAdd(delta, .acq_rel);
            _ = encrypt_calls.fetchAdd(1, .acq_rel);
        } else {
            return error.CipherUnavailable;
        }

        self.send_mutex.lock();
        const send_result = self.writeFrameLocked(self.control_msg_buffer[0..encrypted_len]);
        self.send_mutex.unlock();
        send_result catch |err| {
            self.handleSendFailure(err);
            return err;
        };
    }

    fn cleanup(self: *TunnelConnection) void {
        // Stop heartbeat thread first
        if (self.heartbeat_thread) |thread| {
            self.running.store(false, .release); // Signal thread to stop
            thread.join();
        }

        // Stop and release all streams without holding the mutex during blocking calls
        while (true) {
            self.streams_mutex.lock();
            var iter = self.streams.iterator();
            const entry = iter.next();
            if (entry) |e| {
                const key_copy = e.key_ptr.*; // copy to avoid invalid pointer after remove
                const stream_ptr = e.value_ptr.*;
                _ = self.streams.remove(key_copy);
                self.streams_mutex.unlock();
                stream_ptr.stop();
                stream_ptr.releaseRef(); // drop map reference
            } else {
                self.streams_mutex.unlock();
                break;
            }
        }
        self.streams.deinit();

        if (self.udp_forwarder) |forwarder| {
            forwarder.stop();
            forwarder.destroy();
            self.udp_forwarder = null;
            self.udp_service_id = null;
        }

        if (self.decrypt_buffer.len > 0) {
            global_allocator.free(self.decrypt_buffer);
            self.decrypt_buffer = &[_]u8{};
        }

        posix.close(self.tunnel_fd);
    }

    fn destroy(self: *TunnelConnection) void {
        // Cleanup UDP forwarder if exists
        if (self.udp_forwarder) |forwarder| {
            forwarder.stop();
            forwarder.destroy();
            self.udp_forwarder = null;
            self.udp_service_id = null;
        }

        if (self.decrypt_buffer.len > 0) {
            global_allocator.free(self.decrypt_buffer);
        }
        global_allocator.destroy(self);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    global_allocator = allocator;
    defer diagnostics.flushEncryptStats("server", &encrypt_total_ns, &encrypt_calls);

    var exit_code: u8 = 0;
    defer if (exit_code != 0) posix.exit(exit_code);

    const args_list = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args_list);

    var parse_ctx = ParseContext{};
    var cli_opts = parseServerArgs(args_list, &parse_ctx) catch |err| {
        switch (err) {
            ParseError.UnknownFlag => {
                std.debug.print("error: unknown option '{s}'\n", .{parse_ctx.arg});
            },
            ParseError.MissingValue => {
                std.debug.print("error: missing value for option '{s}'\n", .{parse_ctx.arg});
            },
            ParseError.ConflictingMode => {
                std.debug.print("error: conflicting option '{s}'\n", .{parse_ctx.arg});
            },
            ParseError.TooManyPositionals => {
                std.debug.print("error: unexpected argument '{s}'\n", .{parse_ctx.arg});
            },
            ParseError.InvalidValue => {
                std.debug.print("error: invalid value for option '{s}'\n", .{parse_ctx.arg});
            },
        }
        printServerUsage();
        exit_code = 1;
        return;
    };

    config_path_global = cli_opts.config_path;

    switch (cli_opts.mode) {
        .help => {
            printServerUsage();
            return;
        },
        .version => {
            std.debug.print("floos {s}\n", .{build_options.version});
            return;
        },
        .doctor => {
            const ok = try runServerDoctor(allocator, &cli_opts);
            if (!ok) exit_code = 1;
            return;
        },
        .ping => {
            const ok = try runServerPing(allocator, &cli_opts);
            if (!ok) exit_code = 1;
            return;
        },
        .run => {},
    }

    var cfg = try loadServerConfigWithOverrides(allocator, &cli_opts);
    defer cfg.deinit();
    const port = cfg.port;

    const canonical_cipher = config.canonicalCipher(&cfg);
    if (std.mem.eql(u8, canonical_cipher, "none")) {
        std.debug.print("[WARN] Server encryption disabled; relying solely on tokens for authentication.\n", .{});
    } else if (cfg.psk.len == 0) {
        std.debug.print("[WARN] Server PSK is empty; clients will fail to handshake.\n", .{});
    } else if (std.mem.eql(u8, cfg.psk, config.DEFAULT_PSK)) {
        std.debug.print("[WARN] Server is using the placeholder PSK '{s}'. Update configs for production.\n", .{config.DEFAULT_PSK});
    }

    var default_token_required = false;
    var service_iter = cfg.services.valueIterator();
    while (service_iter.next()) |service| {
        if (service.token.len == 0) {
            default_token_required = true;
            break;
        }
    }

    if (default_token_required and cfg.token.len == 0) {
        std.debug.print("[WARN] Server default token is empty; unauthorized clients may connect.\n", .{});
    } else if (cfg.token.len > 0 and std.mem.eql(u8, cfg.token, config.DEFAULT_TOKEN)) {
        std.debug.print("[WARN] Server is using the placeholder token '{s}'. Change this before deployment.\n", .{config.DEFAULT_TOKEN});
    }

    std.debug.print("Floo Tunnel Server (floos-blocking)\n", .{});
    std.debug.print("====================================\n\n", .{});
    std.debug.print("[CONFIG] Port: {}\n", .{port});
    std.debug.print("[CONFIG] Mode: Blocking I/O + Threads\n", .{});
    std.debug.print("[CONFIG] Hot Reload: Disabled (restart floos to apply configuration changes)\n\n", .{});

    // Register signal handlers (POSIX only)
    if (builtin.target.os.tag != .windows and @hasDecl(posix, "Sigaction") and @hasDecl(posix, "sigaction")) {
        const sig_action = posix.Sigaction{
            .handler = .{ .handler = handleSignal },
            .mask = std.mem.zeroes(posix.sigset_t),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.INT, &sig_action, null);
        if (@hasDecl(posix.SIG, "HUP")) {
            posix.sigaction(posix.SIG.HUP, &sig_action, null); // Register SIGHUP for hot reload
        }
        if (@hasDecl(posix.SIG, "USR1")) {
            posix.sigaction(posix.SIG.USR1, &sig_action, null);
        }
        if (@hasDecl(posix.SIG, "PIPE")) {
            const ignore = posix.Sigaction{
                .handler = .{ .handler = posix.SIG.IGN },
                .mask = std.mem.zeroes(posix.sigset_t),
                .flags = 0,
            };
            posix.sigaction(posix.SIG.PIPE, &ignore, null);
        }
    }

    // Create listen socket
    const listen_addr = try resolveHostPort(cfg.bind, port);
    const listen_fd = try posix.socket(listen_addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(listen_fd);

    try posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    try posix.bind(listen_fd, &listen_addr.any, listen_addr.getOsSockLen());
    try posix.listen(listen_fd, common.LISTEN_BACKLOG);

    var addr_buf: [64]u8 = undefined;
    std.debug.print("[SERVER] Listening on {s}\n", .{formatAddress(listen_addr, &addr_buf)});
    std.debug.print("[READY] Server ready. Press Ctrl+C to stop.\n\n", .{});

    // Generate persistent static keypair for Noise XX authentication
    const static_keypair = std.crypto.dh.X25519.KeyPair.generate();

    const ConnectionEntry = struct {
        conn: *TunnelConnection,
        thread: std.Thread,
    };
    var connections = std.ArrayListUnmanaged(ConnectionEntry){};
    var reverse_listeners = std.ArrayListUnmanaged(*ReverseListener){};
    var reverse_listeners_conn: ?*TunnelConnection = null;
    defer {
        stopAllReverseListeners(&reverse_listeners);
        reverse_listeners.deinit(allocator);

        // Stop all connections
        for (connections.items) |entry| {
            entry.conn.running.store(false, .release);
            // Shutdown tunnel socket to unblock recv() in connection thread
            posix.shutdown(entry.conn.tunnel_fd, .recv) catch {};
        }
        // Wait for threads and cleanup
        for (connections.items) |entry| {
            entry.thread.join();
        }
        for (connections.items) |entry| {
            entry.conn.destroy();
        }
        connections.deinit(allocator);
    }

    // Accept loop
    while (!shutdown_flag.load(.acquire)) {
        // Reap completed connections
        var idx: usize = 0;
        while (idx < connections.items.len) {
            const entry = connections.items[idx];
            if (!entry.conn.running.load(.acquire)) {
                if (reverse_listeners_conn) |active_conn| {
                    if (active_conn == entry.conn) {
                        stopAllReverseListeners(&reverse_listeners);
                        reverse_listeners_conn = null;
                    }
                }
                entry.thread.join();
                entry.conn.destroy();
                _ = connections.swapRemove(idx);
                continue;
            }
            idx += 1;
        }

        // Accept with timeout (poll for shutdown and reload)
        var fds = [_]posix.pollfd{
            .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        const ready = posix.poll(&fds, 1000) catch continue; // 1s timeout
        if (ready == 0) continue; // Timeout, check flags

        const tunnel_fd = posix.accept(listen_fd, null, null, posix.SOCK.CLOEXEC) catch |err| {
            std.debug.print("[SERVER] Accept error: {}\n", .{err});
            continue;
        };

        std.debug.print("[SERVER] Accepted tunnel connection: fd={}\n", .{tunnel_fd});
        tuneSocketBuffers(tunnel_fd, cfg.advanced.socket_buffer_size);
        const tcp_options = common.TcpOptions{
            .nodelay = cfg.advanced.tcp_nodelay,
            .keepalive = cfg.advanced.tcp_keepalive,
            .keepalive_idle = cfg.advanced.tcp_keepalive_idle,
            .keepalive_interval = cfg.advanced.tcp_keepalive_interval,
            .keepalive_count = cfg.advanced.tcp_keepalive_count,
        };
        applyTcpOptions(tunnel_fd, tcp_options);

        // Create tunnel connection (shares static identity across all connections)
        const tunnel_conn = TunnelConnection.create(allocator, tunnel_fd, &cfg, static_keypair) catch |err| {
            std.debug.print("[SERVER] Failed to create tunnel: {}\n", .{err});
            posix.close(tunnel_fd);
            continue;
        };

        // Spawn thread for this connection
        const thread = try std.Thread.spawn(.{
            .stack_size = common.TUNNEL_THREAD_STACK,
        }, tunnelConnectionThread, .{tunnel_conn});

        connections.append(allocator, .{ .conn = tunnel_conn, .thread = thread }) catch |err| {
            std.debug.print("[SERVER] Failed to track connection: {}\n", .{err});
            tunnel_conn.running.store(false, .release);
            posix.shutdown(tunnel_conn.tunnel_fd, .recv) catch {};
            thread.join();
            tunnel_conn.destroy();
            continue;
        };

        // (Re)bind reverse service listeners to this tunnel if reverse mode is configured
        if (cfg.reverse_services.count() > 0) {
            if (reverse_listeners_conn) |_| {
                stopAllReverseListeners(&reverse_listeners);
                reverse_listeners_conn = null;
            }

            std.debug.print("[REVERSE] Starting {} reverse services on new tunnel...\n", .{cfg.reverse_services.count()});
            var rev_iter = cfg.reverse_services.valueIterator();
            while (rev_iter.next()) |service| {
                const listener = ReverseListener.create(allocator, service.*, tunnel_conn) catch |err| {
                    std.debug.print("[REVERSE] Failed to create listener for service '{s}': {}\n", .{ service.name, err });
                    continue;
                };

                reverse_listeners.append(allocator, listener) catch |err| {
                    std.debug.print("[REVERSE] Failed to track listener: {}\n", .{err});
                    listener.stop();
                    listener.destroy();
                    continue;
                };
            }

            if (reverse_listeners.items.len > 0) {
                reverse_listeners_conn = tunnel_conn;
                std.debug.print("[REVERSE] Reverse services bound to current tunnel connection\n", .{});
            }
        }
    }

    std.debug.print("\n[SHUTDOWN] Server stopped.\n", .{});
}

fn tunnelConnectionThread(conn: *TunnelConnection) void {
    conn.run();
    // Note: conn.destroy() is called by main thread on shutdown
}

/// Context for reverse service listener thread
const ReverseServiceListenerContext = struct {
    allocator: std.mem.Allocator,
    service_id: tunnel.ServiceId,
    listen_host: []const u8,
    listen_port: u16,
    tunnel_conn: *TunnelConnection,
    next_stream_id: std.atomic.Value(u32),
};

/// Reverse service listener thread - handles one reverse mode service
/// Listens on a public port, sends CONNECT to client when users connect
fn reverseServiceListener(ctx_ptr: *anyopaque) void {
    const ctx: *ReverseServiceListenerContext = @ptrCast(@alignCast(ctx_ptr));
    defer {
        ctx.allocator.free(ctx.listen_host);
        ctx.allocator.destroy(ctx);
    }

    // Create listener socket
    const local_addr = resolveHostPort(ctx.listen_host, ctx.listen_port) catch |err| {
        std.debug.print("[REVERSE-SERVICE] Failed to parse address for service_id={}: {}\n", .{ ctx.service_id, err });
        return;
    };

    const listen_fd = posix.socket(local_addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
        std.debug.print("[REVERSE-SERVICE] Failed to create socket for service_id={}: {}\n", .{ ctx.service_id, err });
        return;
    };
    defer posix.close(listen_fd);

    posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};

    posix.bind(listen_fd, &local_addr.any, local_addr.getOsSockLen()) catch |err| {
        std.debug.print("[REVERSE-SERVICE] Failed to bind service_id={} on port {}: {}\n", .{ ctx.service_id, ctx.listen_port, err });
        return;
    };

    posix.listen(listen_fd, common.LISTEN_BACKLOG) catch |err| {
        std.debug.print("[REVERSE-SERVICE] Failed to listen for service_id={}: {}\n", .{ ctx.service_id, err });
        return;
    };

    std.debug.print("[REVERSE-SERVICE] Listening on {s}:{} (service_id={}, reverse mode)\n", .{ ctx.listen_host, ctx.listen_port, ctx.service_id });

    // Accept loop
    while (!shutdown_flag.load(.acquire) and ctx.tunnel_conn.running.load(.acquire)) {
        // Poll for accept with timeout
        var fds = [_]posix.pollfd{
            .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        const ready = posix.poll(&fds, 1000) catch continue; // 1s timeout
        if (ready == 0) continue; // Timeout, check shutdown

        const user_fd = posix.accept(listen_fd, null, null, posix.SOCK.CLOEXEC) catch |err| {
            std.debug.print("[REVERSE-SERVICE] Accept error for service_id={}: {}\n", .{ ctx.service_id, err });
            continue;
        };

        // Generate stream_id
        const stream_id = ctx.next_stream_id.fetchAdd(1, .acq_rel);

        std.debug.print("[REVERSE-SERVICE] External user connected, sending CONNECT to client (service_id={}, stream_id={})\n", .{ ctx.service_id, stream_id });

        // Apply socket tuning
        TunnelConnection.setSockOpts(user_fd, ctx.tunnel_conn.cfg);

        // Send CONNECT message to client through tunnel
        const connect_msg = tunnel.ConnectMsg{
            .service_id = ctx.service_id,
            .stream_id = stream_id,
            .token = "",
        };

        var encode_buf: [512]u8 = undefined;
        const encoded_len = connect_msg.encodeInto(&encode_buf) catch {
            std.debug.print("[REVERSE-SERVICE] Failed to encode CONNECT message\n", .{});
            posix.close(user_fd);
            continue;
        };

        ctx.tunnel_conn.sendEncryptedMessage(encode_buf[0..encoded_len]) catch |err| {
            std.debug.print("[REVERSE-SERVICE] Failed to send CONNECT to client: {}\n", .{err});
            ctx.tunnel_conn.handleSendFailure(err);
            posix.close(user_fd);
            continue;
        };

        // Create Stream to forward user_socket <-> tunnel
        const stream = Stream.create(global_allocator, ctx.service_id, stream_id, user_fd, ctx.tunnel_conn) catch |err| {
            std.debug.print("[REVERSE-SERVICE] Failed to create stream: {}\n", .{err});
            posix.close(user_fd);
            continue;
        };

        ctx.tunnel_conn.streams_mutex.lock();
        const key = StreamKey{ .service_id = ctx.service_id, .stream_id = stream_id };
        stream.acquireRef();
        ctx.tunnel_conn.streams.put(key, stream) catch |err| {
            ctx.tunnel_conn.streams_mutex.unlock();
            std.debug.print("[REVERSE-SERVICE] Failed to register stream: {}\n", .{err});
            stream.releaseRef(); // undo map ref
            stream.stop();
            continue;
        };
        ctx.tunnel_conn.streams_mutex.unlock();

        std.debug.print("[REVERSE-SERVICE] Stream {} created for reverse connection\n", .{stream_id});
    }

    std.debug.print("[REVERSE-SERVICE] Service listener stopped for service_id={}\n", .{ctx.service_id});
}
