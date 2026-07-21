//! macOS Cocoa 窗口后端 (Zig 封装)

const c = @cImport({
    @cInclude("cocoa_backend.h");
});

const pal = @import("pal.zig");
const event_mod = @import("event.zig");
const window_mod = @import("window.zig");

pub const CocoaBackend = struct {
    window_handle: ?c.ZiguiWindowHandle = null,

    pub fn init() !CocoaBackend {
        if (c.zigui_cocoa_init() != 0) return error.CocoaInitFailed;
        return .{};
    }

    pub fn createWindow(self: *CocoaBackend, desc: window_mod.WindowDesc) !window_mod.Window {
        var buf: [256:0]u8 = undefined;
        const len = @min(desc.title.len, 255);
        @memcpy(buf[0..len], desc.title[0..len]);
        buf[len] = 0;

        const handle = c.zigui_cocoa_create_window(
            &buf,
            @intCast(desc.width),
            @intCast(desc.height),
        );

        self.window_handle = handle;

        return .{
            .handle = .{ .ns_window = handle.ns_window.? },
            .size = .{ .width = desc.width, .height = desc.height },
            .scale_factor = handle.scale_factor,
        };
    }

    pub fn pollEvents(self: *CocoaBackend, queue: *pal.EventQueue, allocator: std.mem.Allocator) !void {
        _ = self;
        var events: [64]c.ZiguiEvent = undefined;
        const count = c.zigui_cocoa_poll_events(&events, 64);

        var i: usize = 0;
        while (i < @as(usize, @intCast(count))) : (i += 1) {
            const ev = events[i];
            const translated = translateEvent(ev) orelse continue;
            try queue.push(allocator, translated);
        }
    }

    pub fn shouldQuit() bool {
        return c.zigui_cocoa_should_quit();
    }

    pub fn getMetalLayer(self: *CocoaBackend) ?*anyopaque {
        if (self.window_handle) |h| return h.metal_layer;
        return null;
    }

    /// 查询当前 IME 组字中的 marked text (如拼音), 写入 buf (UTF-8), 返回字节数
    pub fn getMarkedText(self: *CocoaBackend, buf: []u8) usize {
        _ = self;
        var sel_start: u32 = 0;
        var sel_end: u32 = 0;
        const n = c.zigui_cocoa_get_marked_text(buf.ptr, @intCast(buf.len), &sel_start, &sel_end);
        return @intCast(@max(n, 0));
    }

    fn translateEvent(ev: c.ZiguiEvent) ?event_mod.Event {
        const u = ev.unnamed_0;
        return switch (ev.type) {
            c.ZIGUI_EVENT_CLOSE_REQUESTED => .{ .close_requested = .{ .window_id = 0 } },
            c.ZIGUI_EVENT_RESIZE => .{ .resize = .{ .width = u.resize.width, .height = u.resize.height } },
            c.ZIGUI_EVENT_MOUSE_MOVE => .{ .mouse_move = .{
                .x = @intFromFloat(u.mouse_move.x),
                .y = @intFromFloat(u.mouse_move.y),
            } },
            c.ZIGUI_EVENT_MOUSE_BUTTON => .{ .mouse_button = .{
                .button = switch (u.mouse_button.button) {
                    0 => .left,
                    1 => .right,
                    else => .middle,
                },
                .state = if (u.mouse_button.pressed != 0) .pressed else .released,
                .x = @intFromFloat(u.mouse_button.x),
                .y = @intFromFloat(u.mouse_button.y),
            } },
            c.ZIGUI_EVENT_SCROLL => .{ .scroll = .{
                .axis = if (@abs(u.scroll.dy) >= @abs(u.scroll.dx)) .vertical else .horizontal,
                .delta = if (@abs(u.scroll.dy) >= @abs(u.scroll.dx)) u.scroll.dy else u.scroll.dx,
            } },
            c.ZIGUI_EVENT_KEY => .{ .key = .{
                .state = if (u.key.pressed != 0) .pressed else .released,
                .key = translateKeyCode(u.key.keycode),
                .modifiers = .{
                    .shift = u.key.mods_shift != 0,
                    .ctrl = u.key.mods_ctrl != 0,
                    .alt = u.key.mods_alt != 0,
                    .super_key = u.key.mods_super != 0,
                },
            } },
            c.ZIGUI_EVENT_TEXT_INPUT => .{ .text_input = .{
                .codepoint = @intCast(u.text_input.codepoint),
            } },
            c.ZIGUI_EVENT_IME_COMPOSITION => .{ .ime_composition = .{
                .cursor_start = u.ime_composition.cursor_start,
                .cursor_end = u.ime_composition.cursor_end,
            } },
            c.ZIGUI_EVENT_IME_COMMIT => .{ .ime_commit = {} },
            c.ZIGUI_EVENT_IME_CANCEL => .{ .ime_cancel = {} },
            c.ZIGUI_EVENT_FILE_DROP => blk: {
                var fd: event_mod.FileDrop = .{
                    .x = @intFromFloat(u.file_drop.x),
                    .y = @intFromFloat(u.file_drop.y),
                    .path = undefined,
                    .path_len = 0,
                };
                const n = @min(@as(usize, u.file_drop.path_len), fd.path.len);
                @memcpy(fd.path[0..n], u.file_drop.path[0..n]);
                fd.path_len = @intCast(n);
                break :blk .{ .file_drop = fd };
            },
            c.ZIGUI_EVENT_TOUCH => .{ .touch = .{
                .id = u.touch.id,
                .phase = switch (u.touch.phase) {
                    0 => .began,
                    1 => .moved,
                    2 => .ended,
                    else => .cancelled,
                },
                .x = u.touch.x,
                .y = u.touch.y,
            } },
            else => null,
        };
    }

    /// macOS virtual keycode → zigui KeyCode
    fn translateKeyCode(keycode: u16) event_mod.KeyCode {
        return switch (keycode) {
            0 => .a, 1 => .s, 2 => .d, 3 => .f, 4 => .h, 5 => .g, 6 => .z, 7 => .x,
            8 => .c, 9 => .v, 11 => .b, 12 => .q, 13 => .w, 14 => .e, 15 => .r,
            16 => .y, 17 => .t, 18 => .@"1", 19 => .@"2", 20 => .@"3", 21 => .@"4",
            22 => .@"6", 23 => .@"5", 24 => .equal, 25 => .@"9", 26 => .@"7",
            27 => .minus, 28 => .@"8", 29 => .@"0",
            30 => .right_bracket, 31 => .o, 32 => .u, 33 => .left_bracket,
            34 => .i, 35 => .p, 36 => .enter, 37 => .l, 38 => .j, 39 => .apostrophe,
            40 => .k, 41 => .semicolon, 42 => .backslash, 43 => .comma,
            44 => .slash, 45 => .n, 46 => .m, 47 => .period,
            48 => .tab, 49 => .space, 50 => .grave, 51 => .backspace,
            53 => .escape, 55 => .left_super, 56 => .left_shift, 57 => .caps_lock,
            58 => .left_alt, 59 => .left_ctrl, 60 => .right_shift, 61 => .right_alt,
            62 => .right_ctrl, 63 => .right_super,
            65 => .kp_decimal, 67 => .kp_multiply, 69 => .kp_add,
            75 => .kp_divide, 76 => .kp_enter, 78 => .kp_subtract,
            81 => .kp_equal, 82 => .kp_0, 83 => .kp_1, 84 => .kp_2, 85 => .kp_3,
            86 => .kp_4, 87 => .kp_5, 88 => .kp_6, 89 => .kp_7,
            91 => .kp_8, 92 => .kp_9,
            96 => .f5, 97 => .f6, 98 => .f7, 99 => .f3, 100 => .f8, 101 => .f9,
            103 => .f11, 105 => .f13, 107 => .f14,
            109 => .f10, 111 => .f12, 113 => .f15,
            114 => .insert, 115 => .home, 116 => .page_up, 117 => .delete,
            118 => .f4, 119 => .end, 120 => .f2, 121 => .page_down, 122 => .f1,
            123 => .left, 124 => .right, 125 => .down, 126 => .up,
            else => .escape,
        };
    }
};

const std = @import("std");
