//! Assistant 控件 - 向导对话框 (对标 GtkAssistant)
//!
//! 多步骤向导，带前进/后退/完成按钮和页面切换
//! 支持进度指示器、页面标题、自定义内容

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const button_mod = @import("button.zig");
const container_mod = @import("container.zig");
const label_mod = @import("label.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Button = button_mod.Button;
const Container = container_mod.Container;
const Label = label_mod.Label;

const AssistantPageType = enum {
    /// 常规内容页（默认：有 Back/Next，最后一页 Apply=完成）
    content,
    /// 介绍页（无 Back，Next=继续）
    intro,
    /// 进度页（Next 需 complete=true；Apply 隐藏）
    progress,
    /// 确认页（Apply 文案=确认，调用 on_apply）
    confirm,
    /// 汇总页（Back/Next 隐藏，Apply 文案=关闭，点击 hide）
    summary,
    /// 自定义（所有按钮默认 hide，由上层控制）
    custom,
};

const AssistantPage = struct {
    title: []const u8,
    content: ?*Widget = null,
    complete: bool = true,
    page_type: AssistantPageType = .content,
};

// 便捷 GTK 兼容别名：AssistantPageType 作为 Assistant 下的命名空间对外导出
pub const PageType = AssistantPageType;

pub const Assistant = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    title: []const u8,
    visible: bool = false,
    current_page: usize = 0,
    pages: std.ArrayListUnmanaged(AssistantPage) = .{ .items = &.{}, .capacity = 0 },

    on_cancel: ?*const fn (self: *Assistant) void = null,
    on_apply: ?*const fn (self: *Assistant) void = null,
    on_prepare: ?*const fn (self: *Assistant, page_index: usize) void = null,
    on_close: ?*const fn (self: *Assistant) void = null,
    /// 自定义下一页跳转函数（GTK4: gtk_assistant_set_forward_page_func）
    /// 返回 `?usize`：非空 = 跳到该页；null = 不前进
    forward_page_func: ?*const fn (self: *const Assistant, current_page: usize) ?usize = null,
    forward_page_data: ?*anyopaque = null,

    btn_back: *Button = undefined,
    btn_next: *Button = undefined,
    btn_apply: *Button = undefined,
    btn_cancel: *Button = undefined,
    page_container: *Container = undefined,
    title_label: *Label = undefined,

    overlay_color: math.Color = math.Color.hex(0x000000AA),
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    header_bg: math.Color = math.Color.hex(0x0F172AFF),
    accent_color: math.Color = math.Color.hex(0x3B82F6FF),
    text_color: math.Color = math.Color.hex(0xF1F5FFFF),
    sub_text_color: math.Color = math.Color.hex(0x94A3B8FF),
    border_color: math.Color = math.Color.hex(0x334155FF),

    corner_radius: f32 = 14.0,
    dialog_width: f32 = 520,
    dialog_height: f32 = 420,
    header_height: f32 = 72,
    button_bar_height: f32 = 56,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        title: []const u8 = "Assistant",
        on_cancel: ?*const fn (self: *Assistant) void = null,
        on_apply: ?*const fn (self: *Assistant) void = null,
        on_prepare: ?*const fn (self: *Assistant, page_index: usize) void = null,
        on_close: ?*const fn (self: *Assistant) void = null,
    }) !*Assistant {
        const self = try allocator.create(Assistant);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .title = try allocator.dupe(u8, opts.title),
            .on_cancel = opts.on_cancel,
            .on_apply = opts.on_apply,
            .on_prepare = opts.on_prepare,
            .on_close = opts.on_close,
        };
        try self.buildUI();
        return self;
    }

    fn buildUI(self: *Assistant) !void {
        self.page_container = try Container.create(self.allocator, .{
            .bg_color = math.Color.hex(0x1E293BFF),
        });

        self.title_label = try Label.create(self.allocator, "", .{
            .font_size = 16,
            .font_weight = 600,
            .color = math.Color.hex(0xF1F5FFFF),
        });

        self.btn_back = try Button.create(self.allocator, "上一步", .{
            .on_click = onBackClicked,
            .corner_radius = 6,
            .padding_h = 16,
            .padding_v = 8,
        });
        self.btn_back.base.user_data = self;

        self.btn_next = try Button.create(self.allocator, "下一步", .{
            .on_click = onNextClicked,
            .corner_radius = 6,
            .padding_h = 16,
            .padding_v = 8,
        });
        self.btn_next.base.user_data = self;

        self.btn_apply = try Button.create(self.allocator, "完成", .{
            .on_click = onApplyClicked,
            .corner_radius = 6,
            .padding_h = 16,
            .padding_v = 8,
        });
        self.btn_apply.base.user_data = self;

        self.btn_cancel = try Button.create(self.allocator, "取消", .{
            .on_click = onCancelClicked,
            .corner_radius = 6,
            .padding_h = 16,
            .padding_v = 8,
        });
        self.btn_cancel.base.user_data = self;
    }

    pub fn destroy(self: *Assistant, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.free(self.title);
        self.pages.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn addPage(self: *Assistant, title: []const u8, content: ?*Widget) !usize {
        return self.addPageTyped(title, content, .content);
    }

    /// GTK4 兼容：append_page (同 addPageTyped，可指定 page_type)
    pub fn addPageTyped(self: *Assistant, title: []const u8, content: ?*Widget, page_type: AssistantPageType) !usize {
        const idx = self.pages.items.len;
        try self.pages.append(self.allocator, .{
            .title = try self.allocator.dupe(u8, title),
            .content = content,
            .page_type = page_type,
        });
        if (content) |w| {
            w.state.visible = false;
        }
        if (self.pages.items.len == 1) {
            self.updatePageUI();
        }
        return idx;
    }

    pub fn setPageType(self: *Assistant, page_index: usize, page_type: AssistantPageType) void {
        if (page_index < self.pages.items.len) {
            self.pages.items[page_index].page_type = page_type;
            self.updateButtonStates();
            self.base.markDirty();
        }
    }

    pub fn getPageType(self: *const Assistant, page_index: usize) AssistantPageType {
        if (page_index < self.pages.items.len)
            return self.pages.items[page_index].page_type;
        return .content;
    }

    /// GTK4 兼容：gtk_assistant_set_forward_page_func
    pub fn setForwardPageFunc(
        self: *Assistant,
        func: ?*const fn (self: *const Assistant, current_page: usize) ?usize,
        data: ?*anyopaque,
    ) void {
        self.forward_page_func = func;
        self.forward_page_data = data;
    }

    pub fn setPageComplete(self: *Assistant, page_index: usize, complete: bool) void {
        if (page_index < self.pages.items.len) {
            self.pages.items[page_index].complete = complete;
            self.updateButtonStates();
            self.base.markDirty();
        }
    }

    pub fn currentPageIndex(self: *const Assistant) usize {
        return self.current_page;
    }

    pub fn nPages(self: *const Assistant) usize {
        return self.pages.items.len;
    }

    pub fn show(self: *Assistant) void {
        self.visible = true;
        self.base.state.visible = true;
        self.current_page = 0;
        self.updatePageUI();
        self.base.markDirty();
    }

    pub fn hide(self: *Assistant) void {
        self.visible = false;
        self.base.state.visible = false;
        self.base.markDirty();
        if (self.on_close) |cb| cb(self);
    }

    fn nextPage(self: *Assistant) void {
        // GTK4: 先走自定义 forward_page_func
        if (self.forward_page_func) |func| {
            if (func(self, self.current_page)) |target| {
                if (target < self.pages.items.len) {
                    self.current_page = target;
                    self.updatePageUI();
                    if (self.on_prepare) |cb| cb(self, self.current_page);
                }
            }
            return;
        }
        // 默认顺序前进
        if (self.current_page + 1 < self.pages.items.len) {
            self.current_page += 1;
            self.updatePageUI();
            if (self.on_prepare) |cb| cb(self, self.current_page);
        }
    }

    fn prevPage(self: *Assistant) void {
        if (self.current_page > 0) {
            self.current_page -= 1;
            self.updatePageUI();
            if (self.on_prepare) |cb| cb(self, self.current_page);
        }
    }

    fn updatePageUI(self: *Assistant) void {
        if (self.current_page < self.pages.items.len) {
            const page = &self.pages.items[self.current_page];
            self.title_label.setText(page.title);
        }
        self.updateButtonStates();
        self.base.markDirty();
    }

    fn updateButtonStates(self: *Assistant) void {
        const is_first = self.current_page == 0;
        const is_last = self.current_page + 1 >= self.pages.items.len;
        const page_complete = if (self.current_page < self.pages.items.len)
            self.pages.items[self.current_page].complete
        else
            true;
        const page_type = self.getPageType(self.current_page);

        // Back（默认首页禁用；intro/summary/custom 隐藏）
        self.btn_back.base.state.disabled = is_first;

        // Next（progress 需 complete=true；intro/summary/custom 隐藏；末页禁用）
        self.btn_next.base.state.disabled = is_last or !page_complete;

        // Apply（最后一页且 complete 才启用；summary 页允许点击"关闭"，progress 禁用；intro/custom 隐藏）
        switch (page_type) {
            .summary => self.btn_apply.base.state.disabled = false,
            .progress => self.btn_apply.base.state.disabled = true,
            else => self.btn_apply.base.state.disabled = !is_last or !page_complete,
        }
    }

    fn onBackClicked(btn: *Button) void {
        const self: *Assistant = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.prevPage();
    }

    fn onNextClicked(btn: *Button) void {
        const self: *Assistant = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.nextPage();
    }

    fn onApplyClicked(btn: *Button) void {
        const self: *Assistant = @ptrCast(@alignCast(btn.base.user_data orelse return));
        const page_type = self.getPageType(self.current_page);
        switch (page_type) {
            .summary => {
                // 汇总页：Apply=关闭 → 走 on_close + hide
                if (self.on_close) |cb| cb(self);
                self.hide();
            },
            else => {
                // 其他页：走 on_apply + hide
                if (self.on_apply) |cb| cb(self);
                self.hide();
            },
        }
    }

    fn onCancelClicked(btn: *Button) void {
        const self: *Assistant = @ptrCast(@alignCast(btn.base.user_data orelse return));
        if (self.on_cancel) |cb| cb(self);
        self.hide();
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "assistant",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Assistant = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = w;
        _ = ctx;
        return .{ .width = constraints.max_width, .height = constraints.max_height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Assistant = @fieldParentPtr("base", w);
        if (!self.visible) return;

        // 遮罩
        ctx.renderer.fillRect(
            .{ .x = ctx.offset_x, .y = ctx.offset_y, .width = w.rect.width, .height = w.rect.height },
            self.overlay_color,
        ) catch {};

        // 对话框位置 (居中)
        const dx = ctx.offset_x + (w.rect.width - self.dialog_width) / 2;
        const dy = ctx.offset_y + (w.rect.height - self.dialog_height) / 2;

        // 对话框背景
        ctx.renderer.fillRoundedRect(
            .{ .x = dx, .y = dy, .width = self.dialog_width, .height = self.dialog_height },
            self.corner_radius,
            self.bg_color,
        ) catch {};

        // 头部背景
        ctx.renderer.fillRoundedRect(
            .{ .x = dx, .y = dy, .width = self.dialog_width, .height = self.header_height },
            self.corner_radius,
            self.header_bg,
        ) catch {};
        // 底部直角补全
        ctx.renderer.fillRect(
            .{ .x = dx, .y = dy + self.header_height - self.corner_radius, .width = self.dialog_width, .height = self.corner_radius },
            self.header_bg,
        ) catch {};

        // 进度指示器 (小圆点)
        const total = self.pages.items.len;
        if (total > 0) {
            const dot_size: f32 = 8;
            const dot_spacing: f32 = 16;
            const dots_total_w = @as(f32, @floatFromInt(total)) * dot_size + @as(f32, @floatFromInt(total - 1)) * dot_spacing;
            const dots_x = dx + (self.dialog_width - dots_total_w) / 2;
            const dots_y = dy + 20;

            var i: usize = 0;
            while (i < total) : (i += 1) {
                const cx = dots_x + @as(f32, @floatFromInt(i)) * (dot_size + dot_spacing) + dot_size / 2;
                const is_current = i == self.current_page;
                const is_past = i < self.current_page;
                const color = if (is_current)
                    self.accent_color
                else if (is_past)
                    math.Color.hex(0x22C55EFF)
                else
                    self.border_color;
                ctx.renderer.fillCircle(cx, dots_y + dot_size / 2, dot_size / 2, color) catch {};
            }
        }

        // 页面标题
        if (self.current_page < self.pages.items.len) {
            const page_title = self.pages.items[self.current_page].title;
            const text_w = @as(f32, @floatFromInt(page_title.len)) * 8.0;
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                page_title,
                dx + (self.dialog_width - text_w) / 2,
                dy + 44,
                .{
                    .font_size = 14,
                    .color = self.text_color,
                    .font_weight = 600,
                },
            );
        }

        // 页面内容区域背景
        const content_y = dy + self.header_height;
        const content_h = self.dialog_height - self.header_height - self.button_bar_height;

        // 分割线
        ctx.renderer.fillRect(
            .{ .x = dx, .y = content_y, .width = self.dialog_width, .height = 1 },
            self.border_color,
        ) catch {};

        // 绘制当前页面的内容 widget
        if (self.current_page < self.pages.items.len) {
            const page = &self.pages.items[self.current_page];
            if (page.content) |content| {
                content.rect.x = dx + 20;
                content.rect.y = content_y + 16;
                content.rect.width = self.dialog_width - 40;
                content.rect.height = content_h - 32;
                content.vtable.paint(content, ctx);
            } else {
                // 默认占位文本
                const placeholder = "此页面暂无内容";
                const pw_text = @as(f32, @floatFromInt(placeholder.len)) * 7.0;
                styled_text.drawText(
                    ctx.renderer,
                    ctx.allocator,
                    placeholder,
                    dx + (self.dialog_width - pw_text) / 2,
                    content_y + content_h / 2 - 8,
                    .{
                        .font_size = 13,
                        .color = self.sub_text_color,
                    },
                );
            }
        }

        // 按钮栏背景
        const bar_y = dy + self.dialog_height - self.button_bar_height;
        ctx.renderer.fillRoundedRect(
            .{ .x = dx, .y = bar_y, .width = self.dialog_width, .height = self.button_bar_height },
            self.corner_radius,
            self.header_bg,
        ) catch {};
        ctx.renderer.fillRect(
            .{ .x = dx, .y = bar_y, .width = self.dialog_width, .height = self.corner_radius },
            self.header_bg,
        ) catch {};

        // 按钮栏分割线
        ctx.renderer.fillRect(
            .{ .x = dx, .y = bar_y, .width = self.dialog_width, .height = 1 },
            self.border_color,
        ) catch {};

        // 按钮：按 page_type 决定显隐 + 文案
        const btn_y = bar_y + (self.button_bar_height - 32) / 2;
        const btn_spacing: f32 = 8;
        const cur_page_type = self.getPageType(self.current_page);

        // 根据 page_type 动态设置按钮文案（updatePageUI 时也会调，这里每帧同步以防万一）
        switch (cur_page_type) {
            .intro => {
                self.btn_next.setText("继续");
                self.btn_back.base.state.visible = false; // intro 无 Back
                self.btn_next.base.state.visible = true;
                self.btn_apply.base.state.visible = false; // intro 无 Apply
            },
            .progress => {
                self.btn_next.setText("下一步");
                self.btn_back.base.state.visible = true;
                self.btn_next.base.state.visible = true;
                self.btn_apply.base.state.visible = false; // progress 无 Apply
            },
            .confirm => {
                self.btn_next.setText("下一步");
                self.btn_back.base.state.visible = true;
                self.btn_next.base.state.visible = self.current_page + 1 < self.pages.items.len;
                self.btn_apply.base.state.visible = true;
                self.btn_apply.setText("确认"); // confirm: Apply = 确认
            },
            .summary => {
                self.btn_back.base.state.visible = false; // summary 无 Back/Next
                self.btn_next.base.state.visible = false;
                self.btn_apply.base.state.visible = true;
                self.btn_apply.setText("关闭"); // summary: Apply = 关闭
            },
            .custom => {
                // custom：全部隐藏（上层自行控制）
                self.btn_back.base.state.visible = false;
                self.btn_next.base.state.visible = false;
                self.btn_apply.base.state.visible = false;
            },
            .content => {
                self.btn_next.setText("下一步");
                self.btn_apply.setText("完成");
                self.btn_back.base.state.visible = true;
                self.btn_next.base.state.visible = true;
                self.btn_apply.base.state.visible = true;
            },
        }

        // Cancel (左，始终显示除非 custom)
        if (cur_page_type != .custom) {
            self.btn_cancel.base.rect.x = dx + 16;
            self.btn_cancel.base.rect.y = btn_y;
            self.btn_cancel.base.rect.width = 80;
            self.btn_cancel.base.rect.height = 32;
            self.btn_cancel.base.state.visible = true;
            self.btn_cancel.base.vtable.paint(&self.btn_cancel.base, ctx);
        } else {
            self.btn_cancel.base.state.visible = false;
        }

        // Back / Next / Apply (右对齐)
        const btn_right_x = dx + self.dialog_width - 16;
        var cur_x = btn_right_x;

        // Apply (最右)
        if (self.btn_apply.base.state.visible) {
            cur_x -= 80;
            self.btn_apply.base.rect.x = cur_x;
            self.btn_apply.base.rect.y = btn_y;
            self.btn_apply.base.rect.width = 80;
            self.btn_apply.base.rect.height = 32;
            self.btn_apply.base.vtable.paint(&self.btn_apply.base, ctx);
            cur_x -= btn_spacing;
        }

        // Next
        if (self.btn_next.base.state.visible) {
            cur_x -= 80;
            self.btn_next.base.rect.x = cur_x;
            self.btn_next.base.rect.y = btn_y;
            self.btn_next.base.rect.width = 80;
            self.btn_next.base.rect.height = 32;
            self.btn_next.base.vtable.paint(&self.btn_next.base, ctx);
            cur_x -= btn_spacing;
        }

        // Back
        if (self.btn_back.base.state.visible) {
            cur_x -= 80;
            self.btn_back.base.rect.x = cur_x;
            self.btn_back.base.rect.y = btn_y;
            self.btn_back.base.rect.width = 80;
            self.btn_back.base.rect.height = 32;
            self.btn_back.base.vtable.paint(&self.btn_back.base, ctx);
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Assistant = @fieldParentPtr("base", w);
        if (!self.visible) return .ignored;

        const dx = (w.rect.width - self.dialog_width) / 2;
        const dy = (w.rect.height - self.dialog_height) / 2;
        const cur_page_type = self.getPageType(self.current_page);
        _ = cur_page_type;

        // 先给按钮分发事件
        const buttons = [_]*Button{ self.btn_cancel, self.btn_back, self.btn_next, self.btn_apply };
        for (buttons) |btn| {
            if (btn.base.state.visible) {
                if (btn.base.vtable.on_event) |ev_fn| {
                    // 转换坐标到按钮局部
                    const local_ev = translateEvent(event, -btn.base.rect.x, -btn.base.rect.y);
                    const result = ev_fn(&btn.base, &local_ev, ectx);
                    if (result == .handled) return .handled;
                }
            }
        }

        // 当前页面内容的事件（修复坐标：与 paint 时 content.rect 的 dx+20 / content_y+16 反向对应）
        if (self.current_page < self.pages.items.len) {
            const page = &self.pages.items[self.current_page];
            if (page.content) |content| {
                if (content.vtable.on_event) |ev_fn| {
                    const content_y = dy + self.header_height;
                    const local_ev = translateEvent(event, -(dx + 20), -(content_y + 16));
                    const result = ev_fn(content, &local_ev, ectx);
                    if (result == .handled) return .handled;
                }
            }
        }

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const lx: f32 = @floatFromInt(mb.x);
                    const ly: f32 = @floatFromInt(mb.y);
                    const inside_dialog = lx >= dx and lx < dx + self.dialog_width and
                        ly >= dy and ly < dy + self.dialog_height;
                    if (!inside_dialog) {
                        // 点击外部关闭
                        // self.hide();
                        return .handled;
                    }
                    return .handled;
                }
            },
            .key => |k| {
                if (k.state == .pressed) {
                    if (k.key == .escape) {
                        self.hide();
                        return .handled;
                    }
                }
            },
            else => {},
        }

        return .handled;
    }

    fn translateEvent(event: *const pal.Event, dx: f32, dy: f32) pal.Event {
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
            .scroll => {},
            else => {},
        }
        return ev;
    }
};
