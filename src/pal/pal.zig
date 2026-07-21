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
    events: std.ArrayListUnmanaged(Event) = .{},
    count: usize = 0,

    pub fn push(self: *EventQueue, allocator: std.mem.Allocator, ev: Event) !void {
        try self.events.append(allocator, ev);
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
