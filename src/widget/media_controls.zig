//! MediaControls 控件 - 媒体播放控制条 (GTK4: GtkMediaControls)
//!
//! 关联一个 MediaStream，提供播放/暂停按钮、进度条、时间标签、音量按钮。
//! 通过 setMediaStream 绑定后自动联动播放状态。
//!
//! GTK4 对应: gtk_media_controls_new() / gtk_media_controls_set_media_stream()

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const media_stream_mod = @import("media_stream.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const MediaStream = media_stream_mod.MediaStream;

pub const MediaControls = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    /// 关联的 MediaStream（非所有权）
    stream: ?*MediaStream = null,

    // ── 布局参数 ──────────────────────────────────────────────────────────
    height: f32 = 48.0,
    padding: f32 = 12.0,
    play_btn_size: f32 = 32.0,
    progress_height: f32 = 6.0,
    time_font_size: f32 = 12.0,
    vol_btn_size: f32 = 24.0,

    // ── 颜色 ─────────────────────────────────────────────────────────────
    bg_color: math.Color = math.Color.hex(0x1E1E1EFF),
    btn_color: math.Color = math.Color.hex(0xCCCCCCFF),
    btn_hover_color: math.Color = math.Color.hex(0xFFFFFFFF),
    progress_bg: math.Color = math.Color.hex(0x3A3A3AFF),
    progress_fill: math.Color = math.Color.hex(0x5B9BD5FF),
    text_color: math.Color = math.Color.hex(0xAAAAAAFF),

    // ── 交互状态 ─────────────────────────────────────────────────────────
    play_btn_hovered: bool = false,
    vol_btn_hovered: bool = false,
    progress_hovered: bool = false,
    dragging_progress: bool = false,
    volume_popup_visible: bool = false,
    volume_dragging: bool = false,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator) !*MediaControls {
        const self = try allocator.create(MediaControls);
        self.* = .{
            .allocator = allocator,
            .base = Widget.init(&vtable),
        };
        self.base.cursor = .default;
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setMediaStream(self: *Self, stream: ?*MediaStream) void {
        self.stream = stream;
        self.base.markDirty();
    }

    pub fn getMediaStream(self: *const Self) ?*MediaStream {
        return self.stream;
    }

    // ── VTable ────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "media_controls",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        const self: *Self = @fieldParentPtr("base", w);
        const h = @max(self.height, constraints.min_height);
        return .{
            .width = constraints.max_width,
            .height = @min(h, constraints.max_height),
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const r2d = ctx.renderer;
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        // 背景
        r2d.fillRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.bg_color) catch {};

        const cx = rx + self.padding;
        const cy = ry + (rh - self.play_btn_size) / 2;

        // 播放/暂停按钮
        const play_bg = if (self.play_btn_hovered) self.btn_hover_color else self.btn_color;
        r2d.fillRoundedRect(
            .{ .x = cx, .y = cy, .width = self.play_btn_size, .height = self.play_btn_size },
            6,
            play_bg,
        ) catch {};

        // 绘制 播放或暂停符号
        const is_playing = if (self.stream) |s| s.playing else false;
        const btn_cx = cx + self.play_btn_size / 2;
        const btn_cy = cy + self.play_btn_size / 2;
        if (is_playing) {
            // 暂停符号：两条竖线
            const bar_w: f32 = 4;
            const bar_h: f32 = 14;
            const gap: f32 = 4;
            r2d.fillRect(.{ .x = btn_cx - bar_w - gap / 2, .y = btn_cy - bar_h / 2, .width = bar_w, .height = bar_h }, self.bg_color) catch {};
            r2d.fillRect(.{ .x = btn_cx + gap / 2, .y = btn_cy - bar_h / 2, .width = bar_w, .height = bar_h }, self.bg_color) catch {};
        } else {
            // 播放符号：三角形
            const tri_size: f32 = 10;
            const half = tri_size / 2;
            r2d.fillTriangle(
                .{ .x = btn_cx - half, .y = btn_cy - tri_size / 2 },
                .{ .x = btn_cx - half, .y = btn_cy + tri_size / 2 },
                .{ .x = btn_cx + half, .y = btn_cy },
                self.bg_color,
            ) catch {};
        }

        // 时间标签
        const pos_us = if (self.stream) |s| s.position else 0;
        const dur_us = if (self.stream) |s| s.duration else -1;
        const pos_str = formatTime(pos_us);
        const dur_str = if (dur_us > 0) formatTime(dur_us) else "--:--";

        const pos_size = styled_text.measureText(ctx.allocator, pos_str, .{ .font_size = self.time_font_size });
        const dur_size = styled_text.measureText(ctx.allocator, dur_str, .{ .font_size = self.time_font_size });

        const time_y = ry + (rh - pos_size.height) / 2;
        var x = cx + self.play_btn_size + self.padding;

        styled_text.drawText(r2d, ctx.allocator, pos_str, x, time_y, .{
            .font_size = self.time_font_size,
            .color = self.text_color,
        });
        x += pos_size.width + 6;

        styled_text.drawText(r2d, ctx.allocator, "/", x, time_y, .{
            .font_size = self.time_font_size,
            .color = self.text_color,
        });
        x += 6;

        styled_text.drawText(r2d, ctx.allocator, dur_str, x, time_y, .{
            .font_size = self.time_font_size,
            .color = self.text_color,
        });
        x += dur_size.width + self.padding;

        // 进度条
        const prog_x = x;
        const prog_y = ry + (rh - self.progress_height) / 2;
        const vol_btn_w = self.vol_btn_size;
        const prog_w = rw - self.padding - (x - rx) - vol_btn_w - self.padding;
        if (prog_w > 10) {
            r2d.fillRoundedRect(.{ .x = prog_x, .y = prog_y, .width = prog_w, .height = self.progress_height }, 3, self.progress_bg) catch {};

            const ratio: f32 = if (dur_us > 0)
                @as(f32, @floatFromInt(@max(0, pos_us))) / @as(f32, @floatFromInt(dur_us))
            else
                0;
            const fill_w = prog_w * std.math.clamp(ratio, 0, 1);
            if (fill_w > 1) {
                r2d.fillRoundedRect(.{ .x = prog_x, .y = prog_y, .width = fill_w, .height = self.progress_height }, 3, self.progress_fill) catch {};
            }

            if (dur_us > 0) {
                const handle_x = prog_x + fill_w - 5;
                const handle_y = prog_y - 3;
                r2d.fillRoundedRect(.{ .x = handle_x, .y = handle_y, .width = 10, .height = self.progress_height + 6 }, 5, self.progress_fill) catch {};
            }
        }

        // 音量按钮
        const vol_x = rx + rw - self.padding - vol_btn_w;
        const vol_y = ry + (rh - vol_btn_w) / 2;
        const vol_bg = if (self.vol_btn_hovered) self.btn_hover_color else self.btn_color;
        r2d.fillRoundedRect(.{ .x = vol_x, .y = vol_y, .width = vol_btn_w, .height = vol_btn_w }, 4, vol_bg) catch {};

        // 音量图标：扬声器形状
        const icon_cx = vol_x + vol_btn_w / 2;
        const icon_cy = vol_y + vol_btn_w / 2;
        r2d.fillRect(.{ .x = icon_cx - 5, .y = icon_cy - 3, .width = 4, .height = 6 }, self.bg_color) catch {};
        r2d.fillTriangle(
            .{ .x = icon_cx - 1, .y = icon_cy - 6 },
            .{ .x = icon_cx - 1, .y = icon_cy + 6 },
            .{ .x = icon_cx + 4, .y = icon_cy },
            self.bg_color,
        ) catch {};

        // 音量滑块弹窗
        if (self.volume_popup_visible) {
            const popup_w: f32 = 120;
            const popup_h: f32 = 36;
            const popup_x = vol_x - (popup_w - vol_btn_w) / 2;
            const popup_y = vol_y - popup_h - 8;
            r2d.fillRoundedRect(.{ .x = popup_x, .y = popup_y, .width = popup_w, .height = popup_h }, 6, math.Color.hex(0x2A2A2AFF)) catch {};

            const vol = if (self.stream) |s| (if (s.muted) 0.0 else s.volume) else 0.0;
            const slider_x = popup_x + 8;
            const slider_y = popup_y + popup_h / 2 - 2;
            const slider_w = popup_w - 16;
            r2d.fillRoundedRect(.{ .x = slider_x, .y = slider_y, .width = slider_w, .height = 4 }, 2, self.progress_bg) catch {};
            const fill_w = slider_w * std.math.clamp(vol, 0, 1);
            if (fill_w > 1) {
                r2d.fillRoundedRect(.{ .x = slider_x, .y = slider_y, .width = fill_w, .height = 4 }, 2, self.progress_fill) catch {};
            }
            const handle_x = slider_x + fill_w - 5;
            r2d.fillRoundedRect(.{ .x = handle_x, .y = slider_y - 4, .width = 10, .height = 12 }, 5, self.progress_fill) catch {};
        }
    }

    // ── 事件 ──────────────────────────────────────────────────────────────

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ectx;
        if (self.stream == null) return .ignored;

        const rx = w.rect.x;
        const ry = w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        switch (event.*) {
            .mouse_move => |mm| {
                const mx = @as(f32, @floatFromInt(mm.x)) - rx;
                const my = @as(f32, @floatFromInt(mm.y)) - ry;

                const play_cx = self.padding;
                const play_cy = (rh - self.play_btn_size) / 2;
                self.play_btn_hovered = mx >= play_cx and mx <= play_cx + self.play_btn_size and
                    my >= play_cy and my <= play_cy + self.play_btn_size;

                const vol_x = rw - self.padding - self.vol_btn_size;
                const vol_y = (rh - self.vol_btn_size) / 2;
                self.vol_btn_hovered = mx >= vol_x and mx <= vol_x + self.vol_btn_size and
                    my >= vol_y and my <= vol_y + self.vol_btn_size;

                self.progress_hovered = self.hitProgress(mx, my, rw, rh);

                if (self.dragging_progress) {
                    self.seekToRatio(mx, rw);
                }

                if (self.volume_dragging and self.volume_popup_visible) {
                    self.setVolumeFromMouse(mx);
                }

                if (self.play_btn_hovered or self.vol_btn_hovered or
                    self.progress_hovered or self.dragging_progress or
                    self.volume_dragging)
                {
                    self.base.markDirty();
                }
                return .pass;
            },
            .mouse_button => |mb| {
                if (mb.state != .pressed) {
                    if (mb.button == .left) {
                        self.dragging_progress = false;
                        self.volume_dragging = false;
                    }
                    return .pass;
                }

                const mx = @as(f32, @floatFromInt(mb.x)) - rx;
                const my = @as(f32, @floatFromInt(mb.y)) - ry;

                // 播放按钮
                const play_cx = self.padding;
                const play_cy = (rh - self.play_btn_size) / 2;
                if (mx >= play_cx and mx <= play_cx + self.play_btn_size and
                    my >= play_cy and my <= play_cy + self.play_btn_size)
                {
                    if (self.stream) |s| {
                        if (s.playing) {
                            s.pause();
                        } else {
                            s.play();
                        }
                    }
                    self.base.markDirty();
                    return .handled;
                }

                // 音量按钮
                const vol_x = rw - self.padding - self.vol_btn_size;
                const vol_y = (rh - self.vol_btn_size) / 2;
                if (mx >= vol_x and mx <= vol_x + self.vol_btn_size and
                    my >= vol_y and my <= vol_y + self.vol_btn_size)
                {
                    self.volume_popup_visible = !self.volume_popup_visible;
                    self.base.markDirty();
                    return .handled;
                }

                // 音量弹窗滑块
                if (self.volume_popup_visible) {
                    const popup_w: f32 = 120;
                    const popup_h: f32 = 36;
                    const popup_x = vol_x - (popup_w - self.vol_btn_size) / 2;
                    const popup_y = vol_y - popup_h - 8;
                    if (mx >= popup_x and mx <= popup_x + popup_w and
                        my >= popup_y and my <= popup_y + popup_h)
                    {
                        self.volume_dragging = true;
                        self.setVolumeFromMouse(mx);
                        self.base.markDirty();
                        return .handled;
                    }
                    self.volume_popup_visible = false;
                    self.base.markDirty();
                }

                // 进度条
                if (self.hitProgress(mx, my, rw, rh)) {
                    self.dragging_progress = true;
                    self.seekToRatio(mx, rw);
                    self.base.markDirty();
                    return .handled;
                }

                return .pass;
            },
            else => return .pass,
        }
    }

    fn hitProgress(self: *const Self, mx: f32, my: f32, rw: f32, rh: f32) bool {
        const prog_y = (rh - self.progress_height) / 2;
        if (my < prog_y - 6 or my > prog_y + self.progress_height + 6) return false;

        const play_end = self.padding + self.play_btn_size + self.padding;
        const pos_size_w: f32 = 40;
        const dur_size_w: f32 = 40;
        const time_w = pos_size_w + 6 + 6 + dur_size_w + self.padding;
        const prog_x = play_end + time_w;
        const vol_btn_w = self.vol_btn_size;
        const prog_w = rw - self.padding - (prog_x) - vol_btn_w - self.padding;
        return mx >= prog_x - 4 and mx <= prog_x + prog_w + 4;
    }

    fn seekToRatio(self: *Self, mx: f32, rw: f32) void {
        const s = self.stream orelse return;
        if (s.duration <= 0) return;

        const play_end = self.padding + self.play_btn_size + self.padding;
        const pos_size_w: f32 = 40;
        const dur_size_w: f32 = 40;
        const time_w = pos_size_w + 6 + 6 + dur_size_w + self.padding;
        const prog_x = play_end + time_w;
        const vol_btn_w = self.vol_btn_size;
        const prog_w = rw - self.padding - prog_x - vol_btn_w - self.padding;

        const ratio = std.math.clamp((mx - prog_x) / prog_w, 0, 1);
        const target_us = @as(i64, @intFromFloat(ratio * @as(f32, @floatFromInt(s.duration))));
        s.seek(target_us) catch {};
        self.base.markDirty();
    }

    fn setVolumeFromMouse(self: *Self, mx: f32) void {
        const s = self.stream orelse return;
        const vol_x = self.base.rect.width - self.padding - self.vol_btn_size;
        const popup_w: f32 = 120;
        const popup_x = vol_x - (popup_w - self.vol_btn_size) / 2;
        const slider_x = popup_x + 8;
        const slider_w = popup_w - 16;
        const ratio = std.math.clamp((mx - slider_x) / slider_w, 0, 1);
        s.setVolume(ratio);
        if (ratio > 0 and s.muted) s.setMuted(false);
        self.base.markDirty();
    }
};

fn formatTime(us: i64) []const u8 {
    const S = struct {
        var buf: [16]u8 = undefined;
    };
    if (us < 0) return "--:--";
    const total_sec = @divTrunc(us, 1_000_000);
    const min = @divTrunc(total_sec, 60);
    const sec = @rem(total_sec, 60);
    return std.fmt.bufPrint(&S.buf, "{d}:{d:0>2}", .{ min, sec }) catch "--:--";
}
