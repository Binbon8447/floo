const std = @import("std");
const posix = std.posix;
const build_options = @import("build_options");
const protocol = @import("protocol.zig");
const tunnel = @import("tunnel.zig");
const config = @import("config.zig");
const noise = @import("noise.zig");
const udp_client = @import("udp_client.zig");
const diagnostics = @import("diagnostics.zig");
const common = @import("common.zig");
const proxy = @import("proxy.zig");

const tracePrint = common.tracePrint;
const tcpOptionsFromSettings = common.tcpOptionsFromSettings;
const tuneSocketBuffers = common.tuneSocketBuffers;
const applyTcpOptions = common.applyTcpOptions;
const TcpOptions = common.TcpOptions;
const formatAddress = common.formatAddress;
const resolveHostPort = common.resolveHostPort;

const CheckStatus = diagnostics.CheckStatus;

const DEFAULT_CONFIG_PATH = "flooc.toml";
const enable_tunnel_trace = false;
const enable_listener_trace = false;

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
    local_port_override: ?u16 = null,
    remote_host_override: ?[]const u8 = null,
    remote_port_override: ?u16 = null,
    proxy_url_override: ?[]const u8 = null,

    fn deinit(self: *CliOptions, allocator: std.mem.Allocator) void {
        if (self.remote_host_override) |host| allocator.free(host);
        if (self.proxy_url_override) |url| allocator.free(url);
    }
};

const ParseError = error{ UnknownFlag, MissingValue, ConflictingMode, TooManyPositionals, InvalidValue, OutOfMemory };

const ParseContext = struct {
    arg: []const u8 = "",
};

const CLIENT_USAGE =
    \\Usage: flooc [options] [config_path]
    \\Options:
    \\  -h, --help                 Show this help message and exit
    \\  -V, --version              Show version information and exit
    \\      --doctor              Run diagnostics using the provided config and exit
    \\      --ping                Measure handshake latency to the remote server and exit
    \\  -l, --local PORT          Override local listener port
    \\  -r, --remote HOST[:PORT]  Override remote server address
    \\  -x, --proxy URL           Connect via proxy (socks5://host:port or http://host:port)
    \\  config_path               Optional path to flooc.toml (defaults to ./flooc.toml)
    \\Examples:
    \\  flooc --ping
    \\  flooc --doctor custom-configs/client.toml
    \\  flooc -r tunnel.example.com:8443 --ping
    \\  flooc -x socks5://127.0.0.1:1080 --ping
    \\  flooc -x http://user:pass@proxy.corp.com:8080
    \\
;

fn printClientUsage() void {
    std.debug.print("{s}", .{CLIENT_USAGE});
}

fn setStringOverride(slot: *?[]const u8, allocator: std.mem.Allocator, value: []const u8) !void {
    if (slot.*) |prev| {
        allocator.free(prev);
    }
    slot.* = try allocator.dupe(u8, value);
}

fn setMode(opts: *CliOptions, new_mode: CliMode, ctx: *ParseContext, arg: []const u8) ParseError!void {
    if (opts.mode != .run and opts.mode != new_mode) {
        ctx.arg = arg;
        return ParseError.ConflictingMode;
    }
    opts.mode = new_mode;
}

fn parseHostPortOption(
    allocator: std.mem.Allocator,
    value: []const u8,
    host_slot: *?[]const u8,
    port_slot: *?u16,
    ctx: *ParseContext,
    flag: []const u8,
) ParseError!void {
    if (value.len == 0) {
        ctx.arg = flag;
        return ParseError.InvalidValue;
    }

    if (value[0] == '[') {
        const close_idx = std.mem.indexOfScalar(u8, value, ']') orelse {
            ctx.arg = flag;
            return ParseError.InvalidValue;
        };
        const host_part = value[1..close_idx];
        if (close_idx + 1 >= value.len or value[close_idx + 1] != ':') {
            ctx.arg = flag;
            return ParseError.InvalidValue;
        }
        const port_str = value[close_idx + 2 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch {
            ctx.arg = flag;
            return ParseError.InvalidValue;
        };
        try setStringOverride(host_slot, allocator, host_part);
        port_slot.* = port;
        return;
    }

    if (std.mem.indexOfScalar(u8, value, ':')) |colon_idx| {
        const host_part = value[0..colon_idx];
        const port_str = value[colon_idx + 1 ..];
        if (port_str.len == 0) {
            ctx.arg = flag;
            return ParseError.InvalidValue;
        }
        const port = std.fmt.parseInt(u16, port_str, 10) catch {
            ctx.arg = flag;
            return ParseError.InvalidValue;
        };
        try setStringOverride(host_slot, allocator, host_part);
        port_slot.* = port;
        return;
    }

    try setStringOverride(host_slot, allocator, value);
}

fn parseClientArgs(allocator: std.mem.Allocator, args_list: [][:0]u8, ctx: *ParseContext) ParseError!CliOptions {
    var opts = CliOptions{};
    errdefer opts.deinit(allocator);
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
        } else if (std.mem.eql(u8, arg, "--local") or std.mem.eql(u8, arg, "-l")) {
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
            opts.local_port_override = port;
        } else if (std.mem.eql(u8, arg, "--remote") or std.mem.eql(u8, arg, "-r")) {
            if (idx + 1 >= args_list.len) {
                ctx.arg = arg;
                return ParseError.MissingValue;
            }
            idx += 1;
            const value = std.mem.sliceTo(args_list[idx], 0);
            try parseHostPortOption(allocator, value, &opts.remote_host_override, &opts.remote_port_override, ctx, arg);
        } else if (std.mem.eql(u8, arg, "--proxy") or std.mem.eql(u8, arg, "-x")) {
            if (idx + 1 >= args_list.len) {
                ctx.arg = arg;
                return ParseError.MissingValue;
            }
            idx += 1;
            const value = std.mem.sliceTo(args_list[idx], 0);
            try setStringOverride(&opts.proxy_url_override, allocator, value);
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

fn applyClientOverrides(allocator: std.mem.Allocator, cfg: *config.ClientConfig, opts: *CliOptions) void {
    // Handle local port override for default service
    if (opts.local_port_override) |port| {
        if (cfg.default_service) |service_name| {
            if (cfg.services.getPtr(service_name)) |service| {
                service.port = port;
            }
        }
    }

    // Handle remote host/port override by rebuilding server string
    if (opts.remote_host_override != null or opts.remote_port_override != null) {
        const current_host = cfg.getServerHost() catch "localhost";
        const current_port = cfg.getServerPort() catch 8443;

        const new_host = opts.remote_host_override orelse current_host;
        const new_port = opts.remote_port_override orelse current_port;

        const new_server = std.fmt.allocPrint(allocator, "{s}:{d}", .{ new_host, new_port }) catch return;
        allocator.free(cfg.server);
        cfg.server = new_server;

        if (opts.remote_host_override) |_| {
            opts.remote_host_override = null;
        }
    }

    if (opts.proxy_url_override) |url| {
        allocator.free(cfg.advanced.proxy_url);
        cfg.advanced.proxy_url = url;
        opts.proxy_url_override = null;
    }
}

fn loadClientConfigWithOverrides(allocator: std.mem.Allocator, opts: *CliOptions) !config.ClientConfig {
    var cfg = try config.ClientConfig.loadFromFile(allocator, opts.config_path);
    errdefer cfg.deinit();
    applyClientOverrides(allocator, &cfg, opts);
    return cfg;
}

const PingResult = struct {
    remote_addr: std.net.Address,
    connect_ns: i128,
    handshake_ns: i128,
    total_ns: i128,
};

fn performClientPing(cfg: *const config.ClientConfig) !PingResult {
    const connect_start = std.time.nanoTimestamp();

    const remote_host = try cfg.getServerHost();
    const remote_port = try cfg.getServerPort();

    // Connect through proxy if configured
    var proxy_cfg_opt: ?proxy.ProxyConfig = null;
    if (cfg.advanced.proxy_url.len > 0) {
        proxy_cfg_opt = try proxy.ProxyConfig.parseUrl(global_allocator, cfg.advanced.proxy_url);
    }
    defer if (proxy_cfg_opt) |*p| p.deinit(global_allocator);

    const fd = try proxy.connectWithProxy(
        global_allocator,
        proxy_cfg_opt,
        remote_host,
        remote_port,
    );
    errdefer posix.close(fd);

    const connect_done = std.time.nanoTimestamp();

    const canonical_cipher = config.canonicalCipher(cfg);
    var handshake_ns: i128 = 0;
    if (!std.mem.eql(u8, canonical_cipher, "none")) {
        const cipher_type = noise.CipherType.fromString(canonical_cipher) catch return error.InvalidCipher;
        const static_keypair = std.crypto.dh.X25519.KeyPair.generate();
        const handshake_start = std.time.nanoTimestamp();
        const handshake = noise.noiseXXHandshake(fd, cipher_type, true, static_keypair, cfg.psk) catch |err| {
            return err;
        };
        const handshake_done = std.time.nanoTimestamp();
        handshake_ns = handshake_done - handshake_start;

        // Version check (using handshake ciphers)
        var send_cipher = handshake.send_cipher;
        var recv_cipher = handshake.recv_cipher;

        // Send our version
        const version_msg = tunnel.VersionMsg{ .version = build_options.version };
        var version_buf: [64]u8 = undefined;
        const version_len = try version_msg.encodeInto(&version_buf);

        var encrypted_version: [128]u8 = undefined;
        const encrypted_len = version_len + noise.TAG_LEN;
        try send_cipher.encrypt(version_buf[0..version_len], encrypted_version[0..encrypted_len]);

        // Write frame directly (no mutex during handshake)
        var frame_header: [4]u8 = undefined;
        std.mem.writeInt(u32, &frame_header, @intCast(encrypted_len), .big);
        try common.sendAllToFd(fd, &frame_header);
        try common.sendAllToFd(fd, encrypted_version[0..encrypted_len]);

        // Receive server version
        var frame_buf: [256]u8 = undefined;
        var frame_offset: usize = 0;

        while (frame_offset < 4) {
            const n = try posix.recv(fd, frame_buf[frame_offset..], 0);
            if (n == 0) return error.ConnectionClosed;
            frame_offset += n;
        }

        const frame_len = std.mem.readInt(u32, frame_buf[0..4], .big);
        if (frame_len > frame_buf.len - 4) return error.FrameTooLarge;

        while (frame_offset < 4 + frame_len) {
            const n = try posix.recv(fd, frame_buf[frame_offset..], 0);
            if (n == 0) return error.ConnectionClosed;
            frame_offset += n;
        }

        var decrypted_version: [128]u8 = undefined;
        const decrypted_len = frame_len - noise.TAG_LEN;
        try recv_cipher.decrypt(frame_buf[4 .. 4 + frame_len], decrypted_version[0..decrypted_len]);

        const server_version_msg = try tunnel.VersionMsg.decode(decrypted_version[0..decrypted_len], global_allocator);
        defer global_allocator.free(server_version_msg.version);

        if (!std.mem.eql(u8, server_version_msg.version, build_options.version)) {
            std.debug.print("[PING] Version mismatch: client={s}, server={s}\n", .{ build_options.version, server_version_msg.version });
            posix.close(fd);
            return error.VersionMismatch;
        }

        const total_ns = std.time.nanoTimestamp() - connect_start;
        posix.close(fd);
        const remote_addr = try std.net.Address.resolveIp(remote_host, remote_port);
        return .{
            .remote_addr = remote_addr,
            .connect_ns = connect_done - connect_start,
            .handshake_ns = handshake_ns,
            .total_ns = total_ns,
        };
    } else {
        posix.close(fd);
        const remote_addr = try std.net.Address.resolveIp(remote_host, remote_port);
        return .{
            .remote_addr = remote_addr,
            .connect_ns = connect_done - connect_start,
            .handshake_ns = 0,
            .total_ns = connect_done - connect_start,
        };
    }
}

const ServiceBinding = struct {
    host: []const u8,
    port: u16,
    token: []const u8,
};

fn getServiceBinding(cfg: *const config.ClientConfig, service_id: tunnel.ServiceId) !ServiceBinding {
    if (cfg.getServiceById(service_id)) |svc| {
        return .{
            .host = svc.address,
            .port = svc.port,
            .token = if (svc.token.len > 0) svc.token else cfg.token,
        };
    }
    return error.UnknownService;
}

fn runClientPing(allocator: std.mem.Allocator, opts: *CliOptions) !bool {
    var cfg = try loadClientConfigWithOverrides(allocator, opts);
    defer cfg.deinit();

    const host = try cfg.getServerHost();
    const port = try cfg.getServerPort();
    std.debug.print("Pinging {s}:{d}...\n", .{ host, port });
    const result = performClientPing(&cfg) catch |err| {
        diagnostics.reportCheck(.fail, "Connection attempt failed: {}", .{err});
        return false;
    };

    var addr_buf: [64]u8 = undefined;
    const addr_str = formatAddress(result.remote_addr, &addr_buf);

    const connect_ms = @as(f64, @floatFromInt(result.connect_ns)) / @as(f64, std.time.ns_per_ms);
    const handshake_ms = @as(f64, @floatFromInt(result.handshake_ns)) / @as(f64, std.time.ns_per_ms);
    const total_ms = @as(f64, @floatFromInt(result.total_ns)) / @as(f64, std.time.ns_per_ms);

    diagnostics.reportCheck(.ok, "Connected to {s}", .{addr_str});
    const canonical_cipher = config.canonicalCipher(&cfg);
    if (result.handshake_ns > 0) {
        diagnostics.reportCheck(.ok, "Handshake completed using cipher '{s}'", .{canonical_cipher});
        diagnostics.reportCheck(.ok, "Version check passed: {s}", .{build_options.version});
        std.debug.print("    connect:  {d:.2} ms\n", .{connect_ms});
        std.debug.print("    handshake:{d:.2} ms\n", .{handshake_ms});
        std.debug.print("    total:    {d:.2} ms\n", .{total_ms});
    } else {
        diagnostics.reportCheck(.warn, "Encryption disabled; only TCP connectivity verified", .{});
        std.debug.print("    connect:  {d:.2} ms\n", .{connect_ms});
    }
    return true;
}

fn runClientDoctor(allocator: std.mem.Allocator, opts: *CliOptions) !bool {
    std.debug.print("Floo Client Doctor\n===================\n", .{});

    var config_exists = true;
    std.fs.cwd().access(opts.config_path, .{}) catch {
        config_exists = false;
    };

    if (config_exists) {
        diagnostics.reportCheck(.ok, "Config file accessible at {s}", .{opts.config_path});
    } else {
        diagnostics.reportCheck(.warn, "Config file {s} not found; defaults will be used", .{opts.config_path});
    }

    var cfg = loadClientConfigWithOverrides(allocator, opts) catch |err| {
        diagnostics.reportCheck(.fail, "Failed to load config: {}", .{err});
        return false;
    };
    defer cfg.deinit();

    var had_fail = false;

    diagnostics.reportCheck(.ok, "Configuration parsed (services: {})", .{cfg.services.count()});
    diagnostics.reportCheck(.ok, "Client version: {s}", .{build_options.version});
    if (std.mem.eql(u8, cfg.psk, config.DEFAULT_PSK)) {
        diagnostics.reportCheck(.warn, "Using default PSK; replace with secret for production", .{});
    }
    if (cfg.token.len == 0 or std.mem.eql(u8, cfg.token, config.DEFAULT_TOKEN)) {
        diagnostics.reportCheck(.warn, "Default token is unset or placeholder; tighten authentication", .{});
    }

    const remote_host = try cfg.getServerHost();
    const remote_port = try cfg.getServerPort();
    const remote_addr = std.net.Address.resolveIp(remote_host, remote_port) catch |err| {
        diagnostics.reportCheck(.fail, "Unable to resolve remote {s}:{d}: {}", .{ remote_host, remote_port, err });
        return false;
    };
    var addr_buf: [64]u8 = undefined;
    diagnostics.reportCheck(.ok, "Remote {s}:{d} resolves to {s}", .{ remote_host, remote_port, formatAddress(remote_addr, &addr_buf) });

    // Check local service ports
    var service_iter = cfg.services.valueIterator();
    while (service_iter.next()) |service| {
        const local_addr = resolveHostPort(service.address, service.port) catch |err| {
            diagnostics.reportCheck(.warn, "Failed to parse address for service '{s}': {}", .{ service.name, err });
            continue;
        };
        const local_fd = posix.socket(local_addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
            diagnostics.reportCheck(.warn, "Failed to create socket for local port probe: {}", .{err});
            continue;
        };
        defer posix.close(local_fd);
        const reuse: c_int = 1;
        posix.setsockopt(local_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(reuse)) catch {};
        const bind_result = posix.bind(local_fd, &local_addr.any, local_addr.getOsSockLen());
        if (bind_result) |_| {
            diagnostics.reportCheck(.ok, "Local port {} available for service '{s}' on {s}", .{ service.port, service.name, service.address });
        } else |err| {
            if (err == error.AddressInUse) {
                diagnostics.reportCheck(.warn, "Local port {} for service '{s}' is already in use", .{ service.port, service.name });
                had_fail = true;
            } else {
                diagnostics.reportCheck(.warn, "Unable to probe local port {} for service '{s}': {}", .{ service.port, service.name, err });
            }
        }
    }

    const ping_result = performClientPing(&cfg) catch |err| {
        diagnostics.reportCheck(.fail, "Ping failed: {}", .{err});
        had_fail = true;
        std.debug.print("\nDiagnostics complete (with failures).\n", .{});
        return false;
    };
    const connect_ms = @as(f64, @floatFromInt(ping_result.connect_ns)) / @as(f64, std.time.ns_per_ms);
    const handshake_ms = @as(f64, @floatFromInt(ping_result.handshake_ns)) / @as(f64, std.time.ns_per_ms);

    diagnostics.reportCheck(.ok, "Ping succeeded (connect {d:.2} ms, handshake {d:.2} ms)", .{ connect_ms, handshake_ms });
    if (had_fail) {
        std.debug.print("\nDiagnostics complete (with warnings).\n", .{});
    } else {
        std.debug.print("\nDiagnostics complete.\n", .{});
    }
    return !had_fail;
}

fn handleSignal(sig: c_int) callconv(.c) void {
    if (sig == posix.SIG.INT or sig == posix.SIG.TERM) {
        std.debug.print("\n[SHUTDOWN] Received interrupt, stopping client...\n", .{});
        shutdown_flag.store(true, .release);
    } else if (sig == posix.SIG.HUP) {
        std.debug.print("\n[INFO] Configuration reload via SIGHUP is currently disabled; restart flooc to apply changes.\n", .{});
    } else if (@hasDecl(posix.SIG, "USR1") and sig == posix.SIG.USR1) {
        diagnostics.flushEncryptStats("client", &encrypt_total_ns, &encrypt_calls);
    }
}

/// Local connection being forwarded
const LocalConnection = struct {
    service_id: tunnel.ServiceId,
    stream_id: tunnel.StreamId,
    local_fd: posix.fd_t,
    tunnel: *TunnelClient,
    thread: std.Thread,
    running: std.atomic.Value(bool),
    fd_closed: std.atomic.Value(bool), // Track if local_fd is closed
    ref_count: std.atomic.Value(usize),
    thread_joined: std.atomic.Value(bool),

    fn create(allocator: std.mem.Allocator, service_id: tunnel.ServiceId, stream_id: tunnel.StreamId, local_fd: posix.fd_t, tunnel_client: *TunnelClient) !*LocalConnection {
        const conn = try allocator.create(LocalConnection);
        conn.* = .{
            .service_id = service_id,
            .stream_id = stream_id,
            .local_fd = local_fd,
            .tunnel = tunnel_client,
            .thread = undefined,
            .running = std.atomic.Value(bool).init(true),
            .fd_closed = std.atomic.Value(bool).init(false),
            .ref_count = std.atomic.Value(usize).init(1),
            .thread_joined = std.atomic.Value(bool).init(false),
        };

        // Spawn thread to handle local -> tunnel forwarding
        conn.thread = try std.Thread.spawn(.{
            .stack_size = common.DEFAULT_THREAD_STACK,
        }, localThreadMain, .{conn});

        return conn;
    }

    fn acquireRef(self: *LocalConnection) void {
        _ = self.ref_count.fetchAdd(1, .acq_rel);
    }

    fn releaseRef(self: *LocalConnection) void {
        const previous = self.ref_count.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous == 1) {
            self.destroyInternal();
        }
    }

    fn destroyInternal(self: *LocalConnection) void {
        global_allocator.destroy(self);
    }

    fn localThreadMain(self: *LocalConnection) void {
        var buf: [common.SOCKET_BUFFER_SIZE]u8 align(64) = undefined;
        var send_buf: [70016]u8 align(64) = undefined; // Buffer for framing + tag

        std.debug.print("[LOCAL {}] Thread started, reading from local fd={}\n", .{ self.stream_id, self.local_fd });

        // Ensure we remove ourselves from the HashMap on exit
        defer {
            var released_map_ref = false;
            self.tunnel.connections_mutex.lock();
            if (self.tunnel.connections.remove(self.stream_id)) {
                released_map_ref = true;
            }
            self.tunnel.connections_mutex.unlock();
            if (released_map_ref) {
                self.releaseRef(); // drop map-held ref
            }
            std.debug.print("[LOCAL {}] Removed from connections map\n", .{self.stream_id});
            self.releaseRef(); // drop worker ref
        }

        const message_header_len: usize = 7;
        while (self.running.load(.acquire)) {
            const recv_slice: []u8 = if (self.tunnel.encryption_enabled) &buf else send_buf[message_header_len..];

            // Blocking read from local connection
            const n = posix.recv(self.local_fd, recv_slice, 0) catch |err| {
                std.debug.print("[LOCAL {}] recv() error: {}\n", .{ self.stream_id, err });
                break;
            };
            // std.debug.print("[LOCAL {}] recv() returned {} bytes\n", .{ self.stream_id, n });
            if (n == 0) {
                std.debug.print("[LOCAL {}] EOF from local connection, sending CLOSE\n", .{self.stream_id});
                // Send CLOSE message to peer (no allocation - use stack buffer)
                const close_msg = tunnel.CloseMsg{ .service_id = self.service_id, .stream_id = self.stream_id };

                var encode_buf: [16]u8 = undefined; // CLOSE is 7 bytes (type:1 + service_id:2 + stream_id:4)
                const encoded_len = close_msg.encodeInto(&encode_buf) catch break;
                self.tunnel.sendEncryptedMessage(encode_buf[0..encoded_len]) catch |err| {
                    std.debug.print("[LOCAL {}] Failed to send CLOSE: {}\n", .{ self.stream_id, err });
                };
                break; // EOF
            }

            if (!self.tunnel.encryption_enabled) {
                send_buf[0] = @intFromEnum(tunnel.MessageType.data);
                std.mem.writeInt(u16, send_buf[1..3], self.service_id, .big);
                std.mem.writeInt(u32, send_buf[3..7], self.stream_id, .big);

                self.tunnel.sendPlainFrame(send_buf[0 .. message_header_len + n]) catch |err| {
                    std.debug.print("[LOCAL {}] send() error: {}\n", .{ self.stream_id, err });
                    break;
                };
                continue;
            }

            // Encode DATA message directly into send buffer (no extra copies beyond framing)
            const data_msg = tunnel.DataMsg{ .service_id = self.service_id, .stream_id = self.stream_id, .data = buf[0..n] };
            const encoded_len = data_msg.encodeInto(send_buf[0..]) catch break;

            self.tunnel.send_mutex.lock();
            defer self.tunnel.send_mutex.unlock();

            const encrypted_len = encoded_len + noise.TAG_LEN;

            if (self.tunnel.send_cipher) |*cipher| {
                const start_ns = std.time.nanoTimestamp();
                cipher.encrypt(send_buf[0..encoded_len], send_buf[0..encrypted_len]) catch |err| {
                    std.debug.print("[LOCAL {}] Encryption error: {}\n", .{ self.stream_id, err });
                    break;
                };
                const end_ns = std.time.nanoTimestamp();
                const delta = @as(u64, @intCast(end_ns - start_ns));
                _ = encrypt_total_ns.fetchAdd(delta, .acq_rel);
                _ = encrypt_calls.fetchAdd(1, .acq_rel);
            } else {
                std.debug.print("[LOCAL {}] Missing send cipher, shutting down stream\n", .{self.stream_id});
                break;
            }

            self.tunnel.writeFrameLocked(send_buf[0..encrypted_len]) catch |err| {
                std.debug.print("[LOCAL {}] send() error: {}\n", .{ self.stream_id, err });
                break;
            };
        }

        std.debug.print("[LOCAL {}] Thread exiting\n", .{self.stream_id});

        // Atomically mark fd as closed before actually closing it
        self.fd_closed.store(true, .release);
        posix.close(self.local_fd);
    }

    fn stop(self: *LocalConnection) void {
        if (self.thread_joined.swap(true, .acq_rel)) return;
        self.running.store(false, .release);
        // Shutdown socket to unblock recv() call in thread (only if not already closed)
        if (!self.fd_closed.load(.acquire)) {
            posix.shutdown(self.local_fd, .recv) catch {};
        }
        self.thread.join();
    }
};

/// Wrapper for UDP forwarder callback
fn sendEncryptedMessageWrapper(conn: *anyopaque, payload: []const u8) anyerror!void {
    const client: *TunnelClient = @ptrCast(@alignCast(conn));
    try client.sendEncryptedMessage(payload);
}

/// Tunnel client
const TunnelClient = struct {
    tunnel_fd: posix.fd_t,
    service_id: tunnel.ServiceId,
    connections: std.AutoHashMap(tunnel.StreamId, *LocalConnection),
    connections_mutex: std.Thread.Mutex,
    send_mutex: std.Thread.Mutex,
    send_cipher: ?noise.TransportCipher,
    recv_cipher: ?noise.TransportCipher,
    encryption_enabled: bool,
    decrypt_buffer: []u8,
    next_stream_id: std.atomic.Value(u32),
    running: std.atomic.Value(bool),

    // Pre-allocated buffer for control messages (avoid per-frame allocation)
    control_msg_buffer: [common.CONTROL_MSG_BUFFER_SIZE]u8,
    control_msg_mutex: std.Thread.Mutex,

    // UDP support
    udp_forwarder: ?*udp_client.UdpForwarder,
    transport: config.Transport,

    // Heartbeat support
    heartbeat_timeout_ms: u32, // Consider connection dead if no heartbeat for N milliseconds (0 = disabled)
    last_heartbeat_time: std.atomic.Value(i64), // Milliseconds since epoch of last received heartbeat

    // Authentication
    default_token: []const u8, // Default token for authentication (empty = no auth)

    // Config reference for TCP tuning (needed for reverse mode)
    cfg: *const config.ClientConfig,

    fn create(allocator: std.mem.Allocator, tunnel_fd: posix.fd_t, service_id: tunnel.ServiceId, cfg: *const config.ClientConfig, static_keypair: std.crypto.dh.X25519.KeyPair) !*TunnelClient {
        setSockOpts(tunnel_fd, cfg);
        errdefer posix.close(tunnel_fd);

        const canonical_cipher = config.canonicalCipher(cfg);
        const encryption_enabled = !std.mem.eql(u8, canonical_cipher, "none");

        var send_cipher: ?noise.TransportCipher = null;
        var recv_cipher: ?noise.TransportCipher = null;
        var decrypt_buffer: []u8 = &[_]u8{};
        errdefer if (decrypt_buffer.len != 0) allocator.free(decrypt_buffer);

        if (encryption_enabled) {
            const cipher_type = noise.CipherType.fromString(canonical_cipher) catch {
                std.debug.print("[NOISE] Invalid cipher '{s}' in configuration\n", .{cfg.cipher});
                return error.InvalidCipher;
            };

            // Perform Noise_XX handshake (client IS initiator, uses persistent static key)
            const handshake = noise.noiseXXHandshake(tunnel_fd, cipher_type, true, static_keypair, cfg.psk) catch |err| switch (err) {
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
            const version_msg = tunnel.VersionMsg{ .version = build_options.version };
            var version_buf: [64]u8 = undefined;
            const version_len = try version_msg.encodeInto(&version_buf);

            // Encrypt and send our version
            var encrypted_version: [128]u8 = undefined;
            const encrypted_len = version_len + noise.TAG_LEN;
            try send_cipher.?.encrypt(version_buf[0..version_len], encrypted_version[0..encrypted_len]);

            // Write frame directly (no mutex needed during handshake)
            var frame_header: [4]u8 = undefined;
            std.mem.writeInt(u32, &frame_header, @intCast(encrypted_len), .big);
            try common.sendAllToFd(tunnel_fd, &frame_header);
            try common.sendAllToFd(tunnel_fd, encrypted_version[0..encrypted_len]);

            // Receive server version
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

            // Decrypt server version
            var decrypted_version: [128]u8 = undefined;
            const decrypted_len = frame_len - noise.TAG_LEN;
            try recv_cipher.?.decrypt(frame_buf[4 .. 4 + frame_len], decrypted_version[0..decrypted_len]);

            // Parse version message
            const server_version_msg = try tunnel.VersionMsg.decode(decrypted_version[0..decrypted_len], allocator);
            defer allocator.free(server_version_msg.version);

            // Check version compatibility
            if (!std.mem.eql(u8, server_version_msg.version, build_options.version)) {
                std.debug.print("[ERROR] Version mismatch: client={s}, server={s}\n", .{ build_options.version, server_version_msg.version });
                std.debug.print("[ERROR] Please use matching floos/flooc versions\n", .{});
                return error.VersionMismatch;
            }

            std.debug.print("[CLIENT] Version check passed: {s}\n", .{build_options.version});
        }

        const client = try allocator.create(TunnelClient);
        errdefer allocator.destroy(client);

        // Initialize struct with cipher state
        client.* = .{
            .tunnel_fd = tunnel_fd,
            .service_id = service_id,
            .connections = std.AutoHashMap(tunnel.StreamId, *LocalConnection).init(allocator),
            .connections_mutex = .{},
            .send_mutex = .{},
            .send_cipher = send_cipher,
            .recv_cipher = recv_cipher,
            .encryption_enabled = encryption_enabled,
            .decrypt_buffer = decrypt_buffer,
            .next_stream_id = std.atomic.Value(u32).init(1),
            .running = std.atomic.Value(bool).init(true),
            .control_msg_buffer = undefined, // Pre-allocated buffer for control messages
            .control_msg_mutex = .{},
            .udp_forwarder = null,
            .transport = .tcp, // Default to TCP for now
            .heartbeat_timeout_ms = cfg.advanced.heartbeat_timeout_seconds * 1000, // Convert to milliseconds
            .last_heartbeat_time = std.atomic.Value(i64).init(std.time.milliTimestamp()), // Initialize to current time
            .default_token = cfg.token,
            .cfg = cfg,
        };
        decrypt_buffer = &[_]u8{};

        if (client.heartbeat_timeout_ms > 0) {
            std.debug.print("[CLIENT] Heartbeat timeout enabled: {}s\n", .{cfg.advanced.heartbeat_timeout_seconds});
        }

        if (client.default_token.len > 0) {
            std.debug.print("[CLIENT] Authentication enabled with token\n", .{});
        }

        return client;
    }

    fn setSockOpts(fd: posix.fd_t, cfg: *const config.ClientConfig) void {
        const tcp_options = TcpOptions{
            .nodelay = cfg.advanced.tcp_nodelay,
            .keepalive = cfg.advanced.tcp_keepalive,
            .keepalive_idle = cfg.advanced.tcp_keepalive_idle,
            .keepalive_interval = cfg.advanced.tcp_keepalive_interval,
            .keepalive_count = cfg.advanced.tcp_keepalive_count,
        };
        applyTcpOptions(fd, tcp_options);
        tuneSocketBuffers(fd, cfg.advanced.socket_buffer_size);
    }

    fn run(self: *TunnelClient) void {
        var buf: [256 * 1024]u8 align(64) = undefined; // 256KB
        var decoder = protocol.FrameDecoder.init(global_allocator);
        defer decoder.deinit();

        // Check if decoder buffer was allocated
        if (decoder.buffer.len == 0) {
            std.debug.print("[CLIENT] Failed to allocate decoder buffer!\n", .{});
            self.cleanup();
            self.running.store(false, .release);
            return;
        }

        std.debug.print("[CLIENT] Tunnel handler started (buffer size: {})\n", .{decoder.buffer.len});

        // Poll timeout: check heartbeat every second if enabled, otherwise use 5 seconds
        const poll_timeout_ms: i32 = if (self.heartbeat_timeout_ms > 0) 1000 else 5000;

        while (self.running.load(.acquire) and !shutdown_flag.load(.acquire)) {
            // Check heartbeat timeout if enabled
            if (self.heartbeat_timeout_ms > 0) {
                const now = std.time.milliTimestamp();
                const last_heartbeat = self.last_heartbeat_time.load(.acquire);
                const elapsed_ms: u32 = @intCast(now - last_heartbeat);

                if (elapsed_ms > self.heartbeat_timeout_ms) {
                    std.debug.print("[CLIENT] Heartbeat timeout! No heartbeat for {}ms (limit: {}ms)\n", .{ elapsed_ms, self.heartbeat_timeout_ms });
                    break; // Connection will be re-established by auto-reconnection logic
                }
            }

            // Poll with timeout to allow periodic heartbeat checking
            var fds = [_]posix.pollfd{
                .{ .fd = self.tunnel_fd, .events = posix.POLL.IN, .revents = 0 },
            };

            const ready = posix.poll(&fds, poll_timeout_ms) catch |err| {
                std.debug.print("[CLIENT] Poll error: {}\n", .{err});
                break;
            };

            if (ready == 0) continue; // Timeout, check heartbeat and loop

            // Data available - read from tunnel
            const n = posix.recv(self.tunnel_fd, &buf, 0) catch |err| {
                std.debug.print("[CLIENT] Recv error: {}\n", .{err});
                break;
            };

            if (n == 0) {
                std.debug.print("[CLIENT] Tunnel server disconnected\n", .{});
                break;
            }

            // Feed decoder
            decoder.feed(buf[0..n]) catch {
                std.debug.print("[CLIENT] Decoder feed error\n", .{});
                break;
            };

            // Process all complete frames
            var decoder_had_error = false;
            while (true) {
                const maybe_frame = decoder.decode() catch |err| {
                    std.debug.print("[CLIENT] Decoder error: {}\n", .{err});
                    decoder_had_error = true;
                    break;
                };
                if (maybe_frame) |frame_payload| {
                    self.handleMessage(frame_payload) catch |err| {
                        std.debug.print("[CLIENT] Handle message error: {}\n", .{err});
                    };
                    continue;
                }
                break;
            }

            if (decoder_had_error) {
                self.running.store(false, .release);
                break;
            }
        }

        std.debug.print("[CLIENT] Tunnel handler stopping\n", .{});
        self.cleanup();
    }

    fn handleMessage(self: *TunnelClient, payload: []const u8) !void {
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
                    std.debug.print("[CLIENT] Decryption error: {}\n", .{err});
                    return err;
                };
            } else return error.CipherUnavailable;

            message_slice = target;
        }

        if (message_slice.len == 0) return;

        const msg_type: tunnel.MessageType = @enumFromInt(message_slice[0]);

        switch (msg_type) {
            .connect => {
                // Client doesn't receive CONNECT messages (only server does)
                // This would indicate a protocol error
                std.debug.print("[CLIENT] Unexpected CONNECT message (protocol error)\n", .{});
            },
            .connect_ack => {
                const ack = try tunnel.ConnectAckMsg.decode(message_slice);
                tracePrint(enable_tunnel_trace, "[CLIENT] CONNECT_ACK stream_id={}\n", .{ack.stream_id});
                // Connection established, local thread will start sending
            },
            .connect_error => {
                const err_msg = try tunnel.ConnectErrorMsg.decode(message_slice, global_allocator);
                defer global_allocator.free(err_msg.error_msg);
                std.debug.print("[CLIENT] CONNECT_ERROR stream_id={} code={s} error={s}\n", .{ err_msg.stream_id, @tagName(err_msg.error_code), err_msg.error_msg });

                self.connections_mutex.lock();
                const maybe_conn = self.connections.fetchRemove(err_msg.stream_id);
                self.connections_mutex.unlock();

                if (maybe_conn) |entry| {
                    entry.value.stop();
                    entry.value.releaseRef();
                }
            },
            .data => {
                const data_msg = try tunnel.DataMsg.decode(message_slice);

                var conn_ref: ?*LocalConnection = null;
                self.connections_mutex.lock();
                if (self.connections.get(data_msg.stream_id)) |c| {
                    c.acquireRef();
                    conn_ref = c;
                }
                self.connections_mutex.unlock();

                if (conn_ref) |c| {
                    defer c.releaseRef();
                    if (!c.fd_closed.load(.acquire)) {
                        sendAllToFd(c.local_fd, data_msg.data) catch |err| {
                            std.debug.print("[STREAM {}] Send to local failed: {}\n", .{ data_msg.stream_id, err });
                        };
                    }
                }
            },
            .close => {
                const close_msg = try tunnel.CloseMsg.decode(message_slice);
                tracePrint(enable_tunnel_trace, "[CLIENT] CLOSE stream_id={}\n", .{close_msg.stream_id});

                self.connections_mutex.lock();
                const maybe_conn = self.connections.fetchRemove(close_msg.stream_id);
                self.connections_mutex.unlock();

                if (maybe_conn) |entry| {
                    entry.value.stop();
                    entry.value.releaseRef();
                    std.debug.print("[CLIENT] Connection {} cleaned up after CLOSE message\n", .{close_msg.stream_id});
                } else {
                    // Connection already cleaned itself up
                    tracePrint(enable_tunnel_trace, "[CLIENT] Connection {} already removed (self-cleanup)\n", .{close_msg.stream_id});
                }
            },
            .udp_data => {
                const udp_msg = try tunnel.UdpDataMsg.decode(message_slice, global_allocator);
                defer global_allocator.free(udp_msg.source_addr);

                if (self.udp_forwarder) |forwarder| {
                    forwarder.handleUdpData(udp_msg) catch |err| {
                        std.debug.print("[UDP-CLIENT] Failed to forward UDP data: {}\n", .{err});
                    };
                }
            },
            .heartbeat => {
                // Received heartbeat from server - update last heartbeat time
                const heartbeat_msg = try tunnel.HeartbeatMsg.decode(message_slice);
                self.last_heartbeat_time.store(std.time.milliTimestamp(), .release);
                tracePrint(enable_tunnel_trace, "[HEARTBEAT] Received from server: timestamp={}\n", .{heartbeat_msg.timestamp});
            },
            .version => {
                // Version exchange happens during handshake only
                // Receiving it here would be unexpected, just ignore
                tracePrint(enable_tunnel_trace, "[CLIENT] Unexpected VERSION message during operation (ignoring)\n", .{});
            },
            .reverse_connect => {
                // REVERSE MODE: Server requests reverse connection using new message format
                const msg = try tunnel.ReverseConnectMsg.decode(message_slice);

                std.debug.print("[CLIENT] REVERSE_CONNECT from server: service_id={} stream_id={}\n", .{
                    msg.service_id,
                    msg.stream_id,
                });

                // Look up reverse service configuration
                var found_service: ?config.Service = null;
                var iter = self.cfg.reverse_services.valueIterator();
                while (iter.next()) |svc| {
                    if (svc.id == msg.service_id) {
                        found_service = svc.*;
                        break;
                    }
                }

                const service = found_service orelse {
                    std.debug.print("[CLIENT] Unknown reverse service_id={}\n", .{msg.service_id});
                    // Send error back
                    const error_msg = tunnel.ConnectErrorMsg{
                        .service_id = msg.service_id,
                        .stream_id = msg.stream_id,
                        .error_code = .unknown_service,
                        .error_msg = "Unknown reverse service",
                    };
                    var encode_buf: [128]u8 = undefined;
                    const encoded_len = error_msg.encodeInto(&encode_buf) catch return;
                    self.sendEncryptedMessage(encode_buf[0..encoded_len]) catch {};
                    return;
                };

                // Connect to local service
                const address = resolveHostPort(service.address, service.port) catch |err| {
                    std.debug.print("[CLIENT] Failed to resolve reverse target {s}:{}: {}\n", .{ service.address, service.port, err });
                    return;
                };

                const local_fd = posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
                    std.debug.print("[CLIENT] Failed to create socket for reverse: {}\n", .{err});
                    return;
                };
                errdefer posix.close(local_fd);

                setSockOpts(local_fd, self.cfg);

                posix.connect(local_fd, &address.any, address.getOsSockLen()) catch |err| {
                    std.debug.print("[CLIENT] Failed to connect to local target {s}:{}: {}\n", .{ service.address, service.port, err });
                    posix.close(local_fd);
                    // Send error back
                    const error_code: tunnel.ErrorCode = switch (err) {
                        error.ConnectionRefused => .connection_refused,
                        error.ConnectionTimedOut => .connection_timeout,
                        else => .service_unavailable,
                    };
                    const error_msg = tunnel.ConnectErrorMsg{
                        .service_id = msg.service_id,
                        .stream_id = msg.stream_id,
                        .error_code = error_code,
                        .error_msg = "Failed to connect to local target",
                    };
                    var encode_buf: [128]u8 = undefined;
                    const encoded_len = error_msg.encodeInto(&encode_buf) catch return;
                    self.sendEncryptedMessage(encode_buf[0..encoded_len]) catch {};
                    return;
                };

                std.debug.print("[CLIENT-REVERSE] Connected to local {s}:{} for stream {}\n", .{ service.address, service.port, msg.stream_id });

                // Create LocalConnection
                const conn = LocalConnection.create(global_allocator, msg.service_id, msg.stream_id, local_fd, self) catch |err| {
                    std.debug.print("[CLIENT] Failed to create reverse connection: {}\n", .{err});
                    posix.close(local_fd);
                    return;
                };

                // Add to connections
                self.connections_mutex.lock();
                conn.acquireRef(); // map reference
                self.connections.put(msg.stream_id, conn) catch |err| {
                    self.connections_mutex.unlock();
                    std.debug.print("[CLIENT] Failed to store reverse connection: {}\n", .{err});
                    conn.releaseRef(); // undo map ref
                    conn.stop();
                    return;
                };
                self.connections_mutex.unlock();

                // Send CONNECT_ACK to server
                const ack_msg = tunnel.ConnectAckMsg{
                    .service_id = msg.service_id,
                    .stream_id = msg.stream_id,
                };
                var ack_buf: [64]u8 = undefined;
                const ack_len = ack_msg.encodeInto(&ack_buf) catch return;
                self.sendEncryptedMessage(ack_buf[0..ack_len]) catch {};
            },
        }
    }

    fn handleReverseConnect(self: *TunnelClient, msg: tunnel.ConnectMsg) !void {
        const binding = getServiceBinding(self.cfg, msg.service_id) catch {
            std.debug.print("[CLIENT-REVERSE] Unknown service_id={} requested by server\n", .{msg.service_id});
            return error.UnknownService;
        };

        std.debug.print("[CLIENT-REVERSE] Connecting to local target {s}:{} for stream_id={}\n", .{
            binding.host,
            binding.port,
            msg.stream_id,
        });

        const address = try resolveHostPort(binding.host, binding.port);
        const local_fd = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        var local_fd_guard = true;
        defer if (local_fd_guard) posix.close(local_fd);

        setSockOpts(local_fd, self.cfg);

        try posix.connect(local_fd, &address.any, address.getOsSockLen());

        std.debug.print("[CLIENT-REVERSE] Connected to local target for stream_id={}\n", .{msg.stream_id});

        // Create LocalConnection to handle forwarding
        const conn = try LocalConnection.create(global_allocator, msg.service_id, msg.stream_id, local_fd, self);
        local_fd_guard = false;

        self.connections_mutex.lock();
        conn.acquireRef();
        self.connections.put(msg.stream_id, conn) catch |err| {
            self.connections_mutex.unlock();
            conn.releaseRef();
            conn.stop();
            return err;
        };
        self.connections_mutex.unlock();

        // Send CONNECT_ACK back to server
        const ack_msg = tunnel.ConnectAckMsg{
            .service_id = msg.service_id,
            .stream_id = msg.stream_id,
        };

        var encode_buf: [16]u8 = undefined; // ACK is 7 bytes
        const encoded_len = try ack_msg.encodeInto(&encode_buf);

        try self.sendEncryptedMessage(encode_buf[0..encoded_len]);

        std.debug.print("[CLIENT-REVERSE] Sent CONNECT_ACK to server for stream_id={}\n", .{msg.stream_id});
    }

    fn handleNewConnection(self: *TunnelClient, local_fd: posix.fd_t) !void {
        return self.handleNewConnectionWithServiceId(local_fd, self.service_id);
    }

    fn handleNewConnectionWithServiceId(self: *TunnelClient, local_fd: posix.fd_t, service_id: tunnel.ServiceId) !void {
        // Use TunnelClient's default token unless overridden by multi-service context
        return self.handleNewConnectionFull(local_fd, service_id, self.default_token);
    }

    fn handleNewConnectionFull(self: *TunnelClient, local_fd: posix.fd_t, service_id: tunnel.ServiceId, token: []const u8) !void {
        const stream_id = self.next_stream_id.fetchAdd(1, .acq_rel);

        tracePrint(enable_tunnel_trace, "[CLIENT] New local connection, service_id={} stream_id={}\n", .{ service_id, stream_id });

        // Create local connection handler
        const conn = try LocalConnection.create(global_allocator, service_id, stream_id, local_fd, self);

        self.connections_mutex.lock();
        conn.acquireRef();
        self.connections.put(stream_id, conn) catch |err| {
            self.connections_mutex.unlock();
            conn.releaseRef();
            conn.stop();
            return err;
        };
        self.connections_mutex.unlock();

        // Send encrypted CONNECT message (no allocation - use stack buffer)
        const connect_msg = tunnel.ConnectMsg{
            .service_id = service_id,
            .stream_id = stream_id,
            .token = token,
        };

        // Use stack buffer for control message encoding
        var encode_buf: [512]u8 = undefined; // CONNECT messages are small (<100 bytes typically)
        const encoded_len = try connect_msg.encodeInto(&encode_buf);

        self.sendEncryptedMessage(encode_buf[0..encoded_len]) catch |err| {
            std.debug.print("[CLIENT] Failed to send CONNECT: {}\n", .{err});
            return err;
        };
    }

    /// Send all data to a file descriptor, looping until complete.
    /// Extracted to common.zig to eliminate duplication with server.zig.
    const sendAllToFd = common.sendAllToFd;

    /// Write length-prefixed frame using writev() for scatter-gather I/O.
    /// Extracted to common.zig to eliminate duplication with server.zig.
    fn writeFrameLocked(self: *TunnelClient, payload: []const u8) !void {
        return common.writeFrameLocked(self.tunnel_fd, payload);
    }

    /// Send plaintext frame (framing only, no encryption).
    /// NOTE: Similar implementation exists in server.zig. Consider unifying.
    fn sendPlainFrame(self: *TunnelClient, payload: []const u8) !void {
        self.send_mutex.lock();
        defer self.send_mutex.unlock();
        try self.writeFrameLocked(payload);
    }

    /// Encrypt a message payload and send it with frame length prefix.
    /// NOTE: Similar implementation exists in server.zig. Consider unifying.
    fn sendEncryptedMessage(self: *TunnelClient, payload: []const u8) !void {
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
        defer self.send_mutex.unlock();
        try self.writeFrameLocked(self.control_msg_buffer[0..encrypted_len]);
    }

    fn handleSendFailure(self: *TunnelClient, err: anyerror) void {
        if (!self.running.load(.acquire)) return;
        std.debug.print("[CLIENT] Tunnel send failure: {}\n", .{err});
        self.running.store(false, .release);
        posix.shutdown(self.tunnel_fd, .both) catch {};
    }

    fn cleanup(self: *TunnelClient) void {
        // Stop UDP forwarder if present
        if (self.udp_forwarder) |forwarder| {
            forwarder.stop();
            forwarder.destroy();
            self.udp_forwarder = null;
        }

        // Stop all connections
        while (true) {
            self.connections_mutex.lock();
            var iter = self.connections.iterator();
            const entry = iter.next();
            if (entry) |e| {
                const key_copy = e.key_ptr.*;
                const conn_ptr = e.value_ptr.*;
                _ = self.connections.remove(key_copy);
                self.connections_mutex.unlock();
                conn_ptr.stop();
                conn_ptr.releaseRef();
            } else {
                self.connections_mutex.unlock();
                break;
            }
        }
        self.connections.deinit();

        if (self.decrypt_buffer.len > 0) {
            global_allocator.free(self.decrypt_buffer);
            self.decrypt_buffer = &[_]u8{};
        }

        posix.close(self.tunnel_fd);
    }

    fn destroy(self: *TunnelClient) void {
        if (self.decrypt_buffer.len > 0) {
            global_allocator.free(self.decrypt_buffer);
        }
        global_allocator.destroy(self);
    }
};

const TcpServiceListenerContext = struct {
    allocator: std.mem.Allocator,
    service_id: tunnel.ServiceId,
    local_host: []const u8,
    local_port: u16,
    token: []const u8,
    tunnel_clients: []?*TunnelClient,
    tunnel_clients_mutex: *std.Thread.Mutex,
    num_tunnels: usize,
    socket_buffer_size: u32,
    tcp_options: TcpOptions,

    fn destroy(self: *TcpServiceListenerContext) void {
        self.allocator.free(self.local_host);
        self.allocator.free(self.token);
        self.allocator.destroy(self);
    }
};

inline fn loadTunnelClient(
    tunnel_clients: []?*TunnelClient,
    mutex: *std.Thread.Mutex,
    index: usize,
) ?*TunnelClient {
    mutex.lock();
    const client_opt = tunnel_clients[index];
    mutex.unlock();
    if (client_opt) |client| {
        if (!client.running.load(.acquire)) return null;
        return client;
    }
    return null;
}

/// TCP service listener thread - handles one service
fn tcpServiceListener(ctx_ptr: *anyopaque) void {
    const ctx: *TcpServiceListenerContext = @ptrCast(@alignCast(ctx_ptr));
    defer ctx.destroy();

    const local_addr = resolveHostPort(ctx.local_host, ctx.local_port) catch |err| {
        std.debug.print("[TCP-SERVICE] Failed to parse address for service_id={}: {}\n", .{ ctx.service_id, err });
        return;
    };

    // Create listener socket
    const listen_fd = posix.socket(local_addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| {
        std.debug.print("[TCP-SERVICE] Failed to create socket for service_id={}: {}\n", .{ ctx.service_id, err });
        return;
    };
    defer posix.close(listen_fd);

    posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};

    posix.bind(listen_fd, &local_addr.any, local_addr.getOsSockLen()) catch |err| {
        std.debug.print("[TCP-SERVICE] Failed to bind service_id={} on port {}: {}\n", .{ ctx.service_id, ctx.local_port, err });
        return;
    };

    posix.listen(listen_fd, common.LISTEN_BACKLOG) catch |err| {
        std.debug.print("[TCP-SERVICE] Failed to listen for service_id={}: {}\n", .{ ctx.service_id, err });
        return;
    };

    std.debug.print("[TCP-SERVICE] Listening on {s}:{} (service_id={})\n", .{ ctx.local_host, ctx.local_port, ctx.service_id });

    // Accept loop with round-robin distribution
    var next_tunnel: usize = 0;
    while (!shutdown_flag.load(.acquire)) {
        // Poll for accept with timeout
        var fds = [_]posix.pollfd{
            .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        const ready = posix.poll(&fds, 1000) catch continue; // 1s timeout
        if (ready == 0) continue; // Timeout, check shutdown

        const local_fd = posix.accept(listen_fd, null, null, posix.SOCK.CLOEXEC) catch |err| {
            std.debug.print("[TCP-SERVICE] Accept error for service_id={}: {}\n", .{ ctx.service_id, err });
            continue;
        };

        tracePrint(enable_listener_trace, "[TCP-SERVICE] Accepted connection on service_id={}: fd={} -> tunnel {}\n", .{ ctx.service_id, local_fd, next_tunnel });
        tuneSocketBuffers(local_fd, ctx.socket_buffer_size);
        applyTcpOptions(local_fd, ctx.tcp_options);

        // Handle new connection via round-robin tunnel selection (skip null tunnels during reconnection)
        var attempts: usize = 0;
        while (attempts < ctx.num_tunnels) : (attempts += 1) {
            if (loadTunnelClient(ctx.tunnel_clients, ctx.tunnel_clients_mutex, next_tunnel)) |client| {
                client.handleNewConnectionFull(local_fd, ctx.service_id, ctx.token) catch |err| {
                    std.debug.print("[TCP-SERVICE] Failed to handle connection for service_id={}: {}\n", .{ ctx.service_id, err });
                    posix.close(local_fd);
                };
                break;
            }
            // Tunnel is reconnecting, try next one
            next_tunnel = (next_tunnel + 1) % ctx.num_tunnels;
        } else {
            // All tunnels are down
            std.debug.print("[TCP-SERVICE] All tunnels down, rejecting connection\n", .{});
            posix.close(local_fd);
        }

        // Round-robin to next tunnel
        next_tunnel = (next_tunnel + 1) % ctx.num_tunnels;
    }

    std.debug.print("[TCP-SERVICE] Service listener stopped for service_id={}\n", .{ctx.service_id});
}

/// Parameters for tunnel connection thread
const TunnelConnectionParams = struct {
    tunnel_index: usize,
    service_id: tunnel.ServiceId,
    remote_host: []const u8,
    remote_port: u16,
    cfg: *const config.ClientConfig,
    static_keypair: std.crypto.dh.X25519.KeyPair,
    tunnel_client_slot: *?*TunnelClient, // Pointer to store the created client
    tunnel_clients_mutex: *std.Thread.Mutex,
};

/// Tunnel connection thread with auto-reconnection
fn tunnelThreadWithReconnection(params_ptr: *TunnelConnectionParams) void {
    const params = params_ptr.*;
    var retry_delay_ms = params.cfg.advanced.reconnect_initial_delay_ms;
    var attempt: usize = 0;

    while (!shutdown_flag.load(.acquire)) {
        attempt += 1;

        // Parse proxy config if provided
        var proxy_cfg_opt: ?proxy.ProxyConfig = null;
        if (params.cfg.advanced.proxy_url.len > 0) {
            proxy_cfg_opt = proxy.ProxyConfig.parseUrl(global_allocator, params.cfg.advanced.proxy_url) catch |err| {
                std.debug.print("[TUNNEL {}] Invalid proxy URL: {}\n", .{ params.tunnel_index, err });
                std.Thread.sleep(retry_delay_ms * std.time.ns_per_ms);
                retry_delay_ms = @min(retry_delay_ms * params.cfg.advanced.reconnect_backoff_multiplier, params.cfg.advanced.reconnect_max_delay_ms);
                continue;
            };
        }
        defer if (proxy_cfg_opt) |*cfg| cfg.deinit(global_allocator);

        if (proxy_cfg_opt) |proxy_cfg| {
            if (proxy_cfg.proxy_type != .none) {
                std.debug.print("[TUNNEL {}] Connecting via {s} proxy {s}:{}\n", .{
                    params.tunnel_index,
                    @tagName(proxy_cfg.proxy_type),
                    proxy_cfg.host,
                    proxy_cfg.port,
                });
            }
        }

        const tunnel_fd = proxy.connectWithProxy(
            global_allocator,
            proxy_cfg_opt,
            params.remote_host,
            params.remote_port,
        ) catch |err| {
            std.debug.print("[TUNNEL {}] Connection failed (attempt {}): {}, retrying in {}ms...\n", .{ params.tunnel_index, attempt, err, retry_delay_ms });
            std.Thread.sleep(retry_delay_ms * std.time.ns_per_ms);
            retry_delay_ms = @min(retry_delay_ms * params.cfg.advanced.reconnect_backoff_multiplier, params.cfg.advanced.reconnect_max_delay_ms);
            continue;
        };

        const tcp_options = TcpOptions{
            .nodelay = params.cfg.advanced.tcp_nodelay,
            .keepalive = params.cfg.advanced.tcp_keepalive,
            .keepalive_idle = params.cfg.advanced.tcp_keepalive_idle,
            .keepalive_interval = params.cfg.advanced.tcp_keepalive_interval,
            .keepalive_count = params.cfg.advanced.tcp_keepalive_count,
        };
        applyTcpOptions(tunnel_fd, tcp_options);
        tuneSocketBuffers(tunnel_fd, params.cfg.advanced.socket_buffer_size);

        // Successfully connected
        std.debug.print("[TUNNEL {}] Connected to {s}:{} (attempt {})\n", .{ params.tunnel_index, params.remote_host, params.remote_port, attempt });

        // Create tunnel client
        const tunnel_client = TunnelClient.create(
            global_allocator,
            tunnel_fd,
            params.service_id,
            params.cfg,
            params.static_keypair,
        ) catch |err| {
            std.debug.print("[TUNNEL {}] Failed to create client: {}\n", .{ params.tunnel_index, err });
            std.Thread.sleep(retry_delay_ms * std.time.ns_per_ms);
            retry_delay_ms = @min(retry_delay_ms * params.cfg.advanced.reconnect_backoff_multiplier, params.cfg.advanced.reconnect_max_delay_ms);
            continue;
        };

        // Store client reference for connection handling
        params.tunnel_clients_mutex.lock();
        params.tunnel_client_slot.* = tunnel_client;
        params.tunnel_clients_mutex.unlock();

        // Reset retry delay on successful connection
        retry_delay_ms = params.cfg.advanced.reconnect_initial_delay_ms;

        // Run client (blocks until disconnection)
        tunnel_client.run();

        // Cleanup after disconnection
        params.tunnel_clients_mutex.lock();
        params.tunnel_client_slot.* = null;
        params.tunnel_clients_mutex.unlock();
        tunnel_client.destroy();

        // Check if reconnection is enabled
        if (!params.cfg.advanced.reconnect_enabled or shutdown_flag.load(.acquire)) {
            std.debug.print("[TUNNEL {}] Reconnection disabled or shutting down\n", .{params.tunnel_index});
            break;
        }

        std.debug.print("[TUNNEL {}] Disconnected, reconnecting in {}ms...\n", .{ params.tunnel_index, retry_delay_ms });
        std.Thread.sleep(retry_delay_ms * std.time.ns_per_ms);
    }

    std.debug.print("[TUNNEL {}] Thread exiting\n", .{params.tunnel_index});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    global_allocator = allocator;
    defer diagnostics.flushEncryptStats("client", &encrypt_total_ns, &encrypt_calls);

    var exit_code: u8 = 0;
    defer if (exit_code != 0) posix.exit(exit_code);

    const args_list = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args_list);

    var parse_ctx = ParseContext{};
    var cli_opts = parseClientArgs(allocator, args_list, &parse_ctx) catch |err| {
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
            ParseError.OutOfMemory => {
                std.debug.print("error: out of memory while parsing arguments\n", .{});
            },
        }
        printClientUsage();
        exit_code = 1;
        return;
    };
    defer cli_opts.deinit(allocator);

    // Store config path globally for reload / doctor modes
    config_path_global = cli_opts.config_path;

    switch (cli_opts.mode) {
        .help => {
            printClientUsage();
            return;
        },
        .version => {
            std.debug.print("flooc {s}\n", .{build_options.version});
            return;
        },
        .doctor => {
            const ok = try runClientDoctor(allocator, &cli_opts);
            if (!ok) exit_code = 1;
            return;
        },
        .ping => {
            const ok = try runClientPing(allocator, &cli_opts);
            if (!ok) exit_code = 1;
            return;
        },
        .run => {},
    }

    // Load config with any CLI overrides applied
    var cfg = try loadClientConfigWithOverrides(allocator, &cli_opts);
    defer cfg.deinit();

    const canonical_cipher = config.canonicalCipher(&cfg);
    if (std.mem.eql(u8, canonical_cipher, "none")) {
        std.debug.print("[WARN] Client encryption disabled; ensure tokens are treated as secrets.\n", .{});
    } else if (cfg.psk.len == 0) {
        std.debug.print("[WARN] Client PSK is empty; connection attempts will fail.\n", .{});
    } else if (std.mem.eql(u8, cfg.psk, config.DEFAULT_PSK)) {
        std.debug.print("[WARN] Client is using the placeholder PSK '{s}'. Change this before deployment.\n", .{config.DEFAULT_PSK});
    }

    var default_token_required = cfg.services.count() == 0;
    if (!default_token_required) {
        var iter = cfg.services.valueIterator();
        while (iter.next()) |service| {
            if (service.token.len == 0) {
                default_token_required = true;
                break;
            }
        }
    }

    if (default_token_required and cfg.token.len == 0) {
        std.debug.print("[WARN] Client default token is empty; server access control will fail.\n", .{});
    } else if (cfg.token.len > 0 and std.mem.eql(u8, cfg.token, config.DEFAULT_TOKEN)) {
        std.debug.print("[WARN] Client is using the placeholder token '{s}'. Update configs to a secret value.\n", .{config.DEFAULT_TOKEN});
    }

    const remote_host = try cfg.getServerHost();
    const remote_port = try cfg.getServerPort();

    // Get default service for single-service mode
    var default_service_id: tunnel.ServiceId = 0;
    var local_host: []const u8 = "127.0.0.1";
    var local_port: u16 = 9001;
    var transport: config.Transport = .tcp; // Default to TCP for single-service mode

    if (cfg.default_service) |service_name| {
        if (cfg.services.get(service_name)) |service| {
            default_service_id = service.id;
            local_host = service.address;
            local_port = service.port;
            transport = service.transport;
        }
    }

    std.debug.print("Floo Tunnel Client (flooc-blocking)\n", .{});
    std.debug.print("====================================\n\n", .{});
    std.debug.print("[CONFIG] Local:  {s}:{}\n", .{ local_host, local_port });
    std.debug.print("[CONFIG] Remote: {s}:{}\n", .{ remote_host, remote_port });
    if (default_service_id != 0) {
        std.debug.print("[CONFIG] Default Service ID: {}\n", .{default_service_id});
    } else {
        std.debug.print("[CONFIG] Default Service ID: (unset)\n", .{});
    }
    std.debug.print("[CONFIG] Services: {}\n", .{cfg.services.count()});
    std.debug.print("[CONFIG] Parallel Tunnels: {}\n", .{cfg.advanced.num_tunnels});
    std.debug.print("[CONFIG] Mode: Blocking I/O + Threads\n", .{});
    std.debug.print("[CONFIG] Hot Reload: Disabled (restart flooc to apply configuration changes)\n\n", .{});

    // Register signal handlers (POSIX only)
    if (@hasDecl(posix, "Sigaction") and @hasDecl(posix, "sigaction")) {
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

    // Connect to tunnel server with parallel tunnels
    const num_tunnels = cfg.advanced.num_tunnels;
    std.debug.print("[CLIENT] Connecting {} parallel tunnels to {s}:{}...\n", .{ num_tunnels, remote_host, remote_port });

    // Generate persistent static keypair for Noise XX authentication
    const static_keypair = std.crypto.dh.X25519.KeyPair.generate();

    // Create array to hold tunnel clients (nullable since they reconnect)
    const tunnel_clients = try allocator.alloc(?*TunnelClient, num_tunnels);
    defer allocator.free(tunnel_clients);

    // Initialize all slots to null
    for (tunnel_clients) |*slot| {
        slot.* = null;
    }

    var tunnel_clients_mutex = std.Thread.Mutex{};

    // Create connection parameters for each tunnel
    const tunnel_params = try allocator.alloc(TunnelConnectionParams, num_tunnels);
    defer allocator.free(tunnel_params);

    // Connect each tunnel (all share the same static identity)
    for (0..num_tunnels) |i| {
        tunnel_params[i] = .{
            .tunnel_index = i,
            .service_id = default_service_id,
            .remote_host = remote_host,
            .remote_port = remote_port,
            .cfg = &cfg,
            .static_keypair = static_keypair,
            .tunnel_client_slot = &tunnel_clients[i],
            .tunnel_clients_mutex = &tunnel_clients_mutex,
        };

        // Spawn tunnel handler thread with reconnection
        const tunnel_thread = try std.Thread.spawn(.{
            .stack_size = common.TUNNEL_THREAD_STACK,
        }, tunnelThreadWithReconnection, .{&tunnel_params[i]});
        tunnel_thread.detach();
    }

    std.debug.print("[CLIENT] All tunnel threads started (reconnection: {})\n", .{cfg.advanced.reconnect_enabled});

    // Check if multi-service mode is enabled
    if (cfg.services.count() > 0) {
        std.debug.print("\n[MULTI-SERVICE] Starting {} services...\n", .{cfg.services.count()});

        // Create listeners/forwarders for each service
        var service_iter = cfg.services.valueIterator();
        while (service_iter.next()) |service| {
            std.debug.print("[SERVICE] Starting service '{s}' (id={}, transport={any}, local={s}:{})\n", .{
                service.name,
                service.id,
                service.transport,
                service.address,
                service.port,
            });

            if (service.transport == .tcp) {
                // Create TCP listener thread for this service
                const effective_token = if (service.token.len > 0) service.token else cfg.token;
                const token_copy = try allocator.dupe(u8, effective_token);
                errdefer allocator.free(token_copy);
                const local_host_copy = try allocator.dupe(u8, service.address);
                errdefer allocator.free(local_host_copy);

                const ctx = try allocator.create(TcpServiceListenerContext);
                ctx.* = .{
                    .allocator = allocator,
                    .service_id = service.id,
                    .local_host = local_host_copy,
                    .local_port = service.port,
                    .token = token_copy,
                    .tunnel_clients = tunnel_clients,
                    .tunnel_clients_mutex = &tunnel_clients_mutex,
                    .num_tunnels = num_tunnels,
                    .socket_buffer_size = cfg.advanced.socket_buffer_size,
                    .tcp_options = TcpOptions{
                        .nodelay = cfg.advanced.tcp_nodelay,
                        .keepalive = cfg.advanced.tcp_keepalive,
                        .keepalive_idle = cfg.advanced.tcp_keepalive_idle,
                        .keepalive_interval = cfg.advanced.tcp_keepalive_interval,
                        .keepalive_count = cfg.advanced.tcp_keepalive_count,
                    },
                };
                // Ownership transferred to ctx
                const thread = try std.Thread.spawn(.{}, tcpServiceListener, .{ctx});
                thread.detach();
            } else if (service.transport == .udp) {
                // Wait for first tunnel to be available
                while (loadTunnelClient(tunnel_clients, &tunnel_clients_mutex, 0) == null and !shutdown_flag.load(.acquire)) {
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                }

                if (loadTunnelClient(tunnel_clients, &tunnel_clients_mutex, 0)) |first_client| {
                    const effective_token = if (service.token.len > 0) service.token else cfg.token;
                    // Create UDP forwarder for this service
                    const forwarder = try udp_client.UdpForwarder.create(
                        allocator,
                        service.id,
                        service.address,
                        service.port,
                        @ptrCast(first_client),
                        sendEncryptedMessageWrapper,
                        cfg.advanced.udp_timeout_seconds,
                    );

                    // Store forwarder reference (for cleanup)
                    first_client.udp_forwarder = forwarder;

                    // Send initial CONNECT message for UDP service
                    const stream_id = first_client.next_stream_id.fetchAdd(1, .acq_rel);
                    const connect_msg = tunnel.ConnectMsg{
                        .service_id = service.id,
                        .stream_id = stream_id,
                        .token = effective_token,
                    };

                    var encode_buf: [512]u8 = undefined;
                    const encoded_len = try connect_msg.encodeInto(&encode_buf);
                    try first_client.sendEncryptedMessage(encode_buf[0..encoded_len]);

                    std.debug.print("[UDP-SERVICE] Service '{s}' ready on {s}:{}\n", .{ service.name, service.address, service.port });
                }
            }
        }

        std.debug.print("\n[READY] All services ready. Press Ctrl+C to stop.\n\n", .{});

        // Wait for shutdown signal
        while (!shutdown_flag.load(.acquire)) {
            std.Thread.sleep(1 * std.time.ns_per_s);
        }
    } else if (transport == .udp) {
        // Legacy single-service UDP mode
        // UDP mode: create UDP forwarders
        std.debug.print("[UDP-CLIENT] Creating UDP forwarders on port {}...\n", .{local_port});

        // Wait for first tunnel to be available
        while (loadTunnelClient(tunnel_clients, &tunnel_clients_mutex, 0) == null and !shutdown_flag.load(.acquire)) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        if (loadTunnelClient(tunnel_clients, &tunnel_clients_mutex, 0)) |first_client| {
            // Create one UDP forwarder per tunnel (each on same local port needs SO_REUSEPORT,
            // but for simplicity, create just one forwarder for the first tunnel)
            const forwarder = try udp_client.UdpForwarder.create(
                allocator,
                default_service_id,
                local_host,
                local_port,
                @ptrCast(first_client),
                sendEncryptedMessageWrapper,
                cfg.advanced.udp_timeout_seconds,
            );

            first_client.udp_forwarder = forwarder;

            // Send CONNECT message to server to initialize UDP forwarder
            const stream_id = first_client.next_stream_id.fetchAdd(1, .acq_rel);
            const connect_msg = tunnel.ConnectMsg{
                .service_id = default_service_id,
                .stream_id = stream_id,
                .token = first_client.default_token,
            };

            var encode_buf: [512]u8 = undefined;
            const encoded_len = try connect_msg.encodeInto(&encode_buf);
            try first_client.sendEncryptedMessage(encode_buf[0..encoded_len]);

            std.debug.print("[UDP-CLIENT] Sent CONNECT message to server (stream_id={})\n", .{stream_id});
            std.debug.print("[UDP-CLIENT] UDP forwarder ready on {s}:{}\n", .{ local_host, local_port });
            std.debug.print("[READY] Client ready. Press Ctrl+C to stop.\n\n", .{});

            // Wait for shutdown signal
            while (!shutdown_flag.load(.acquire)) {
                std.Thread.sleep(1 * std.time.ns_per_s);

                // Periodic session cleanup
                forwarder.cleanupExpiredSessions() catch {};
            }
        }
    } else {
        // TCP mode: create local listener
        const local_addr = try resolveHostPort(local_host, local_port);
        const listen_fd = try posix.socket(local_addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        defer posix.close(listen_fd);

        try posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        try posix.bind(listen_fd, &local_addr.any, local_addr.getOsSockLen());
        try posix.listen(listen_fd, common.LISTEN_BACKLOG);

        std.debug.print("[LISTENER] Listening on {s}:{}\n", .{ local_host, local_port });
        std.debug.print("[READY] Client ready. Press Ctrl+C to stop.\n\n", .{});

        // Accept loop with round-robin distribution
        var next_tunnel: usize = 0;
        while (!shutdown_flag.load(.acquire)) {
            // Poll for accept with timeout
            var fds = [_]posix.pollfd{
                .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 },
            };

            const ready = posix.poll(&fds, 1000) catch continue; // 1s timeout
            if (ready == 0) continue; // Timeout, check flags

            const local_fd = posix.accept(listen_fd, null, null, posix.SOCK.CLOEXEC) catch |err| {
                std.debug.print("[LISTENER] Accept error: {}\n", .{err});
                continue;
            };

            tracePrint(enable_listener_trace, "[LISTENER] Accepted local connection: fd={} -> tunnel {}\n", .{ local_fd, next_tunnel });
            tuneSocketBuffers(local_fd, cfg.advanced.socket_buffer_size);
            const tcp_opts = TcpOptions{
                .nodelay = cfg.advanced.tcp_nodelay,
                .keepalive = cfg.advanced.tcp_keepalive,
                .keepalive_idle = cfg.advanced.tcp_keepalive_idle,
                .keepalive_interval = cfg.advanced.tcp_keepalive_interval,
                .keepalive_count = cfg.advanced.tcp_keepalive_count,
            };
            applyTcpOptions(local_fd, tcp_opts);

            // Handle new connection via round-robin tunnel selection (skip null tunnels during reconnection)
            var attempts: usize = 0;
            while (attempts < num_tunnels) : (attempts += 1) {
                if (loadTunnelClient(tunnel_clients, &tunnel_clients_mutex, next_tunnel)) |client| {
                    client.handleNewConnection(local_fd) catch |err| {
                        std.debug.print("[LISTENER] Failed to handle connection: {}\n", .{err});
                        posix.close(local_fd);
                    };
                    break;
                }
                // Tunnel is reconnecting, try next one
                next_tunnel = (next_tunnel + 1) % num_tunnels;
            } else {
                // All tunnels are down
                std.debug.print("[LISTENER] All tunnels down, rejecting connection\n", .{});
                posix.close(local_fd);
            }

            // Round-robin to next tunnel
            next_tunnel = (next_tunnel + 1) % num_tunnels;
        }
    }

    std.debug.print("\n[SHUTDOWN] Client stopped.\n", .{});
}
