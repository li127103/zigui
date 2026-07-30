//! 性能监控 - 帧时间统计 (FPS / 帧耗时 / 百分位)
//!
//! App 主循环每帧调用 beginFrame/endFrame 采样, 应用可读取 fps、frame_time_ms
//! 或 frameTimePercentile(0.99) 用于性能 overlay 或卡顿诊断。
//! 统计基于固定容量环形缓冲, 无堆分配。

const std = @import("std");
const builtin = @import("builtin");
const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;
const is_windows = builtin.os.tag == .windows;

/// 帧时间统计 (滚动窗口)
pub const FrameStats = struct {
    /// 环形缓冲: 最近若干帧的 CPU 耗时 (ms)
    samples: [window]f32 = [_]f32{0} ** window,
    count: usize = 0,
    write_idx: usize = 0,
    /// 上一帧起始时刻 (ns, 用于计算帧间隔 → FPS)
    last_frame_start_ns: ?u64 = null,
    /// 当前帧起始时刻 (ns)
    frame_start_ns: u64 = 0,
    /// 平滑 FPS (指数滑动平均)
    fps: f32 = 0,
    /// 最近一帧 CPU 耗时 (ms)
    frame_time_ms: f32 = 0,
    /// 累计帧数
    total_frames: u64 = 0,

    /// 统计窗口 (帧数)
    pub const window: usize = 120;

    /// 帧起始: 记录起始时刻并由帧间隔更新平滑 FPS
    pub fn beginFrame(self: *FrameStats) void {
        const now = nowNs();
        if (self.last_frame_start_ns) |last| {
            const dt_ns = now -| last;
            if (dt_ns > 0) {
                const inst = @as(f32, @floatFromInt(std.time.ns_per_s)) / @as(f32, @floatFromInt(dt_ns));
                // 首帧直接赋值, 之后指数滑动平均 (α=0.1)
                self.fps = if (self.fps <= 0) inst else self.fps * 0.9 + inst * 0.1;
            }
        }
        self.last_frame_start_ns = now;
        self.frame_start_ns = now;
    }

    /// 帧结束: 记录本帧 CPU 耗时到环形缓冲
    pub fn endFrame(self: *FrameStats) void {
        const now = nowNs();
        const dt_ms = @as(f32, @floatFromInt(now -| self.frame_start_ns)) / 1_000_000.0;
        self.frame_time_ms = dt_ms;
        self.samples[self.write_idx] = dt_ms;
        self.write_idx = (self.write_idx + 1) % window;
        if (self.count < window) self.count += 1;
        self.total_frames += 1;
    }

    /// 窗口内平均帧耗时 (ms)
    pub fn averageFrameTime(self: *const FrameStats) f32 {
        if (self.count == 0) return 0;
        var sum: f32 = 0;
        for (self.samples[0..self.count]) |s| sum += s;
        return sum / @as(f32, @floatFromInt(self.count));
    }

    /// 获取上一帧到当前帧的时间差 (ms); 首帧返回 16 (约 60fps)
    pub fn getDeltaMs(self: *const FrameStats) u32 {
        if (self.last_frame_start_ns) |last| {
            const dt_ns = self.frame_start_ns -| last;
            if (dt_ns > 0) {
                const dt_ms = @as(f32, @floatFromInt(dt_ns)) / 1_000_000.0;
                return @intFromFloat(@min(dt_ms, 100.0));
            }
        }
        return 16;
    }

    /// 窗口内帧耗时百分位 (ms); p 取值 0..1 (如 0.99 → P99 卡顿指标)
    pub fn frameTimePercentile(self: *const FrameStats, p: f32) f32 {
        if (self.count == 0) return 0;
        var buf: [window]f32 = undefined;
        const n = self.count;
        @memcpy(buf[0..n], self.samples[0..n]);
        std.mem.sort(f32, buf[0..n], {}, asc);
        var idx: usize = @intFromFloat(@round(@as(f32, @floatFromInt(n - 1)) * std.math.clamp(p, 0, 1)));
        if (idx >= n) idx = n - 1;
        return buf[idx];
    }

    fn asc(_: void, a: f32, b: f32) bool {
        return a < b;
    }
};

/// 单调时钟纳秒 (Linux: clock_gettime(MONOTONIC); macOS: mach_absolute_time 近似)
pub fn nowNs() u64 {
    if (comptime is_linux) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        const sec: u64 = @intCast(ts.sec);
        const nsec: u64 = @intCast(ts.nsec);
        return sec * std.time.ns_per_s + nsec;
    } else if (comptime is_macos) {
        // mach_absolute_time 为固定频率计数; 用于帧间隔测量 (比例一致即可)
        return std.c.mach_absolute_time();
    } else if (comptime is_windows) {
        var counter: std.os.windows.LARGE_INTEGER = undefined;
        var freq: std.os.windows.LARGE_INTEGER = undefined;
        _ = std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter);
        _ = std.os.windows.ntdll.RtlQueryPerformanceFrequency(&freq);
        const c: u64 = @bitCast(counter);
        const f: u64 = @bitCast(freq);
        return (c * std.time.ns_per_s) / f;
    } else {
        @compileError("perf: unsupported platform clock");
    }
}

/// 单调时钟毫秒（跨平台）
pub fn nowMs() u64 {
    return nowNs() / std.time.ns_per_ms;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "frame stats records samples and average" {
    var stats = FrameStats{};
    // 手动注入样本避免依赖真实时钟
    stats.samples[0] = 10;
    stats.samples[1] = 20;
    stats.count = 2;
    try std.testing.expectApproxEqAbs(@as(f32, 15), stats.averageFrameTime(), 0.001);
}

test "frame stats percentile sorts window" {
    var stats = FrameStats{};
    for ([_]f32{ 5, 1, 9, 3, 7 }) |v| {
        stats.samples[stats.count] = v;
        stats.count += 1;
    }
    // 排序后 [1,3,5,7,9]; P0=1, P100=9, P50=5
    try std.testing.expectApproxEqAbs(@as(f32, 1), stats.frameTimePercentile(0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 9), stats.frameTimePercentile(1.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), stats.frameTimePercentile(0.5), 0.001);
}

test "frame stats empty returns zero" {
    const stats = FrameStats{};
    try std.testing.expectEqual(@as(f32, 0), stats.averageFrameTime());
    try std.testing.expectEqual(@as(f32, 0), stats.frameTimePercentile(0.99));
}

test "frame stats ring buffer wraps at window" {
    var stats = FrameStats{};
    var i: usize = 0;
    while (i < FrameStats.window + 10) : (i += 1) {
        stats.samples[stats.write_idx] = @floatFromInt(i);
        stats.write_idx = (stats.write_idx + 1) % FrameStats.window;
        if (stats.count < FrameStats.window) stats.count += 1;
    }
    try std.testing.expectEqual(FrameStats.window, stats.count);
    try std.testing.expectEqual(@as(usize, 10), stats.write_idx);
}

test "begin/end frame increments total and computes fps" {
    var stats = FrameStats{};
    stats.beginFrame();
    stats.endFrame();
    try std.testing.expectEqual(@as(u64, 1), stats.total_frames);
    try std.testing.expectEqual(@as(usize, 1), stats.count);
    // 第二帧产生帧间隔 → fps > 0
    stats.beginFrame();
    try std.testing.expect(stats.fps > 0);
    stats.endFrame();
}

test "ring buffer overwrites oldest after window full" {
    var stats = FrameStats{};
    const n = FrameStats.window;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        stats.samples[stats.write_idx] = 10;
        stats.write_idx = (stats.write_idx + 1) % n;
        if (stats.count < n) stats.count += 1;
    }
    try std.testing.expectEqual(n, stats.count);
    try std.testing.expectApproxEqAbs(@as(f32, 10), stats.averageFrameTime(), 0.001);
    stats.samples[stats.write_idx] = 20;
    stats.write_idx = (stats.write_idx + 1) % n;
    const avg = stats.averageFrameTime();
    try std.testing.expect(avg > 10);
    try std.testing.expect(avg < 20);
}

test "percentile clamps p to valid range" {
    var stats = FrameStats{};
    for ([_]f32{ 1, 2, 3, 4, 5 }) |v| {
        stats.samples[stats.count] = v;
        stats.count += 1;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1), stats.frameTimePercentile(-0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5), stats.frameTimePercentile(2.0), 0.001);
}

test "single sample percentile returns same value" {
    var stats = FrameStats{};
    stats.samples[0] = 42;
    stats.count = 1;
    try std.testing.expectApproxEqAbs(@as(f32, 42), stats.frameTimePercentile(0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 42), stats.frameTimePercentile(0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 42), stats.frameTimePercentile(1.0), 0.001);
}
