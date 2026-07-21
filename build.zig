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

    // 平台链接
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

        // 示例也需要平台链接
        switch (os_tag) {
            .windows => {
                exe.root_module.linkSystemLibrary("d3d11", .{});
                exe.root_module.linkSystemLibrary("dxgi", .{});
                exe.root_module.linkSystemLibrary("user32", .{});
                exe.root_module.linkSystemLibrary("gdi32", .{});
                exe.root_module.linkSystemLibrary("ole32", .{});
            },
            .linux => {
                if (enable_x11) {
                    exe.root_module.linkSystemLibrary("xcb", .{});
                    exe.root_module.linkSystemLibrary("xcb-xkb", .{});
                }
                if (enable_wayland) {
                    exe.root_module.linkSystemLibrary("wayland-client", .{});
                }
                exe.root_module.linkSystemLibrary("vulkan", .{});
                exe.root_module.linkSystemLibrary("xkbcommon", .{});
                exe.root_module.linkSystemLibrary("freetype2", .{});
                exe.root_module.linkSystemLibrary("harfbuzz", .{});
            },
            .macos => {
                exe.root_module.linkFramework("Cocoa", .{});
                exe.root_module.linkFramework("Metal", .{});
                exe.root_module.linkFramework("QuartzCore", .{});
                exe.root_module.linkFramework("CoreText", .{});
                exe.root_module.linkFramework("CoreGraphics", .{});
                exe.root_module.linkFramework("CoreFoundation", .{});
            },
            else => {},
        }

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
