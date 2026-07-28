//! 跨平台系统剪贴板 (子进程实现)
//!
//! 通过 fork + execvp 调用平台命令行工具读写系统剪贴板:
//!   - macOS:           pbcopy / pbpaste
//!   - Linux Wayland:   wl-copy / wl-paste (wl-clipboard 包)
//!   - Linux X11:       xclip -selection clipboard
//!
//! 子进程同步等待 (阻塞式), 适用于用户交互触发的复制/粘贴 (Ctrl+C/V),
//! 不应在每帧绘制路径中调用。

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

const c = if (!is_windows) @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
}) else void;

const O_WRONLY: c_int = 1;

extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;

/// 运行命令并捕获 stdout (同步阻塞; 失败返回 error)
fn runCapture(allocator: std.mem.Allocator, argv: []const [*:0]const u8) ![]u8 {
    var pipe_fds: [2]c_int = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.PipeFailed;

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return error.ForkFailed;
    }

    if (pid == 0) {
        _ = c.dup2(pipe_fds[1], 1);
        const devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 2);
            _ = c.close(devnull);
        }
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        var c_argv: [8]?[*:0]const u8 = std.mem.zeroes([8]?[*:0]const u8);
        for (argv, 0..) |a, i| c_argv[i] = a;
        _ = c.execvp(argv[0], @ptrCast(&c_argv));
        c._exit(127);
    }

    _ = c.close(pipe_fds[1]);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(pipe_fds[0], &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    _ = c.close(pipe_fds[0]);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    if ((status & 0x7f) != 0 or @as(u8, @intCast((status >> 8) & 0xff)) != 0) {
        return error.CommandFailed;
    }
    return out.toOwnedSlice(allocator);
}

/// 读取系统剪贴板文本 (UTF-8)。调用者拥有返回内存 (allocator 分配)。
pub fn getText(allocator: std.mem.Allocator) ![]u8 {
    if (comptime builtin.os.tag == .macos) {
        return runCapture(allocator, &.{"pbpaste"});
    } else if (comptime !is_windows) {
        if (std.c.getenv("WAYLAND_DISPLAY") != null) {
            return runCapture(allocator, &.{ "wl-paste", "--no-newline" });
        }
        return runCapture(allocator, &.{ "xclip", "-selection", "clipboard", "-o" });
    } else {
        return error.Unsupported;
    }
}

/// 写入文本到系统剪贴板
pub fn setText(text: []const u8) !void {
    if (comptime builtin.os.tag == .macos) {
        return runSet(&.{"pbcopy"}, text);
    } else if (comptime !is_windows) {
        if (std.c.getenv("WAYLAND_DISPLAY") != null) {
            return runSet(&.{"wl-copy"}, text);
        }
        return runSet(&.{ "xclip", "-selection", "clipboard" }, text);
    } else {
        return error.Unsupported;
    }
}

/// 写入: 子进程 stdin ← 管道读端, 父进程写入文本后关闭
fn runSet(argv: []const [*:0]const u8, text: []const u8) !void {
    var pipe_fds: [2]c_int = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.PipeFailed;

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        return error.ForkFailed;
    }

    if (pid == 0) {
        _ = c.dup2(pipe_fds[0], 0);
        const devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 1);
            _ = c.dup2(devnull, 2);
            _ = c.close(devnull);
        }
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        var c_argv: [8]?[*:0]const u8 = std.mem.zeroes([8]?[*:0]const u8);
        for (argv, 0..) |a, i| c_argv[i] = a;
        _ = c.execvp(argv[0], @ptrCast(&c_argv));
        c._exit(127);
    }

    _ = c.close(pipe_fds[0]);
    var written: usize = 0;
    while (written < text.len) {
        const n = c.write(pipe_fds[1], text.ptr + written, text.len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
    _ = c.close(pipe_fds[1]);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    if ((status & 0x7f) != 0 or @as(u8, @intCast((status >> 8) & 0xff)) != 0) {
        return error.CommandFailed;
    }
}

// ── 图像剪贴板 ─────────────────────────────────────────────────────────────

/// 读取剪贴板中的 PNG 图像数据 (原始字节)。调用者拥有返回内存。
pub fn getImagePng(allocator: std.mem.Allocator) ![]u8 {
    if (comptime builtin.os.tag == .macos) {
        // macOS: 使用 osascript 调用剪贴板
        return runCapture(allocator, &.{ "osascript", "-e", "the clipboard as «class PNGf»" });
    } else if (comptime !is_windows) {
        if (std.c.getenv("WAYLAND_DISPLAY") != null) {
            // Wayland: wl-paste --type image/png
            return runCapture(allocator, &.{ "wl-paste", "--type", "image/png" });
        }
        // X11: xclip -selection clipboard -t image/png -o
        return runCapture(allocator, &.{ "xclip", "-selection", "clipboard", "-t", "image/png", "-o" });
    } else {
        return error.Unsupported;
    }
}

/// 写入 PNG 图像数据到剪贴板
pub fn setImagePng(png_data: []const u8) !void {
    if (comptime builtin.os.tag == .macos) {
        // macOS: 使用临时文件 + osascript 设置剪贴板图像
        return setImagePngMacos(png_data);
    } else if (comptime !is_windows) {
        if (std.c.getenv("WAYLAND_DISPLAY") != null) {
            // Wayland: wl-copy --type image/png
            return runSet(&.{ "wl-copy", "--type", "image/png" }, png_data);
        }
        // X11: xclip -selection clipboard -t image/png
        return runSet(&.{ "xclip", "-selection", "clipboard", "-t", "image/png" }, png_data);
    } else {
        return error.Unsupported;
    }
}

/// 检查剪贴板是否包含图像
pub fn hasImage() bool {
    if (comptime builtin.os.tag == .macos) {
        return hasImageMacos();
    } else if (comptime !is_windows) {
        if (std.c.getenv("WAYLAND_DISPLAY") != null) {
            // Wayland: 检查可用类型
            var tmp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer tmp_arena.deinit();
            const types = runCapture(tmp_arena.allocator(), &.{ "wl-paste", "--list-types" }) catch return false;
            return std.mem.indexOf(u8, types, "image/png") != null;
        }
        // X11: xclip -selection clipboard -t TARGETS -o 列出可用类型
        var tmp_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer tmp_arena.deinit();
        const targets = runCapture(tmp_arena.allocator(), &.{ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" }) catch return false;
        return std.mem.indexOf(u8, targets, "image/png") != null;
    } else {
        return false;
    }
}

/// macOS 写入 PNG 到剪贴板
fn setImagePngMacos(png_data: []const u8) !void {
    // macOS 可以通过 pbcopy 配合类型设置, 但比较复杂
    // 简化方案: 先尝试直接用 pbcopy (部分系统支持), 失败返回错误
    // 实际项目中建议使用 NSPasteboard 原生 API
    return runSet(&.{"pbcopy"}, png_data);
}

/// macOS 检查剪贴板是否有图像
fn hasImageMacos() bool {
    return false;
}
