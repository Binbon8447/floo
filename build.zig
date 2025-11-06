const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Read version from build.zig.zon by default, can be overridden with -Dversion
    const build_zon_contents = @embedFile("build.zig.zon");
    const version_start = std.mem.indexOf(u8, build_zon_contents, ".version = \"") orelse {
        @panic("Could not find .version in build.zig.zon");
    };
    const version_value_start = version_start + ".version = \"".len;
    const version_end = std.mem.indexOfPos(u8, build_zon_contents, version_value_start, "\"") orelse {
        @panic("Could not parse .version in build.zig.zon");
    };
    const default_version_string = build_zon_contents[version_value_start..version_end];
    const version_option = b.option([]const u8, "version", "Version string reported by --version") orelse default_version_string;
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version_option);

    // Server executable: floos
    const server = b.addExecutable(.{
        .name = "floos",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    server.root_module.addOptions("build_options", build_options);
    server.root_module.strip = true;
    b.installArtifact(server);

    // Client executable: flooc
    const client = b.addExecutable(.{
        .name = "flooc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    client.root_module.addOptions("build_options", build_options);
    client.root_module.strip = true;
    b.installArtifact(client);

    // Run server
    const run_server = b.step("server", "Run the tunnel server (floos)");
    const server_cmd = b.addRunArtifact(server);
    server_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        server_cmd.addArgs(args);
    }
    run_server.dependOn(&server_cmd.step);

    // Run client
    const run_client = b.step("client", "Run the tunnel client (flooc)");
    const client_cmd = b.addRunArtifact(client);
    client_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        client_cmd.addArgs(args);
    }
    run_client.dependOn(&client_cmd.step);

    // Tests
    const protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protocol.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    protocol_tests.root_module.addOptions("build_options", build_options);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(protocol_tests).step);

    // Cross-platform release matrix
    const ReleaseTarget = struct {
        name: []const u8,
        query: std.Target.Query,
    };

    const release_cpu_option = b.option([]const u8, "release_cpu", "Override CPU model for release-all targets (e.g. haswell, znver3, baseline, native)");

    const release_targets = [_]ReleaseTarget{
        .{ .name = "x86_64-linux-gnu", .query = .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .gnu,
        } },
        .{ .name = "aarch64-linux-gnu", .query = .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .gnu,
        } },
        .{ .name = "x86_64-macos", .query = .{
            .cpu_arch = .x86_64,
            .os_tag = .macos,
        } },
        .{ .name = "aarch64-macos", .query = .{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
        } },
    };

    const release_step = b.step("release-all", "Build release binaries for common platforms");

    inline for (release_targets) |cfg| {
        var target_query = cfg.query;

        if (release_cpu_option) |cpu_name_raw| {
            const cpu_name = std.mem.trim(u8, cpu_name_raw, " \t\r\n");
            if (cpu_name.len != 0) {
                if (std.mem.eql(u8, cpu_name, "native")) {
                    target_query.cpu_model = .native;
                } else if (std.mem.eql(u8, cpu_name, "baseline")) {
                    target_query.cpu_model = .baseline;
                } else {
                    const arch = target_query.cpu_arch orelse builtin.target.cpu.arch;
                    const parsed = std.Target.Cpu.Arch.parseCpuModel(arch, cpu_name) catch |err| switch (err) {
                        error.UnknownCpuModel => null,
                    };
                    if (parsed) |model| {
                        target_query.cpu_model = .{ .explicit = model };
                    } else {
                        std.debug.print(
                            "Warning: CPU model '{s}' not valid for target {s}; using baseline\n",
                            .{ cpu_name, cfg.name },
                        );
                        target_query.cpu_model = .baseline;
                    }
                }
            }
        }

        const resolved_target = b.resolveTargetQuery(target_query);
        const server_name = "floos";
        const client_name = "flooc";
        const dest_dir = b.pathJoin(&.{ "release", cfg.name });

        const server_release = b.addExecutable(.{
            .name = server_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/server.zig"),
                .target = resolved_target,
                .optimize = .ReleaseFast,
            }),
        });
        server_release.root_module.addOptions("build_options", build_options);
        const client_release = b.addExecutable(.{
            .name = client_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/client.zig"),
                .target = resolved_target,
                .optimize = .ReleaseFast,
            }),
        });
        client_release.root_module.addOptions("build_options", build_options);
        server_release.root_module.strip = true;
        client_release.root_module.strip = true;

        release_step.dependOn(&b.addInstallArtifact(server_release, .{
            .dest_dir = .{ .override = .{ .custom = dest_dir } },
        }).step);
        release_step.dependOn(&b.addInstallArtifact(client_release, .{
            .dest_dir = .{ .override = .{ .custom = dest_dir } },
        }).step);
    }
}
