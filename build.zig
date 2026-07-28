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
    configureModule(b, zigui_mod, target, enable_wayland, enable_x11);
    zigui_mod.addOptions("build_options", options);

    // 平台链接 + ObjC 源文件
    const os_tag = target.result.os.tag;
    switch (os_tag) {
        .windows => {},
        .linux => {
            // Shader 编译步骤 (需要 glslangValidator)
            const compile_shaders = b.step("compile-shaders", "Compile GLSL shaders to SPIR-V");
            const shader_names = [_]struct { in: []const u8, out: []const u8 }{
                .{ .in = "shaders/src/solid.vert.glsl", .out = "shaders/spirv/solid_vert.spv" },
                .{ .in = "shaders/src/solid.frag.glsl", .out = "shaders/spirv/solid_frag.spv" },
                .{ .in = "shaders/src/textured.vert.glsl", .out = "shaders/spirv/textured_vert.spv" },
                .{ .in = "shaders/src/textured.frag.glsl", .out = "shaders/spirv/textured_frag.spv" },
            };
            for (shader_names) |shader| {
                const cmd = b.addSystemCommand(&.{ "glslangValidator", "-V" });
                cmd.addFileArg(b.path(shader.in));
                cmd.addArg("-o");
                cmd.addFileArg(b.path(shader.out));
                compile_shaders.dependOn(&cmd.step);
            }
        },
        .macos => {},
        else => {},
    }

    // 示例 (根据平台选择源文件)
    const m3_path = "examples/m3_demo.zig";
    const m4_path = "examples/m4_demo.zig";
    const bg_path = "examples/background.zig";
    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "simple", .path = "examples/simple.zig" },
        .{ .name = "hello", .path = "examples/hello.zig" },
        .{ .name = "input", .path = "examples/input.zig" },
        .{ .name = "text-align", .path = "examples/text_align.zig" },
        .{ .name = "widgets", .path = "examples/widgets.zig" },
        .{ .name = "background", .path = bg_path },
        .{ .name = "m3-demo", .path = m3_path },
        .{ .name = "m4-demo", .path = m4_path },
        .{ .name = "new-widgets", .path = "examples/new_widgets_demo.zig" },
        .{ .name = "new-controls", .path = "examples/new_controls_demo_linux.zig" },
        .{ .name = "layout-demo", .path = "examples/layout_containers_demo_linux.zig" },
        .{ .name = "perf-demo", .path = "examples/perf_demo.zig" },
        .{ .name = "multi-window", .path = "examples/multi_window_demo_linux.zig" },
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

    // 单元测试 (与库模块共享平台链接配置, 以支持 cImport 头文件)
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    configureModule(b, tests.root_module, target, enable_wayland, enable_x11);
    tests.root_module.addOptions("build_options", options);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

/// 为模块配置平台链接 + C include 路径 + ObjC/C 源文件 (库与测试共享)
fn configureModule(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, enable_wayland: bool, enable_x11: bool) void {
    // C include 路径
    mod.addIncludePath(b.path("src/pal/cocoa"));
    mod.addIncludePath(b.path("src/gpu"));
    mod.addIncludePath(b.path("src/text"));

    switch (target.result.os.tag) {
        .windows => {
            mod.linkSystemLibrary("d3d11", .{});
            mod.linkSystemLibrary("dxgi", .{});
            mod.linkSystemLibrary("d3dcompiler", .{});
            mod.linkSystemLibrary("dwmapi", .{});
            mod.linkSystemLibrary("user32", .{});
            mod.linkSystemLibrary("gdi32", .{});
            mod.linkSystemLibrary("shell32", .{});
            mod.linkSystemLibrary("ole32", .{});
        },
        .linux => {
            if (enable_x11) {
                mod.linkSystemLibrary("xcb", .{});
                mod.linkSystemLibrary("xcb-xkb", .{});
                mod.linkSystemLibrary("xcb-xinput", .{});
                mod.linkSystemLibrary("xcb-randr", .{});
            }
            if (enable_wayland) {
                mod.linkSystemLibrary("wayland-client", .{});
                mod.addIncludePath(b.path("src/pal/wayland"));
                mod.addCSourceFile(.{ .file = b.path("src/pal/wayland/xdg-shell-protocol.c"), .flags = &.{} });
                mod.addCSourceFile(.{ .file = b.path("src/pal/wayland/xdg-decoration-protocol.c"), .flags = &.{} });
                mod.addCSourceFile(.{ .file = b.path("src/pal/wayland/text-input-unstable-v3-protocol.c"), .flags = &.{} });
            }
            // 当没有 C 源文件时 (wayland 禁用)，显式链接 libc
            if (!enable_wayland) {
                mod.link_libc = true;
            }
            mod.linkSystemLibrary("vulkan", .{});
            mod.linkSystemLibrary("xkbcommon", .{});
            mod.linkSystemLibrary("xkbcommon-x11", .{});
            mod.linkSystemLibrary("freetype2", .{});
            mod.linkSystemLibrary("harfbuzz", .{});
            mod.linkSystemLibrary("fontconfig", .{});
        },
        .macos => {
            mod.linkFramework("Cocoa", .{});
            mod.linkFramework("Metal", .{});
            mod.linkFramework("QuartzCore", .{});
            mod.linkFramework("CoreText", .{});
            mod.linkFramework("CoreGraphics", .{});
            mod.linkFramework("CoreFoundation", .{});
            mod.addCSourceFiles(.{
                .files = &.{
                    "src/pal/cocoa/cocoa_backend.m",
                    "src/gpu/metal_backend.m",
                    "src/text/coretext_backend.m",
                },
                .flags = &.{"-fobjc-arc"},
            });
        },
        else => {},
    }
}
