const std = @import("std");

pub const CheckStatus = enum { ok, warn, fail };

pub fn reportCheck(status: CheckStatus, comptime fmt: []const u8, args: anytype) void {
    const prefix = switch (status) {
        .ok => "[OK] ",
        .warn => "[WARN] ",
        .fail => "[FAIL] ",
    };
    std.debug.print("{s}", .{prefix});
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

pub fn flushEncryptStats(prefix: []const u8, total: *std.atomic.Value(u64), calls: *std.atomic.Value(u64)) void {
    const total_ns = total.load(.acquire);
    const call_count = calls.load(.acquire);
    if (call_count == 0 or total_ns == 0) return;

    const avg = total_ns / call_count;
    std.debug.print("[PROFILE] {s} encryption total={} ns calls={} avg={} ns\n", .{ prefix, total_ns, call_count, avg });
    appendProfileLine(prefix, total_ns, call_count, avg);
}

fn appendProfileLine(prefix: []const u8, total: u64, calls: u64, avg: u64) void {
    const path = "/tmp/floo_profile.log";
    _ = std.fs.createFileAbsolute(path, .{ .truncate = false, .read = false }) catch {};

    var file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch return;
    defer file.close();

    _ = file.seekFromEnd(0) catch {};

    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\ttotal_ns={}\tcalls={}\tavg_ns={}\n", .{ prefix, total, calls, avg }) catch return;
    file.writeAll(line) catch {};
}
