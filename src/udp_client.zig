const std = @import("std");
const posix = std.posix;
const tunnel = @import("tunnel.zig");
const config = @import("config.zig");
const udp_session = @import("udp_session.zig");

/// UDP forwarder for client side
/// Handles local UDP clients and forwards through tunnel
///
/// Design: Client listens on local UDP port and tracks sessions for each
/// local client that sends packets. Each unique source address gets a
/// session ID that's used to route responses back correctly.
pub const UdpForwarder = struct {
    allocator: std.mem.Allocator,
    service_id: tunnel.ServiceId,
    local_port: u16,
    local_fd: posix.fd_t,
    target_host: []const u8,
    target_port: u16,
    tunnel_conn: *anyopaque, // Opaque pointer to TunnelClient
    send_fn: *const fn (conn: *anyopaque, payload: []const u8) anyerror!void,
    running: std.atomic.Value(bool),
    thread: std.Thread,
    session_manager: udp_session.UdpSessionManager,
    timeout_seconds: u64,

    pub fn create(
        allocator: std.mem.Allocator,
        service_id: tunnel.ServiceId,
        local_port: u16,
        target_host: []const u8,
        target_port: u16,
        tunnel_conn: *anyopaque,
        send_fn: *const fn (conn: *anyopaque, payload: []const u8) anyerror!void,
        timeout_seconds: u64,
    ) !*UdpForwarder {
        // Create and bind local UDP socket
        const local_fd = try posix.socket(
            posix.AF.INET,
            posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(local_fd);

        // Bind to local port
        const bind_addr = try std.net.Address.parseIp4("127.0.0.1", local_port);
        try posix.bind(local_fd, &bind_addr.any, bind_addr.getOsSockLen());

        const forwarder = try allocator.create(UdpForwarder);
        forwarder.* = .{
            .allocator = allocator,
            .service_id = service_id,
            .local_port = local_port,
            .local_fd = local_fd,
            .target_host = try allocator.dupe(u8, target_host),
            .target_port = target_port,
            .tunnel_conn = tunnel_conn,
            .send_fn = send_fn,
            .running = std.atomic.Value(bool).init(true),
            .thread = undefined,
            .session_manager = udp_session.UdpSessionManager.init(allocator),
            .timeout_seconds = timeout_seconds,
        };

        // Start local receiver thread
        forwarder.thread = try std.Thread.spawn(.{
            .stack_size = 256 * 1024,
        }, localReceiveThread, .{forwarder});

        std.debug.print("[UDP-CLIENT] Listening on local port {}\n", .{local_port});

        return forwarder;
    }

    fn localReceiveThread(self: *UdpForwarder) void {
        var buf: [65536]u8 align(64) = undefined;
        var from_addr: posix.sockaddr.storage = undefined;
        var from_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

        std.debug.print("[UDP-CLIENT] Local receiver thread started\n", .{});

        while (self.running.load(.acquire)) {
            // Receive UDP packet from local client
            const n = posix.recvfrom(
                self.local_fd,
                &buf,
                0,
                @ptrCast(&from_addr),
                &from_len,
            ) catch |err| {
                std.debug.print("[UDP-CLIENT] recvfrom error: {}\n", .{err});
                continue;
            };

            if (n == 0) continue;

            // Convert source address
            const source_addr = std.net.Address.initPosix(@ptrCast(@alignCast(&from_addr)));

            // Get or create session for this local source
            const session = self.session_manager.getOrCreate(source_addr) catch |err| {
                std.debug.print("[UDP-CLIENT] Session creation error: {}\n", .{err});
                continue;
            };

            std.debug.print("[UDP-CLIENT] Received {} bytes from local {any}, stream_id={}\n", .{
                n,
                source_addr,
                session.stream_id,
            });

            // Encode UDP data message
            var encode_buf: [70000]u8 = undefined;

            // Get source address bytes for encoding
            var addr_bytes: [16]u8 = undefined;
            var addr_len: usize = 0;
            var source_port: u16 = 0;

            switch (source_addr.any.family) {
                posix.AF.INET => {
                    const ipv4 = source_addr.in;
                    @memcpy(addr_bytes[0..4], std.mem.asBytes(&ipv4.sa.addr));
                    addr_len = 4;
                    source_port = ipv4.getPort();
                },
                posix.AF.INET6 => {
                    const ipv6 = source_addr.in6;
                    @memcpy(&addr_bytes, &ipv6.sa.addr);
                    addr_len = 16;
                    source_port = ipv6.getPort();
                },
                else => continue,
            }

            const udp_msg = tunnel.UdpDataMsg{
                .service_id = self.service_id,
                .stream_id = session.stream_id,
                .source_addr = addr_bytes[0..addr_len],
                .source_port = source_port,
                .data = buf[0..n],
            };

            const encoded_len = udp_msg.encodeInto(&encode_buf) catch |err| {
                std.debug.print("[UDP-CLIENT] Encode error: {}\n", .{err});
                continue;
            };

            // Send through tunnel
            self.send_fn(self.tunnel_conn, encode_buf[0..encoded_len]) catch |err| {
                std.debug.print("[UDP-CLIENT] Tunnel send error: {}\n", .{err});
            };
        }

        std.debug.print("[UDP-CLIENT] Local receiver thread stopped\n", .{});
    }

    /// Handle incoming UDP data from tunnel (forward to local client)
    pub fn handleUdpData(self: *UdpForwarder, udp_msg: tunnel.UdpDataMsg) !void {
        // Look up session by stream_id
        const session = self.session_manager.getByStreamId(udp_msg.stream_id) orelse {
            std.debug.print("[UDP-CLIENT] Unknown stream_id={}, dropping packet\n", .{udp_msg.stream_id});
            return;
        };

        // Send back to local source address
        _ = try posix.sendto(
            self.local_fd,
            udp_msg.data,
            0,
            &session.source_addr.any,
            session.source_addr.getOsSockLen(),
        );

        std.debug.print("[UDP-CLIENT] Forwarded {} bytes to local {any}\n", .{
            udp_msg.data.len,
            session.source_addr,
        });
    }

    /// Cleanup expired sessions
    pub fn cleanupExpiredSessions(self: *UdpForwarder) !void {
        const removed = try self.session_manager.cleanupExpired(self.timeout_seconds);
        if (removed > 0) {
            std.debug.print("[UDP-CLIENT] Cleaned up {} expired sessions\n", .{removed});
        }
    }

    pub fn stop(self: *UdpForwarder) void {
        self.running.store(false, .release);
        // Shutdown socket to unblock recvfrom()
        posix.shutdown(self.local_fd, .recv) catch {};
        self.thread.join();
    }

    pub fn destroy(self: *UdpForwarder) void {
        posix.close(self.local_fd);
        self.allocator.free(self.target_host);
        self.session_manager.deinit();
        self.allocator.destroy(self);
    }
};
