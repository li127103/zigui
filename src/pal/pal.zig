//! PAL - 平台抽象层
//! 统一窗口管理、事件采集、剪贴板、光标等平台服务

pub const event = @import("event.zig");
pub const window = @import("window.zig");

pub const Event = event.Event;
pub const KeyCode = event.KeyCode;
pub const Modifiers = event.Modifiers;
pub const MouseButton = event.MouseButton;
pub const ButtonState = event.ButtonState;
pub const ScrollAxis = event.ScrollAxis;
pub const TouchPhase = event.TouchPhase;

pub const Window = window.Window;
pub const WindowDesc = window.WindowDesc;
pub const SurfaceInfo = window.SurfaceInfo;

pub const PollResult = enum { events_available, no_events };

pub const CursorType = enum {
    arrow,
    ibeam,
    crosshair,
    pointing_hand,
    resize_ew,
    resize_ns,
    resize_nwse,
    resize_nesw,
    not_allowed,
    wait,
};

pub const Options = struct {
    force_backend: ?BackendType = null,
};

pub const BackendType = enum {
    win32,
    x11,
    wayland,
    cocoa,
};

/// PAL 主接口
pub const Pal = struct {
    backend: Backend,

    pub const Backend = union(enum) {
        win32: void, // Win32Backend (M1 实现)
        x11: void, // X11Backend (M1 实现)
        wayland: void, // WaylandBackend (M1 实现)
        cocoa: void, // CocoaBackend (M1 实现)
    };

    pub fn init(allocator: std.mem.Allocator, opts: Options) !Pal {
        _ = allocator;
        _ = opts;
        // M1: 根据平台初始化对应后端
        return error.NotImplemented;
    }

    pub fn deinit(self: *Pal) void {
        _ = self;
    }

    pub fn createWindow(self: *Pal, desc: WindowDesc) !Window {
        _ = self;
        _ = desc;
        return error.NotImplemented;
    }

    pub fn pollEvents(self: *Pal, events: *EventQueue) PollResult {
        _ = self;
        _ = events;
        return .no_events;
    }

    pub fn getClipboard(self: *Pal) ![]const u8 {
        _ = self;
        return error.NotImplemented;
    }

    pub fn setClipboard(self: *Pal, text_content: []const u8) !void {
        _ = self;
        _ = text_content;
    }

    pub fn setCursor(self: *Pal, cursor: CursorType) void {
        _ = self;
        _ = cursor;
    }
};

pub const EventQueue = struct {
    events: std.ArrayListUnmanaged(Event) = .{ .items = &.{}, .capacity = 0 },
    count: usize = 0,

    pub fn push(self: *EventQueue, allocator: std.mem.Allocator, ev: Event) !void {
        // 写入 count 槽位复用已 drain 的容量; 仅当 count 达到 items.len 时才扩容。
        // 不能直接 append: append 落在 items.len(只增不减), 而 drain 只取 [0..count],
        // 首次 drain 后新事件会全部落在窗口外被丢弃 (物理点击丢失的根因)。
        if (self.count < self.events.items.len) {
            self.events.items[self.count] = ev;
        } else {
            try self.events.append(allocator, ev);
        }
        self.count += 1;
    }

    pub fn drain(self: *EventQueue) []Event {
        const items = self.events.items[0..self.count];
        self.count = 0;
        return items;
    }

    pub fn deinit(self: *EventQueue, allocator: std.mem.Allocator) void {
        self.events.deinit(allocator);
    }
};

const std = @import("std");

// ── Tests ──────────────────────────────────────────────────────────────────

test "EventQueue push/drain reuses capacity without losing events" {
    // 回归测试: 历史 bug — push 用 append 落在 items.len (只增不减),
    // drain 只取 [0..count] 且仅重置 count, 首次 drain 后新事件全部
    // 落在窗口外被静默丢弃 (物理点击失效真凶)。
    var q: EventQueue = .{};
    defer q.deinit(std.testing.allocator);

    // 第一批
    try q.push(std.testing.allocator, .{ .text_input = .{ .codepoint = 'a' } });
    try q.push(std.testing.allocator, .{ .text_input = .{ .codepoint = 'b' } });
    var batch = q.drain();
    try std.testing.expectEqual(@as(usize, 2), batch.len);
    try std.testing.expectEqual(@as(u21, 'a'), batch[0].text_input.codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), batch[1].text_input.codepoint);

    // 第二批 (首次 drain 之后) — 旧实现从这里开始丢事件
    try q.push(std.testing.allocator, .{ .text_input = .{ .codepoint = 'c' } });
    try q.push(std.testing.allocator, .{ .text_input = .{ .codepoint = 'd' } });
    try q.push(std.testing.allocator, .{ .text_input = .{ .codepoint = 'e' } });
    batch = q.drain();
    try std.testing.expectEqual(@as(usize, 3), batch.len);
    try std.testing.expectEqual(@as(u21, 'c'), batch[0].text_input.codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), batch[1].text_input.codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), batch[2].text_input.codepoint);

    // 空队列 drain
    batch = q.drain();
    try std.testing.expectEqual(@as(usize, 0), batch.len);

    // 第三批 (容量复用路径: count < items.len)
    try q.push(std.testing.allocator, .{ .text_input = .{ .codepoint = 'f' } });
    batch = q.drain();
    try std.testing.expectEqual(@as(usize, 1), batch.len);
    try std.testing.expectEqual(@as(u21, 'f'), batch[0].text_input.codepoint);
}
