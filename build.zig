const std = @import("std");
const builtin = @import("builtin");

// const zmath = @import("src/deps/zig-gamedev/zmath/build.zig");
// const zstbi = @import("src/deps/zig-gamedev/zstbi/build.zig");
// const zflecs = @import("src/deps/zig-gamedev/zflecs/build.zig");

const mach = @import("mach");
const mach_gpu_dawn = @import("mach_gpu_dawn");
const xcode_frameworks = @import("xcode_frameworks");

const content_dir = "assets/";
const src_path = "src/aftersun.zig";

const ProcessAssetsStep = @import("src/tools/process_assets.zig").ProcessAssetsStep;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zstbi = b.dependency("zstbi", .{ .target = target, .optimize = optimize });
    const zflecs = b.dependency("zflecs", .{ .target = target, .optimize = optimize });
    const zmath = b.dependency("zmath", .{ .target = target, .optimize = optimize });

    // const zstbi_pkg = zstbi.package(b, target, optimize, .{});
    // const zmath_pkg = zmath.package(b, target, optimize, .{});
    // const zflecs_pkg = zflecs.package(b, target, optimize, .{});

    const use_sysgpu = b.option(bool, "use_sysgpu", "Use sysgpu") orelse false;

    const mach_dep = b.dependency("mach", .{
        .target = target,
        .optimize = optimize,
    });

    const zig_imgui_dep = b.dependency("zig_imgui", .{});

    const imgui_module = b.addModule("zig-imgui", .{
        .root_source_file = zig_imgui_dep.path("src/imgui.zig"),
        .imports = &.{
            .{ .name = "mach", .module = mach_dep.module("mach") },
        },
    });

    const build_options = b.addOptions();
    build_options.addOption(bool, "use_sysgpu", use_sysgpu);

    const app = try mach.CoreApp.init(b, mach_dep.builder, .{
        .name = "aftersun",
        .src = src_path,
        .target = target,
        .deps = &.{
            .{ .name = "zstbi", .module = zstbi.module("root") },
            .{ .name = "zmath", .module = zmath.module("root") },
            .{ .name = "zflecs", .module = zflecs.module("root") },
            .{ .name = "zig-imgui", .module = imgui_module },
            .{ .name = "build-options", .module = build_options.createModule() },
        },
        .optimize = optimize,
    });

    const run_step = b.step("run", "Run aftersun");
    run_step.dependOn(&app.run.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = src_path },
        .target = target,
        .optimize = optimize,
    });

    unit_tests.root_module.addImport("zstbi", zstbi.module("root"));
    unit_tests.root_module.addImport("zmath", zmath.module("root"));
    unit_tests.root_module.addImport("zflecs", zflecs.module("root"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    app.compile.root_module.addImport("zstbi", zstbi.module("root"));
    app.compile.root_module.addImport("zmath", zmath.module("root"));
    app.compile.root_module.addImport("zflecs", zflecs.module("root"));
    app.compile.root_module.addImport("zig-imgui", imgui_module);

    app.compile.linkLibrary(zstbi.artifact("zstbi"));
    app.compile.linkLibrary(zflecs.artifact("flecs"));
    app.compile.linkLibrary(zig_imgui_dep.artifact("imgui"));

    const assets = ProcessAssetsStep.init(b, "assets", "src/assets.zig", "src/animations.zig");
    const process_assets_step = b.step("process-assets", "generates struct for all assets");
    process_assets_step.dependOn(&assets.step);
    app.compile.step.dependOn(&assets.step);

    const install_content_step = b.addInstallDirectory(.{
        .source_dir = .{ .path = thisDir() ++ "/" ++ content_dir },
        .install_dir = .{ .custom = "" },
        .install_subdir = "bin/" ++ content_dir,
    });
    app.compile.step.dependOn(&install_content_step.step);
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}

comptime {
    const supported_zig = std.SemanticVersion.parse("0.12.0-dev.2063+804cee3b9") catch unreachable;
    if (builtin.zig_version.order(supported_zig) != .eq) {
        @compileError(std.fmt.comptimePrint("unsupported Zig version ({}). Required Zig version 2024.1.0-mach: https://machengine.org/about/nominated-zig/#202410-mach", .{builtin.zig_version}));
    }
}
