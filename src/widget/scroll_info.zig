//! ScrollInfo — GTK4.4+ 滚动事件信息对象
//!
//! 对标 GtkScrollInfo：包装滚动事件数据，包括像素/逻辑/表面单位、位置、是否是惯性停止。
//! 上层滚动容器（Scrollbar/Spin/ScrolledWindow）根据 getEnabled 判断是否被消费。
//!

const std = @import("std");
const math = @import("../math.zig");

pub const ScrollUnit = enum(u2) { pixel, logical, surface };

pub const ScrollInfo = struct {
    /// 是否已处理 / 启用。GTK4 默认启用；调用 setEnabled(false) 表示此滚动事件
    /// 被某个 widget 消费，不再向上冒泡。
    enabled: bool = true,

    /// 滚动增量（与 unit 结合解释）
    delta_x: f32 = 0,
    delta_y: f32 = 0,

    /// 光标坐标（Widget 相对坐标系；可选 has_position 判断是否真实）
    cursor_x: f32 = 0,
    cursor_y: f32 = 0,
    has_position: bool = false,

    /// 惯性滚动停止信号；GTK4.12+ 新增
    is_stop: bool = false,

    unit: ScrollUnit = .pixel,

    const Self = @This();

    pub fn init() Self { return .{}; }

    // ── enabled ──────────────────────────────────────────────────────────

    pub fn setEnabled(self: *Self, v: bool) void { self.enabled = v; }
    pub fn isEnabled(self: *const Self) bool { return self.enabled; }

    // ── deltas ───────────────────────────────────────────────────────────

    pub fn setDeltas(self: *Self, dx: f32, dy: f32) void {
        self.delta_x = dx; self.delta_y = dy;
    }

    pub fn getDeltas(self: *const Self) struct { x: f32, y: f32 } {
        return .{ .x = self.delta_x, .y = self.delta_y };
    }

    pub fn setUnit(self: *Self, unit: ScrollUnit) void { self.unit = unit; }
    pub fn getUnit(self: *const Self) ScrollUnit { return self.unit; }

    // ── position ─────────────────────────────────────────────────────────

    pub fn setPosition(self: *Self, x: f32, y: f32) void {
        self.cursor_x = x;
        self.cursor_y = y;
        self.has_position = true;
    }

    pub fn getPosition(self: *const Self) struct { x: f32, y: f32, has_position: bool } {
        return .{ .x = self.cursor_x, .y = self.cursor_y, .has_position = self.has_position };
    }

    // ── stop event ───────────────────────────────────────────────────────

    pub fn setStop(self: *Self) void { self.is_stop = true; }
    pub fn isStop(self: *const Self) bool { return self.is_stop; }

    // ── 便捷：累加 delta（多次 scroll 合并） ───────────────────────────────

    pub fn addDeltas(self: *Self, dx: f32, dy: f32) void {
        self.delta_x += dx; self.delta_y += dy;
    }
};
