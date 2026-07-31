//! Notebook 控件 - 标签页容器（GTK4: GtkNotebook）
//!
//! 支持：
//!   - 多标签页切换，活动页内容绘制 + 事件转发
//!   - GTK4 命名对齐：append_page / remove_page / get_nth_page / page_num
//!   - 标签位置：top / bottom / left / right
//!   - 显示/隐藏标签栏（show_tabs）、显示/隐藏边框（show_border）
//!   - 单页属性：reorderable / detachable / can_close（标签关闭按钮 ×）
//!   - 关闭回调：on_tab_close_requested（用户点击 × 触发）

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

/// 标签位置（GTK4: GtkPositionType）
pub const NotebookTabPosition = enum { top, bottom, left, right };

/// Notebook（GTK4: GtkNotebook）
pub const Notebook = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    tabs: std.ArrayListUnmanaged(Tab),
    active: usize = 0,
    font_size: f32,
    on_change: ?*const fn (self: *Notebook, index: usize) void,
    /// 用户点击单页 × 关闭按钮时触发（返回值忽略，调用方内部自行 removePage）
    on_tab_close_requested: ?*const fn (self: *Notebook, index: usize) void = null,
    // 样式
    tab_bg: math.Color = math.Color.hex(0x1E293BFF),
    tab_active_bg: math.Color = math.Color.hex(0x0F172AFF),
    tab_text: math.Color = math.Color.hex(0x94A3B8FF),
    tab_active_text: math.Color = math.Color.hex(0xF8FAFCFF),
    indicator_color: math.Color = math.Color.hex(0x3B82F6FF),
    border_color: math.Color = math.Color.hex(0x334155FF),
    tab_height: f32 = 40.0,
    tab_padding_h: f32 = 20.0,
    corner_radius: f32 = 8.0,
    close_btn_size: f32 = 16.0,
    // GTK4 属性
    show_tabs: bool = true,
    show_border: bool = true,
    tab_pos: NotebookTabPosition = .top,
    scrollable: bool = false,

    pub const Tab = struct {
        title: []const u8,
        content: ?*Widget = null,
        reorderable: bool = false,
        detachable: bool = false,
        can_close: bool = false,
    };

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        font_size: f32 = 14.0,
        on_change: ?*const fn (self: *Notebook, index: usize) void = null,
        on_tab_close_requested: ?*const fn (self: *Notebook, index: usize) void = null,
        show_tabs: bool = true,
        show_border: bool = true,
        tab_pos: NotebookTabPosition = .top,
    }) !*Notebook {
        const self = try allocator.create(Notebook);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .tabs = .{ .items = &.{}, .capacity = 0 },
            .font_size = opts.font_size,
            .on_change = opts.on_change,
            .on_tab_close_requested = opts.on_tab_close_requested,
            .show_tabs = opts.show_tabs,
            .show_border = opts.show_border,
            .tab_pos = opts.tab_pos,
        };
        return self;
    }

    pub fn destroy(self: *Notebook, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.tabs.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    // ── GTK4 对标 API ───────────────────────────────────────────────────────

    /// GTK4: gtk_notebook_append_page → 返回新增页索引
    pub fn appendPage(self: *Notebook, title: []const u8, content: ?*Widget) !usize {
        const idx = self.tabs.items.len;
        try self.tabs.append(self.allocator, .{
            .title = title,
            .content = content,
        });
        self.base.markDirty();
        return idx;
    }

    /// 兼容旧 API（转调 appendPage，不返回索引）
    pub fn addTab(self: *Notebook, title: []const u8, content: ?*Widget) !void {
        _ = try self.appendPage(title, content);
    }

    /// GTK4: gtk_notebook_remove_page
    pub fn removePage(self: *Notebook, index: usize) void {
        if (index >= self.tabs.items.len) return;
        _ = self.tabs.orderedRemove(index);
        // 活动页修正
        if (self.active >= self.tabs.items.len) {
            if (self.tabs.items.len > 0) {
                self.active = self.tabs.items.len - 1;
            } else {
                self.active = 0;
            }
        }
        if (self.on_change) |cb| cb(self, self.active);
        self.base.markDirty();
    }

    pub fn getNPages(self: *const Notebook) usize {
        return self.tabs.items.len;
    }

    /// GTK4: gtk_notebook_get_nth_page
    pub fn getNthPage(self: *const Notebook, n: usize) ?*Widget {
        if (n < self.tabs.items.len) return self.tabs.items[n].content;
        return null;
    }

    /// GTK4: gtk_notebook_page_num → 反查 content 所在页
    pub fn pageNum(self: *const Notebook, child: *const Widget) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.content == child) return i;
        }
        return null;
    }

    pub fn setActive(self: *Notebook, index: usize) void {
        if (index < self.tabs.items.len and index != self.active) {
            self.active = index;
            self.base.markDirty();
            if (self.on_change) |cb| cb(self, index);
        }
    }

    pub fn getCurrentPage(self: *const Notebook) usize {
        return self.active;
    }

    pub fn setShowTabs(self: *Notebook, v: bool) void {
        self.show_tabs = v;
        self.base.markDirty();
    }

    pub fn getShowTabs(self: *const Notebook) bool {
        return self.show_tabs;
    }

    pub fn setShowBorder(self: *Notebook, v: bool) void {
        self.show_border = v;
        self.base.markDirty();
    }

    pub fn setTabPos(self: *Notebook, pos: NotebookTabPosition) void {
        self.tab_pos = pos;
        self.base.markDirty();
    }

    pub fn getTabPos(self: *const Notebook) NotebookTabPosition {
        return self.tab_pos;
    }

    pub fn setTabReorderable(self: *Notebook, index: usize, v: bool) void {
        if (index < self.tabs.items.len) {
            self.tabs.items[index].reorderable = v;
            self.base.markDirty();
        }
    }

    pub fn setTabDetachable(self: *Notebook, index: usize, v: bool) void {
        if (index < self.tabs.items.len) {
            self.tabs.items[index].detachable = v;
            self.base.markDirty();
        }
    }

    pub fn setTabCanClose(self: *Notebook, index: usize, v: bool) void {
        if (index < self.tabs.items.len) {
            self.tabs.items[index].can_close = v;
            self.base.markDirty();
        }
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "notebook",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Notebook = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = w;
        _ = ctx;
        _ = constraints;
        return .{ .width = 400, .height = 300 };
    }

    // ── paint（修复 Bug A：画活动 content） ────────────────────────────────

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Notebook = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        // 背景（fill 整个 widget 区域以保证透明区域正确）
        ctx.renderer.fillRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.tab_bg) catch {};

        // 1. show_border：外框
        const border_w: f32 = if (self.show_border) 1.0 else 0.0;

        // 2. 计算标签栏区域 / 内容区域
        const bar_h = if (self.show_tabs) self.tab_height else 0.0;
        var tab_area: math.Rect(f32) = undefined;
        var content_area: math.Rect(f32) = undefined;

        switch (self.tab_pos) {
            .top => {
                tab_area = .{ .x = rx, .y = ry, .width = rw, .height = bar_h };
                content_area = .{ .x = rx + border_w, .y = ry + bar_h + border_w, .width = rw - 2 * border_w, .height = rh - bar_h - 2 * border_w };
            },
            .bottom => {
                tab_area = .{ .x = rx, .y = ry + rh - bar_h, .width = rw, .height = bar_h };
                content_area = .{ .x = rx + border_w, .y = ry + border_w, .width = rw - 2 * border_w, .height = rh - bar_h - 2 * border_w };
            },
            .left => {
                tab_area = .{ .x = rx, .y = ry, .width = self.tab_height * 2.0, .height = rh }; // 左侧：竖排 tab，宽度约 2*height
                content_area = .{ .x = rx + tab_area.width + border_w, .y = ry + border_w, .width = rw - tab_area.width - 2 * border_w, .height = rh - 2 * border_w };
            },
            .right => {
                tab_area = .{ .x = rx + rw - self.tab_height * 2.0, .y = ry, .width = self.tab_height * 2.0, .height = rh };
                content_area = .{ .x = rx + border_w, .y = ry + border_w, .width = rw - tab_area.width - 2 * border_w, .height = rh - 2 * border_w };
            },
        }

        // 3. 画边框（show_border）
        if (self.show_border) {
            ctx.renderer.strokeRect(.{ .x = rx + 0.5, .y = ry + 0.5, .width = rw - 1.0, .height = rh - 1.0 }, 1.0, self.border_color) catch {};
        }

        // 4. 标签栏绘制
        if (self.show_tabs and self.tabs.items.len > 0) {
            // 标签栏背景
            ctx.renderer.fillRect(
                .{ .x = tab_area.x, .y = tab_area.y, .width = tab_area.width, .height = tab_area.height },
                self.tab_bg,
            ) catch {};

            // 各 tab 水平绘制（top/bottom），left/right 简化按水平（后续可扩展）
            switch (self.tab_pos) {
                .top, .bottom => {
                    var tab_x: f32 = tab_area.x;
                    for (self.tabs.items, 0..) |tab, i| {
                        const title_w = self.measureTextWithFont(ctx, tab.title);
                        const close_extra: f32 = if (tab.can_close) self.close_btn_size + 8.0 else 0.0;
                        const tab_w = title_w + self.tab_padding_h * 2 + close_extra;
                        const tab_ry: f32 = tab_area.y;

                        if (i == self.active) {
                            ctx.renderer.fillRect(
                                .{ .x = tab_x, .y = tab_ry, .width = tab_w, .height = tab_area.height },
                                self.tab_active_bg,
                            ) catch {};
                            // 指示条（top 在下边缘；bottom 在上边缘）
                            const iy: f32 = if (self.tab_pos == .top) tab_ry + tab_area.height - 3 else tab_ry;
                            ctx.renderer.fillRect(
                                .{ .x = tab_x, .y = iy, .width = tab_w, .height = 3 },
                                self.indicator_color,
                            ) catch {};
                        }

                        // 标签文本
                        const text_color = if (i == self.active) self.tab_active_text else self.tab_text;
                        const text_y = tab_ry + (tab_area.height - self.font_size * 1.2) / 2.0;
                        self.drawLabel(ctx, tab.title, tab_x + self.tab_padding_h, text_y, text_color);

                        // 关闭按钮 ×
                        if (tab.can_close) {
                            const bx = tab_x + tab_w - self.tab_padding_h - self.close_btn_size;
                            const by = tab_ry + (tab_area.height - self.close_btn_size) / 2.0;
                            drawCloseButton(ctx, bx, by, self.close_btn_size, text_color);
                        }

                        tab_x += tab_w;
                    }
                },
                // left / right 简化：按水平堆叠在左/右栏，但文字仍水平绘制（足够示意）
                .left, .right => {
                    var tab_y: f32 = tab_area.y;
                    for (self.tabs.items, 0..) |tab, i| {
                        const title_w = self.measureTextWithFont(ctx, tab.title);
                        const close_extra: f32 = if (tab.can_close) self.close_btn_size + 8.0 else 0.0;
                        const tab_w = tab_area.width; // 整栏宽度
                        const tab_h = self.tab_height * 0.9;

                        if (i == self.active) {
                            ctx.renderer.fillRect(
                                .{ .x = tab_area.x, .y = tab_y, .width = tab_w, .height = tab_h },
                                self.tab_active_bg,
                            ) catch {};
                            const ix: f32 = if (self.tab_pos == .left) tab_area.x + tab_w - 3 else tab_area.x;
                            ctx.renderer.fillRect(
                                .{ .x = ix, .y = tab_y, .width = 3, .height = tab_h },
                                self.indicator_color,
                            ) catch {};
                        }
                        const text_color = if (i == self.active) self.tab_active_text else self.tab_text;
                        const txt_x: f32 = tab_area.x + @max(4.0, (tab_w - title_w - close_extra) / 2.0);
                        const txt_y: f32 = tab_y + (tab_h - self.font_size * 1.2) / 2.0;
                        self.drawLabel(ctx, tab.title, txt_x, txt_y, text_color);
                        if (tab.can_close) {
                            const bx = tab_area.x + tab_w - self.close_btn_size - 4.0;
                            const by = tab_y + (tab_h - self.close_btn_size) / 2.0;
                            drawCloseButton(ctx, bx, by, self.close_btn_size, text_color);
                        }
                        tab_y += tab_h;
                    }
                },
            }
        }

        // 5. 内容区分隔线（标签栏与内容之间）
        if (self.show_tabs and self.tabs.items.len > 0) {
            const line_rect: math.Rect(f32) = switch (self.tab_pos) {
                .top => .{ .x = rx, .y = content_area.y - 1.0, .width = rw, .height = 1.0 },
                .bottom => .{ .x = rx, .y = ry + rh - bar_h - 1.0, .width = rw, .height = 1.0 },
                .left => .{ .x = content_area.x - 1.0, .y = ry, .width = 1.0, .height = rh },
                .right => .{ .x = rx + rw - (if (self.show_tabs) self.tab_height * 2.0 else 0.0) - 1.0, .y = ry, .width = 1.0, .height = rh },
            };
            ctx.renderer.fillRect(line_rect, self.border_color) catch {};
        }

        // 6. 画活动 content（Bug A 修复：之前完全没画）
        if (self.active < self.tabs.items.len) {
            if (self.tabs.items[self.active].content) |content| {
                // content.rect 设为相对 widget 内部的坐标（不含 ctx.offset_x/y，由 paintTree 处理）
                content.rect.x = content_area.x - ctx.offset_x;
                content.rect.y = content_area.y - ctx.offset_y;
                content.rect.width = content_area.width;
                content.rect.height = content_area.height;
                content.state.visible = true;
                // 使用 paintTree 递归（让子容器的子控件也走到 paint）
                content.paintTree(ctx);
            }
        }
    }

    fn measureTextWithFont(self: *Notebook, ctx: *PaintContext, text: []const u8) f32 {
        return styled_text.measureText(ctx.allocator, text, .{ .font_size = self.font_size }).width;
    }

    fn drawLabel(self: *Notebook, ctx: *PaintContext, text: []const u8, x: f32, y: f32, color: math.Color) void {
        styled_text.drawText(ctx.renderer, ctx.allocator, text, x, y, .{ .font_size = self.font_size, .color = color });
    }

    fn drawCloseButton(ctx: *PaintContext, bx: f32, by: f32, size: f32, color: math.Color) void {
        // 关闭按钮: 用圆角边框框表示 (库无 strokeLine 原语)
        ctx.renderer.strokeRoundedRect(.{ .x = bx, .y = by, .width = size, .height = size }, 4, 1.5, color) catch {};
    }

    // ── onEvent（修复 Bug B：转发事件 + measureText 字号一致） ─────────

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Notebook = @fieldParentPtr("base", w);

        // 1. 计算内容区相对当前 widget 的矩形（与 paint 中一致，不含 ctx offset）
        const bar_h: f32 = if (self.show_tabs) self.tab_height else 0.0;
        const border_w: f32 = if (self.show_border) 1.0 else 0.0;
        var content_rel: math.Rect(f32) = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        var tab_area_rel: math.Rect(f32) = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

        const rw = w.rect.width;
        const rh = w.rect.height;
        switch (self.tab_pos) {
            .top => {
                tab_area_rel = .{ .x = 0, .y = 0, .width = rw, .height = bar_h };
                content_rel = .{ .x = border_w, .y = bar_h + border_w, .width = rw - 2 * border_w, .height = rh - bar_h - 2 * border_w };
            },
            .bottom => {
                tab_area_rel = .{ .x = 0, .y = rh - bar_h, .width = rw, .height = bar_h };
                content_rel = .{ .x = border_w, .y = border_w, .width = rw - 2 * border_w, .height = rh - bar_h - 2 * border_w };
            },
            .left => {
                tab_area_rel = .{ .x = 0, .y = 0, .width = self.tab_height * 2.0, .height = rh };
                content_rel = .{ .x = tab_area_rel.width + border_w, .y = border_w, .width = rw - tab_area_rel.width - 2 * border_w, .height = rh - 2 * border_w };
            },
            .right => {
                tab_area_rel = .{ .x = rw - self.tab_height * 2.0, .y = 0, .width = self.tab_height * 2.0, .height = rh };
                content_rel = .{ .x = border_w, .y = border_w, .width = rw - tab_area_rel.width - 2 * border_w, .height = rh - 2 * border_w };
            },
        }

        // 2. 事件优先派发给活动 tab 的 content（Bug B 修复：之前完全没派发）
        switch (event.*) {
            .mouse_button, .mouse_move, .scroll, .key, .text_input, .touch => {
                if (self.active < self.tabs.items.len) {
                    if (self.tabs.items[self.active].content) |content| {
                        if (content.vtable.on_event) |ev_fn| {
                            // 转换到 content 的局部坐标（减去 content_rel.x/y）
                            const local_ev = translateRectEvent(event, -content_rel.x, -content_rel.y);
                            const result = ev_fn(content, &local_ev, ectx);
                            if (result == .handled) return .handled;
                        }
                    }
                }
            },
            else => {},
        }

        // 3. 标签栏点击（只处理鼠标；字号统一为 self.font_size 避免宽度测算不一致）
        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);

                    // 标签栏命中测试
                    if (self.show_tabs and self.tabs.items.len > 0 and
                        mx >= tab_area_rel.x and mx < tab_area_rel.x + tab_area_rel.width and
                        my >= tab_area_rel.y and my < tab_area_rel.y + tab_area_rel.height)
                    {
                        switch (self.tab_pos) {
                            .top, .bottom => {
                                var tab_x: f32 = tab_area_rel.x;
                                for (self.tabs.items, 0..) |tab, i| {
                                    const title_w = self.measureTextStatic(self.allocator, tab.title, self.font_size);
                                    const close_extra: f32 = if (tab.can_close) self.close_btn_size + 8.0 else 0.0;
                                    const tab_w = title_w + self.tab_padding_h * 2 + close_extra;
                                    // 先命中关闭按钮
                                    if (tab.can_close) {
                                        const bx = tab_x + tab_w - self.tab_padding_h - self.close_btn_size;
                                        const by = tab_area_rel.y + (tab_area_rel.height - self.close_btn_size) / 2.0;
                                        if (mx >= bx and mx < bx + self.close_btn_size and
                                            my >= by and my < by + self.close_btn_size)
                                        {
                                            if (self.on_tab_close_requested) |cb| cb(self, i);
                                            return .handled;
                                        }
                                    }
                                    // 再命中 tab 切换
                                    if (mx >= tab_x and mx < tab_x + tab_w) {
                                        self.setActive(i);
                                        return .handled;
                                    }
                                    tab_x += tab_w;
                                }
                            },
                            .left, .right => {
                                var tab_y: f32 = tab_area_rel.y;
                                for (self.tabs.items, 0..) |tab, i| {
                                    const tab_h = self.tab_height * 0.9;
                                    const tab_w = tab_area_rel.width;
                                    const title_w = self.measureTextStatic(self.allocator, tab.title, self.font_size);
                                    const close_extra: f32 = if (tab.can_close) self.close_btn_size + 8.0 else 0.0;
                                    _ = title_w;
                                    _ = close_extra;
                                    if (tab.can_close) {
                                        const bx = tab_area_rel.x + tab_w - self.close_btn_size - 4.0;
                                        const by = tab_y + (tab_h - self.close_btn_size) / 2.0;
                                        if (mx >= bx and mx < bx + self.close_btn_size and
                                            my >= by and my < by + self.close_btn_size)
                                        {
                                            if (self.on_tab_close_requested) |cb| cb(self, i);
                                            return .handled;
                                        }
                                    }
                                    if (my >= tab_y and my < tab_y + tab_h) {
                                        self.setActive(i);
                                        return .handled;
                                    }
                                    tab_y += tab_h;
                                }
                            },
                        }
                        // 点到标签栏空白处：handled 避免冒泡
                        return .handled;
                    }
                }
            },
            else => {},
        }
        return .ignored;
    }

    fn measureTextStatic(self: *Notebook, allocator: std.mem.Allocator, text: []const u8, font_size: f32) f32 {
        _ = self;
        return styled_text.measureText(allocator, text, .{ .font_size = font_size }).width;
    }

    fn translateRectEvent(event: *const pal.Event, dx: f32, dy: f32) pal.Event {
        var ev = event.*;
        switch (ev) {
            .mouse_move => |*m| {
                m.x -= @intFromFloat(dx);
                m.y -= @intFromFloat(dy);
            },
            .mouse_button => |*m| {
                m.x -= @intFromFloat(dx);
                m.y -= @intFromFloat(dy);
            },
            else => {},
        }
        return ev;
    }
};
