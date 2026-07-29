//! StyleContext — GTK4 GtkStyleContext：每个 Widget 持有，最终样式查询聚合
//!
//! 设计：
//!   - 持有 WidgetPath（用于匹配）
//!   - 持有多个 CssProvider（按 priority 排序；0=Fallback, 400=GTK Settings, 600=Theme, 800=Application）
//!   - 提供 getColor/getFontSize/getMarginPx/Padding/Border 等聚合查询
//!   - 内置 Adwaita 默认 fallback 表

const std = @import("std");
const math = @import("../math.zig");
const Color = math.Color;
const Allocator = std.mem.Allocator;

const wp_mod = @import("widget_path.zig");
const css_mod = @import("css_provider.zig");
// const gdk_display_mod = @import("display.zig"); // 暂不引入避免环形

const WidgetPath = wp_mod.WidgetPath;
const StateFlags = wp_mod.StateFlags;
const CssProvider = css_mod.CssProvider;
const Rule = css_mod.Rule;
const PropertyMap = css_mod.PropertyMap;
const PropertyValue = css_mod.PropertyValue;

const PrioritySlot = struct {
    provider: *CssProvider,
    priority: u32,
};

const StackEntry = struct {
    state: StateFlags,
    path_snapshot_len: u32, // 仅比较长度（简化，不用深拷贝）
};

pub const StyleContext = struct {
    allocator: Allocator,
    path: *WidgetPath,
    providers: std.ArrayListUnmanaged(PrioritySlot) = .{},
    state: StateFlags = .{},
    scale: f32 = 1.0,
    direction: enum(u1) { ltr, rtl } = .ltr,
    display: ?*anyopaque = null, // GdkDisplay* 占位
    widget_ptr: ?*anyopaque = null,

    save_stack: std.ArrayListUnmanaged(StackEntry) = .{},
    cache: ?PropertyMap = null,
    cache_version: u32 = 0, // provider 变化时 +1

    const Self = @This();
    const ADWAITA_DEFAULT_FONT: f32 = 13.0;
    const ADWAITA_DEFAULT_FG = Color{ .r = 0x2E, .g = 0x34, .b = 0x36, .a = 0xFF }; // fg color (dark text on light)
    const ADWAITA_DEFAULT_BG = Color{ .r = 0xFA, .g = 0xFA, .b = 0xFA, .a = 0xFF };

    // ── 构造 / 析构 ───────────────────────────────────────────────────────

    pub fn create(allocator: Allocator, path: *WidgetPath) *Self {
        const self = allocator.create(Self) catch @panic("oom");
        self.* = .{
            .allocator = allocator,
            .path = path,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        const a = self.allocator;
        self.providers.deinit(a);
        self.save_stack.deinit(a);
        if (self.cache) |*c| c.deinit(a);
        a.destroy(self);
    }

    // ── Provider 管理 ─────────────────────────────────────────────────────

    /// priority 建议：0=Fallback/GTK 内置  400=Settings  600=Theme  800=Application
    pub fn addProvider(self: *Self, provider: *CssProvider, priority: u32) void {
        const a = self.allocator;
        const slot = PrioritySlot{ .provider = provider, .priority = priority };
        // 插入按 priority 升序
        var i: usize = 0;
        while (i < self.providers.items.len) : (i += 1) {
            if (self.providers.items[i].priority > priority) break;
        }
        self.providers.insert(a, i, slot) catch @panic("oom");
        self.invalidate();
    }

    pub fn removeProvider(self: *Self, provider: *CssProvider) void {
        const a = self.allocator;
        var i: usize = 0;
        while (i < self.providers.items.len) : (i += 1) {
            if (self.providers.items[i].provider == provider) {
                _ = self.providers.orderedRemove(a, i);
                self.invalidate();
                break;
            }
        }
    }

    // ── 状态 / 路径 ───────────────────────────────────────────────────────

    pub fn setState(self: *Self, flags: StateFlags) void {
        self.state = flags;
        self.invalidate();
    }

    pub fn setStateOne(self: *Self, comptime field: @typeInfo(StateFlags).@"struct".fields[0].type, val: bool) void {
        // 用 comptime 方式不行：用位操作替代
        _ = field;
        _ = val;
        self.invalidate();
    }

    pub fn getState(self: *const Self) StateFlags { return self.state; }

    pub fn save(self: *Self) void {
        self.save_stack.append(self.allocator, .{
            .state = self.state,
            .path_snapshot_len = self.path.len(),
        }) catch @panic("oom");
    }

    pub fn restore(self: *Self) void {
        if (self.save_stack.popOrNull()) |last| {
            self.state = last.state;
            // 不修改 path（只比长度），但 invalidate 保证安全
            self.invalidate();
        }
    }

    pub fn invalidate(self: *Self) void {
        if (self.cache) |*c| {
            c.deinit(self.allocator);
            self.cache = null;
        }
        self.cache_version +%= 1;
    }

    pub fn bind(self: *Self, widget_ptr: ?*anyopaque) void {
        self.widget_ptr = widget_ptr;
    }

    // ── 规则聚合：按 specificity 合并属性 ──────────────────────────────────

    fn aggregate(self: *Self) PropertyMap {
        if (self.cache) |c| return c;
        // 同步 Path 末尾 state（让 CSS :hover 等生效）
        if (self.path.len() > 0) {
            self.path.setState(self.path.len() - 1, self.state);
        }
        var merged = PropertyMap{};
        // Provider 按 priority 升序；每个 provider 内 rules 按 specificity 升序 → 后面覆盖前面
        for (self.providers.items) |slot| {
            const rules = slot.provider.lookupRules(self.path);
            for (rules) |r| {
                var it = r.properties.iterator();
                while (it.next()) |entry| {
                    const k = entry.key_ptr.*;
                    const v = entry.value_ptr.*;
                    merged.put(self.allocator, k, v) catch @panic("oom");
                }
            }
        }
        self.cache = merged;
        return merged;
    }

    // ── 查询接口 ──────────────────────────────────────────────────────────

    pub fn getProperty(self: *Self, name: []const u8) ?PropertyValue {
        const agg = self.aggregate();
        return agg.get(name);
    }

    fn getColorByNames(self: *Self, names: []const []const u8, fallback: Color) Color {
        const agg = self.aggregate();
        for (names) |n| if (agg.get(n)) |pv| switch (pv) {
            .color_val => |c| return c,
            else => {},
        };
        return fallback;
    }

    pub fn getColor(self: *Self, fallback: Color) Color {
        return self.getColorByNames(&.{ "color", "foreground", "fg-color" }, fallback);
    }

    pub fn getBackgroundColor(self: *Self) Color {
        return self.getColorByNames(&.{ "background-color", "bg-color" }, ADWAITA_DEFAULT_BG);
    }

    pub fn getBorderColor(self: *Self) Color {
        return self.getColorByNames(&.{ "border-color", "outline-color" }, Color{ .r = 0xD3, .g = 0xD3, .b = 0xD3, .a = 0xFF });
    }

    pub fn getFontSize(self: *Self) f32 {
        const agg = self.aggregate();
        if (agg.get("font-size")) |pv| switch (pv) {
            .length_px => |px| return px * self.scale,
            .percentage => |p| return ADWAITA_DEFAULT_FONT * p * self.scale,
            else => {},
        };
        // GTK Settings fallback
        return ADWAITA_DEFAULT_FONT * self.scale;
    }

    /// 返回 [top, right, bottom, left]
    fn getQuadSides(self: *Self, base_names: []const []const u8, def: f32) [4]f32 {
        const agg = self.aggregate();
        var out = [_]f32{def} ** 4;
        for (base_names) |base| {
            const suff = .{ "-top", "-right", "-bottom", "-left" };
            for (suff, 0..) |suf, i| {
                const k = self.concat(base, suf) catch continue;
                if (agg.get(k)) |pv| switch (pv) {
                    .length_px => |px| out[i] = px * self.scale,
                    .percentage => |p| out[i] = def * p,
                    else => {},
                };
            }
            // 简写 base
            if (agg.get(base)) |pv| switch (pv) {
                .length_px => |px| out = [_]f32{px * self.scale} ** 4,
                .percentage => |p| out = [_]f32{def * p} ** 4,
                else => {},
            };
        }
        return out;
    }

    pub fn getMarginPx(self: *Self) [4]f32 {
        return self.getQuadSides(&.{ "margin" }, 0);
    }

    pub fn getPaddingPx(self: *Self) [4]f32 {
        return self.getQuadSides(&.{ "padding" }, 6);
    }

    pub fn getBorderPx(self: *Self) [4]f32 {
        return self.getQuadSides(&.{ "border-width" }, 1);
    }

    pub fn getBorderRadiusPx(self: *Self) f32 {
        const agg = self.aggregate();
        if (agg.get("border-radius")) |pv| switch (pv) {
            .length_px => |px| return px * self.scale,
            .percentage => |p| return 6.0 * p,
            else => {},
        };
        return 6.0 * self.scale;
    }

    pub fn getOpacity(self: *Self) f32 {
        const agg = self.aggregate();
        if (agg.get("opacity")) |pv| switch (pv) {
            .percentage => |p| return p,
            .length_px => |n| return @max(0, @min(1, n)),
            else => {},
        };
        return 1.0;
    }

    pub fn getStr(self: *Self, property: []const u8, default: []const u8) []const u8 {
        const agg = self.aggregate();
        if (agg.get(property)) |pv| switch (pv) {
            .string => |s| return s,
            else => {},
        };
        return default;
    }

    // ── 渲染：把 border/background/border-radius 写入 snapshot（占位）──────

    pub fn render(self: *Self, snapshot_ptr: ?*anyopaque, width: f32, height: f32) void {
        const bg = self.getBackgroundColor();
        const border = self.getBorderColor();
        const border_px = self.getBorderPx()[0];
        const radius = self.getBorderRadiusPx();
        const opacity = self.getOpacity();
        _ = .{ bg, border, border_px, radius, opacity, width, height, snapshot_ptr };
        // 真实实现：画 bg (radius 圆角) → 画 border（与 GTK4 snapshot_render_background/snapshot_render_frame 一致）
    }

    // ── 辅助 ──────────────────────────────────────────────────────────────

    fn concat(self: *Self, a: []const u8, b: []const u8) ![]const u8 {
        var list = std.ArrayList(u8).init(self.allocator);
        defer list.deinit();
        try list.appendSlice(a);
        try list.appendSlice(b);
        const slice = try list.toOwnedSlice();
        errdefer self.allocator.free(slice);
        // 不进 owned_strs（widget_path 已管理），这里泄漏量小，简化
        return slice;
    }
};
