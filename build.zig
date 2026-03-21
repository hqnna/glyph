const std = @import("std");

pub fn build(b: *std.Build) anyerror!void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_tracy = b.option(bool, "tracy", "Enable the tracy profiler");
    const ztracy_dep = b.dependency("ztracy", .{ .enable_ztracy = enable_tracy orelse false });

    const library = b.addModule("glyph", .{
        .root_source_file = b.path("src/lib/lib.zig"),
        .optimize = optimize,
        .target = target,
        .imports = &.{
            .{ .name = "ztracy", .module = ztracy_dep.module("root") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "glyph",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });

    exe.root_module.addImport("glyph", library);
    exe.root_module.addImport("ztracy", ztracy_dep.module("root"));
    exe.root_module.linkLibrary(ztracy_dep.artifact("tracy"));
    b.installArtifact(exe);
}
