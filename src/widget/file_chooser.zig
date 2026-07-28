//! FileChooser 控件 - 文件选择对话框
//!
//! 支持打开文件和保存文件两种模式, 可自定义文件过滤器。
//!
//! 使用方法:
//! ```
//! var chooser = try FileChooser.create(allocator, .{
//!     .mode = .open,
//!     .title = "选择文件",
//!     .initial_path = "/home/user",
//! });
//! chooser.show();
//! ```

const std = @import("std");
const c = std.c;
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const pal = @import("../pal/pal.zig");
const container_mod = @import("container.zig");
const label_mod = @import("label.zig");
const button_mod = @import("button.zig");
const text_input_mod = @import("text_input.zig");
const scroll_view_mod = @import("scroll_view.zig");
const list_view_mod = @import("list_view.zig");
const separator_mod = @import("separator.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

const Container = container_mod.Container;
const Label = label_mod.Label;
const Button = button_mod.Button;
const TextInput = text_input_mod.TextInput;
const ScrollView = scroll_view_mod.ScrollView;
const ListView = list_view_mod.ListView;
const Separator = separator_mod.Separator;
const SeparatorOrientation = separator_mod.SeparatorOrientation;

/// 文件选择器模式
pub const FileChooserMode = enum {
    open,
    save,
};

/// 文件过滤规则
pub const FileFilter = struct {
    name: []const u8,
    /// 文件扩展名列表 (不含点, 如 &.{ "txt", "png" })
    extensions: []const []const u8,
};

pub const FileChooser = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    mode: FileChooserMode,
    title: []const u8,
    visible: bool = false,
    /// 当前目录 (owned)
    current_dir: []const u8,
    /// 选中的文件名 (owned)
    selected_file: []const u8,
    /// 文件过滤器 (可选)
    filter: ?FileFilter = null,
    on_file_selected: ?*const fn (self: *FileChooser, path: []const u8) void = null,
    on_cancel: ?*const fn (self: *FileChooser) void = null,

    // 子控件
    content_container: ?*Container = null,
    path_label: ?*Label = null,
    file_list: ?*ListView = null,
    filename_input: ?*TextInput = null,

    // 样式
    overlay_color: math.Color = math.Color.hex(0x000000AA),
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    text_secondary: math.Color = math.Color.hex(0x94A3B8FF),
    corner_radius: f32 = 14.0,
    dialog_width: f32 = 600,
    dialog_height: f32 = 500,
    title_size: f32 = 18.0,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        mode: FileChooserMode = .open,
        title: []const u8 = "选择文件",
        initial_path: []const u8 = "/",
        filter: ?FileFilter = null,
        on_file_selected: ?*const fn (self: *FileChooser, path: []const u8) void = null,
        on_cancel: ?*const fn (self: *FileChooser) void = null,
    }) !*FileChooser {
        const self = try allocator.create(FileChooser);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .mode = opts.mode,
            .title = opts.title,
            .current_dir = try allocator.dupe(u8, opts.initial_path),
            .selected_file = try allocator.dupe(u8, ""),
            .filter = opts.filter,
            .on_file_selected = opts.on_file_selected,
            .on_cancel = opts.on_cancel,
        };
        try self.buildUI();
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.current_dir);
        allocator.free(self.selected_file);
        self.base.background.deinit(allocator);
        // 子控件由 content_container 递归销毁
        if (self.content_container) |cc| {
            cc.base.vtable.destroy(&cc.base, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn show(self: *Self) void {
        self.visible = true;
        self.base.markDirty();
        self.refreshFileList();
    }

    pub fn hide(self: *Self) void {
        self.visible = false;
        self.base.markDirty();
    }

    /// 构建对话框 UI
    fn buildUI(self: *Self) !void {
        const alloc = self.allocator;

        // 主内容容器 (垂直布局)
        const content = try Container.create(alloc, .{
            .direction = .column,
            .bg_color = self.bg_color,
            .corner_radius = self.corner_radius,
            .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 },
            .gap = .{ .width = 0, .height = 12 },
        });
        self.content_container = content;
        try self.base.addChild(alloc, &content.base);

        // 标题栏
        const title = try Label.create(alloc, self.title, .{
            .font_size = self.title_size,
            .color = self.text_color,
        });
        try content.base.addChild(alloc, &title.base);

        // 路径行 (当前路径 + 上级目录按钮)
        const path_row = try Container.create(alloc, .{
            .direction = .row,
            .gap = .{ .width = 8, .height = 0 },
        });
        try content.base.addChild(alloc, &path_row.base);

        const up_btn = try Button.create(alloc, "↑", .{});
        try path_row.base.addChild(alloc, &up_btn.base);
        up_btn.on_click = onUpDir;
        up_btn.base.user_data = self;

        const path_lbl = try Label.create(alloc, self.current_dir, .{
            .font_size = 13,
            .color = self.text_secondary,
        });
        try path_row.base.addChild(alloc, &path_lbl.base);
        self.path_label = path_lbl;

        // 文件列表区域 (用 ScrollView 包裹 ListView)
        const sv = try ScrollView.create(alloc, .{
            .width = self.dialog_width - 32,
            .height = self.dialog_height - 200,
        });
        try content.base.addChild(alloc, &sv.base);

        const list = try ListView.create(alloc, .{
            .item_height = 36,
            .font_size = 14,
            .on_select = onFileSelected,
        });
        try sv.base.addChild(alloc, &list.base);
        self.file_list = list;
        list.base.user_data = self;

        // 分隔线
        const sep = try Separator.create(alloc, .{ .orientation = .horizontal });
        try content.base.addChild(alloc, &sep.base);

        // 文件名输入行
        const file_row = try Container.create(alloc, .{
            .direction = .row,
            .gap = .{ .width = 8, .height = 0 },
        });
        try content.base.addChild(alloc, &file_row.base);

        const file_lbl = try Label.create(alloc, "文件名:", .{
            .font_size = 13,
            .color = self.text_secondary,
        });
        try file_row.base.addChild(alloc, &file_lbl.base);

        const fi = try TextInput.create(alloc, .{
            .placeholder = if (self.mode == .save) "输入文件名" else "选择文件",
        });
        try file_row.base.addChild(alloc, &fi.base);
        self.filename_input = fi;

        // 按钮行
        const btn_row = try Container.create(alloc, .{
            .direction = .row,
            .gap = .{ .width = 8, .height = 0 },
        });
        try content.base.addChild(alloc, &btn_row.base);

        const cancel_btn = try Button.create(alloc, "取消", .{});
        try btn_row.base.addChild(alloc, &cancel_btn.base);
        cancel_btn.on_click = onCancelClick;
        cancel_btn.base.user_data = self;

        const action_label = if (self.mode == .save) "保存" else "打开";
        const action_btn = try Button.create(alloc, action_label, .{});
        try btn_row.base.addChild(alloc, &action_btn.base);
        action_btn.on_click = onActionClick;
        action_btn.base.user_data = self;
    }

    /// 刷新文件列表
    fn refreshFileList(self: *Self) void {
        const list = self.file_list orelse return;
        const alloc = self.allocator;

        // 清空旧列表
        for (list.items.items) |item| {
            alloc.free(item);
        }
        list.items.clearRetainingCapacity();

        // 读取目录 (用 libc)
        const dir_path = alloc.dupeZ(u8, self.current_dir) catch return;
        defer alloc.free(dir_path);

        const dir = c.opendir(dir_path) orelse return;
        defer _ = c.closedir(dir);

        var entries = std.ArrayListUnmanaged([]const u8){ .items = &.{}, .capacity = 0 };
        defer {
            for (entries.items) |e| alloc.free(e);
            entries.deinit(alloc);
        }

        while (true) {
            const entry = c.readdir(dir) orelse break;
            const name = std.mem.sliceTo(&entry.name, 0);
            // 跳过隐藏文件
            if (name.len > 0 and name[0] == '.') continue;

            const is_dir = entry.type == 4; // DT_DIR = 4 on Linux

            // 过滤文件 (目录不过滤)
            if (!is_dir) {
                if (self.filter) |filt| {
                    if (!matchFilter(name, filt.extensions)) continue;
                }
            }

            const display = alloc.alloc(u8, name.len + 3) catch continue;
            if (is_dir) {
                display[0] = '[';
                @memcpy(display[1 .. name.len + 1], name);
                display[name.len + 1] = ']';
                display[name.len + 2] = 0;
            } else {
                @memcpy(display[0..name.len], name);
                display[name.len] = 0;
                display[name.len + 1] = 0;
                display[name.len + 2] = 0;
            }
            entries.append(alloc, display) catch {
                alloc.free(display);
                continue;
            };
        }

        // 按名称排序 (目录在前)
        std.mem.sort([]const u8, entries.items, {}, sortEntries);

        // 复制到 list view
        for (entries.items) |e| {
            const owned = alloc.dupe(u8, e) catch continue;
            list.items.append(alloc, owned) catch {
                alloc.free(owned);
                continue;
            };
        }

        list.scroll_offset = 0;
        list.selected = null;

        // 更新路径标签
        if (self.path_label) |pl| {
            pl.text = self.current_dir;
        }

        self.base.markDirty();
    }

    fn sortEntries(_: void, a: []const u8, b: []const u8) bool {
        // 目录 (以 [ 开头) 排在前面
        const a_is_dir = a.len > 0 and a[0] == '[';
        const b_is_dir = b.len > 0 and b[0] == '[';
        if (a_is_dir != b_is_dir) return a_is_dir;
        // 按名称比较
        return std.mem.lessThan(u8, a, b);
    }

    fn matchFilter(filename: []const u8, extensions: []const []const u8) bool {
        for (extensions) |ext| {
            if (filename.len > ext.len + 1) {
                const dot_pos = filename.len - ext.len - 1;
                if (filename[dot_pos] == '.') {
                    const file_ext = filename[dot_pos + 1 ..];
                    if (std.ascii.eqlIgnoreCase(file_ext, ext)) return true;
                }
            }
        }
        return false;
    }

    /// 进入指定子目录或选中文件
    fn onFileSelected(list: *ListView, index: usize) void {
        const self: *Self = @ptrCast(@alignCast(list.base.user_data orelse return));
        const item = list.items.items[index];

        // 判断是目录还是文件
        if (item.len > 0 and item[0] == '[') {
            // 目录 - 进入
            const dir_name = item[1 .. item.len - 1]; // 去掉 [ 和 ]
            self.enterDir(dir_name);
        } else {
            // 文件 - 填入文件名输入框
            const name = std.mem.sliceTo(item, 0);
            self.setSelectedFile(name);
        }
    }

    fn onUpDir(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.goToParentDir();
    }

    fn onCancelClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.hide();
        if (self.on_cancel) |cb| cb(self);
    }

    fn onActionClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        const filename = if (self.filename_input) |fi| fi.getText() else "";
        if (filename.len == 0) return;

        // 构造完整路径
        const path = blk: {
            const dir = self.current_dir;
            const has_slash = dir.len > 0 and dir[dir.len - 1] == '/';
            const total_len = dir.len + filename.len + @as(usize, if (has_slash) 0 else 1);
            const buf = self.allocator.alloc(u8, total_len) catch return;
            @memcpy(buf[0..dir.len], dir);
            var pos = dir.len;
            if (!has_slash) {
                buf[pos] = '/';
                pos += 1;
            }
            @memcpy(buf[pos..], filename);
            break :blk buf;
        };
        defer self.allocator.free(path);

        // 转换为以 0 结尾的字符串供 libc 使用
        const path_z = self.allocator.dupeZ(u8, path) catch return;
        defer self.allocator.free(path_z);

        // 检查路径是否存在
        const exists = c.access(path_z, c.F_OK) == 0;
        if (!exists and self.mode == .open) return;

        // 检查是否是目录
        const is_dir = blk: {
            const d = c.opendir(path_z) orelse break :blk false;
            _ = c.closedir(d);
            break :blk true;
        };

        if (is_dir) {
            // 如果是目录, 进入
            self.setCurrentDir(path);
            return;
        }

        // 选择文件
        self.hide();
        if (self.on_file_selected) |cb| cb(self, path);
    }

    fn enterDir(self: *Self, name: []const u8) void {
        const dir = self.current_dir;
        const has_slash = dir.len > 0 and dir[dir.len - 1] == '/';
        const total_len = dir.len + name.len + @as(usize, if (has_slash) 0 else 1);
        const buf = self.allocator.alloc(u8, total_len) catch return;
        @memcpy(buf[0..dir.len], dir);
        var pos = dir.len;
        if (!has_slash) {
            buf[pos] = '/';
            pos += 1;
        }
        @memcpy(buf[pos..], name);
        self.setCurrentDir(buf);
        self.allocator.free(buf);
    }

    fn goToParentDir(self: *Self) void {
        if (std.mem.eql(u8, self.current_dir, "/")) return;

        // 找到最后一个斜杠
        const idx = std.mem.lastIndexOfScalar(u8, self.current_dir, '/') orelse return;
        const parent = if (idx == 0) "/" else self.current_dir[0..idx];

        const new_path = self.allocator.dupe(u8, parent) catch return;
        self.allocator.free(self.current_dir);
        self.current_dir = new_path;
        self.refreshFileList();
    }

    fn setCurrentDir(self: *Self, path: []const u8) void {
        const new_path = self.allocator.dupe(u8, path) catch return;
        self.allocator.free(self.current_dir);
        self.current_dir = new_path;
        self.refreshFileList();
    }

    fn setSelectedFile(self: *Self, name: []const u8) void {
        const new_name = self.allocator.dupe(u8, name) catch return;
        self.allocator.free(self.selected_file);
        self.selected_file = new_name;

        // 更新输入框
        if (self.filename_input) |fi| {
            fi.setText(name) catch {};
        }
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "file_chooser",
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

        // 半透明遮罩
        ctx.renderer.fillRect(rect, self.overlay_color) catch {};

        // 居中计算对话框位置
        const dl_w = self.dialog_width;
        const dl_h = self.dialog_height;
        const dl_x = rect.x + (rect.width - dl_w) / 2;
        const dl_y = rect.y + (rect.height - dl_h) / 2;

        // 设置内容容器的位置和尺寸
        if (self.content_container) |cc| {
            cc.base.rect = .{ .x = dl_x, .y = dl_y, .width = dl_w, .height = dl_h };
            // 递归绘制内容
            cc.base.vtable.paint(&cc.base, ctx);
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.visible) return .ignored;

        // 先让子控件处理事件
        if (self.content_container) |cc| {
            if (cc.base.vtable.on_event) |ev_fn| {
                const result = ev_fn(&cc.base, event, ectx);
                if (result == .handled) return .handled;
            }
        }

        // ESC 关闭
        if (event.* == .key and event.key.state == .pressed and event.key.key == .escape) {
            self.hide();
            if (self.on_cancel) |cb| cb(self);
            return .handled;
        }

        return .handled; // 模态: 吞掉所有未处理事件
    }
};
