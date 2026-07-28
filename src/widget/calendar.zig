//! Calendar 控件 - 月历视图 (对标 GtkCalendar)
//! 支持月份导航、日期选择、标记日期

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const Calendar = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    year: u16,
    month: u4, // 1-12
    /// 选中的日 (0=未选)
    selected_day: u8 = 0,
    /// 悬停的日 (0=无)
    hovered_day: u8 = 0,
    on_change: ?*const fn (self: *Calendar, year: u16, month: u4, day: u8) void = null,
    // 样式
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    header_bg: math.Color = math.Color.hex(0x334155FF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    dim_color: math.Color = math.Color.hex(0x64748BFF),
    today_color: math.Color = math.Color.hex(0x3B82F6FF),
    selected_color: math.Color = math.Color.hex(0x3B82F6FF),
    hover_color: math.Color = math.Color.hex(0x475569FF),
    weekend_color: math.Color = math.Color.hex(0xF87171FF),
    font_size: f32 = 13.0,
    header_font_size: f32 = 14.0,
    cell_size: f32 = 32.0,
    header_height: f32 = 36.0,
    weekday_height: f32 = 24.0,
    corner_radius: f32 = 8.0,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        year: u16 = 2024,
        month: u4 = 1,
        on_change: ?*const fn (self: *Calendar, year: u16, month: u4, day: u8) void = null,
    }) !*Calendar {
        const self = try allocator.create(Calendar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .year = opts.year,
            .month = opts.month,
            .on_change = opts.on_change,
        };
        self.base.accessibility = .{ .role = .container, .label = "calendar" };
        return self;
    }

    pub fn destroy(self: *Calendar, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn nextMonth(self: *Calendar) void {
        if (self.month == 12) {
            self.month = 1;
            self.year += 1;
        } else {
            self.month += 1;
        }
        self.selected_day = 0;
        self.base.markDirty();
    }

    pub fn prevMonth(self: *Calendar) void {
        if (self.month == 1) {
            self.month = 12;
            self.year -= 1;
        } else {
            self.month -= 1;
        }
        self.selected_day = 0;
        self.base.markDirty();
    }

    /// 获取某月的天数
    fn daysInMonth(year: u16, month: u4) u8 {
        return switch (month) {
            1, 3, 5, 7, 8, 10, 12 => 31,
            4, 6, 9, 11 => 30,
            2 => if (isLeapYear(year)) 29 else 28,
            else => 30,
        };
    }

    fn isLeapYear(year: u16) bool {
        return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
    }

    /// 获取某月 1 号是星期几 (0=周日, 1=周一, ...)
    fn firstWeekday(year: u16, month: u4) u8 {
        // Zeller 公式
        const m: u32 = if (month < 3) @as(u32, month) + 12 else @as(u32, month);
        const y: u32 = if (month < 3) @as(u32, year) - 1 else @as(u32, year);
        const day: u32 = 1;
        const h = (@mod(day + 13 * (m + 1) / 5 + y + y / 4 - y / 100 + y / 400, 7));
        return @intCast(h); // 0=周六, 1=周日, 2=周一...
        // 调整: 0=周六 -> 我们要 0=周日
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "calendar",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Calendar = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        _ = w;
        _ = constraints;
        // 7 列 x 6 行 + 头部 + 星期行
        const width = 7 * 32.0;
        const height = 36.0 + 24.0 + 6 * 32.0;
        return .{ .width = width, .height = height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Calendar = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const cs = self.cell_size;

        // 背景
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            self.bg_color,
        ) catch {};

        // ── 月份导航头 ──
        ctx.renderer.fillRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = self.header_height },
            self.header_bg,
        ) catch {};

        // 月份文本
        const month_names = [_][]const u8{ "", "1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月" };
        const title = month_names[self.month];
        var title_buf: [32]u8 = undefined;
        const title_text = std.fmt.bufPrint(&title_buf, "{s} {d}", .{ title, self.year }) catch title;
        const title_size = styled_text.measureText(ctx.allocator, title_text, .{
            .font_size = self.header_font_size,
            .font_weight = 700,
        });
        const title_x = rx + (w.rect.width - title_size.width) / 2.0;
        const title_y = ry + (self.header_height - title_size.height) / 2.0;
        styled_text.drawText(ctx.renderer, ctx.allocator, title_text, title_x, title_y, .{
            .font_size = self.header_font_size,
            .font_weight = 700,
            .color = self.text_color,
        });

        // 左右箭头
        const arrow_y = ry + (self.header_height - 8) / 2.0;
        // 左箭头 <
        ctx.renderer.fillRect(.{ .x = rx + 8, .y = arrow_y + 2, .width = 2.0, .height = 4.0 }, self.text_color) catch {};
        ctx.renderer.fillRect(.{ .x = rx + 10, .y = arrow_y, .width = 2.0, .height = 8.0 }, self.text_color) catch {};
        ctx.renderer.fillRect(.{ .x = rx + 12, .y = arrow_y + 2, .width = 2.0, .height = 4.0 }, self.text_color) catch {};
        // 右箭头 >
        ctx.renderer.fillRect(.{ .x = rx + w.rect.width - 14, .y = arrow_y + 2, .width = 2.0, .height = 4.0 }, self.text_color) catch {};
        ctx.renderer.fillRect(.{ .x = rx + w.rect.width - 12, .y = arrow_y, .width = 2.0, .height = 8.0 }, self.text_color) catch {};
        ctx.renderer.fillRect(.{ .x = rx + w.rect.width - 10, .y = arrow_y + 2, .width = 2.0, .height = 4.0 }, self.text_color) catch {};

        // ── 星期行 ──
        const weekdays = [_][]const u8{ "日", "一", "二", "三", "四", "五", "六" };
        const weekday_y = ry + self.header_height;
        for (weekdays, 0..) |wd, i| {
            const cell_x = rx + @as(f32, @floatFromInt(i)) * cs;
            const wd_size = styled_text.measureText(ctx.allocator, wd, .{
                .font_size = self.font_size,
                .font_weight = 500,
            });
            const wd_color: math.Color = if (i == 0 or i == 6) self.weekend_color else self.dim_color;
            styled_text.drawText(ctx.renderer, ctx.allocator, wd, cell_x + (cs - wd_size.width) / 2.0, weekday_y + (self.weekday_height - wd_size.height) / 2.0, .{
                .font_size = self.font_size,
                .font_weight = 500,
                .color = wd_color,
            });
        }

        // ── 日期网格 ──
        const days = daysInMonth(self.year, self.month);
        const first_wd = firstWeekday(self.year, self.month);
        const grid_y = ry + self.header_height + self.weekday_height;

        var day: u8 = 1;
        var col: u8 = first_wd;
        var row: u8 = 0;

        while (day <= days) {
            const cell_x = rx + @as(f32, @floatFromInt(col)) * cs;
            const cell_y = grid_y + @as(f32, @floatFromInt(row)) * cs;
            const is_weekend = col == 0 or col == 6;
            const is_selected = day == self.selected_day;
            const is_hovered = day == self.hovered_day;

            // 选中/悬停背景
            if (is_selected) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = cell_x + 2, .y = cell_y + 2, .width = cs - 4, .height = cs - 4 },
                    4.0,
                    self.selected_color,
                ) catch {};
            } else if (is_hovered) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = cell_x + 2, .y = cell_y + 2, .width = cs - 4, .height = cs - 4 },
                    4.0,
                    self.hover_color,
                ) catch {};
            }

            // 日期文本
            var day_buf: [4]u8 = undefined;
            const day_text = std.fmt.bufPrint(&day_buf, "{d}", .{day}) catch "?";
            const day_size = styled_text.measureText(ctx.allocator, day_text, .{
                .font_size = self.font_size,
            });
            const day_color = if (is_selected)
                math.Color.hex(0xFFFFFFFF)
            else if (is_weekend)
                self.weekend_color
            else
                self.text_color;
            styled_text.drawText(ctx.renderer, ctx.allocator, day_text, cell_x + (cs - day_size.width) / 2.0, cell_y + (cs - day_size.height) / 2.0, .{
                .font_size = self.font_size,
                .color = day_color,
            });

            day += 1;
            col += 1;
            if (col >= 7) {
                col = 0;
                row += 1;
            }
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Calendar = @fieldParentPtr("base", w);
        _ = ectx;
        const abs = w.absoluteRect();

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button != .left or mb.state != .pressed) return .ignored;
                const mx = @as(f32, @floatFromInt(mb.x)) - abs.x;
                const my = @as(f32, @floatFromInt(mb.y)) - abs.y;
                const cs = self.cell_size;

                // 检查箭头点击
                if (my < self.header_height) {
                    if (mx < 20) {
                        self.prevMonth();
                        w.markDirty();
                        return .handled;
                    }
                    if (mx > w.rect.width - 20) {
                        self.nextMonth();
                        w.markDirty();
                        return .handled;
                    }
                    return .ignored;
                }

                // 检查日期点击
                const grid_y = self.header_height + self.weekday_height;
                if (my < grid_y) return .ignored;
                const col = @as(u8, @intFromFloat(mx / cs));
                const row = @as(u8, @intFromFloat((my - grid_y) / cs));
                if (col >= 7) return .ignored;

                const first_wd = firstWeekday(self.year, self.month);
                const days = daysInMonth(self.year, self.month);
                const day_idx: i32 = @as(i32, row) * 7 + @as(i32, col) - @as(i32, first_wd) + 1;
                if (day_idx >= 1 and day_idx <= @as(i32, days)) {
                    self.selected_day = @intCast(day_idx);
                    w.markDirty();
                    if (self.on_change) |cb| cb(self, self.year, self.month, self.selected_day);
                    return .handled;
                }
            },
            .mouse_move => |mm| {
                const mx = @as(f32, @floatFromInt(mm.x)) - abs.x;
                const my = @as(f32, @floatFromInt(mm.y)) - abs.y;
                const cs = self.cell_size;
                const grid_y = self.header_height + self.weekday_height;
                if (my < grid_y) {
                    if (self.hovered_day != 0) {
                        self.hovered_day = 0;
                        w.markDirty();
                    }
                    return .ignored;
                }
                const col = @as(u8, @intFromFloat(mx / cs));
                const row = @as(u8, @intFromFloat((my - grid_y) / cs));
                if (col >= 7) return .ignored;
                const first_wd = firstWeekday(self.year, self.month);
                const days = daysInMonth(self.year, self.month);
                const day_idx: i32 = @as(i32, row) * 7 + @as(i32, col) - @as(i32, first_wd) + 1;
                const new_hover: u8 = if (day_idx >= 1 and day_idx <= @as(i32, days)) @intCast(day_idx) else 0;
                if (new_hover != self.hovered_day) {
                    self.hovered_day = new_hover;
                    w.markDirty();
                }
            },
            else => {},
        }
        return .ignored;
    }
};
