//! Video 控件 - GTK4 视频播放控件
//!
//! GTK4 对应: GtkVideo
//!
//! 提供一个支持播放、暂停、停止、进度、音量控制的视频播放组件:
//! - 顶部: 封面 / 视频帧显示区
//! - 底部: 控制栏 (播放/暂停/停止, 进度条, 时间, 音量, 全屏)
//! - 自动隐藏控制栏 (鼠标不动 2.5 秒后淡出)
//! - 支持缓冲状态、错误状态、结束状态

const std = @import("std");
const perf = @import("../perf.zig");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const icons_mod = @import("icons.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Allocator = std.mem.Allocator;
const Event = pal.event_mod.Event;

pub const VideoState = enum {
    stopped,
    loading,
    playing,
    paused,
    buffering,
    ended,
    err_state,
};

pub const VideoErrorTag = enum {
    none,
    not_found,
    decode_error,
    format_unsupported,
    network,
};

pub const Video = struct {
    base: Widget,
    allocator: Allocator,

    /// 文件路径或 URL
    media_uri: []const u8 = "",
    uri_dup: []const u8 = &.{},

    state: VideoState = .stopped,
    error_code: VideoErrorTag = .none,
    error_message: []const u8 = "",

    /// 视频长度 (秒)
    duration_s: f32 = 0,
    /// 当前位置 (秒)
    position_s: f32 = 0,
    /// 已缓冲到 (秒)
    buffered_s: f32 = 0,

    /// 音量 0~1
    volume: f32 = 1,
    muted: bool = false,

    /// 循环
    loop_mode: bool = false,

    /// 是否显示内建控制栏
    show_controls: bool = true,
    /// 控制栏自动隐藏
    controls_autohide: bool = true,

    /// 封面图 (未加载视频时显示)
    poster_png: ?[]const u8 = null,

    /// 事件回调
    on_state_changed: ?*const fn (self: *Video, new_state: VideoState) void = null,
    on_position_changed: ?*const fn (self: *Video, position_s: f32) void = null,
    on_end_of_stream: ?*const fn (self: *Video) void = null,
    on_error: ?*const fn (self: *Video, code: VideoErrorTag, msg: []const u8) void = null,

    // 内部状态
    last_tick_ms: u64 = 0,
    last_mouse_move_ms: u64 = 0,
    controls_alpha: f32 = 1,
    hover_controls: bool = false,
    hover_play: bool = false,
    hover_mute: bool = false,
    hover_fullscreen: bool = false,
    drag_progress: bool = false,
    is_fullscreen: bool = false,

    // 命中检测缓存 (上次 paint 写入, onEvent 读取)
    _hit_controls_area: math.Rect = math.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
    _hit_rect_play: math.Rect = math.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
    _hit_rect_stop: math.Rect = math.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
    _hit_rect_progress: math.Rect = math.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
    _hit_rect_mute: math.Rect = math.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
    _hit_rect_volume: math.Rect = math.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },
    _hit_rect_fs: math.Rect = math.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 },

    // 样式
    bg_color: math.Color = math.Color.hex(0x000000FF),
    controls_bg: math.Color = math.Color.hex(0x000000CC),
    controls_text: math.Color = math.Color.hex(0xFFFFFFFF),
    controls_muted: math.Color = math.Color.hex(0x94A3B8FF),
    progress_track: math.Color = math.Color.hex(0x475569FF),
    progress_buf: math.Color = math.Color.hex(0x64748BFF),
    progress_fill: math.Color = math.Color.hex(0x3B82F6FF),
    icon_color: math.Color = math.Color.hex(0xFFFFFFFF),
    corner_radius: f32 = 12,

    pub fn new(allocator: Allocator, opts: struct {
        uri: []const u8 = "",
        show_controls: bool = true,
        controls_autohide: bool = true,
        volume: f32 = 1,
        muted: bool = false,
        loop_mode: bool = false,
        poster_png: ?[]const u8 = null,
        duration_s: f32 = 0,
        corner_radius: f32 = 12,
        on_state_changed: ?*const fn (self: *Video, new_state: VideoState) void = null,
        on_position_changed: ?*const fn (self: *Video, position_s: f32) void = null,
        on_end_of_stream: ?*const fn (self: *Video) void = null,
        on_error: ?*const fn (self: *Video, code: VideoErrorTag, msg: []const u8) void = null,
    }) !*Video {
        const self = try allocator.create(Video);
        const dup = if (opts.uri.len > 0) try allocator.dupe(u8, opts.uri) else &.{};
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
                .cursor = .default,
            },
            .allocator = allocator,
            .media_uri = dup,
            .uri_dup = dup,
            .show_controls = opts.show_controls,
            .controls_autohide = opts.controls_autohide,
            .volume = opts.volume,
            .muted = opts.muted,
            .loop_mode = opts.loop_mode,
            .poster_png = opts.poster_png,
            .duration_s = opts.duration_s,
            .corner_radius = opts.corner_radius,
            .on_state_changed = opts.on_state_changed,
            .on_position_changed = opts.on_position_changed,
            .on_end_of_stream = opts.on_end_of_stream,
            .on_error = opts.on_error,
        };
        self.base.accessibility = .{ .role = .panel, .label = "Video" };
        return self;
    }

    pub fn destroy(self: *Video, allocator: Allocator) void {
        self.base.background.deinit(allocator);
        if (self.uri_dup.len > 0) allocator.free(self.uri_dup);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setUri(self: *Video, uri: []const u8) !void {
        if (self.uri_dup.len > 0) self.allocator.free(self.uri_dup);
        const dup = try self.allocator.dupe(u8, uri);
        self.uri_dup = dup;
        self.media_uri = dup;
        self.position_s = 0;
        self.buffered_s = 0;
        self.state = .stopped;
        self.base.markDirty();
    }

    pub fn setDuration(self: *Video, seconds: f32) void {
        self.duration_s = @max(0, seconds);
        self.base.markDirty();
    }

    pub fn play(self: *Video) void {
        if (self.state == .err_state) return;
        if (self.state == .ended) self.position_s = 0;
        self.changeState(.playing);
    }

    pub fn pause(self: *Video) void {
        if (self.state == .playing) self.changeState(.paused);
    }

    pub fn togglePlay(self: *Video) void {
        if (self.state == .playing) self.pause() else self.play();
    }

    pub fn stop(self: *Video) void {
        self.position_s = 0;
        self.buffered_s = 0;
        self.changeState(.stopped);
    }

    pub fn seek(self: *Video, seconds: f32) void {
        const clamped = @max(0, @min(self.duration_s, seconds));
        if (clamped != self.position_s) {
            self.position_s = clamped;
            self.base.markDirty();
            if (self.on_position_changed) |cb| cb(self, self.position_s);
        }
    }

    pub fn setVolume(self: *Video, vol: f32) void {
        const clamped = @max(0, @min(1, vol));
        if (clamped != self.volume) {
            self.volume = clamped;
            if (self.volume > 0) self.muted = false;
            self.base.markDirty();
        }
    }

    pub fn setMuted(self: *Video, m: bool) void {
        if (self.muted != m) {
            self.muted = m;
            self.base.markDirty();
        }
    }

    pub fn toggleMute(self: *Video) void {
        self.setMuted(!self.muted);
    }

    pub fn setLoop(self: *Video, loop_: bool) void {
        self.loop_mode = loop_;
    }

    pub fn setErrorMsg(self: *Video, code: VideoErrorTag, msg: []const u8) void {
        self.error_code = code;
        self.error_message = msg;
        self.changeState(.err_state);
        if (self.on_error) |cb| cb(self, code, msg);
    }

    pub fn setPoster(self: *Video, png: ?[]const u8) void {
        self.poster_png = png;
        self.base.markDirty();
    }

    fn changeState(self: *Video, s: VideoState) void {
        if (self.state != s) {
            self.state = s;
            if (self.on_state_changed) |cb| cb(self, s);
            self.base.markDirty();
        }
    }

    fn fmtTime(_: *const Video, seconds: f32, buf: *[16]u8) []const u8 {
        if (!std.math.isFinite(seconds) or seconds < 0) return "0:00";
        const total: u32 = @intFromFloat(@floor(seconds));
        const h = total / 3600;
        const m = (total % 3600) / 60;
        const s = total % 60;
        if (h > 0) {
            return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch "0:00";
        } else {
            return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ m, s }) catch "0:00";
        }
    }

    /// 每帧 tick: 更新播放进度 / 缓冲 / 控制栏隐藏
    pub fn tick(self: *Video, now_ms: u64) void {
        if (self.last_tick_ms == 0) self.last_tick_ms = now_ms;
        const dt_ms = if (now_ms >= self.last_tick_ms) now_ms - self.last_tick_ms else 0;
        self.last_tick_ms = now_ms;
        const dt = @as(f32, @floatFromInt(dt_ms)) / 1000.0;

        if (self.state == .playing and self.duration_s > 0) {
            const new_pos = self.position_s + dt;
            if (new_pos >= self.duration_s) {
                if (self.loop_mode) {
                    self.position_s = 0;
                } else {
                    self.position_s = self.duration_s;
                    self.changeState(.ended);
                    if (self.on_end_of_stream) |cb| cb(self);
                }
            } else {
                self.position_s = new_pos;
            }
            self.buffered_s = @min(self.duration_s, self.position_s + 5);
            if (self.on_position_changed) |cb| cb(self, self.position_s);
            self.base.markDirty();
        }

        if (self.controls_autohide and self.show_controls) {
            const idle = if (self.last_mouse_move_ms == 0) 9999 else now_ms - self.last_mouse_move_ms;
            const target: f32 = if (idle < 2500 or self.hover_controls or self.drag_progress or self.state != .playing) 1 else 0;
            const step = dt * 3.5;
            if (self.controls_alpha < target) self.controls_alpha = @min(target, self.controls_alpha + step);
            if (self.controls_alpha > target) self.controls_alpha = @max(target, self.controls_alpha - step);
            self.base.markDirty();
        } else if (self.controls_alpha != 1) {
            self.controls_alpha = 1;
            self.base.markDirty();
        }
    }
};

const vtable = Widget.VTable{
    .type_name = "video",
    .measure = measure,
    .paint = paint,
    .on_event = onEvent,
    .focusable = true,
    .destroy = destroyVTable,
};

fn destroyVTable(w: *Widget, allocator: Allocator) void {
    const self: *Video = @fieldParentPtr("base", w);
    self.destroy(allocator);
}

fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size {
    _ = w;
    _ = ctx;
    const max_w = if (constraints.max_width < std.math.inf(f32)) constraints.max_width else 960;
    const max_h = if (constraints.max_height < std.math.inf(f32)) constraints.max_height else 720;
    return .{
        .width = @max(300, @min(720, max_w)),
        .height = @max(200, @min(480, max_h)),
    };
}

fn withAlpha(color: math.Color, alpha: f32) math.Color {
    const ca: f32 = @as(f32, @floatFromInt(color.a)) / 255.0 * alpha;
    return .{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = @intFromFloat(@max(0, @min(255, ca * 255))),
    };
}

fn paint(w: *Widget, ctx: *PaintContext) void {
    const self: *Video = @fieldParentPtr("base", w);
    const rx = ctx.offset_x + w.rect.x;
    const ry = ctx.offset_y + w.rect.y;
    const rw = w.rect.width;
    const rh = w.rect.height;
    const R = ctx.renderer;
    const alloc = ctx.allocator;

    const saved = R.getClipRect();
    R.setClipRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }) catch {};
    R.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, self.bg_color) catch {};

    const controls_h: f32 = if (self.show_controls) 60 else 0;
    const video_h = rh - controls_h;
    const video_rect = math.Rect{ .x = rx, .y = ry, .width = rw, .height = video_h };

    // 视频画面占位: 渐变背景
    const grad_top = math.Color.hex(0x0F172AFF);
    const grad_bot = math.Color.hex(0x1E293BFF);
    const grad_steps: usize = 8;
    var step_i: usize = 0;
    while (step_i < grad_steps) : (step_i += 1) {
        const t0 = @as(f32, @floatFromInt(step_i)) / @as(f32, @floatFromInt(grad_steps));
        const t1 = @as(f32, @floatFromInt(step_i + 1)) / @as(f32, @floatFromInt(grad_steps));
        const r0 = @as(f32, @floatFromInt(grad_top.r)) / 255;
        const g0 = @as(f32, @floatFromInt(grad_top.g)) / 255;
        const b0 = @as(f32, @floatFromInt(grad_top.b)) / 255;
        const a0 = @as(f32, @floatFromInt(grad_top.a)) / 255;
        const r1 = @as(f32, @floatFromInt(grad_bot.r)) / 255;
        const g1 = @as(f32, @floatFromInt(grad_bot.g)) / 255;
        const b1 = @as(f32, @floatFromInt(grad_bot.b)) / 255;
        const a1 = @as(f32, @floatFromInt(grad_bot.a)) / 255;
        const t = (t0 + t1) / 2;
        const rr = r0 + (r1 - r0) * t;
        const gg = g0 + (g1 - g0) * t;
        const bb = b0 + (b1 - b0) * t;
        const aa = a0 + (a1 - a0) * t;
        const color = math.Color{
            .r = @intFromFloat(rr * 255),
            .g = @intFromFloat(gg * 255),
            .b = @intFromFloat(bb * 255),
            .a = @intFromFloat(aa * 255),
        };
        R.fillRect(.{
            .x = video_rect.x,
            .y = video_rect.y + video_rect.height * t0,
            .width = video_rect.width,
            .height = video_rect.height * (t1 - t0) + 1,
        }, color, 0) catch {};
    }
    const bar_h = @max(6, video_h * 0.06);
    R.fillRect(.{ .x = video_rect.x, .y = video_rect.y, .width = video_rect.width, .height = bar_h }, math.Color.hex(0x000000AA), 0) catch {};
    R.fillRect(.{ .x = video_rect.x, .y = video_rect.y + video_h - bar_h, .width = video_rect.width, .height = bar_h }, math.Color.hex(0x000000AA), 0) catch {};

    const show_big_play = self.state == .stopped or self.state == .ended or self.state == .paused or self.state == .loading or self.state == .err_state;
    if (show_big_play) {
        const icon_size = @min(96, @min(video_h * 0.4, rw * 0.2));
        const cx = video_rect.x + (video_rect.width - icon_size) / 2;
        const cy = video_rect.y + (video_rect.height - icon_size) / 2;

        const bg_color_ = switch (self.state) {
            .err_state => math.Color.hex(0xEF4444AA),
            .loading => math.Color.hex(0x475569AA),
            else => math.Color.hex(0x00000088),
        };
        R.fillCircle(cx + icon_size / 2, cy + icon_size / 2, icon_size / 2 + 8, bg_color_) catch {};

        const icon_color_ = switch (self.state) {
            .err_state => math.Color.hex(0xFFFFFFFF),
            .loading => math.Color.hex(0xE2E8F0FF),
            else => self.icon_color,
        };
        if (self.state == .err_state) {
            icons_mod.drawIcon(alloc, R, icons_mod.IconName.alert_circle, .{
                .x = cx,
                .y = cy,
                .size = icon_size,
                .color = icon_color_,
            }) catch {};
        } else if (self.state == .loading) {
            icons_mod.drawIcon(alloc, R, icons_mod.IconName.loader, .{
                .x = cx,
                .y = cy,
                .size = icon_size,
                .color = icon_color_,
            }) catch {};
        } else {
            icons_mod.drawIcon(alloc, R, icons_mod.IconName.play, .{
                .x = cx,
                .y = cy,
                .size = icon_size,
                .color = icon_color_,
            }) catch {};
        }
    }

    if (self.state == .buffering or self.state == .loading) {
        const sz: f32 = 24;
        icons_mod.drawIcon(alloc, R, icons_mod.IconName.loader, .{
            .x = video_rect.x + video_rect.width - sz - 16,
            .y = video_rect.y + 16,
            .size = sz,
            .color = math.Color.hex(0xFFFFFFFF),
        }) catch {};
    }

    if (self.state == .err_state) {
        const msg = if (self.error_message.len > 0) self.error_message else "Video playback failed";
        var title_buf: [64]u8 = undefined;
        const title_msg = std.fmt.bufPrint(&title_buf, "Error: {s}", .{@tagName(self.error_code)}) catch "Error";
        const title_ts = styled_text.measureText(alloc, title_msg, .{ .font_size = 18, .bold = true });
        const msg_ts = styled_text.measureText(alloc, msg, .{ .font_size = 14 });
        const block_w = @max(title_ts.width, msg_ts.width) + 40;
        const block_h = title_ts.height + msg_ts.height + 28;
        const bx = video_rect.x + (video_rect.width - block_w) / 2;
        const by = video_rect.y + video_rect.height * 0.65;
        R.fillRoundedRect(.{ .x = bx, .y = by, .width = block_w, .height = block_h }, 8, math.Color.hex(0x000000AA)) catch {};
        styled_text.drawText(ctx, title_msg, .{
            .x = bx + 20,
            .y = by + 14,
            .color = math.Color.hex(0xFCA5A5FF),
            .font_size = 18,
            .bold = true,
        });
        styled_text.drawText(ctx, msg, .{
            .x = bx + 20,
            .y = by + 14 + title_ts.height + 8,
            .color = math.Color.hex(0xE2E8F0FF),
            .font_size = 14,
        });
    }

    if (!self.show_controls and self.duration_s > 0) {
        var buf: [16]u8 = undefined;
        var buf2: [16]u8 = undefined;
        const pos_s = self.fmtTime(self.position_s, &buf);
        const dur_s = self.fmtTime(self.duration_s, &buf2);
        var both_buf: [32]u8 = undefined;
        const both = std.fmt.bufPrint(&both_buf, "{s} / {s}", .{ pos_s, dur_s }) catch "";
        styled_text.drawText(ctx, both, .{
            .x = video_rect.x + video_rect.width - 90,
            .y = video_rect.y + 16,
            .color = math.Color.hex(0xFFFFFFFF),
            .font_size = 12,
        });
    }

    if (self.show_controls and controls_h > 0 and self.controls_alpha > 0.01) {
        const cy = ry + rh - controls_h;
        const cb = withAlpha(self.controls_bg, self.controls_alpha);
        R.fillRect(.{ .x = rx, .y = cy, .width = rw, .height = controls_h }, cb, 0) catch {};
        R.fillRoundedRectPartial(.{ .x = rx, .y = cy, .width = rw, .height = controls_h }, cb, self.corner_radius, .{
            .top_left = false,
            .top_right = false,
            .bottom_left = true,
            .bottom_right = true,
        }) catch {};

        const pad: f32 = 10;
        const btn_size: f32 = 32;
        const row_y = cy + (controls_h - 36) / 2;

        var cur_x: f32 = rx + pad;
        const play_rect = math.Rect{ .x = cur_x, .y = row_y + 2, .width = btn_size, .height = btn_size };
        const play_icon: icons_mod.IconName = if (self.state == .playing) icons_mod.IconName.pause else icons_mod.IconName.play;
        const play_bg = if (self.hover_play) withAlpha(math.Color.hex(0x334155FF), self.controls_alpha) else math.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
        if (play_bg.a > 0) R.fillRoundedRect(play_rect, 6, play_bg) catch {};
        icons_mod.drawIcon(alloc, R, play_icon, .{
            .x = play_rect.x + 8,
            .y = play_rect.y + 8,
            .size = 16,
            .color = withAlpha(self.icon_color, self.controls_alpha),
        }) catch {};
        cur_x = play_rect.x + play_rect.width + 4;

        const stop_rect = math.Rect{ .x = cur_x, .y = row_y + 2, .width = 24, .height = btn_size };
        icons_mod.drawIcon(alloc, R, icons_mod.IconName.square, .{
            .x = stop_rect.x + 6,
            .y = stop_rect.y + 10,
            .size = 12,
            .color = withAlpha(self.controls_text, self.controls_alpha),
        }) catch {};
        cur_x = stop_rect.x + stop_rect.width + 10;

        var pos_buf: [16]u8 = undefined;
        var dur_buf: [16]u8 = undefined;
        const pos_s = self.fmtTime(self.position_s, &pos_buf);
        const dur_s = if (self.duration_s > 0) self.fmtTime(self.duration_s, &dur_buf) else "--:--";
        var time_buf: [40]u8 = undefined;
        const time_text = std.fmt.bufPrint(&time_buf, "{s} / {s}", .{ pos_s, dur_s }) catch "";
        const ts = styled_text.measureText(alloc, time_text, .{ .font_size = 12 });
        styled_text.drawText(ctx, time_text, .{
            .x = cur_x,
            .y = row_y + (36 - ts.height) / 2,
            .color = withAlpha(self.controls_text, self.controls_alpha),
            .font_size = 12,
        });
        cur_x += ts.width + 12;

        const right_area_start = rx + rw - pad - 40 - 4 - 40 - 8 - 120;
        const prog_area_x = cur_x;
        const prog_area_w = @max(80, right_area_start - cur_x);
        const prog_y = row_y + 16;
        const prog_h: f32 = 4;
        R.fillRoundedRect(.{ .x = prog_area_x, .y = prog_y, .width = prog_area_w, .height = prog_h }, 2, withAlpha(self.progress_track, self.controls_alpha)) catch {};
        const buf_w = if (self.duration_s > 0) prog_area_w * (self.buffered_s / self.duration_s) else 0;
        if (buf_w > 0) {
            R.fillRoundedRect(.{ .x = prog_area_x, .y = prog_y, .width = buf_w, .height = prog_h }, 2, withAlpha(self.progress_buf, self.controls_alpha)) catch {};
        }
        const fill_w = if (self.duration_s > 0) prog_area_w * (self.position_s / self.duration_s) else 0;
        if (fill_w > 0) {
            R.fillRoundedRect(.{ .x = prog_area_x, .y = prog_y, .width = fill_w, .height = prog_h }, 2, withAlpha(self.progress_fill, self.controls_alpha)) catch {};
        }
        if (fill_w > 0) {
            R.fillCircle(prog_area_x + fill_w, prog_y + prog_h / 2, 5, withAlpha(self.progress_fill, self.controls_alpha)) catch {};
            R.fillCircle(prog_area_x + fill_w, prog_y + prog_h / 2, 3, withAlpha(math.Color.hex(0xFFFFFFFF), self.controls_alpha)) catch {};
        }

        cur_x = rx + rw - pad - 40;
        const fs_rect = math.Rect{ .x = cur_x, .y = row_y + 2, .width = 36, .height = 32 };
        const fs_bg = if (self.hover_fullscreen) withAlpha(math.Color.hex(0x334155FF), self.controls_alpha) else math.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
        if (fs_bg.a > 0) R.fillRoundedRect(fs_rect, 6, fs_bg) catch {};
        const fs_icon: icons_mod.IconName = if (self.is_fullscreen) icons_mod.IconName.minimize_2 else icons_mod.IconName.maximize_2;
        icons_mod.drawIcon(alloc, R, fs_icon, .{
            .x = fs_rect.x + 10,
            .y = fs_rect.y + 8,
            .size = 16,
            .color = withAlpha(self.icon_color, self.controls_alpha),
        }) catch {};
        cur_x = fs_rect.x - 120 - 4;

        const vol_area_x = cur_x;
        const vol_icon_rect = math.Rect{ .x = vol_area_x, .y = row_y + 2, .width = 32, .height = 32 };
        const muted_ = self.muted or self.volume < 0.001;
        const vol_icon: icons_mod.IconName = if (muted_) icons_mod.IconName.volume_x else if (self.volume < 0.33) icons_mod.IconName.volume_1 else if (self.volume < 0.66) icons_mod.IconName.volume_2 else icons_mod.IconName.volume;
        const vbg = if (self.hover_mute) withAlpha(math.Color.hex(0x334155FF), self.controls_alpha) else math.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
        if (vbg.a > 0) R.fillRoundedRect(vol_icon_rect, 6, vbg) catch {};
        icons_mod.drawIcon(alloc, R, vol_icon, .{
            .x = vol_icon_rect.x + 8,
            .y = vol_icon_rect.y + 8,
            .size = 16,
            .color = withAlpha(if (muted_) self.controls_muted else self.icon_color, self.controls_alpha),
        }) catch {};
        const vb_x = vol_icon_rect.x + vol_icon_rect.width + 4;
        const vb_w: f32 = 80;
        const vb_y = row_y + 16;
        const vb_h: f32 = 4;
        R.fillRoundedRect(.{ .x = vb_x, .y = vb_y, .width = vb_w, .height = vb_h }, 2, withAlpha(self.progress_track, self.controls_alpha)) catch {};
        const v_fill = if (muted_) 0 else vb_w * self.volume;
        if (v_fill > 0) {
            R.fillRoundedRect(.{ .x = vb_x, .y = vb_y, .width = v_fill, .height = vb_h }, 2, withAlpha(self.progress_fill, self.controls_alpha)) catch {};
            R.fillCircle(vb_x + v_fill, vb_y + vb_h / 2, 4, withAlpha(self.progress_fill, self.controls_alpha)) catch {};
        }

        self._hit_rect_play = play_rect;
        self._hit_rect_stop = stop_rect;
        self._hit_rect_progress = math.Rect{ .x = prog_area_x, .y = prog_y - 10, .width = prog_area_w, .height = prog_h + 20 };
        self._hit_rect_mute = vol_icon_rect;
        self._hit_rect_volume = math.Rect{ .x = vb_x, .y = vb_y - 10, .width = vb_w, .height = vb_h + 20 };
        self._hit_rect_fs = fs_rect;
        self._hit_controls_area = math.Rect{ .x = rx, .y = cy, .width = rw, .height = controls_h };
    } else {
        // 清空
        self._hit_controls_area = math.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
        self._hit_rect_play = math.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
        self._hit_rect_stop = math.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
        self._hit_rect_progress = math.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
        self._hit_rect_mute = math.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
        self._hit_rect_volume = math.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
        self._hit_rect_fs = math.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    if (saved) |s| R.setClipRect(s) catch {};
    R.strokeRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, 1, math.Color.hex(0x1E293BFF)) catch {};
}

fn in_rect(r: math.Rect, x: f32, y: f32) bool {
    return x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height;
}

fn onEvent(w: *Widget, event: *const Event, _: *EventContext) EventResult {
    const self: *Video = @fieldParentPtr("base", w);
    const abs_rect = w.absoluteRect();

    const now_ts = @as(i64, @intCast(perf.nowMs()));
    const now_u: u64 = @intCast(if (now_ts < 0) 0 else now_ts);

    switch (event.*) {
        .mouse_move, .scroll, .mouse_button => self.last_mouse_move_ms = now_u,
        else => {},
    }

    switch (event.*) {
        .key => |k| {
            if (k.state == .pressed) {
                switch (k.key) {
                    .space, .kp_space => {
                        self.togglePlay();
                        return .handled;
                    },
                    .k => {
                        self.togglePlay();
                        return .handled;
                    },
                    .arrow_left => {
                        self.seek(self.position_s - 5);
                        return .handled;
                    },
                    .arrow_right => {
                        self.seek(self.position_s + 5);
                        return .handled;
                    },
                    .home => {
                        self.seek(0);
                        return .handled;
                    },
                    .end => {
                        self.seek(self.duration_s);
                        return .handled;
                    },
                    .arrow_up => {
                        self.setVolume(self.volume + 0.05);
                        return .handled;
                    },
                    .arrow_down => {
                        self.setVolume(self.volume - 0.05);
                        return .handled;
                    },
                    .m => {
                        self.toggleMute();
                        return .handled;
                    },
                    .f => {
                        self.is_fullscreen = !self.is_fullscreen;
                        self.base.markDirty();
                        return .handled;
                    },
                    .escape => {
                        if (self.is_fullscreen) {
                            self.is_fullscreen = false;
                            self.base.markDirty();
                        }
                        return .handled;
                    },
                    else => {},
                }
            }
        },
        .mouse_move => |m| {
            if (!self.show_controls) return .ignored;
            const mx: f32 = @floatFromInt(m.x);
            const my: f32 = @floatFromInt(m.y);
            const hp = self._hit_controls_area;
            const hp_valid = hp.width > 0 and hp.height > 0;
            if (hp_valid and in_rect(hp, mx, my)) {
                self.hover_controls = true;
                const hrp = self._hit_rect_play;
                const hrm = self._hit_rect_mute;
                const hrfs = self._hit_rect_fs;
                const hrst = self._hit_rect_stop;
                const hrpr = self._hit_rect_progress;
                const hrv = self._hit_rect_volume;
                self.hover_play = in_rect(hrp, mx, my);
                self.hover_mute = in_rect(hrm, mx, my);
                self.hover_fullscreen = in_rect(hrfs, mx, my);
                const cursor_hand = (in_rect(hrp, mx, my) or in_rect(hrst, mx, my) or in_rect(hrm, mx, my) or in_rect(hrfs, mx, my) or in_rect(hrpr, mx, my) or in_rect(hrv, mx, my));
                self.base.cursor = if (cursor_hand) .pointing_hand else .default;
                if (self.drag_progress and self._hit_rect_progress.width > 0) {
                    const prog = self._hit_rect_progress;
                    const pct = @max(0, @min(1, (mx - prog.x) / prog.width));
                    self.seek(self.duration_s * pct);
                }
            } else {
                if (self.hover_controls or self.hover_play or self.hover_mute or self.hover_fullscreen) {
                    self.hover_controls = false;
                    self.hover_play = false;
                    self.hover_mute = false;
                    self.hover_fullscreen = false;
                    self.base.cursor = .default;
                    self.base.markDirty();
                }
            }
            return .handled;
        },
        .mouse_button => |mb| {
            if (mb.button == .left) {
                const mx: f32 = @floatFromInt(mb.x);
                const my: f32 = @floatFromInt(mb.y);
                if (self.show_controls and self._hit_controls_area.width > 0) {
                    const ca = self._hit_controls_area;
                    const in_controls = in_rect(ca, mx, my);
                    if (!in_controls and
                        mx >= abs_rect.x and mx < abs_rect.x + abs_rect.width and
                        my >= abs_rect.y and my < abs_rect.y + abs_rect.height)
                    {
                        if (mb.state == .pressed) {
                            self.togglePlay();
                            return .handled;
                        }
                    }
                }
                if (mb.state == .pressed) {
                    if (in_rect(self._hit_rect_play, mx, my)) {
                        self.togglePlay();
                        return .handled;
                    }
                    if (in_rect(self._hit_rect_stop, mx, my)) {
                        self.stop();
                        return .handled;
                    }
                    if (in_rect(self._hit_rect_mute, mx, my)) {
                        self.toggleMute();
                        return .handled;
                    }
                    if (in_rect(self._hit_rect_fs, mx, my)) {
                        self.is_fullscreen = !self.is_fullscreen;
                        self.base.markDirty();
                        return .handled;
                    }
                    if (in_rect(self._hit_rect_progress, mx, my)) {
                        self.drag_progress = true;
                        const prog = self._hit_rect_progress;
                        const pct = @max(0, @min(1, (mx - prog.x) / prog.width));
                        self.seek(self.duration_s * pct);
                        return .handled;
                    }
                    if (in_rect(self._hit_rect_volume, mx, my)) {
                        const vb = self._hit_rect_volume;
                        const pct = @max(0, @min(1, (mx - vb.x) / vb.width));
                        self.setVolume(pct);
                        return .handled;
                    }
                } else {
                    if (self.drag_progress) {
                        self.drag_progress = false;
                        return .handled;
                    }
                }
            }
        },
        .scroll => |s| {
            if (s.axis == .vertical) {
                self.setVolume(self.volume - s.delta * 0.05);
                return .handled;
            }
        },
        else => {},
    }
    return .ignored;
}
