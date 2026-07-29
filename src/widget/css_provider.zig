//! CssProvider — GTK4 GtkCssProvider 样式规则加载器
//!
//! 实现：
//!   - 规则结构 = Selector + PropertyMap
//!   - 简化解析器（分号分隔键值，花括号分块，忽略嵌套）
//!   - 支持根据 WidgetPath 查找匹配规则按 specificity 排序
//!

const std = @import("std");
const math = @import("../math.zig");
const Color = math.Color;
const wp_mod = @import("widget_path.zig");
const WidgetPath = wp_mod.WidgetPath;
const PathElement = wp_mod.PathElement;
const StateFlags = wp_mod.StateFlags;

const Allocator = std.mem.Allocator;

/// PropertyValue = 多类型 GValue 联合（标签式 union）
pub const PropertyValue = union(enum) {
    color_val: Color,
    length_px: f32,
    percentage: f32,
    string: []const u8,
    enum_: i32,
};

/// 字符串哈希键 = 属性名
pub const PropertyMap = std.StringArrayHashMapUnmanaged(PropertyValue);

/// CSS 选择器（简化版，不含复杂组合器）
pub const Selector = struct {
    type_: ?[]const u8 = null, // "button"、"label"…null = any
    id: ?[]const u8 = null, // "#my-id"
    classes: []const []const u8 = &[0][]const u8{},
    state: StateFlags = .{}, // 伪类要求（= selector 中必须同时满足的状态位）
    any_child: bool = false, // "*" 或任意后代
    /// specificity 计算（按 id*10000 + class*100 + type*1）
    specificity: u32 = 0,

    /// 计算并填充 specificity
    pub fn calcSpecificity(self: *Selector) void {
        var s: u32 = 0;
        if (self.id != null) s += 10000;
        s += @as(u32, @intCast(self.classes.len)) * 100;
        if (self.type_ != null) s += 1;
        const st: u16 = @bitCast(self.state);
        s += @as(u32, @intCast(@popCount(st))) * 10; // state 也算权重
        self.specificity = s;
    }

    pub fn matches(self: *const Selector, path: *const WidgetPath, idx_at: u32) bool {
        if (idx_at >= path.len()) return false;
        const el = path.elements.items[idx_at];
        if (self.type_) |t| if (!std.mem.eql(u8, t, el.type_name)) return false;
        if (self.id) |id| {
            if (el.widget_id) |wid| if (!std.mem.eql(u8, wid, id)) return false else return false;
        }
        for (self.classes) |c| {
            var ok = false;
            for (el.classes.items) |cc| {
                if (std.mem.eql(u8, cc, c)) ok = true;
            }
            if (!ok) return false;
        }
        if (!el.state_flags.containsAll(self.state)) return false;
        _ = self.any_child;
        return true;
    }
};

/// 单条规则
pub const Rule = struct {
    selector: Selector,
    properties: PropertyMap,
    /// 可选：原 CSS 源码
    source: ?[]const u8 = null,
    allocator: Allocator,

    pub fn deinit(self: *Rule) void {
        self.properties.deinit(self.allocator);
        if (self.source) |src| self.allocator.free(src);
    }
};

pub const CssProvider = struct {
    allocator: Allocator,
    rules: std.ArrayListUnmanaged(Rule) = .{},
    owned_classes: std.ArrayListUnmanaged([]const u8) = .{},
    parse_errors: std.ArrayListUnmanaged([]const u8) = .{},

    // 单例
    var g_default: ?*CssProvider = null;

    const Self = @This();

    pub fn create(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *Self) void {
        const a = self.allocator;
        for (self.rules.items) |*r| r.deinit();
        self.rules.deinit(a);
        for (self.owned_classes.items) |s| a.free(s);
        self.owned_classes.deinit(a);
        for (self.parse_errors.items) |e| a.free(e);
        self.parse_errors.deinit(a);
        a.destroy(self);
    }

    pub fn getDefault(allocator: Allocator) *CssProvider {
        if (g_default) |d| return d;
        const p = create(allocator) catch @panic("oom default css");
        g_default = p;
        return p;
    }

    // ── 程序化添加 ────────────────────────────────────────────────────────

    pub fn addRule(self: *Self, sel: Selector, props: PropertyMap) void {
        var real_sel = sel;
        real_sel.calcSpecificity();
        self.rules.append(self.allocator, .{
            .selector = real_sel,
            .properties = props,
            .allocator = self.allocator,
        }) catch @panic("oom");
    }

    fn addErr(self: *Self, line: []const u8, msg: []const u8) void {
        var out = std.ArrayList(u8).init(self.allocator);
        out.writer().print("CSS parse @ [{s}]: {s}", .{ line, msg }) catch @panic("oom");
        const slice = out.toOwnedSlice() catch @panic("oom");
        self.parse_errors.append(self.allocator, slice) catch @panic("oom");
    }

    // ── 解析（简化版：忽略嵌套，不处理 @media / @keyframes）────────────────

    pub fn loadFromData(self: *Self, css: []const u8) bool {
        // 步骤：剥注释 /* ... */ → 按 { } 分割 block → 每个 block = selector { props }
        const stripped = self.stripComments(css);
        var pos: usize = 0;
        var ok = true;
        while (pos < stripped.len) {
            // 找到 '{' 前 selector
            const lb = std.mem.indexOfScalarPos(u8, stripped, pos, '{') orelse break;
            const rb = std.mem.indexOfScalarPos(u8, stripped, lb + 1, '}') orelse {
                self.addErr(stripped[pos..], "missing '}'");
                ok = false;
                break;
            };
            const selector_str = std.mem.trim(u8, stripped[pos..lb], " \t\r\n,");
            const props_str = std.mem.trim(u8, stripped[lb + 1 .. rb], " \t\r\n");
            self.parseBlock(selector_str, props_str) catch |e| {
                self.addErr(selector_str, @errorName(e));
                ok = false;
            };
            pos = rb + 1;
        }
        return ok;
    }

    pub fn loadFromFile(self: *Self, path: []const u8) bool {
        const data = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch return false;
        defer self.allocator.free(data);
        return self.loadFromData(data);
    }

    pub fn loadFromResource(self: *Self, resource_path: []const u8) bool {
        return self.loadFromFile(resource_path);
    }

    pub fn getParseErrors(self: *const Self) []const []const u8 {
        return self.parse_errors.items;
    }

    // ── 内部 ──────────────────────────────────────────────────────────────

    fn stripComments(self: *Self, input: []const u8) []const u8 {
        var out = std.ArrayList(u8).init(self.allocator);
        var i: usize = 0;
        while (i < input.len) {
            if (i + 1 < input.len and input[i] == '/' and input[i + 1] == '*') {
                i += 2;
                while (i + 1 < input.len and !(input[i] == '*' and input[i + 1] == '/')) i += 1;
                i += 2;
            } else if (i + 1 < input.len and input[i] == '/' and input[i + 1] == '/') {
                while (i < input.len and input[i] != '\n') i += 1;
            } else {
                out.append(input[i]) catch @panic("oom");
                i += 1;
            }
        }
        const slice = out.toOwnedSlice() catch @panic("oom");
        self.owned_classes.append(self.allocator, slice) catch @panic("oom");
        return slice;
    }

    fn parseBlock(self: *Self, sel_str: []const u8, props_str: []const u8) !void {
        const selector = try self.parseSelector(sel_str);
        var map = PropertyMap{};
        // 按 ; 拆分
        var it = std.mem.splitScalar(u8, props_str, ';');
        while (it.next()) |kv| {
            const k_trim = std.mem.trim(u8, kv, " \t\r\n");
            if (k_trim.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, k_trim, ':') orelse continue;
            const k = std.mem.trim(u8, k_trim[0..colon], " \t");
            const v = std.mem.trim(u8, k_trim[colon + 1 ..], " \t");
            if (k.len == 0 or v.len == 0) continue;
            const pv = self.parseValue(v);
            const owned_k = self.allocator.dupe(u8, k) catch @panic("oom");
            self.owned_classes.append(self.allocator, owned_k) catch @panic("oom");
            map.put(self.allocator, owned_k, pv) catch @panic("oom");
        }
        self.addRule(selector, map);
    }

    fn parseSelector(self: *Self, s: []const u8) !Selector {
        var sel = Selector{};
        var remaining = s;
        if (std.mem.indexOfScalar(u8, remaining, '#')) |hash_pos| {
            const id_start = hash_pos + 1;
            const after = remaining[id_start..];
            const end = std.mem.indexOfAny(u8, after, ".:[ \t>#~") orelse after.len;
            const id_slice = try self.dupe(after[0..end]);
            sel.id = id_slice;
            // 剩下可能还有 .class :state type
            const left_before_hash = try self.dupe(remaining[0..hash_pos]);
            remaining = try self.concat(left_before_hash, after[end..]);
        }
        // 解析 classes（.classname）
        var class_list = std.ArrayList([]const u8).init(self.allocator);
        while (std.mem.indexOfScalar(u8, remaining, '.')) |dot_pos| {
            const after = remaining[dot_pos + 1 ..];
            const end = std.mem.indexOfAny(u8, after, ".:[ \t>#~") orelse after.len;
            const c = try self.dupe(after[0..end]);
            try class_list.append(c);
            const left = remaining[0..dot_pos];
            remaining = try self.concat(try self.dupe(left), after[end..]);
        }
        // state: :hover :active... (简化识别前缀)
        var sf: StateFlags = .{};
        while (std.mem.indexOfScalar(u8, remaining, ':')) |colon_pos| {
            const after = remaining[colon_pos + 1 ..];
            const end = std.mem.indexOfAny(u8, after, ".:[ \t>#~(") orelse after.len;
            const pclass = after[0..end];
            if (std.mem.eql(u8, pclass, "hover") or std.mem.eql(u8, pclass, "prelight")) sf.prelit = true else if (std.mem.eql(u8, pclass, "active")) sf.active = true else if (std.mem.eql(u8, pclass, "focus")) sf.focused = true else if (std.mem.eql(u8, pclass, "selected")) sf.selected = true else if (std.mem.eql(u8, pclass, "disabled") or std.mem.eql(u8, pclass, "insensitive")) sf.insensitive = true else if (std.mem.eql(u8, pclass, "checked")) sf.checked = true else if (std.mem.eql(u8, pclass, "link")) sf.link = true;
            const left = remaining[0..colon_pos];
            remaining = try self.concat(try self.dupe(left), after[end..]);
        }
        sel.state = sf;
        sel.classes = try self.allocator.dupe([]const u8, class_list.items);
        class_list.deinit(self.allocator);
        // 剩下的就是 type name（trim）
        const t = std.mem.trim(u8, remaining, " \t\r\n>*");
        if (t.len > 0) sel.type_ = try self.dupe(t);
        if (std.mem.indexOfScalar(u8, s, '*') != null) sel.any_child = true;
        sel.calcSpecificity();
        return sel;
    }

    fn parseValue(self: *Self, v: []const u8) PropertyValue {
        // #RRGGBB / #RRGGBBAA → color
        if (v.len > 0 and v[0] == '#' and (v.len == 7 or v.len == 9)) {
            const num = std.fmt.parseInt(u32, v[1..], 16) catch 0;
            const color = if (v.len == 7) blk: {
                const r: u8 = @intCast((num >> 16) & 0xFF);
                const g: u8 = @intCast((num >> 8) & 0xFF);
                const b: u8 = @intCast(num & 0xFF);
                break :blk Color{ .r = r, .g = g, .b = b, .a = 255 };
            } else blk: {
                const r: u8 = @intCast((num >> 24) & 0xFF);
                const g: u8 = @intCast((num >> 16) & 0xFF);
                const b: u8 = @intCast((num >> 8) & 0xFF);
                const a: u8 = @intCast(num & 0xFF);
                break :blk Color{ .r = r, .g = g, .b = b, .a = a };
            };
            return .{ .color_val = color };
        }
        // N% → percentage
        if (v.len > 0 and v[v.len - 1] == '%') {
            const n = std.fmt.parseFloat(f32, v[0 .. v.len - 1]) catch 0;
            return .{ .percentage = n / 100.0 };
        }
        // Npx / N → length_px
        const num_end = if (std.mem.endsWith(u8, v, "px")) v.len - 2 else v.len;
        const num_slice = v[0..num_end];
        if (num_slice.len > 0 and (num_slice[0] == '-' or (num_slice[0] >= '0' and num_slice[0] <= '9') or num_slice[0] == '.')) {
            const n = std.fmt.parseFloat(f32, num_slice) catch 0;
            return .{ .length_px = n };
        }
        // 字符串：直接 dupe
        const s = self.allocator.dupe(u8, v) catch v;
        self.owned_classes.append(self.allocator, s) catch {};
        return .{ .string = s };
    }

    fn dupe(self: *Self, s: []const u8) ![]const u8 {
        const c = try self.allocator.dupe(u8, s);
        errdefer self.allocator.free(c);
        try self.owned_classes.append(self.allocator, c);
        return c;
    }

    fn concat(self: *Self, a: []const u8, b: []const u8) ![]const u8 {
        var list = std.ArrayList(u8).init(self.allocator);
        try list.appendSlice(a);
        try list.appendSlice(b);
        const slice = try list.toOwnedSlice();
        try self.owned_classes.append(self.allocator, slice);
        return slice;
    }

    // ── Lookup ────────────────────────────────────────────────────────────

    /// 返回所有匹配 path 末端（idx = path.len()-1）的规则，按 specificity 升序
    pub fn lookupRules(self: *Self, path: *const WidgetPath) []const Rule {
        var matched = std.ArrayList(Rule).init(self.allocator);
        defer matched.deinit();
        if (path.len() == 0) return &[0]Rule{};
        const last = path.len() - 1;
        for (self.rules.items) |r| {
            if (r.selector.matches(path, last))
                matched.append(r) catch @panic("oom");
        }
        // 按 specificity 升序插入排序
        std.sort.insertion(Rule, matched.items, {}, ruleCmp);
        const slice = self.allocator.alloc(Rule, matched.items.len) catch @panic("oom");
        @memcpy(slice, matched.items);
        self.owned_classes.append(self.allocator, slice) catch @panic("oom");
        return slice;
    }

    fn ruleCmp(_: void, a: Rule, b: Rule) bool {
        return a.selector.specificity < b.selector.specificity;
    }
};
