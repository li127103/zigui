//! WidgetPath — GTK4 GtkWidgetPath 样式路径
//!
//! 描述 Widget 在 Widget 树中的路径及状态，供 CSS 样式匹配。
//! 每个元素 = 一个 ancestor 或自身：类型 + 可选 id/name/类/region/state + 兄弟索引。
//!

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const Widget = widget_mod.Widget;

/// GTK4 GtkStateFlags（共 14 个 + 2 padding；u16 够用）
pub const StateFlags = packed struct(u16) {
    normal: bool = false,
    active: bool = false,
    prelit: bool = false, // :hover
    selected: bool = false,
    insensitive: bool = false, // :disabled
    inconsistent: bool = false,
    focused: bool = false,
    backdrop: bool = false,
    direction_ltr: bool = false,
    direction_rtl: bool = false,
    link: bool = false,
    visited: bool = false,
    checked: bool = false,
    drop_active: bool = false,
    _pad: u2 = 0,

    pub fn empty() StateFlags {
        return .{};
    }
    pub fn unionWith(self: *StateFlags, other: StateFlags) void {
        const a: u16 = @bitCast(self.*);
        const b: u16 = @bitCast(other);
        self.* = @bitCast(a | b);
    }
    pub fn intersect(self: *const StateFlags, other: StateFlags) StateFlags {
        const a: u16 = @bitCast(self.*);
        const b: u16 = @bitCast(other);
        return @bitCast(a & b);
    }
    pub fn containsAll(self: *const StateFlags, required: StateFlags) bool {
        const a: u16 = @bitCast(self.*);
        const b: u16 = @bitCast(required);
        return (a & b) == b;
    }
};

const RegionEntry = struct {
    region: []const u8,
    flags: StateFlags = .{},
};

pub const PathElement = struct {
    type_name: []const u8,
    widget_id: ?[]const u8 = null,
    object_name: ?[]const u8 = null,
    classes: std.ArrayListUnmanaged([]const u8) = .{},
    regions: std.ArrayListUnmanaged(RegionEntry) = .{},
    state_flags: StateFlags = .{},
    sibling_index: u32 = 0,
    sibling_count: u32 = 0,

    fn deinit(self: *PathElement, allocator: std.mem.Allocator) void {
        self.classes.deinit(allocator);
        for (self.regions.items) |r| _ = r; // regions.items 持有的 []const u8 来自外部或已复制，此处不释放
        self.regions.deinit(allocator);
    }
};

pub const WidgetPath = struct {
    allocator: std.mem.Allocator,
    elements: std.ArrayListUnmanaged(PathElement) = .{},
    owned_strs: std.ArrayListUnmanaged([]const u8) = .{}, // 所有需要 free 的字符串副本

    const Self = @This();

    // ── 初始化 / 析构 ─────────────────────────────────────────────────────

    pub fn create(allocator: std.mem.Allocator) *Self {
        const self = allocator.create(Self) catch @panic("oom");
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *Self) void {
        const a = self.allocator;
        for (self.elements.items) |*el| el.deinit(a);
        self.elements.deinit(a);
        for (self.owned_strs.items) |s| a.free(s);
        self.owned_strs.deinit(a);
        a.destroy(self);
    }

    fn dup(self: *Self, s: []const u8) []const u8 {
        const c = self.allocator.dupe(u8, s) catch @panic("oom");
        self.owned_strs.append(self.allocator, c) catch @panic("oom");
        return c;
    }

    // ── 操作 ──────────────────────────────────────────────────────────────

    pub fn len(self: *const Self) u32 {
        return @intCast(self.elements.items.len);
    }

    pub fn appendType(self: *Self, type_name: []const u8) u32 {
        const el = PathElement{ .type_name = self.dup(type_name) };
        self.elements.append(self.allocator, el) catch @panic("oom");
        return self.len() - 1;
    }

    /// 从 Widget 自动追加：type_name = vtable.type_name；id = widget.id 转字符串？或 object_name
    pub fn appendWidget(self: *Self, widget: *const Widget) u32 {
        const name = if (widget.base_iface) |bi| bi.type_name else widget.vtable.type_name;
        const idx = self.appendType(name);
        // object_name 字段 (P 阶段 Widget.name 默认 "widget")
        self.elements.items[idx].object_name = self.dup(widget.name);
        // id 置为 数字索引字符串的占位，不使用
        self.updateSiblingIndices();
        return idx;
    }

    pub fn insertAt(self: *Self, index: u32, type_name: []const u8) void {
        const el = PathElement{ .type_name = self.dup(type_name) };
        self.elements.insert(self.allocator, index, el) catch @panic("oom");
        self.updateSiblingIndices();
    }

    pub fn removeAt(self: *Self, index: u32) void {
        if (index >= self.elements.items.len) return;
        var el = self.elements.items[index];
        el.deinit(self.allocator);
        _ = self.elements.orderedRemove(self.allocator, index);
        self.updateSiblingIndices();
    }

    fn updateSiblingIndices(self: *Self) void {
        const total: u32 = self.len();
        for (self.elements.items, 0..) |*el, i| {
            el.sibling_index = @intCast(i);
            el.sibling_count = total;
        }
    }

    // ── 读写 ──────────────────────────────────────────────────────────────

    pub fn getObjectTypeAt(self: *const Self, idx: u32) []const u8 {
        if (idx >= self.elements.items.len) return "";
        return self.elements.items[idx].type_name;
    }

    pub fn setObjectTypeAt(self: *Self, idx: u32, name: []const u8) void {
        if (idx >= self.elements.items.len) return;
        self.elements.items[idx].type_name = self.dup(name);
    }

    // ── Classes ───────────────────────────────────────────────────────────

    pub fn addClass(self: *Self, idx: u32, class_name: []const u8) void {
        if (idx >= self.elements.items.len) return;
        const name = self.dup(class_name);
        self.elements.items[idx].classes.append(self.allocator, name) catch @panic("oom");
    }

    pub fn hasClass(self: *const Self, idx: u32, class_name: []const u8) bool {
        if (idx >= self.elements.items.len) return false;
        for (self.elements.items[idx].classes.items) |c| {
            if (std.mem.eql(u8, c, class_name)) return true;
        }
        return false;
    }

    pub fn removeClass(self: *Self, idx: u32, class_name: []const u8) void {
        if (idx >= self.elements.items.len) return;
        var list = &self.elements.items[idx].classes;
        var i: usize = 0;
        while (i < list.items.len) : (i += 1) {
            if (std.mem.eql(u8, list.items[i], class_name)) {
                _ = list.orderedRemove(self.allocator, i);
                i -= 1;
            }
        }
    }

    pub fn listClasses(self: *const Self, idx: u32) []const []const u8 {
        if (idx >= self.elements.items.len) return &[0][]const u8{};
        return self.elements.items[idx].classes.items;
    }

    pub fn setObjectName(self: *Self, idx: u32, name: []const u8) void {
        if (idx >= self.elements.items.len) return;
        self.elements.items[idx].object_name = self.dup(name);
    }

    pub fn setWidgetId(self: *Self, idx: u32, id: []const u8) void {
        if (idx >= self.elements.items.len) return;
        self.elements.items[idx].widget_id = self.dup(id);
    }

    // ── Region ────────────────────────────────────────────────────────────

    pub fn addRegion(self: *Self, idx: u32, region: []const u8, flags: StateFlags) void {
        if (idx >= self.elements.items.len) return;
        const r = self.dup(region);
        self.elements.items[idx].regions.append(self.allocator, .{ .region = r, .flags = flags }) catch @panic("oom");
    }

    pub fn hasRegion(self: *const Self, idx: u32, region: []const u8) ?*const RegionEntry {
        if (idx >= self.elements.items.len) return null;
        for (self.elements.items[idx].regions.items) |*r| {
            if (std.mem.eql(u8, r.region, region)) return r;
        }
        return null;
    }

    // ── State ─────────────────────────────────────────────────────────────

    pub fn setState(self: *Self, idx: u32, flags: StateFlags) void {
        if (idx >= self.elements.items.len) return;
        self.elements.items[idx].state_flags = flags;
    }

    pub fn getState(self: *const Self, idx: u32) StateFlags {
        if (idx >= self.elements.items.len) return .{};
        return self.elements.items[idx].state_flags;
    }

    // ── 调试：转字符串 ────────────────────────────────────────────────────

    /// 生成 CSS-like 选择器字符串。返回值需由调用方 free 或在后续 destroy 一起释放（这里写入 owned_strs）。
    pub fn toString(self: *Self) []const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        for (0..self.elements.items.len) |i_usize| {
            const e = &self.elements.items[i_usize];
            if (e.widget_id) |id| {
                buf.append('#') catch @panic("oom");
                buf.appendSlice(id) catch @panic("oom");
            }
            buf.appendSlice(e.type_name) catch @panic("oom");
            for (e.classes.items) |c| {
                buf.append('.') catch @panic("oom");
                buf.appendSlice(c) catch @panic("oom");
            }
            // state flags → 伪类
            const s: u16 = @bitCast(e.state_flags);
            if (s != 0) {
                const flags_strs = @import("builtin").zig_backend; // dummy fallback for switch
                _ = flags_strs;
                // 常见几个转伪类
                if (e.state_flags.prelit) buf.appendSlice(":hover") catch @panic("oom");
                if (e.state_flags.active) buf.appendSlice(":active") catch @panic("oom");
                if (e.state_flags.focused) buf.appendSlice(":focus") catch @panic("oom");
                if (e.state_flags.selected) buf.appendSlice(":selected") catch @panic("oom");
                if (e.state_flags.insensitive) buf.appendSlice(":disabled") catch @panic("oom");
            }
            if (e.sibling_count > 0) {
                buf.writer().print(":nth-child({d}/{d})", .{ e.sibling_index + 1, e.sibling_count }) catch @panic("oom");
            }
            if (i_usize + 1 < self.elements.items.len)
                buf.appendSlice(" > ") catch @panic("oom");
        }
        const slice = buf.toOwnedSlice() catch @panic("oom");
        self.owned_strs.append(self.allocator, slice) catch @panic("oom");
        return slice;
    }

    // ── 前缀匹配：本 path 是 ref_path 的 ancestor 或相同类型前缀 ────────────

    pub fn isType(self: *const Self, ref_path: *const WidgetPath) bool {
        if (self.len() < ref_path.len()) return false;
        // ref 最底部若干元素（末位 = 自身），self 对应位置类型需匹配
        const offset: u32 = self.len() - ref_path.len();
        for (0..ref_path.elements.items.len) |i| {
            const a = self.elements.items[i + offset];
            const b = ref_path.elements.items[i];
            if (!std.mem.eql(u8, a.type_name, b.type_name)) return false;
            // ref 中指定的 class/id 必须包含在 self 中（不要求 self 不包含其他）
            for (b.classes.items) |c| if (!self.hasClass(@intCast(i + offset), c)) return false;
            if (b.widget_id) |bid| {
                if (a.widget_id) |aid| if (!std.mem.eql(u8, aid, bid)) return false else return false;
            }
        }
        return true;
    }
};
