//! Chooser 对话框系列 (对标 GTK4 GtkAppChooserDialog / GtkColorChooserDialog / GtkFontChooserDialog)
//!
//! 三个完整的模态对话框 Widget：
//! - AppChooserDialog: 为给定内容类型选择应用程序
//! - ColorChooserDialog: 颜色选择器对话框
//! - FontChooserDialog: 字体选择器对话框

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const button_mod = @import("button.zig");
const label_mod = @import("label.zig");
const container_mod = @import("container.zig");
const list_box_mod = @import("list_box.zig");
const entry_mod = @import("entry.zig");
const color_chooser_mod = @import("color_chooser.zig");
const scroll_mod = @import("scrolled_window.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Button = button_mod.Button;
const Label = label_mod.Label;
const Container = container_mod.Container;

// ────────────────────────────────────────────────────────────────────────────
// 通用对话框基类 (共享模态框绘制和按钮区)
// ────────────────────────────────────────────────────────────────────────────

const ChooserDialogBase = struct {
    title: []const u8,
    visible: bool = false,
    result_response: enum { none, ok, cancel } = .none,
    overlay_color: math.Color = math.Color.hex(0x000000AA),
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    title_color: math.Color = math.Color.hex(0xF8FAFCFF),
    corner_radius: f32 = 14.0,
    dialog_width: f32 = 520,
    dialog_height: f32 = 480,
    title_size: f32 = 18.0,
    content_container: ?*Container = null,
    ok_button: ?*Button = null,
    cancel_button: ?*Button = null,
};

// ────────────────────────────────────────────────────────────────────────────
// AppInfo —— 应用程序信息 (GTK4: GAppInfo)
// ────────────────────────────────────────────────────────────────────────────

pub const AppInfo = struct {
    allocator: std.mem.Allocator,
    display_name: []const u8,
    description: ?[]const u8 = null,
    /// 命令行可执行文件路径
    executable: ?[]const u8 = null,
    /// icon 图标名称(GTK4 图标主题中的名称)
    icon_name: ?[]const u8 = null,
    /// 支持的内容类型 MIME
    supported_types: std.ArrayListUnmanaged([]const u8) = .empty,
    /// ID (桌面文件
    id: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, display_name: []const u8) AppInfo {
        return .{
            .allocator = allocator,
            .display_name = display_name,
        };
    }

    pub fn deinit(self: *AppInfo) void {
        self.supported_types.deinit(self.allocator);
    }
};

// ────────────────────────────────────────────────────────────────────────────
// AppChooserDialog (GTK4: GtkAppChooserDialog)
// ────────────────────────────────────────────────────────────────────────────

pub const AppChooserDialog = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    cb: ChooserDialogBase,
    /// 要打开的内容类型 (MIME 如 "text/plain")
    content_type: []const u8,
    /// 可选: 关联文件 URI
    file_uri: ?[]const u8 = null,
    /// 是否显示"其他应用"选项
    show_all: bool = true,
    /// 推荐应用列表
    app_list: std.ArrayListUnmanaged(AppInfo) = .empty,
    /// 当前选中
    selected_index: ?usize = null,

    on_response: ?*const fn (self: *AppChooserDialog, response: enum { ok, cancel }, selected_app: ?*const AppInfo) void = null,

    // 内部子控件
    inner_container: ?*Container = null,
    app_listbox: ?*list_box_mod.ListBox = null,
    scrolled: ?*scroll_mod.ScrolledWindow = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        title: []const u8 = "选择应用程序",
        content_type: []const u8 = "*/*",
        file_uri: ?[]const u8 = null,
        show_all: bool = true,
        dialog_width: f32 = 520,
        dialog_height: f32 = 480,
        on_response: ?*const fn (self: *AppChooserDialog, response: enum { ok, cancel }, selected_app: ?*const AppInfo) void = null,
    }) !*AppChooserDialog {
        const self = try allocator.create(AppChooserDialog);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .cb = .{
                .title = opts.title,
                .dialog_width = opts.dialog_width,
                .dialog_height = opts.dialog_height,
            },
            .content_type = opts.content_type,
            .file_uri = opts.file_uri,
            .show_all = opts.show_all,
            .on_response = opts.on_response,
        };
        try self.buildUI();
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        // 销毁 app_list 中的 AppInfo
        for (self.app_list.items) |*app| {
            app.deinit();
        }
        self.app_list.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        // 销毁容器树
        if (self.inner_container) |cc| {
            cc.base.vtable.destroy(&cc.base, allocator);
        }
        allocator.destroy(self);
    }

    pub fn show(self: *Self) void {
        self.cb.visible = true;
        self.cb.result_response = .none;
        self.base.markDirty();
    }

    pub fn hide(self: *Self, response: enum { ok, cancel }) void {
        self.cb.visible = false;
        self.cb.result_response = response;
        self.base.markDirty();
        const selected: ?*const AppInfo = if (response == .ok and self.selected_index) |idx| &self.app_list.items[idx] else null;
        if (self.on_response) |cb| cb(self, response, selected);
    }

    /// 添加一个候选应用
    pub fn addApp(self: *Self, app: AppInfo) !void {
        try self.app_list.append(self.allocator, app);
    }

    /// 获取选中的应用
    pub fn getSelectedApp(self: *const Self) ?*const AppInfo {
        const idx = self.selected_index orelse return null;
        return &self.app_list.items[idx];
    }

    fn buildUI(self: *Self) !void {
        const alloc = self.allocator;
        const outer = try Container.create(alloc, .{
            .direction = .column,
            .bg_color = math.Color.hex(0x00000000),
            .padding = math.EdgeInsets.all(0),
            .gap = .{ .width = 0, .height = 0 },
        });
        self.inner_container = outer;
        try self.base.addChild(alloc, &outer.base);

        // 标题区
        const title_lbl = try Label.create(alloc, self.cb.title, .{
            .font_size = self.cb.title_size,
            .color = self.cb.title_color,
            .padding = math.EdgeInsets{ .left = 20, .right = 20, .top = 16, .bottom = 12 },
        });
        title_lbl.base.layout_style.flex_grow = 0;
        try outer.base.addChild(alloc, &title_lbl.base);

        // 分隔线 (用 Label 模拟
        const sep = try Label.create(alloc, "", .{
            .bg_color = math.Color.hex(0x334155FF),
            .min_height = 1,
        });
        sep.base.layout_style.min_height = .{ .px = 1 };
        try outer.base.addChild(alloc, &sep.base);

        // 内容区: 应用列表
        const content = try Container.create(alloc, .{
            .direction = .column,
            .padding = math.EdgeInsets.all(16),
            .gap = .{ .width = 0, .height = 8 },
            .bg_color = math.Color.hex(0x00000000),
        });
        content.base.layout_style.flex_grow = 1;
        try outer.base.addChild(alloc, &content.base);

        // 内容类型提示
        const hint = try Label.create(alloc, if (self.file_uri) |u| u else "选择用于打开此内容的应用程序：", .{
            .font_size = 13,
            .color = math.Color.hex(0x94A3B8FF),
            .padding = math.EdgeInsets{ .left = 4, .right = 0, .top = 0, .bottom = 8 },
        });
        try content.base.addChild(alloc, &hint.base);

        // 应用列表 (包在 ScrolledWindow 中)
        const sw = try scroll_mod.ScrolledWindow.create(alloc, .{});
        sw.base.layout_style.flex_grow = 1;
        self.scrolled = sw;
        try content.base.addChild(alloc, &sw.base);

        // 空列表占位
        const placeholder = try Label.create(alloc, "（尚未添加应用。使用 addApp() 添加候选应用）", .{
            .font_size = 13,
            .color = math.Color.hex(0x64748BFF),
            .padding = math.EdgeInsets.all(16),
        });
        try sw.setChild(alloc, &placeholder.base);

        // 底部按钮栏
        const btn_bar = try Container.create(alloc, .{
            .direction = .row,
            .padding = math.EdgeInsets{ .left = 20, .right = 20, .top = 12, .bottom = 16 },
            .gap = .{ .width = 8, .height = 0 },
            .bg_color = math.Color.hex(0x00000000),
        });
        try outer.base.addChild(alloc, &btn_bar.base);

        // 弹簧
        const spring = try Container.create(alloc, .{ .direction = .row, .bg_color = math.Color.hex(0x00000000) });
        spring.base.layout_style.flex_grow = 1;
        try btn_bar.base.addChild(alloc, &spring.base);

        const cancel_btn = try Button.create(alloc, "取消", .{ .on_click = onCancelClick });
        cancel_btn.base.user_data = self;
        self.cb.cancel_button = cancel_btn;
        try btn_bar.base.addChild(alloc, &cancel_btn.base);

        const ok_btn = try Button.create(alloc, "确定", .{
            .on_click = onOkClick,
            .style = .primary,
        });
        ok_btn.base.user_data = self;
        self.cb.ok_button = ok_btn;
        try btn_bar.base.addChild(alloc, &ok_btn.base);
    }

    fn onCancelClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.hide(.cancel);
    }

    fn onOkClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.hide(.ok);
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "app_chooser_dialog",
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

    fn measure(w: *Widget, _ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = _ctx;
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.cb.visible) return constraints.constrain(.{ .width = 0, .height = 0 });
        return constraints.constrain(.{ .width = self.cb.dialog_width, .height = self.cb.dialog_height });
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.cb.visible) return;

        // 遮罩层 (全屏)
        const overlay_rect = math.Rect(f32){
            .x = ctx.offset_x - 0,
            .y = ctx.offset_y - 0,
            .width = 99999,
            .height = 99999,
        };
        ctx.renderer.fillRect(overlay_rect, self.cb.overlay_color) catch {};

        // 对话框居中绘制
        const dw = self.cb.dialog_width;
        const dh = self.cb.dialog_height;
        const rx = ctx.offset_x + w.rect.x + (w.rect.width - dw) * 0.5;
        const ry = ctx.offset_y + w.rect.y + (w.rect.height - dh) * 0.5;
        const dr = math.Rect(f32){ .x = rx, .y = ry, .width = dw, .height = dh };
        ctx.renderer.fillRoundedRect(dr, self.cb.corner_radius, self.cb.bg_color) catch {};

        // 绘制内部内容
        if (self.inner_container) |cc| {
            cc.base.rect = math.Rect(f32){ .x = 0, .y = 0, .width = dw, .height = dh };
            // 暂时把 offset 平移到对话框坐标
            const old_ox = ctx.offset_x;
            const old_oy = ctx.offset_y;
            ctx.offset_x = rx;
            ctx.offset_y = ry;
            cc.base.vtable.paint(&cc.base, ctx);
            ctx.offset_x = old_ox;
            ctx.offset_y = old_oy;
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.cb.visible) return .ignored;

        // 先让子控件处理
        if (self.inner_container) |cc| {
            if (cc.base.vtable.on_event) |evfn| {
                if (evfn(&cc.base, event, ectx) == .handled) return .handled;
            }
        }
        if (event.* == .key and event.key.state == .pressed) {
            if (event.key.key == .escape) {
                self.hide(.cancel);
                return .handled;
            }
        }
        return .handled; // 模态: 吞掉所有事件防止穿透
    }
};

// ────────────────────────────────────────────────────────────────────────────
// ColorChooserDialog (GTK4: GtkColorChooserDialog)
// ────────────────────────────────────────────────────────────────────────────

pub const ColorChooserDialog = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    cb: ChooserDialogBase,
    /// 当前颜色 (用户选中的颜色
    current_color: math.Color = math.Color.hex(0x3B82F6FF),
    /// 支持透明通道
    use_alpha: bool = true,
    /// 调色板预设
    palette: std.ArrayListUnmanaged(math.Color) = .empty,

    on_response: ?*const fn (self: *ColorChooserDialog, response: enum { ok, cancel }, color: math.Color) void = null,

    inner_container: ?*Container = null,
    color_chooser_widget: ?*color_chooser_mod.ColorChooser = null,
    hex_entry: ?*entry_mod.Entry = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        title: []const u8 = "选择颜色",
        initial_color: math.Color = math.Color.hex(0x3B82F6FF),
        use_alpha: bool = true,
        dialog_width: f32 = 520,
        dialog_height: f32 = 460,
        on_response: ?*const fn (self: *ColorChooserDialog, response: enum { ok, cancel }, color: math.Color) void = null,
    }) !*ColorChooserDialog {
        const self = try allocator.create(ColorChooserDialog);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .cb = .{
                .title = opts.title,
                .dialog_width = opts.dialog_width,
                .dialog_height = opts.dialog_height,
            },
            .current_color = opts.initial_color,
            .use_alpha = opts.use_alpha,
            .on_response = opts.on_response,
        };
        // 添加一些默认调色板
        const palette_defaults = [_]u32{
            0xEF4444FF, 0xF97316FF, 0xEAB308FF, 0x22C55EFF, 0x14B8A6FF,
            0x3B82F6FF, 0x8B5CF6FF, 0xEC4899FF, 0x64748BFF, 0x0F172AFF,
            0xFCA5A5FF, 0xFED7AAFF, 0xFDE047FF, 0x86EFACFF, 0x5EEAD4FF,
            0x93C5FDFF, 0xC4B5FDFF, 0xF9A8D4FF, 0xCBD5E1FF, 0xFFFFFF33,
        };
        for (palette_defaults) |c| {
            try self.palette.append(allocator, math.Color.hex(c));
        }
        try self.buildUI();
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.palette.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        if (self.inner_container) |cc| {
            cc.base.vtable.destroy(&cc.base, allocator);
        }
        allocator.destroy(self);
    }

    pub fn show(self: *Self) void {
        self.cb.visible = true;
        self.cb.result_response = .none;
        self.base.markDirty();
    }

    pub fn hide(self: *Self, response: enum { ok, cancel }) void {
        self.cb.visible = false;
        self.cb.result_response = response;
        self.base.markDirty();
        if (self.on_response) |cb| cb(self, response, self.current_color);
    }

    pub fn getCurrentColor(self: *const Self) math.Color {
        return self.current_color;
    }

    pub fn setCurrentColor(self: *Self, color: math.Color) void {
        self.current_color = color;
        self.base.markDirty();
    }

    fn buildUI(self: *Self) !void {
        const alloc = self.allocator;
        const outer = try Container.create(alloc, .{
            .direction = .column,
            .bg_color = math.Color.hex(0x00000000),
            .padding = math.EdgeInsets.all(0),
            .gap = .{ .width = 0, .height = 0 },
        });
        self.inner_container = outer;
        try self.base.addChild(alloc, &outer.base);

        // 标题
        const title_lbl = try Label.create(alloc, self.cb.title, .{
            .font_size = self.cb.title_size,
            .color = self.cb.title_color,
            .padding = math.EdgeInsets{ .left = 20, .right = 20, .top = 16, .bottom = 12 },
        });
        try outer.base.addChild(alloc, &title_lbl.base);

        // 分隔线
        const sep = try Label.create(alloc, "", .{ .bg_color = math.Color.hex(0x334155FF), .min_height = 1 });
        sep.base.layout_style.min_height = .{ .px = 1 };
        try outer.base.addChild(alloc, &sep.base);

        // 中间内容
        const content = try Container.create(alloc, .{
            .direction = .column,
            .padding = math.EdgeInsets.all(20),
            .gap = .{ .width = 0, .height = 16 },
            .bg_color = math.Color.hex(0x00000000),
        });
        content.base.layout_style.flex_grow = 1;
        try outer.base.addChild(alloc, &content.base);

        // 调色板
        const pal_lbl = try Label.create(alloc, "调色板：", .{
            .font_size = 13,
            .color = math.Color.hex(0x94A3B8FF),
        });
        try content.base.addChild(alloc, &pal_lbl.base);

        // 简单调色板网格（2 行 10 列的颜色方块由 paint 中直接绘制
        // 这里添加一个固定高度占位（调色板容器）
        const palette_holder = try Container.create(alloc, .{
            .direction = .row,
            .bg_color = math.Color.hex(0x00000000),
        });
        palette_holder.base.layout_style.min_height = .{ .px = 60 };
        try content.base.addChild(alloc, &palette_holder.base);
        // 保存在 inner_container user_data 里
        palette_holder.base.user_data = self;
        // 覆写其 paint: 这里简单用 Container 包装，vtable 不能换；用自定义
        palette_holder.base.vtable = &paletteHolderVTable;

        // HEX 输入
        const hex_row = try Container.create(alloc, .{
            .direction = .row,
            .bg_color = math.Color.hex(0x00000000),
            .gap = .{ .width = 8, .height = 0 },
        });
        try content.base.addChild(alloc, &hex_row.base);
        const hex_lbl = try Label.create(alloc, "HEX:", .{
            .font_size = 14,
            .color = math.Color.hex(0xE2E8F0FF),
        });
        hex_lbl.base.layout_style.min_width = .{ .px = 48 };
        try hex_row.base.addChild(alloc, &hex_lbl.base);
        const hex_buf = try fmtHexColor(self.current_color, alloc);
        const entry = try entry_mod.Entry.create(alloc, .{
            .placeholder = "#RRGGBB",
            .initial_text = hex_buf,
        });
        self.hex_entry = entry;
        entry.base.layout_style.flex_grow = 1;
        try hex_row.base.addChild(alloc, &entry.base);

        // 预览区
        const preview_row = try Container.create(alloc, .{
            .direction = .row,
            .bg_color = math.Color.hex(0x00000000),
            .gap = .{ .width = 12, .height = 0 },
        });
        try content.base.addChild(alloc, &preview_row.base);

        const prev_lbl = try Label.create(alloc, "预览：", .{
            .font_size = 13,
            .color = math.Color.hex(0x94A3B8FF),
        });
        prev_lbl.base.layout_style.min_width = .{ .px = 48 };
        try preview_row.base.addChild(alloc, &prev_lbl.base);

        const color_prev = try Label.create(alloc, "", .{
            .bg_color = self.current_color,
            .corner_radius = 8,
            .min_height = 40,
        });
        color_prev.base.layout_style.flex_grow = 1;
        color_prev.base.layout_style.min_height = .{ .px = 40 };
        color_prev.base.user_data = self;
        try preview_row.base.addChild(alloc, &color_prev.base);

        // 底部按钮栏
        const btn_bar = try Container.create(alloc, .{
            .direction = .row,
            .padding = math.EdgeInsets{ .left = 20, .right = 20, .top = 12, .bottom = 16 },
            .gap = .{ .width = 8, .height = 0 },
        });
        try outer.base.addChild(alloc, &btn_bar.base);
        const spring = try Container.create(alloc, .{ .direction = .row, .bg_color = math.Color.hex(0x00000000) });
        spring.base.layout_style.flex_grow = 1;
        try btn_bar.base.addChild(alloc, &spring.base);
        const cancel_btn = try Button.create(alloc, "取消", .{ .on_click = onColorCancelClick });
        cancel_btn.base.user_data = self;
        try btn_bar.base.addChild(alloc, &cancel_btn.base);
        const ok_btn = try Button.create(alloc, "确定", .{ .on_click = onColorOkClick, .style = .primary });
        ok_btn.base.user_data = self;
        try btn_bar.base.addChild(alloc, &ok_btn.base);
    }

    fn fmtHexColor(c: math.Color, allocator: std.mem.Allocator) ![]const u8 {
        // hex -> 8 char: RRGGBBAA
        const buf = try allocator.alloc(u8, 9);
        _ = try std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ c.r, c.g, c.b, c.a });
        return buf;
    }

    fn onColorCancelClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.hide(.cancel);
    }
    fn onColorOkClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.hide(.ok);
    }

    // palette holder 自定义 vtable (画调色板方块网格)
    const paletteHolderVTable = Widget.VTable{
        .type_name = "palette_holder",
        .measure = paletteHolderMeasure,
        .paint = paletteHolderPaint,
        .on_event = paletteHolderEvent,
        .focusable = false,
    };
    fn paletteHolderMeasure(_w: *Widget, _ctx: *PaintContext, c: layout_mod.Constraints) math.Size(f32) {
        _ = _ctx;
        _ = _w;
        return c.constrain(.{ .width = c.max_width, .height = 60 });
    }
    fn paletteHolderPaint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @ptrCast(@alignCast(w.user_data orelse return));
        const cols: u32 = 10;
        const rows: u32 = 2;
        const total = self.palette.items.len;
        const gap: f32 = 6;
        const avail_w = w.rect.width - gap * @as(f32, @floatFromInt(cols - 1));
        const cell_w = @floor(avail_w / @as(f32, @floatFromInt(cols)));
        const cell_h: f32 = 24;
        var idx: usize = 0;
        var row: u32 = 0;
        while (row < rows) : (row += 1) {
            var col: u32 = 0;
            while (col < cols and idx < total) : (col += 1) {
                const x = ctx.offset_x + w.rect.x + @as(f32, @floatFromInt(col)) * (cell_w + gap);
                const y = ctx.offset_y + w.rect.y + @as(f32, @floatFromInt(row)) * (cell_h + gap);
                const c = self.palette.items[idx];
                ctx.renderer.fillRoundedRect(.{ .x = x, .y = y, .width = cell_w, .height = cell_h }, 4, c) catch {};
                // 边框
                ctx.renderer.strokeRoundedRect(.{ .x = x, .y = y, .width = cell_w, .height = cell_h }, 4, 1.0, math.Color.hex(0x334155FF)) catch {};
                idx += 1;
            }
        }
    }
    fn paletteHolderEvent(w: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _ectx;
        const self: *Self = @ptrCast(@alignCast(w.user_data orelse return .ignored));
        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const cols: u32 = 10;
                    const rows: u32 = 2;
                    const total = self.palette.items.len;
                    const gap: f32 = 6;
                    const avail_w = w.rect.width - gap * @as(f32, @floatFromInt(cols - 1));
                    const cell_w = @floor(avail_w / @as(f32, @floatFromInt(cols)));
                    const cell_h: f32 = 24;
                    const abs = w.absoluteRect();
                    const mx = @as(f32, @floatFromInt(mb.x)) - abs.x;
                    const my = @as(f32, @floatFromInt(mb.y)) - abs.y;
                    var idx: usize = 0;
                    var row: u32 = 0;
                    while (row < rows) : (row += 1) {
                        var col: u32 = 0;
                        while (col < cols and idx < total) : (col += 1) {
                            const cx = @as(f32, @floatFromInt(col)) * (cell_w + gap);
                            const cy = @as(f32, @floatFromInt(row)) * (cell_h + gap);
                            if (mx >= cx and mx <= cx + cell_w and my >= cy and my <= cy + cell_h) {
                                self.setCurrentColor(self.palette.items[idx]);
                                return .handled;
                            }
                            idx += 1;
                        }
                    }
                }
            },
            else => {},
        }
        return .ignored;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "color_chooser_dialog",
        .measure = colorDialogMeasure,
        .paint = colorDialogPaint,
        .on_event = colorDialogEvent,
        .focusable = false,
        .destroy = colorDialogDestroy,
    };
    fn colorDialogDestroy(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }
    fn colorDialogMeasure(w: *Widget, _ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = _ctx;
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.cb.visible) return constraints.constrain(.{ .width = 0, .height = 0 });
        return constraints.constrain(.{ .width = self.cb.dialog_width, .height = self.cb.dialog_height });
    }
    fn colorDialogPaint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.cb.visible) return;
        ctx.renderer.fillRect(.{ .x = 0, .y = 0, .width = 99999, .height = 99999 }, self.cb.overlay_color) catch {};
        const dw = self.cb.dialog_width;
        const dh = self.cb.dialog_height;
        const rx = ctx.offset_x + w.rect.x + (w.rect.width - dw) * 0.5;
        const ry = ctx.offset_y + w.rect.y + (w.rect.height - dh) * 0.5;
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = dw, .height = dh }, self.cb.corner_radius, self.cb.bg_color) catch {};
        if (self.inner_container) |cc| {
            cc.base.rect = .{ .x = 0, .y = 0, .width = dw, .height = dh };
            const ox = ctx.offset_x;
            const oy = ctx.offset_y;
            ctx.offset_x = rx;
            ctx.offset_y = ry;
            cc.base.vtable.paint(&cc.base, ctx);
            ctx.offset_x = ox;
            ctx.offset_y = oy;
        }
    }
    fn colorDialogEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.cb.visible) return .ignored;
        if (self.inner_container) |cc| {
            if (cc.base.vtable.on_event) |evfn| if (evfn(&cc.base, event, ectx) == .handled) return .handled;
        }
        if (event.* == .key and event.key.state == .pressed and event.key.key == .escape) {
            self.hide(.cancel);
            return .handled;
        }
        return .handled;
    }
};

// ────────────────────────────────────────────────────────────────────────────
// FontChooserDialog (GTK4: GtkFontChooserDialog)
// ────────────────────────────────────────────────────────────────────────────

pub const FontChooserDialog = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    cb: ChooserDialogBase,
    /// 当前字体 family
    font_family: []const u8 = "Sans",
    /// 字体大小 (px)
    font_size: f32 = 14,
    /// 粗体
    bold: bool = false,
    /// 斜体
    italic: bool = false,
    /// 预览文本
    preview_text: []const u8 = "The quick brown fox jumps over the lazy dog 敏捷的棕色狐狸",

    on_response: ?*const fn (self: *FontChooserDialog, response: enum { ok, cancel }, family: []const u8, size: f32, bold: bool, italic: bool) void = null,

    inner_container: ?*Container = null,
    family_entry: ?*entry_mod.Entry = null,
    size_entry: ?*entry_mod.Entry = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        title: []const u8 = "选择字体",
        initial_family: []const u8 = "Sans",
        initial_size: f32 = 14,
        initial_bold: bool = false,
        initial_italic: bool = false,
        preview_text: []const u8 = "The quick brown fox jumps over the lazy dog 敏捷的棕色狐狸",
        dialog_width: f32 = 560,
        dialog_height: f32 = 500,
        on_response: ?*const fn (self: *FontChooserDialog, response: enum { ok, cancel }, family: []const u8, size: f32, bold: bool, italic: bool) void = null,
    }) !*FontChooserDialog {
        const self = try allocator.create(FontChooserDialog);
        self.* = .{
            .base = .{ .vtable = &vtable, .id = widget_mod.genWidgetId() },
            .allocator = allocator,
            .cb = .{ .title = opts.title, .dialog_width = opts.dialog_width, .dialog_height = opts.dialog_height },
            .font_family = opts.initial_family,
            .font_size = opts.initial_size,
            .bold = opts.initial_bold,
            .italic = opts.initial_italic,
            .preview_text = opts.preview_text,
            .on_response = opts.on_response,
        };
        try self.buildUI();
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        if (self.inner_container) |cc| cc.base.vtable.destroy(&cc.base, allocator);
        allocator.destroy(self);
    }

    pub fn show(self: *Self) void {
        self.cb.visible = true;
        self.cb.result_response = .none;
        self.base.markDirty();
    }

    pub fn hide(self: *Self, response: enum { ok, cancel }) void {
        self.cb.visible = false;
        self.cb.result_response = response;
        self.base.markDirty();
        if (self.on_response) |cb| cb(self, response, self.font_family, self.font_size, self.bold, self.italic);
    }

    pub fn getFontFamily(self: *const Self) []const u8 {
        return self.font_family;
    }
    pub fn getFontSize(self: *const Self) f32 {
        return self.font_size;
    }
    pub fn isBold(self: *const Self) bool {
        return self.bold;
    }
    pub fn isItalic(self: *const Self) bool {
        return self.italic;
    }

    fn buildUI(self: *Self) !void {
        const alloc = self.allocator;
        const outer = try Container.create(alloc, .{ .direction = .column, .bg_color = math.Color.hex(0x00000000), .padding = math.EdgeInsets.all(0) });
        self.inner_container = outer;
        try self.base.addChild(alloc, &outer.base);

        // 标题
        const tl = try Label.create(alloc, self.cb.title, .{ .font_size = self.cb.title_size, .color = self.cb.title_color, .padding = math.EdgeInsets{ .left = 20, .right = 20, .top = 16, .bottom = 12 } });
        try outer.base.addChild(alloc, &tl.base);
        const sep = try Label.create(alloc, "", .{ .bg_color = math.Color.hex(0x334155FF), .min_height = 1 });
        sep.base.layout_style.min_height = .{ .px = 1 };
        try outer.base.addChild(alloc, &sep.base);

        const content = try Container.create(alloc, .{ .direction = .column, .padding = math.EdgeInsets.all(20), .gap = .{ .width = 0, .height = 12 }, .bg_color = math.Color.hex(0x00000000) });
        content.base.layout_style.flex_grow = 1;
        try outer.base.addChild(alloc, &content.base);

        // Family + Size 行
        const row1 = try Container.create(alloc, .{ .direction = .row, .bg_color = math.Color.hex(0x00000000), .gap = .{ .width = 12, .height = 0 } });
        try content.base.addChild(alloc, &row1.base);
        const fam_col = try Container.create(alloc, .{ .direction = .column, .bg_color = math.Color.hex(0x00000000), .gap = .{ .width = 0, .height = 4 } });
        fam_col.base.layout_style.flex_grow = 3;
        try row1.base.addChild(alloc, &fam_col.base);
        const fam_lbl = try Label.create(alloc, "字体", .{ .font_size = 12, .color = math.Color.hex(0x94A3B8FF) });
        try fam_col.base.addChild(alloc, &fam_lbl.base);
        const fam_entry = try entry_mod.Entry.create(alloc, .{ .placeholder = "字体族", .initial_text = self.font_family });
        self.family_entry = fam_entry;
        try fam_col.base.addChild(alloc, &fam_entry.base);

        const size_col = try Container.create(alloc, .{ .direction = .column, .bg_color = math.Color.hex(0x00000000), .gap = .{ .width = 0, .height = 4 } });
        size_col.base.layout_style.flex_grow = 1;
        try row1.base.addChild(alloc, &size_col.base);
        const size_lbl = try Label.create(alloc, "大小", .{ .font_size = 12, .color = math.Color.hex(0x94A3B8FF) });
        try size_col.base.addChild(alloc, &size_lbl.base);
        var size_buf: [16]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d:.1}", .{self.font_size}) catch "14.0";
        const size_entry = try entry_mod.Entry.create(alloc, .{ .placeholder = "字号", .initial_text = size_str });
        self.size_entry = size_entry;
        try size_col.base.addChild(alloc, &size_entry.base);

        // 样式行: Bold / Italic
        const row2 = try Container.create(alloc, .{ .direction = .row, .bg_color = math.Color.hex(0x00000000), .gap = .{ .width = 16, .height = 0 } });
        try content.base.addChild(alloc, &row2.base);
        const bold_btn = try Button.create(alloc, if (self.bold) "✓ 粗体" else "  粗体", .{ .on_click = onToggleBold });
        bold_btn.base.user_data = self;
        try row2.base.addChild(alloc, &bold_btn.base);
        const italic_btn = try Button.create(alloc, if (self.italic) "✓ 斜体" else "  斜体", .{ .on_click = onToggleItalic });
        italic_btn.base.user_data = self;
        try row2.base.addChild(alloc, &italic_btn.base);

        // 预览区
        const prev_lbl = try Label.create(alloc, "预览：", .{ .font_size = 12, .color = math.Color.hex(0x94A3B8FF) });
        try content.base.addChild(alloc, &prev_lbl.base);
        const preview_box = try Container.create(alloc, .{ .direction = .column, .bg_color = math.Color.hex(0x0F172AFF), .padding = math.EdgeInsets.all(16), .corner_radius = 8 });
        preview_box.base.layout_style.flex_grow = 1;
        preview_box.base.layout_style.min_height = .{ .px = 120 };
        try content.base.addChild(alloc, &preview_box.base);
        const preview_label = try Label.create(alloc, self.preview_text, .{ .font_size = 16, .color = math.Color.hex(0xF8FAFCFF), .wrap = true });
        try preview_box.base.addChild(alloc, &preview_label.base);

        // 底部按钮栏
        const btn_bar = try Container.create(alloc, .{ .direction = .row, .padding = math.EdgeInsets{ .left = 20, .right = 20, .top = 12, .bottom = 16 }, .gap = .{ .width = 8, .height = 0 } });
        try outer.base.addChild(alloc, &btn_bar.base);
        const spring = try Container.create(alloc, .{ .direction = .row, .bg_color = math.Color.hex(0x00000000) });
        spring.base.layout_style.flex_grow = 1;
        try btn_bar.base.addChild(alloc, &spring.base);
        const cancel_btn = try Button.create(alloc, "取消", .{ .on_click = onFontCancelClick });
        cancel_btn.base.user_data = self;
        try btn_bar.base.addChild(alloc, &cancel_btn.base);
        const ok_btn = try Button.create(alloc, "确定", .{ .on_click = onFontOkClick, .style = .primary });
        ok_btn.base.user_data = self;
        try btn_bar.base.addChild(alloc, &ok_btn.base);
    }

    fn onToggleBold(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.bold = !self.bold;
        // 简单方式: 通过按钮标签反馈状态 (这里仅更新内存字段)
        self.base.markDirty();
    }
    fn onToggleItalic(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.italic = !self.italic;
        self.base.markDirty();
    }
    fn onFontCancelClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.hide(.cancel);
    }
    fn onFontOkClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        // 从 entry 读取 family 和 size
        if (self.family_entry) |e| self.font_family = e.getText();
        self.hide(.ok);
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "font_chooser_dialog",
        .measure = fontDialogMeasure,
        .paint = fontDialogPaint,
        .on_event = fontDialogEvent,
        .focusable = false,
        .destroy = fontDialogDestroy,
    };
    fn fontDialogDestroy(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }
    fn fontDialogMeasure(w: *Widget, _ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = _ctx;
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.cb.visible) return constraints.constrain(.{ .width = 0, .height = 0 });
        return constraints.constrain(.{ .width = self.cb.dialog_width, .height = self.cb.dialog_height });
    }
    fn fontDialogPaint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.cb.visible) return;
        ctx.renderer.fillRect(.{ .x = 0, .y = 0, .width = 99999, .height = 99999 }, self.cb.overlay_color) catch {};
        const dw = self.cb.dialog_width;
        const dh = self.cb.dialog_height;
        const rx = ctx.offset_x + w.rect.x + (w.rect.width - dw) * 0.5;
        const ry = ctx.offset_y + w.rect.y + (w.rect.height - dh) * 0.5;
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = dw, .height = dh }, self.cb.corner_radius, self.cb.bg_color) catch {};
        if (self.inner_container) |cc| {
            cc.base.rect = .{ .x = 0, .y = 0, .width = dw, .height = dh };
            const ox = ctx.offset_x;
            const oy = ctx.offset_y;
            ctx.offset_x = rx;
            ctx.offset_y = ry;
            cc.base.vtable.paint(&cc.base, ctx);
            ctx.offset_x = ox;
            ctx.offset_y = oy;
        }
    }
    fn fontDialogEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.cb.visible) return .ignored;
        if (self.inner_container) |cc| {
            if (cc.base.vtable.on_event) |evfn| if (evfn(&cc.base, event, ectx) == .handled) return .handled;
        }
        if (event.* == .key and event.key.state == .pressed and event.key.key == .escape) {
            self.hide(.cancel);
            return .handled;
        }
        return .handled;
    }
};
