const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 编译选项
    const options = b.addOptions();
    const enable_wayland = b.option(bool, "wayland", "Enable Wayland backend (Linux)") orelse true;
    const enable_x11 = b.option(bool, "x11", "Enable X11 backend (Linux)") orelse true;
    const enable_vulkan_validation = b.option(bool, "vulkan-validation", "Enable Vulkan validation layers") orelse false;
    options.addOption(bool, "enable_wayland", enable_wayland);
    options.addOption(bool, "enable_x11", enable_x11);
    options.addOption(bool, "enable_vulkan_validation", enable_vulkan_validation);

    // 库模块
    const zigui_mod = b.addModule("zigui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zigui_mod.addOptions("build_options", options);

    // C include 路径 (ObjC header)
    zigui_mod.addIncludePath(b.path("src/pal/cocoa"));
    zigui_mod.addIncludePath(b.path("src/gpu"));
    zigui_mod.addIncludePath(b.path("src/text"));

    // 平台链接 + ObjC 源文件
    const os_tag = target.result.os.tag;
    switch (os_tag) {
        .windows => {
            zigui_mod.linkSystemLibrary("d3d11", .{});
            zigui_mod.linkSystemLibrary("dxgi", .{});
            zigui_mod.linkSystemLibrary("d3dcompiler", .{});
            zigui_mod.linkSystemLibrary("dwmapi", .{});
            zigui_mod.linkSystemLibrary("user32", .{});
            zigui_mod.linkSystemLibrary("gdi32", .{});
            zigui_mod.linkSystemLibrary("shell32", .{});
            zigui_mod.linkSystemLibrary("ole32", .{});
        },
        .linux => {
            if (enable_x11) {
                zigui_mod.linkSystemLibrary("xcb", .{});
                zigui_mod.linkSystemLibrary("xcb-xkb", .{});
                zigui_mod.linkSystemLibrary("xcb-xinput", .{});
                zigui_mod.linkSystemLibrary("xcb-randr", .{});
            }
            if (enable_wayland) {
                zigui_mod.linkSystemLibrary("wayland-client", .{});
            }
            zigui_mod.linkSystemLibrary("vulkan", .{});
            zigui_mod.linkSystemLibrary("xkbcommon", .{});
            zigui_mod.linkSystemLibrary("freetype2", .{});
            zigui_mod.linkSystemLibrary("harfbuzz", .{});
            zigui_mod.linkSystemLibrary("fontconfig", .{});
        },
        .macos => {
            zigui_mod.linkFramework("Cocoa", .{});
            zigui_mod.linkFramework("Metal", .{});
            zigui_mod.linkFramework("QuartzCore", .{});
            zigui_mod.linkFramework("CoreText", .{});
            zigui_mod.linkFramework("CoreGraphics", .{});
            zigui_mod.linkFramework("CoreFoundation", .{});
            // ObjC 源文件
            zigui_mod.addCSourceFiles(.{
                .files = &.{
                    "src/pal/cocoa/cocoa_backend.m",
                    "src/gpu/metal_backend.m",
                    "src/text/coretext_backend.m",
                },
                .flags = &.{ "-fobjc-arc" },
            });
        },
        else => {},
    }

    // 示例
    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "hello", .path = "examples/hello.zig" },
    };
    for (examples) |ex| {
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.path),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("zigui", zigui_mod);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step(b.fmt("run-{s}", .{ex.name}), b.fmt("Run {s} example", .{ex.name}));
        run_step.dependOn(&run_cmd.step);
    }

    // 单元测试
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
