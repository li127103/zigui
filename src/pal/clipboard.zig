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
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
}) else void;

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
        // ── 子进程: stdout → 管道写端, stderr → /dev/null, exec ──
        _ = c.dup2(pipe_fds[1], 1);
        const devnull = c.open("/dev/null", 1); // O_WRONLY
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

    // ── 父进程: 读取管道至 EOF, 等待子进程退出 ──
    _ = c.close(pipe_fds[1]);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(pipe_fds[0], &buf, buf.len);
        if (n <= 0) break; // EOF 或错误
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    _ = c.close(pipe_fds[0]);

    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    // 低 7 位为信号号 (0 = 正常退出), 8-15 位为退出码
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
        // ── 子进程: stdin ← 管道读端, stdout/stderr → /dev/null, exec ──
        _ = c.dup2(pipe_fds[0], 0);
        const devnull = c.open("/dev/null", 1); // O_WRONLY
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

    // ── 父进程: 写入文本到管道, 关闭后等待子进程退出 ──
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
