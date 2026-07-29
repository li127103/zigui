//! MediaStream — GTK4 GtkMediaStream 播放流抽象
//!
//! 不是 Widget，是 GObject 级别的流对象；GtkVideo / GtkMediaFile 持有本对象。
//! 播放时间单位：微秒 (μs)，与 GTK4 一致。
//!

const std = @import("std");

const PreparedFn = *const fn (ud: ?*anyopaque, stream: *anyopaque) void;
const UnpreparedFn = *const fn (ud: ?*anyopaque) void;
const StateChangedFn = *const fn (ud: ?*anyopaque, playing: bool) void;
const PositionChangedFn = *const fn (ud: ?*anyopaque, position_us: i64) void;
const DurationChangedFn = *const fn (ud: ?*anyopaque, duration_us: i64) void;
const EndedFn = *const fn (ud: ?*anyopaque) void;
const ErrorFn = *const fn (ud: ?*anyopaque, err_str: []const u8) void;

pub const MediaStream = struct {
    allocator: std.mem.Allocator,

    playing: bool = false,
    ended: bool = false,
    seekable: bool = true,
    seeking: bool = false,

    has_audio: bool = true,
    has_video: bool = true,

    loop: bool = false,

    position: i64 = 0, // μs
    duration: i64 = -1, // μs, -1 = 未知

    volume: f32 = 1.0,
    muted: bool = false,

    prepared: bool = false,
    realized: bool = false,

    error_msg: ?[]const u8 = null,
    owned_error_msg: bool = false,

    // 回调
    on_prepared: ?PreparedFn = null,
    on_prepared_ud: ?*anyopaque = null,
    on_unprepared: ?UnpreparedFn = null,
    on_unprepared_ud: ?*anyopaque = null,
    on_state_changed: ?StateChangedFn = null,
    on_state_changed_ud: ?*anyopaque = null,
    on_position_changed: ?PositionChangedFn = null,
    on_position_changed_ud: ?*anyopaque = null,
    on_duration_changed: ?DurationChangedFn = null,
    on_duration_changed_ud: ?*anyopaque = null,
    on_ended: ?EndedFn = null,
    on_ended_ud: ?*anyopaque = null,
    on_error: ?ErrorFn = null,
    on_error_ud: ?*anyopaque = null,

    const Self = @This();

    // ── 构造 / 析构 ───────────────────────────────────────────────────────

    pub fn create(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *Self) void {
        const a = self.allocator;
        if (self.error_msg) |e| if (self.owned_error_msg) a.free(e);
        a.destroy(self);
    }

    // ── 播放控制 ──────────────────────────────────────────────────────────

    pub fn play(self: *Self) void {
        if (!self.prepared) return;
        if (self.playing) return;
        self.playing = true;
        self.ended = false;
        if (self.on_state_changed) |cb| cb(self.on_state_changed_ud, true);
    }

    pub fn pause(self: *Self) void {
        if (!self.playing) return;
        self.playing = false;
        if (self.on_state_changed) |cb| cb(self.on_state_changed_ud, false);
    }

    pub fn stop(self: *Self) void {
        self.pause();
        self.seek(0) catch {};
        self.ended = false;
    }

    pub fn seek(self: *Self, position_us: i64) !void {
        if (!self.seekable) return error.NotSeekable;
        const pos = if (self.duration > 0) std.math.clamp(position_us, 0, self.duration) else @max(0, position_us);
        self.seeking = true;
        self.position = pos;
        self.seeking = false;
        if (self.on_position_changed) |cb| cb(self.on_position_changed_ud, pos);
    }

    // ── 查询 ──────────────────────────────────────────────────────────────

    pub fn getPosition(self: *const Self) i64 {
        return self.position;
    }
    pub fn getDuration(self: *const Self) i64 {
        return self.duration;
    }
    pub fn getVolume(self: *const Self) f32 {
        return self.volume;
    }
    pub fn setVolume(self: *Self, v: f32) void {
        self.volume = std.math.clamp(v, 0.0, 1.0);
    }
    pub fn getMuted(self: *const Self) bool {
        return self.muted;
    }
    pub fn setMuted(self: *Self, v: bool) void {
        self.muted = v;
    }
    pub fn getLoop(self: *const Self) bool {
        return self.loop;
    }
    pub fn setLoop(self: *Self, v: bool) void {
        self.loop = v;
    }

    pub fn isPrepared(self: *const Self) bool {
        return self.prepared;
    }
    pub fn isPlaying(self: *const Self) bool {
        return self.playing and !self.ended;
    }
    pub fn isSeekable(self: *const Self) bool {
        return self.seekable;
    }
    pub fn hasAudio(self: *const Self) bool {
        return self.has_audio;
    }
    pub fn hasVideo(self: *const Self) bool {
        return self.has_video;
    }

    // ── 时钟步进：每帧调用，累计 position ──────────────────────────────────

    pub fn update(self: *Self, delta_us: i64) void {
        if (!self.playing) return;
        if (!self.prepared) return;
        const dur = self.duration;
        self.position += delta_us;
        if (dur > 0 and self.position >= dur) {
            if (self.loop) {
                self.position = dur;
                // loop: 回到 0
                _ = self.seek(0) catch {
                    self.position = 0;
                };
                if (self.on_position_changed) |cb| cb(self.on_position_changed_ud, 0);
            } else {
                self.position = dur;
                self.playing = false;
                self.ended = true;
                if (self.on_state_changed) |cb| cb(self.on_state_changed_ud, false);
                if (self.on_ended) |cb| cb(self.on_ended_ud);
                if (self.on_position_changed) |cb| cb(self.on_position_changed_ud, dur);
            }
        } else {
            if (self.on_position_changed) |cb| cb(self.on_position_changed_ud, self.position);
        }
    }

    // ── 供子类/调用方设置实现状态 ──────────────────────────────────────────

    pub fn setPrepared(self: *Self, prepared: bool) void {
        if (self.prepared == prepared) return;
        self.prepared = prepared;
        if (prepared) {
            if (self.on_prepared) |cb| cb(self.on_prepared_ud, self);
        } else {
            if (self.on_unprepared) |cb| cb(self.on_unprepared_ud);
        }
    }

    pub fn setDuration(self: *Self, duration_us: i64) void {
        if (self.duration == duration_us) return;
        self.duration = duration_us;
        if (self.on_duration_changed) |cb| cb(self.on_duration_changed_ud, duration_us);
    }

    pub fn setError(self: *Self, msg: []const u8) void {
        const a = self.allocator;
        if (self.error_msg) |e| if (self.owned_error_msg) a.free(e);
        const owned = a.dupe(u8, msg) catch {
            self.error_msg = msg;
            self.owned_error_msg = false;
            if (self.on_error) |cb| cb(self.on_error_ud, msg);
            return;
        };
        self.error_msg = owned;
        self.owned_error_msg = true;
        if (self.on_error) |cb| cb(self.on_error_ud, owned);
    }

    // ── 回调注册 ──────────────────────────────────────────────────────────

    pub fn setOnPrepared(self: *Self, cb: ?PreparedFn, ud: ?*anyopaque) void {
        self.on_prepared = cb;
        self.on_prepared_ud = ud;
    }
    pub fn setOnUnprepared(self: *Self, cb: ?UnpreparedFn, ud: ?*anyopaque) void {
        self.on_unprepared = cb;
        self.on_unprepared_ud = ud;
    }
    pub fn setOnStateChanged(self: *Self, cb: ?StateChangedFn, ud: ?*anyopaque) void {
        self.on_state_changed = cb;
        self.on_state_changed_ud = ud;
    }
    pub fn setOnPositionChanged(self: *Self, cb: ?PositionChangedFn, ud: ?*anyopaque) void {
        self.on_position_changed = cb;
        self.on_position_changed_ud = ud;
    }
    pub fn setOnDurationChanged(self: *Self, cb: ?DurationChangedFn, ud: ?*anyopaque) void {
        self.on_duration_changed = cb;
        self.on_duration_changed_ud = ud;
    }
    pub fn setOnEnded(self: *Self, cb: ?EndedFn, ud: ?*anyopaque) void {
        self.on_ended = cb;
        self.on_ended_ud = ud;
    }
    pub fn setOnError(self: *Self, cb: ?ErrorFn, ud: ?*anyopaque) void {
        self.on_error = cb;
        self.on_error_ud = ud;
    }
};
