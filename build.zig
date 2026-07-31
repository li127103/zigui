const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 编译选项
    const options = b.addOptions();
    const enable_wayland = b.option(bool, "wayland", "Enable Wayland backend (Linux)") orelse true;
    const enable_x11 = b.option(bool, "x11", "Enable X11 backend (Linux)") orelse true;
    const enable_vulkan_validation = b.option(bool, "vulkan-validation", "Enable Vulkan validation layers") orelse false;
    const enable_vulkan = b.option(bool, "vulkan", "Use Vulkan backend on Windows (instead of default D3D11)") orelse false;
    options.addOption(bool, "enable_wayland", enable_wayland);
    options.addOption(bool, "enable_x11", enable_x11);
    options.addOption(bool, "enable_vulkan_validation", enable_vulkan_validation);
    options.addOption(bool, "enable_vulkan", enable_vulkan);

    // 库模块
    const zigui_mod = b.addModule("zigui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureModule(b, zigui_mod, target, enable_wayland, enable_x11, enable_vulkan);
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

    // 示例 (Linux 演示集合; 每个均可在当前平台运行)
    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "hello", .path = "examples/hello.zig" },
        .{ .name = "widgets", .path = "examples/widgets.zig" },
        .{ .name = "canvas", .path = "examples/canvas.zig" },
        .{ .name = "multi-window", .path = "examples/multi_window.zig" },
        .{ .name = "input", .path = "examples/input.zig" },
        .{ .name = "text", .path = "examples/text.zig" },
        .{ .name = "gallery-buttons", .path = "examples/gallery_buttons.zig" },
        .{ .name = "gallery-display", .path = "examples/gallery_display.zig" },
        .{ .name = "gallery-inputs", .path = "examples/gallery_inputs.zig" },
        .{ .name = "gallery-lists", .path = "examples/gallery_lists.zig" },
        .{ .name = "gallery-layout", .path = "examples/gallery_layout.zig" },
        .{ .name = "gallery-containers", .path = "examples/gallery_containers.zig" },
        .{ .name = "gallery-menus", .path = "examples/gallery_menus.zig" },
        .{ .name = "gallery-dialogs", .path = "examples/gallery_dialogs.zig" },
        .{ .name = "gallery-canvas", .path = "examples/gallery_canvas.zig" },
        .{ .name = "gallery-advanced", .path = "examples/gallery_advanced.zig" },
        .{ .name = "gallery-data", .path = "examples/gallery_data.zig" },
        .{ .name = "gallery-choosers", .path = "examples/gallery_choosers.zig" },
        .{ .name = "gallery-navigation", .path = "examples/gallery_navigation.zig" },
        .{ .name = "gallery-grid", .path = "examples/gallery_grid.zig" },
        .{ .name = "gallery-misc", .path = "examples/gallery_misc.zig" },
        .{ .name = "gallery-menus2", .path = "examples/gallery_menus2.zig" },
        .{ .name = "gallery-widgets3", .path = "examples/gallery_widgets3.zig" },
        .{ .name = "gallery-more1", .path = "examples/gallery_more1.zig" },
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
    configureModule(b, tests.root_module, target, enable_wayland, enable_x11, enable_vulkan);
    tests.root_module.addOptions("build_options", options);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

/// 为模块配置平台链接 + C include 路径 + ObjC/C 源文件 (库与测试共享)
fn configureModule(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, enable_wayland: bool, enable_x11: bool, enable_vulkan: bool) void {
    // C include 路径
    mod.addIncludePath(b.path("src/pal/cocoa"));
    mod.addIncludePath(b.path("src/gpu"));
    mod.addIncludePath(b.path("src/text"));

    switch (target.result.os.tag) {
        .windows => {
            // 交叉编译到 Windows 时, 指向 vendor/win32/lib 下的导入库。
            // Zig 自带 mingw 仅提供 .def(可生成 d3d11/dxgi/d2d1/dwrite 等的导入库),
            // 但 d3dcompiler 只有版本化的 d3dcompiler_47.def(按通用名 d3dcompiler 找不到),
            // 且完全没有 vulkan-1。这里用系统 mingw 的 libd3dcompiler.a 与由 Linux
            // Vulkan loader 导出的符号生成的 libvulkan-1.a 补齐。见 vendor/win32/README。
            mod.addLibraryPath(b.path("vendor/win32/lib"));
            // 自带 mingw 不含 vulkan 头文件, 用宿主的 vulkan C 头 (纯跨平台 typedef) 补齐,
            // 供 vulkan.zig 的 @cImport 在 Windows 目标下翻译 vulkan/vulkan.h。
            mod.addIncludePath(b.path("vendor/win32/include"));
            mod.linkSystemLibrary("d3d11", .{});
            mod.linkSystemLibrary("d3d12", .{});
            mod.linkSystemLibrary("dxgi", .{});
            mod.linkSystemLibrary("d3dcompiler", .{});
            mod.linkSystemLibrary("dwmapi", .{});
            mod.linkSystemLibrary("user32", .{});
            mod.linkSystemLibrary("gdi32", .{});
            mod.linkSystemLibrary("shell32", .{});
            mod.linkSystemLibrary("ole32", .{});
            // DirectWrite / D2D1 / WIC
            mod.linkSystemLibrary("dwrite", .{});
            mod.linkSystemLibrary("d2d1", .{});
            mod.linkSystemLibrary("windowscodecs", .{});
            mod.linkSystemLibrary("uuid", .{});
            mod.linkSystemLibrary("shcore", .{});
            // Vulkan (Win32 表面 + 跨平台 GPU 后端可选): 仅 -Dvulkan 时链接,
            // 默认 D3D11 构建不需要 vulkan-1 导入库。
            if (enable_vulkan) {
                mod.linkSystemLibrary("vulkan-1", .{});
            }
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
