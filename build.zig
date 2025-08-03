const std = @import("std");

const is_0_15 = @import("builtin").zig_version.major == 0 and @import("builtin").zig_version.minor == 15;

pub fn build(b: *std.Build) void {
    if (!is_0_15) {
        const zig_dep, const zig_exe = switch (@import("builtin").os.tag) {
            .linux => .{ "zig_linux", "zig" },
            .windows => .{ "zig_windows", "zig.exe" },
            else => @panic("Unsupported OS"),
        };
        const zig = b.lazyDependency(zig_dep, .{}) orelse return;
        const zig_path = zig.path(zig_exe).getPath(zig.builder);
        _ = b.run(&.{ zig_path, "build" });
        return;
    }

    const exe = b.addExecutable(.{
        .name = "main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
