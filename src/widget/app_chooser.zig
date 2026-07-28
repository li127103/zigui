//! AppChooser 控件 - 应用选择对话框
//!
//! 支持选择打开指定文件或 MIME 类型的应用程序。
//!
//! 使用方法:
//! ```
//! var dlg = try AppChooserDialog.create(allocator, .{
//!     .content_type = "text/plain",
//!     .on_app_selected = onAppSelected,
//! });
//! dlg.show();
//! ```

const std = @import("std");
const c = std.c;
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const pal = @import("../pal/pal.zig");
const container_mod = @import("container.zig");
const label_mod = @import("label.zig");
const button_mod = @import("button.zig");
const scroll_view_mod = @import("scroll_view.zig");
const list_view_mod = @import("list_view.zig");
const separator_mod = @import("separator.zig");
const checkbox_mod = @import("checkbox.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

const Container = container_mod.Container;
const Label = label_mod.Label;
const Button = button_mod.Button;
const ScrollView = scroll_view_mod.ScrollView;
const ListView = list_view_mod.ListView;
const Separator = separator_mod.Separator;
const Checkbox = checkbox_mod.Checkbox;

/// 应用信息
pub const AppInfo = struct {
    name: []const u8,
    exec: []const u8,
    icon_name: []const u8 = "",
    desktop_id: []const u8 = "",
};

pub const AppChooserDialog = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    visible: bool = false,
    content_type: []const u8,
    selected_app: ?AppInfo = null,
    set_as_default: bool = false,
    on_app_selected: ?*const fn (self: *AppChooserDialog, app: AppInfo) void = null,
    on_cancel: ?*const fn (self: *AppChooserDialog) void = null,

    content_container: ?*Container = null,
    app_list: ?*ListView = null,
    default_check: ?*Checkbox = null,

    overlay_color: math.Color = math.Color.hex(0x000000AA),
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    text_secondary: math.Color = math.Color.hex(0x94A3B8FF),
    corner_radius: f32 = 14.0,
    dialog_width: f32 = 500,
    dialog_height: f32 = 450,
    title_size: f32 = 18.0,

    apps: std.ArrayListUnmanaged(AppInfo) = .{ .items = &.{}, .capacity = 0 },

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        title: []const u8 = "选择应用",
        content_type: []const u8 = "application/octet-stream",
        on_app_selected: ?*const fn (self: *AppChooserDialog, app: AppInfo) void = null,
        on_cancel: ?*const fn (self: *AppChooserDialog) void = null,
    }) !*AppChooserDialog {
        const self = try allocator.create(AppChooserDialog);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .content_type = try allocator.dupe(u8, opts.content_type),
            .on_app_selected = opts.on_app_selected,
            .on_cancel = opts.on_cancel,
        };
        self.loadApps();
        try self.buildUI(opts.title);
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.content_type);
        for (self.apps.items) |*app| {
            allocator.free(app.name);
            allocator.free(app.exec);
            if (app.icon_name.len > 0) allocator.free(app.icon_name);
            if (app.desktop_id.len > 0) allocator.free(app.desktop_id);
        }
        self.apps.deinit(allocator);
        self.base.background.deinit(allocator);
        if (self.content_container) |cc| {
            cc.base.vtable.destroy(&cc.base, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn show(self: *Self) void {
        self.visible = true;
        self.base.markDirty();
    }

    pub fn hide(self: *Self) void {
        self.visible = false;
        self.base.markDirty();
    }

    fn loadApps(self: *Self) void {
        if (comptime @import("builtin").os.tag == .macos) {
            self.loadAppsMacos();
        } else if (comptime @import("builtin").os.tag != .windows) {
            self.loadAppsLinux();
        }
    }

    fn loadAppsLinux(self: *Self) void {
        var app_dirs = std.ArrayList([]const u8).init(self.allocator);
        defer app_dirs.deinit();

        const data_home = std.c.getenv("XDG_DATA_HOME") orelse {
            const home = std.c.getenv("HOME") orelse "/";
            const path = std.fmt.allocPrint(self.allocator, "{s}/.local/share/applications", .{home}) catch return;
            app_dirs.append(path) catch return;
            const sys_path = "/usr/share/applications";
            app_dirs.append(sys_path) catch return;
            self.scanDesktopFiles(app_dirs.items);
            return;
        };
        const data_home_path = std.fmt.allocPrint(self.allocator, "{s}/applications", .{data_home}) catch return;
        app_dirs.append(data_home_path) catch return;

        const data_dirs = std.c.getenv("XDG_DATA_DIRS") orelse "/usr/share:/usr/local/share";
        var it = std.mem.split(u8, data_dirs, ":");
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const path = std.fmt.allocPrint(self.allocator, "{s}/applications", .{dir}) catch continue;
            app_dirs.append(path) catch {
                self.allocator.free(path);
                continue;
            };
        }

        self.scanDesktopFiles(app_dirs.items);
    }

    fn scanDesktopFiles(self: *Self, dirs: []const []const u8) void {
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        for (dirs) |dir| {
            var d = std.fs.openDirAbsolute(dir, .{ .iterate = true }) catch continue;
            defer d.close();

            var it = d.iterate();
            while (it.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;

                const id = entry.name;
                if (seen.contains(id)) continue;
                const gop = seen.getOrPut(id) catch continue;
                if (!gop.found_existing) {}

                const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, entry.name }) catch continue;
                defer self.allocator.free(path);

                if (self.parseDesktopFile(path)) |app| {
                    self.apps.append(self.allocator, app) catch {
                        self.allocator.free(app.name);
                        self.allocator.free(app.exec);
                        if (app.icon_name.len > 0) self.allocator.free(app.icon_name);
                        if (app.desktop_id.len > 0) self.allocator.free(app.desktop_id);
                    };
                }
            }
        }
    }

    fn parseDesktopFile(self: *Self, path: []const u8) ?AppInfo {
        const content = std.fs.cwd().readFileAllocOptions(
            self.allocator,
            path,
            1024 * 1024,
            null,
            1,
            0,
        ) catch return null;
        defer self.allocator.free(content);

        var name: ?[]const u8 = null;
        var exec: ?[]const u8 = null;
        var icon: []const u8 = "";
        var in_desktop_entry = false;
        var hidden = false;
        var no_display = false;

        var lines = std.mem.split(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue;

            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                in_desktop_entry = std.mem.eql(u8, trimmed[1 .. trimmed.len - 1], "Desktop Entry");
                continue;
            }

            if (!in_desktop_entry) continue;

            const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = trimmed[0..eq_pos];
            const value = trimmed[eq_pos + 1 ..];

            if (std.mem.eql(u8, key, "Name") and name == null) {
                name = self.allocator.dupe(u8, value) catch null;
            } else if (std.mem.eql(u8, key, "Exec") and exec == null) {
                exec = self.allocator.dupe(u8, value) catch null;
            } else if (std.mem.eql(u8, key, "Icon")) {
                icon = self.allocator.dupe(u8, value) catch "";
            } else if (std.mem.eql(u8, key, "Hidden")) {
                hidden = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "NoDisplay")) {
                no_display = std.mem.eql(u8, value, "true");
            }
        }

        if (hidden or no_display) {
            if (name) |n| self.allocator.free(n);
            if (exec) |e| self.allocator.free(e);
            if (icon.len > 0) self.allocator.free(icon);
            return null;
        }

        const n = name orelse return null;
        const e = exec orelse {
            self.allocator.free(n);
            if (icon.len > 0) self.allocator.free(icon);
            return null;
        };

        const desktop_id = std.fs.path.basename(path);
        const owned_id = self.allocator.dupe(u8, desktop_id) catch "";

        return .{
            .name = n,
            .exec = e,
            .icon_name = icon,
            .desktop_id = owned_id,
        };
    }

    fn loadAppsMacos(self: *Self) void {
        _ = self;
    }

    fn buildUI(self: *Self, title: []const u8) !void {
        const alloc = self.allocator;

        const content = try Container.create(alloc, .{
            .direction = .column,
            .bg_color = self.bg_color,
            .corner_radius = self.corner_radius,
            .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 },
            .gap = .{ .width = 0, .height = 12 },
        });
        self.content_container = content;
        try self.base.addChild(alloc, &content.base);

        const title_lbl = try Label.create(alloc, title, .{
            .font_size = self.title_size,
            .color = self.text_color,
        });
        try content.base.addChild(alloc, &title_lbl.base);

        const desc = try Label.create(alloc, "选择要用来打开此文件类型的应用程序:", .{
            .font_size = 12,
            .color = self.text_secondary,
        });
        try content.base.addChild(alloc, &desc.base);

        const sv = try ScrollView.create(alloc, .{
            .width = 460,
            .height = 280,
        });
        try content.base.addChild(alloc, &sv.base);

        const list = try ListView.create(alloc, .{
            .item_height = 32,
            .font_size = 13,
            .on_select = onAppSelected,
        });
        try sv.base.addChild(alloc, &list.base);
        self.app_list = list;
        list.base.user_data = self;

        for (self.apps.items) |app| {
            const owned = alloc.dupe(u8, app.name) catch continue;
            list.items.append(alloc, owned) catch {
                alloc.free(owned);
            };
        }

        const default_check = try Checkbox.create(alloc, "设为默认应用", .{});
        try content.base.addChild(alloc, &default_check.base);
        self.default_check = default_check;
        default_check.base.user_data = self;

        const sep = try Separator.create(alloc, .{ .orientation = .horizontal });
        try content.base.addChild(alloc, &sep.base);

        const btn_row = try Container.create(alloc, .{
            .direction = .row,
            .gap = .{ .width = 8, .height = 0 },
        });
        try content.base.addChild(alloc, &btn_row.base);

        const cancel_btn = try Button.create(alloc, "取消", .{});
        try btn_row.base.addChild(alloc, &cancel_btn.base);
        cancel_btn.on_click = onCancelClick;
        cancel_btn.base.user_data = self;

        const ok_btn = try Button.create(alloc, "确定", .{});
        try btn_row.base.addChild(alloc, &ok_btn.base);
        ok_btn.on_click = onOkClick;
        ok_btn.base.user_data = self;
    }

    fn onAppSelected(list: *ListView, index: usize) void {
        const self: *Self = @ptrCast(@alignCast(list.base.user_data orelse return));
        if (index < self.apps.items.len) {
            self.selected_app = self.apps.items[index];
        }
    }

    fn onCancelClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.hide();
        if (self.on_cancel) |cb| cb(self);
    }

    fn onOkClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        if (self.default_check) |chk| {
            self.set_as_default = chk.checked;
        }
        if (self.selected_app) |app| {
            self.hide();
            if (self.on_app_selected) |cb| cb(self, app);
        }
    }

    const vtable = Widget.VTable{
        .type_name = "app_chooser",
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

    fn measure(w: *Widget, ctx: *PaintContext, constraints: @import("../layout/engine.zig").Constraints) math.Size(f32) {
        _ = w;
        _ = ctx;
        return .{ .width = constraints.max_width, .height = constraints.max_height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.visible) return;

        const rect = w.rect;
        ctx.renderer.fillRect(rect, self.overlay_color) catch {};

        const dl_w = self.dialog_width;
        const dl_h = self.dialog_height;
        const dl_x = rect.x + (rect.width - dl_w) / 2;
        const dl_y = rect.y + (rect.height - dl_h) / 2;

        if (self.content_container) |cc| {
            cc.base.rect = .{ .x = dl_x, .y = dl_y, .width = dl_w, .height = dl_h };
            cc.base.vtable.paint(&cc.base, ctx);
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.visible) return .ignored;

        if (self.content_container) |cc| {
            if (cc.base.vtable.on_event) |ev_fn| {
                const result = ev_fn(&cc.base, event, ectx);
                if (result == .handled) return .handled;
            }
        }

        if (event.* == .key and event.key.state == .pressed and event.key.key == .escape) {
            self.hide();
            if (self.on_cancel) |cb| cb(self);
            return .handled;
        }

        return .handled;
    }
};
