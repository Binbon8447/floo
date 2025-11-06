const std = @import("std");
const posix = std.posix;
const tunnel = @import("tunnel.zig");
const config = @import("config.zig");
const udp_session = @import("udp_session.zig");

/// UDP forwarder for server side
/// Handles UDP forwarding from tunnel to target and back
///
/// Design: Server maintains a single UDP socket for the target service.
/// It tracks the most recent client source address to route responses back.
/// For initial implementation, this is simple and works for most use cases.
pub const UdpForwarder = struct {
    allocator: std.mem.Allocator,
    target_host: []const u8,
    target_port: u16,
    target_addr: std.net.Address,
    udp_fd: posix.fd_t,
    tunnel_conn: *anyopaque, // Opaque pointer to TunnelConnection
    send_fn: *const fn (conn: *anyopaque, payload: []const u8) anyerror!void,
    running: std.atomic.Value(bool),
    thread: std.Thread,

    // Track most recent client source for routing responses
    // This is simplified - proper implementation would track multiple sessions
    last_source_mutex: std.Thread.Mutex,
    last_source_service_id: tunnel.ServiceId,
    last_source_stream_id: tunnel.StreamId,
    last_source_addr_bytes: [16]u8,
    last_source_addr_len: u8,
    last_source_port: u16,

    pub fn create(
        allocator: std.mem.Allocator,
        target_host: []const u8,
        target_port: u16,
        tunnel_conn: *anyopaque,
        send_fn: *const fn (conn: *anyopaque, payload: []const u8) anyerror!void,
    ) !*UdpForwarder {
        // Resolve target address
        const target_addr = try std.net.Address.resolveIp(target_host, target_port);

        // Create UDP socket
        const udp_fd = try posix.socket(
            posix.AF.INET,
            posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(udp_fd);

        const forwarder = try allocator.create(UdpForwarder);
        forwarder.* = .{
            .allocator = allocator,
            .target_host = try allocator.dupe(u8, target_host),
            .target_port = target_port,
            .target_addr = target_addr,
            .udp_fd = udp_fd,
            .tunnel_conn = tunnel_conn,
            .send_fn = send_fn,
            .running = std.atomic.Value(bool).init(true),
            .thread = undefined,
            .last_source_mutex = .{},
            .last_source_service_id = 0,
            .last_source_stream_id = 0,
            .last_source_addr_bytes = undefined,
            .last_source_addr_len = 0,
            .last_source_port = 0,
        };

        // Start receiver thread (receives responses from target)
        forwarder.thread = try std.Thread.spawn(.{
            .stack_size = 256 * 1024,
        }, receiveThreadMain, .{forwarder});

        return forwarder;
    }

    fn receiveThreadMain(self: *UdpForwarder) void {
        var buf: [65536]u8 align(64) = undefined;
        var from_addr: posix.sockaddr.storage = undefined;
        var from_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

        std.debug.print("[UDP-SERVER] Receiver thread started for target {s}:{}\n", .{
            self.target_host,
            self.target_port,
        });

        while (self.running.load(.acquire)) {
            // Receive UDP response from target
            const n = posix.recvfrom(
                self.udp_fd,
                &buf,
                0,
                @ptrCast(&from_addr),
                &from_len,
            ) catch |err| {
                std.debug.print("[UDP-SERVER] recvfrom error: {}\n", .{err});
                continue;
            };

            if (n == 0) continue;

            // Get last source info to route response back
            self.last_source_mutex.lock();
            const stream_id = self.last_source_stream_id;
            const service_id = self.last_source_service_id;
            const source_addr_len = self.last_source_addr_len;
            var source_addr_bytes: [16]u8 = undefined;
            @memcpy(source_addr_bytes[0..source_addr_len], self.last_source_addr_bytes[0..source_addr_len]);
            const source_port = self.last_source_port;
            self.last_source_mutex.unlock();

            if (source_addr_len == 0) {
                // No client has sent yet, drop packet
                continue;
            }

            std.debug.print("[UDP-SERVER] Received {} bytes from target, routing to stream_id={}\n", .{
                n,
                stream_id,
            });

            // Encode UDP data message to send back through tunnel
            var encode_buf: [70000]u8 = undefined;

            const udp_msg = tunnel.UdpDataMsg{
                .service_id = service_id,
                .stream_id = stream_id,
                .source_addr = source_addr_bytes[0..source_addr_len],
                .source_port = source_port,
                .data = buf[0..n],
            };

            const encoded_len = udp_msg.encodeInto(&encode_buf) catch |err| {
                std.debug.print("[UDP-SERVER] Encode error: {}\n", .{err});
                continue;
            };

            // Send through tunnel back to client
            self.send_fn(self.tunnel_conn, encode_buf[0..encoded_len]) catch |err| {
                std.debug.print("[UDP-SERVER] Tunnel send error: {}\n", .{err});
            };
        }

        std.debug.print("[UDP-SERVER] Receiver thread stopped\n", .{});
    }

    /// Handle incoming UDP data from tunnel (forward to target)
    /// Also saves source address for routing responses back
    pub fn handleUdpData(self: *UdpForwarder, udp_msg: tunnel.UdpDataMsg) !void {
        // Save source address for routing responses back
        self.last_source_mutex.lock();
        self.last_source_service_id = udp_msg.service_id;
        self.last_source_stream_id = udp_msg.stream_id;
        self.last_source_addr_len = @intCast(udp_msg.source_addr.len);
        @memcpy(self.last_source_addr_bytes[0..udp_msg.source_addr.len], udp_msg.source_addr);
        self.last_source_port = udp_msg.source_port;
        self.last_source_mutex.unlock();

        // Forward to target
        _ = try posix.sendto(
            self.udp_fd,
            udp_msg.data,
            0,
            &self.target_addr.any,
            self.target_addr.getOsSockLen(),
        );

        std.debug.print("[UDP-SERVER] Forwarded {} bytes to target {s}:{} (stream_id={})\n", .{
            udp_msg.data.len,
            self.target_host,
            self.target_port,
            udp_msg.stream_id,
        });
    }

    pub fn stop(self: *UdpForwarder) void {
        self.running.store(false, .release);
        // Shutdown socket to unblock recvfrom()
        posix.shutdown(self.udp_fd, .recv) catch {};
        self.thread.join();
    }

    pub fn destroy(self: *UdpForwarder) void {
        posix.close(self.udp_fd);
        self.allocator.free(self.target_host);
        self.allocator.destroy(self);
    }
};
