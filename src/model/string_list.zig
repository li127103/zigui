//! StringObject + StringList — Gio/Gtk 风格字符串对象列表
//!
//! 对标:
//!   - GStringObject / G_TYPE_STRING_OBJECT — 把字符串包装成一个带 .string 属性的对象
//!   - GtkStringList — Gtk4 常用的简单字符串列表模型（item = GStringObject*）
//!
//! StringList 实现 ListModelIface，可直接被 ColumnView / GridView / SelectionModel 消费。
//! 每个 getItem 返回 *StringObject，用户可用 `StringObject.getString()` 或 .string 字段访问。
//!
//! 典型用法:
//! ```
//! var sl = try m.StringList.createFromSlice(alloc, &.{ "Apple", "Banana", "Cherry" });
//! defer sl.destroy();
//! var sel = try m.SingleSelection.create(alloc, sl.model(), .{});
//! col_view.setSelectionModel(sel);
//!
//! // 从 ListItem.item 获取:
//! const obj: *StringObject = @ptrCast(@alignCast(item.?));
//! const s: []const u8 = obj.string;
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const list_model = @import("list_model.zig");
const ListModel = list_model.ListModel;
const ListModelIface = list_model.ListModelIface;
const ItemsChangedFn = list_model.ItemsChangedFn;

/// 字符串对象包装（对标 GStringObject）
pub const StringObject = struct {
    /// 字符串内容（由 StringList 拥有、dup）
    string: []const u8,

    /// 取出字符串（兼容 GtkStringObject 的 get_string() API）
    pub fn getString(self: *const StringObject) []const u8 {
        return self.string;
    }
};

/// 字符串列表模型（对标 GtkStringList）
pub const StringList = struct {
    allocator: Allocator,
    /// 每个元素是 *StringObject（已 dup 字符串）
    items: std.ArrayListUnmanaged(*StringObject) = .{},

    on_items_changed: ?ItemsChangedFn = null,
    on_items_changed_userdata: ?*anyopaque = null,

    const static_iface = ListModelIface{
        .getItemFn = getItemFn,
        .getNItemsFn = getNItemsFn,
        .getItemTypeFn = getTypeFn,
    };

    const Self = @This();

    // ── 创建 / 销毁 ──────────────────────────────────────────────────────

    pub fn createEmpty(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{ .allocator = allocator };
        return self;
    }

    /// 从切片创建（每个字符串自动 dup）
    pub fn createFromSlice(allocator: Allocator, strings: []const []const u8) !*Self {
        const self = try createEmpty(allocator);
        errdefer {
            self.destroy();
        }
        try self.items.ensureTotalCapacity(allocator, strings.len);
        for (strings) |s| {
            const dup = try allocator.dupe(u8, s);
            const obj = try allocator.create(StringObject);
            obj.* = .{ .string = dup };
            self.items.appendAssumeCapacity(obj);
        }
        return self;
    }

    pub fn destroy(self: *Self) void {
        for (self.items.items) |obj| {
            self.allocator.free(obj.string);
            self.allocator.destroy(obj);
        }
        self.items.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    // ── 模型获取 ─────────────────────────────────────────────────────────

    pub fn model(self: *Self) ListModel {
        return .{ .iface = &static_iface, .userdata = self };
    }

    // ── 修改 API (对标 GtkStringList) ────────────────────────────────────

    /// 末尾追加字符串
    pub fn append(self: *Self, s: []const u8) !void {
        const dup = try self.allocator.dupe(u8, s);
        const obj = try self.allocator.create(StringObject);
        obj.* = .{ .string = dup };
        try self.items.append(self.allocator, obj);
        const pos = self.items.items.len - 1;
        self.emitChanged(pos, 0, 1);
    }

    /// 在 position 位置插入字符串
    pub fn insert(self: *Self, position: usize, s: []const u8) !void {
        const dup = try self.allocator.dupe(u8, s);
        const obj = try self.allocator.create(StringObject);
        obj.* = .{ .string = dup };
        try self.items.insert(self.allocator, position, obj);
        self.emitChanged(position, 0, 1);
    }

    /// 移除 position 位置的字符串
    pub fn removeAt(self: *Self, position: usize) void {
        if (position >= self.items.items.len) return;
        const obj = self.items.orderedRemove(position);
        self.allocator.free(obj.string);
        self.allocator.destroy(obj);
        self.emitChanged(position, 1, 0);
    }

    /// 替换 position 位置的字符串
    pub fn set(self: *Self, position: usize, s: []const u8) !void {
        if (position >= self.items.items.len) {
            try self.append(s);
            return;
        }
        const obj = self.items.items[position];
        self.allocator.free(obj.string);
        obj.string = try self.allocator.dupe(u8, s);
        self.emitChanged(position, 1, 1);
    }

    /// 清空
    pub fn clear(self: *Self) void {
        const old = self.items.items.len;
        for (self.items.items) |obj| {
            self.allocator.free(obj.string);
            self.allocator.destroy(obj);
        }
        self.items.clearRetainingCapacity();
        if (old > 0) self.emitChanged(0, old, 0);
    }

    /// 替换整个列表为 strings 切片
    pub fn replaceAll(self: *Self, strings: []const []const u8) !void {
        const old = self.items.items.len;
        for (self.items.items) |obj| {
            self.allocator.free(obj.string);
            self.allocator.destroy(obj);
        }
        self.items.clearRetainingCapacity();
        if (old > 0) self.emitChanged(0, old, 0);

        try self.items.ensureTotalCapacity(self.allocator, strings.len);
        for (strings) |s| {
            const dup = try self.allocator.dupe(u8, s);
            const obj = try self.allocator.create(StringObject);
            obj.* = .{ .string = dup };
            self.items.appendAssumeCapacity(obj);
        }
        const n = self.items.items.len;
        if (n > 0) self.emitChanged(0, 0, n);
    }

    pub fn len(self: *const Self) usize {
        return self.items.items.len;
    }

    /// 便捷获取第 idx 个字符串
    pub fn getString(self: *const Self, idx: usize) ?[]const u8 {
        if (idx >= self.items.items.len) return null;
        return self.items.items[idx].string;
    }

    // ── 内部 ──────────────────────────────────────────────────────────────

    inline fn emitChanged(self: *Self, pos: usize, removed: usize, added: usize) void {
        if (self.on_items_changed) |cb| {
            cb(self.on_items_changed_userdata, pos, removed, added);
        }
    }

    // ── ListModelIface ────────────────────────────────────────────────────

    fn getItemFn(userdata: ?*anyopaque, position: usize) ?*anyopaque {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return null));
        if (position >= self.items.items.len) return null;
        return self.items.items[position];
    }

    fn getNItemsFn(userdata: ?*anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return 0));
        return self.items.items.len;
    }

    fn getTypeFn(_: ?*anyopaque) []const u8 {
        return "StringObject";
    }
};
