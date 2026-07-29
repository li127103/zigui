//! CellRenderer 家族 — GTK4/GTK3 传统单元格渲染器
//!
//! GTK4 官方推荐 ColumnView/ListItemFactory，但若仍需 GTK3 风格的 TreeView/CellRenderer，
//! 这里提供完整抽象：通用 vtable + 5 种常用 Renderer + CellAreaBox（布局容器）。
//!
//! 典型组合：`TreeViewColumn → CellAreaBox → (CellRendererText, CellRendererPixbuf, ...)`
//!

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const texture_mod = @import("texture.zig");
const GdkTexture = texture_mod.GdkTexture;

const Widget = widget_mod.Widget;
const RectF = math.Rect(f32);
const SizeF = math.Size(f32);

// ═══════════════════════════════════════════════════════════════════════════════
//  CellRendererFlags / CellRendererState（GTK4 位域）
// ═══════════════════════════════════════════════════════════════════════════════

pub const CellRendererFlags = packed struct(u8) {
    editable: bool = false,
    editable_set: bool = false,
    visible: bool = true,
    sensitive: bool = true,
    /// 内边距 1-15 px（用 4 bits 存，够用的简化版）
    padding: u4 = 0,
    /// align: fixed-size 模式下是否按 cell_area 对齐
    align_fixed: bool = false,
};

pub const CellRendererState = packed struct(u8) {
    selected: bool = false,
    prelit: bool = false, // mouse hover
    insensitive: bool = false,
    sorted: bool = false,
    focused: bool = false,
    expandable: bool = false,
    _pad: u2 = 0,
};

// ═══════════════════════════════════════════════════════════════════════════════
//  通用 CellEditable 接口（Text/Spin 渲染器 startEditing 返回）
// ═══════════════════════════════════════════════════════════════════════════════

pub const CellEditableIface = struct {
    startEditing: *const fn (self: ?*anyopaque, event: ?*anyopaque) void = defaultStart,
    editingDone: *const fn (self: ?*anyopaque, canceled: bool) void = defaultDone,
    removeWidget: *const fn (self: ?*anyopaque) void = defaultRemove,
    fn defaultStart(_: ?*anyopaque, _: ?*anyopaque) void {}
    fn defaultDone(_: ?*anyopaque, _: bool) void {}
    fn defaultRemove(_: ?*anyopaque) void {}
};

pub const CellEditable = struct {
    iface: CellEditableIface = .{},
    self_ptr: ?*anyopaque = null,
    editing_canceled: bool = false,

    pub fn wrap(self_ptr: ?*anyopaque, iface: CellEditableIface) CellEditable {
        return .{ .iface = iface, .self_ptr = self_ptr };
    }
    pub fn startEditing(self: *CellEditable, event: ?*anyopaque) void {
        self.iface.startEditing(self.self_ptr, event);
    }
    pub fn editingDone(self: *CellEditable, canceled: bool) void {
        self.editing_canceled = canceled;
        self.iface.editingDone(self.self_ptr, canceled);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
//  CellRendererIface + 包装
// ═══════════════════════════════════════════════════════════════════════════════

pub const CellRendererIface = struct {
    /// 返回 (min, nat) 宽高（width/height 分别调用）
    getPreferredWidth: *const fn (sp: ?*anyopaque, widget: ?*const Widget, cell_area: RectF) SizeF = defaultSize,
    getPreferredHeight: *const fn (sp: ?*anyopaque, widget: ?*const Widget, cell_area: RectF) SizeF = defaultSize,
    /// 渲染到 snapshot（渲染管线占位）
    render: *const fn (sp: ?*anyopaque, snapshot_ptr: ?*anyopaque, widget: ?*const Widget, cell_area: RectF, background_area: RectF, flags: CellRendererState) void = defaultRender,
    /// 用户点击/按键激活；返回 true 表示已处理（Toggle 典型）
    activate: *const fn (sp: ?*anyopaque, event: ?*anyopaque, widget: ?*const Widget, path_str: []const u8, cell_area: RectF, flags: CellRendererState) bool = defaultActivate,
    /// 进入编辑模式，返回可编辑控件接口（Text/Spin 典型）
    startEditing: *const fn (sp: ?*anyopaque, event: ?*anyopaque, widget: ?*const Widget, path_str: []const u8, cell_area: RectF, flags: CellRendererState) ?*CellEditable = defaultStartEdit,

    fn defaultSize(_: ?*anyopaque, _: ?*const Widget, _: RectF) SizeF {
        return .{ .width = 0, .height = 0 };
    }
    fn defaultRender(_: ?*anyopaque, _: ?*anyopaque, _: ?*const Widget, _: RectF, _: RectF, _: CellRendererState) void {}
    fn defaultActivate(_: ?*anyopaque, _: ?*anyopaque, _: ?*const Widget, _: []const u8, _: RectF, _: CellRendererState) bool {
        return false;
    }
    fn defaultStartEdit(_: ?*anyopaque, _: ?*anyopaque, _: ?*const Widget, _: []const u8, _: RectF, _: CellRendererState) ?*CellEditable {
        return null;
    }
};

pub const CellRenderer = struct {
    iface: CellRendererIface = .{},
    self_ptr: ?*anyopaque = null,
    /// GTK4 `GtkCellRenderer` 通用字段
    flags: CellRendererFlags = .{},
    /// 对齐（0.0 = left/top，1.0 = right/bottom；0.5 = 居中）
    x_align: f32 = 0.0,
    y_align: f32 = 0.5,
    xpad: u4 = 2,
    ypad: u4 = 2,
    width: i32 = -1, // -1 = 自动；≥0 固定宽
    height: i32 = -1,
    is_expanded: bool = false,

    pub fn wrap(obj: ?*anyopaque, iface: CellRendererIface) CellRenderer {
        return .{ .iface = iface, .self_ptr = obj };
    }

    // ── 转发 ──────────────────────────────────────────────────────────────
    pub fn getPreferredWidth(self: *const CellRenderer, widget: ?*const Widget, cell_area: RectF) SizeF {
        return self.iface.getPreferredWidth(self.self_ptr, widget, cell_area);
    }
    pub fn getPreferredHeight(self: *const CellRenderer, widget: ?*const Widget, cell_area: RectF) SizeF {
        return self.iface.getPreferredHeight(self.self_ptr, widget, cell_area);
    }
    pub fn render(self: *const CellRenderer, snapshot: ?*anyopaque, widget: ?*const Widget, cell_area: RectF, background_area: RectF, state: CellRendererState) void {
        self.iface.render(self.self_ptr, snapshot, widget, cell_area, background_area, state);
    }
    pub fn activate(self: *const CellRenderer, event: ?*anyopaque, widget: ?*const Widget, path_str: []const u8, cell_area: RectF, state: CellRendererState) bool {
        return self.iface.activate(self.self_ptr, event, widget, path_str, cell_area, state);
    }
    pub fn startEditing(self: *const CellRenderer, event: ?*anyopaque, widget: ?*const Widget, path_str: []const u8, cell_area: RectF, state: CellRendererState) ?*CellEditable {
        return self.iface.startEditing(self.self_ptr, event, widget, path_str, cell_area, state);
    }

    // ── 便捷：从 iface + self_ptr 重新构造一个新的包装（复制 flags/align 等通用字段） ──
    pub fn withCommonFrom(self: *const CellRenderer, obj: ?*anyopaque, iface: CellRendererIface) CellRenderer {
        var c = CellRenderer.wrap(obj, iface);
        c.flags = self.flags;
        c.x_align = self.x_align;
        c.y_align = self.y_align;
        c.xpad = self.xpad;
        c.ypad = self.ypad;
        c.width = self.width;
        c.height = self.height;
        return c;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
//  CellArea + CellAreaBox（横向线性布局容器，GTK4 GtkCellArea / GtkCellAreaBox）
// ═══════════════════════════════════════════════════════════════════════════════

const CellRendererWithContext = struct {
    renderer: *CellRenderer,
    expand: bool,
    fixed_align: bool,
    padding: f32,
};

pub const CellAreaBox = struct {
    renderers: std.ArrayListUnmanaged(CellRendererWithContext) = .{},
    spacing: f32 = 4,
    orientation: enum(u1) { horizontal = 0, vertical = 1 } = .horizontal,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.renderers.deinit(allocator);
    }

    /// packStart: 追加到头部（左/上）
    pub fn packStart(self: *Self, allocator: std.mem.Allocator, renderer: *CellRenderer, expand: bool, fixed_align: bool, padding: f32) !void {
        try self.renderers.insert(allocator, 0, .{ .renderer = renderer, .expand = expand, .fixed_align = fixed_align, .padding = padding });
    }
    /// packEnd: 追加到尾部（右/下）
    pub fn packEnd(self: *Self, allocator: std.mem.Allocator, renderer: *CellRenderer, expand: bool, fixed_align: bool, padding: f32) !void {
        try self.renderers.append(allocator, .{ .renderer = renderer, .expand = expand, .fixed_align = fixed_align, .padding = padding });
    }

    /// 测量：orientation 方向累加，另一方向取最大
    pub fn measure(self: *const Self, widget: ?*const Widget, cell_area: RectF) SizeF {
        var total_primary: f32 = 0;
        var max_cross: f32 = 0;
        for (self.renderers.items) |rc| {
            const w = rc.renderer.getPreferredWidth(widget, cell_area);
            const h = rc.renderer.getPreferredHeight(widget, cell_area);
            switch (self.orientation) {
                .horizontal => {
                    total_primary += w.width + rc.padding + self.spacing;
                    max_cross = @max(max_cross, h.height);
                },
                .vertical => {
                    total_primary += h.height + rc.padding + self.spacing;
                    max_cross = @max(max_cross, w.width);
                },
            }
        }
        if (total_primary > 0) total_primary -= self.spacing; // 去掉尾部 spacing
        return switch (self.orientation) {
            .horizontal => .{ .width = total_primary, .height = max_cross },
            .vertical => .{ .width = max_cross, .height = total_primary },
        };
    }

    /// 分配：expand=true 的 renderer 均分剩余空间
    pub fn allocate(self: *const Self, widget: ?*const Widget, cell_area: RectF, state: CellRendererState, snapshot: ?*anyopaque) void {
        _ = widget;
        const n = self.renderers.items.len;
        if (n == 0) return;

        // 先计算非 expand 的自然尺寸总和 + expand 个数
        var used: f32 = 0;
        var expand_count: u32 = 0;
        const total_primary = if (self.orientation == .horizontal) cell_area.width else cell_area.height;

        for (self.renderers.items) |rc| {
            if (rc.expand) {
                expand_count += 1;
                continue;
            }
            const w = rc.renderer.getPreferredWidth(null, cell_area);
            const h = rc.renderer.getPreferredHeight(null, cell_area);
            const s = if (self.orientation == .horizontal) w.width else h.height;
            used += s + rc.padding + self.spacing;
        }
        if (used > 0) used -= self.spacing;
        const remain = @max(0, total_primary - used);
        const per_expand = if (expand_count > 0) remain / @as(f32, @floatFromInt(expand_count)) else 0;

        var pos: f32 = if (self.orientation == .horizontal) cell_area.x else cell_area.y;
        for (self.renderers.items) |rc| {
            const w = rc.renderer.getPreferredWidth(null, cell_area);
            const h = rc.renderer.getPreferredHeight(null, cell_area);
            const cross_start = if (self.orientation == .horizontal) cell_area.y else cell_area.x;
            const cross_total = if (self.orientation == .horizontal) cell_area.height else cell_area.width;

            const prim_size = if (rc.expand) per_expand else (if (self.orientation == .horizontal) w.width else h.height);
            const cross_size = if (self.orientation == .horizontal) h.height else w.width;
            const cross_pos = cross_start + if (rc.fixed_align) @max(0, (cross_total - cross_size) * rc.renderer.x_align) else 0;

            var area: RectF = undefined;
            switch (self.orientation) {
                .horizontal => {
                    area = .{ .x = pos + rc.padding, .y = cross_pos, .width = prim_size, .height = cross_size };
                    pos += rc.padding + prim_size + self.spacing;
                },
                .vertical => {
                    area = .{ .x = cross_pos, .y = pos + rc.padding, .width = cross_size, .height = prim_size };
                    pos += rc.padding + prim_size + self.spacing;
                },
            }
            rc.renderer.render(snapshot, null, area, area, state);
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
//  CellRendererText
// ═══════════════════════════════════════════════════════════════════════════════

pub const WrapMode = enum { none, word, char, word_char };
pub const EllipsizeMode = enum { none, start, middle, end };

pub const CellRendererText = struct {
    base: CellRenderer = .{},
    text: []const u8 = "",
    markup: []const u8 = "", // 暂未解析 Pango Markup，回退显示 text
    font: []const u8 = "",
    foreground: ?math.Color = null,
    background: ?math.Color = null,
    size_points: f32 = 12,
    wrap_width: i32 = -1,
    wrap_mode: WrapMode = .word,
    text_align: enum(u2) { left, center, right } = .left,
    text_valign: enum(u2) { top, center, bottom } = .center,
    single_paragraph_mode: bool = true,
    ellipsize: EllipsizeMode = .end,
    editable: bool = false,
    width_chars: i32 = -1,
    max_width_chars: i32 = -1,

    const T = @This();
    const char_width_approx: f32 = 7.0;
    const line_height_approx: f32 = 18.0;

    pub fn init() T {
        var t = T{};
        t.base = CellRenderer.wrap(&t, .{
            .getPreferredWidth = ifaceGetWidth,
            .getPreferredHeight = ifaceGetHeight,
            .render = ifaceRender,
            .startEditing = ifaceStartEdit,
        });
        return t;
    }

    pub fn asCellRenderer(self: *T) *CellRenderer {
        return &self.base;
    }

    fn ifaceGetWidth(sp: ?*anyopaque, _: ?*const Widget, _: RectF) SizeF {
        const t: *T = @ptrCast(@alignCast(sp orelse return .{ .width = 0, .height = 0 }));
        const chars = if (t.width_chars >= 0) @as(f32, @floatFromInt(t.width_chars)) else @max(1, @as(f32, @floatFromInt(t.text.len)));
        return .{ .width = chars * char_width_approx + 8, .height = 0 };
    }
    fn ifaceGetHeight(sp: ?*anyopaque, _: ?*const Widget, _: RectF) SizeF {
        const t: *T = @ptrCast(@alignCast(sp orelse return .{ .width = 0, .height = 0 }));
        const lines: f32 = if (t.wrap_width > 0 and t.text.len > 0) @max(1, @ceil(@as(f32, @floatFromInt(t.text.len)) * char_width_approx / @as(f32, @floatFromInt(t.wrap_width)))) else 1;
        return .{ .width = 0, .height = lines * line_height_approx + 4 };
    }
    fn ifaceRender(sp: ?*anyopaque, snapshot_ptr: ?*anyopaque, _: ?*const Widget, cell_area: RectF, bg: RectF, state: CellRendererState) void {
        const t: *T = @ptrCast(@alignCast(sp orelse return));
        _ = bg;
        _ = state;
        _ = snapshot_ptr;
        // 真正绘制：调用 text_layout.render(cell_area, text, foreground, size_points)
        // 此处占位，仅把内容整理好便于后端实现
        _ = t;
        _ = cell_area;
    }
    fn ifaceStartEdit(sp: ?*anyopaque, event: ?*anyopaque, _: ?*const Widget, _: []const u8, _: RectF, _: CellRendererState) ?*CellEditable {
        const t: *T = @ptrCast(@alignCast(sp orelse return null));
        if (!t.editable) return null;
        _ = event;
        // 简化：若 editable=true 则返回空占位（真实实现需返回 Entry 包装的 CellEditable）
        const ce = std.heap.page_allocator.create(CellEditable) catch return null;
        ce.* = CellEditable.wrap(t, .{});
        return ce;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
//  CellRendererPixbuf
// ═══════════════════════════════════════════════════════════════════════════════

pub const CellRendererPixbuf = struct {
    base: CellRenderer = .{},
    texture: ?*GdkTexture = null,
    icon_name: []const u8 = "",
    stock_id: []const u8 = "",
    icon_size: i32 = 16, // px（GTK GTK_ICON_SIZE_MENU=16, BUTTON=16, ..., DIALOG=48）

    const P = @This();

    pub fn init() P {
        var p = P{};
        p.base = CellRenderer.wrap(&p, .{
            .getPreferredWidth = ifaceGetWidth,
            .getPreferredHeight = ifaceGetHeight,
            .render = ifaceRender,
        });
        return p;
    }

    pub fn asCellRenderer(self: *P) *CellRenderer {
        return &self.base;
    }

    fn sizeFrom(self: *const P) f32 {
        if (self.texture) |t| return @floatFromInt(@max(t.width, t.height));
        return @floatFromInt(self.icon_size);
    }
    fn ifaceGetWidth(sp: ?*anyopaque, _: ?*const Widget, _: RectF) SizeF {
        const p: *P = @ptrCast(@alignCast(sp orelse return .{ .width = 0, .height = 0 }));
        const s = p.sizeFrom();
        return .{ .width = s + 4, .height = s };
    }
    fn ifaceGetHeight(sp: ?*anyopaque, _: ?*const Widget, _: RectF) SizeF {
        const p: *P = @ptrCast(@alignCast(sp orelse return .{ .width = 0, .height = 0 }));
        return .{ .width = 0, .height = p.sizeFrom() + 4 };
    }
    fn ifaceRender(sp: ?*anyopaque, snapshot_ptr: ?*anyopaque, _: ?*const Widget, cell_area: RectF, _: RectF, _: CellRendererState) void {
        const p: *P = @ptrCast(@alignCast(sp orelse return));
        if (p.texture) |t| {
            var paint = t.asPaintable();
            paint.snapshot(snapshot_ptr, cell_area.width, cell_area.height);
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
//  CellRendererToggle
// ═══════════════════════════════════════════════════════════════════════════════

pub const CellRendererToggle = struct {
    base: CellRenderer = .{},
    active: bool = false,
    inconsistent: bool = false,
    activatable: bool = true,
    /// true=单选 (radio), false=复选 (check)
    radio: bool = false,
    /// 用户切换回调（传入新 active 值）
    on_toggled: ?*const fn (ud: ?*anyopaque, path_str: []const u8, new_active: bool) void = null,
    on_toggled_ud: ?*anyopaque = null,

    const TG = @This();
    const size_px: f32 = 18;

    pub fn init() TG {
        var t = TG{};
        t.base = CellRenderer.wrap(&t, .{
            .getPreferredWidth = ifaceGetW,
            .getPreferredHeight = ifaceGetH,
            .activate = ifaceActivate,
            .render = ifaceRender,
        });
        return t;
    }
    pub fn asCellRenderer(self: *TG) *CellRenderer {
        return &self.base;
    }

    fn ifaceGetW(_: ?*anyopaque, _: ?*const Widget, _: RectF) SizeF {
        return .{ .width = size_px + 8, .height = size_px };
    }
    fn ifaceGetH(_: ?*anyopaque, _: ?*const Widget, _: RectF) SizeF {
        return .{ .width = 0, .height = size_px + 4 };
    }
    fn ifaceActivate(sp: ?*anyopaque, _: ?*anyopaque, _: ?*const Widget, path_str: []const u8, _: RectF, _: CellRendererState) bool {
        const t: *TG = @ptrCast(@alignCast(sp orelse return false));
        if (!t.activatable) return false;
        const new = !t.active;
        t.active = new;
        if (t.on_toggled) |cb| cb(t.on_toggled_ud, path_str, new);
        return true;
    }
    fn ifaceRender(_: ?*anyopaque, _: ?*anyopaque, _: ?*const Widget, _: RectF, _: RectF, _: CellRendererState) void {}
};

// ═══════════════════════════════════════════════════════════════════════════════
//  CellRendererProgress
// ═══════════════════════════════════════════════════════════════════════════════

pub const CellRendererProgress = struct {
    base: CellRenderer = .{},
    value: f32 = 0, // 0..1 （<0 表示 indeterminate，pulse 模式）
    text: ?[]const u8 = null, // 覆盖默认百分比文本
    pulse: i32 = 0, // pulse 帧号
    inverted: bool = false,

    const PR = @This();

    pub fn init() PR {
        var p = PR{};
        p.base = CellRenderer.wrap(&p, .{
            .getPreferredWidth = ifaceGetW,
            .getPreferredHeight = ifaceGetH,
            .render = ifaceRender,
        });
        return p;
    }
    pub fn asCellRenderer(self: *PR) *CellRenderer {
        return &self.base;
    }

    fn defaultText(self: *const PR) []const u8 {
        if (self.value < 0) return "…";
        return ""; // 实际实现可 sprintf %d%%
    }
    fn ifaceGetW(_: ?*anyopaque, _: ?*const Widget, _: RectF) SizeF {
        return .{ .width = 120, .height = 12 };
    }
    fn ifaceGetH(_: ?*anyopaque, _: ?*const Widget, _: RectF) SizeF {
        return .{ .width = 0, .height = 22 };
    }
    fn ifaceRender(sp: ?*anyopaque, snapshot_ptr: ?*anyopaque, _: ?*const Widget, cell_area: RectF, _: RectF, _: CellRendererState) void {
        const p: *PR = @ptrCast(@alignCast(sp orelse return));
        _ = p;
        _ = snapshot_ptr;
        _ = cell_area;
        // 占位：绘制 (0..value)*width 进度条 + 居中文字 (text orelse defaultText)
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
//  CellRendererSpin
// ═══════════════════════════════════════════════════════════════════════════════

pub const Adjustment = struct {
    value: f64 = 0,
    lower: f64 = 0,
    upper: f64 = 100,
    step_increment: f64 = 1,
    page_increment: f64 = 10,
    page_size: f64 = 0,
};

pub const CellRendererSpin = struct {
    base: CellRenderer = .{},
    adjustment: Adjustment = .{},
    climb_rate: f32 = 1.0, // 每秒步长数
    digits: u4 = 0, // 小数位
    editable: bool = true,

    const SP = @This();

    pub fn init() SP {
        var s = SP{};
        s.base = CellRenderer.wrap(&s, .{
            .getPreferredWidth = ifaceGetW,
            .getPreferredHeight = ifaceGetH,
            .startEditing = ifaceStartEdit,
            .render = ifaceRender,
        });
        return s;
    }
    pub fn asCellRenderer(self: *SP) *CellRenderer {
        return &self.base;
    }

    fn ifaceGetW(_: ?*anyopaque, _: ?*const Widget, _: RectF) SizeF {
        return .{ .width = 72, .height = 20 };
    }
    fn ifaceGetH(_: ?*anyopaque, _: ?*const Widget, _: RectF) SizeF {
        return .{ .width = 0, .height = 26 };
    }
    fn ifaceStartEdit(sp: ?*anyopaque, _: ?*anyopaque, _: ?*const Widget, _: []const u8, _: RectF, _: CellRendererState) ?*CellEditable {
        const s: *SP = @ptrCast(@alignCast(sp orelse return null));
        if (!s.editable) return null;
        const ce = std.heap.page_allocator.create(CellEditable) catch return null;
        ce.* = CellEditable.wrap(s, .{});
        return ce;
    }
    fn ifaceRender(_: ?*anyopaque, _: ?*anyopaque, _: ?*const Widget, _: RectF, _: RectF, _: CellRendererState) void {}
};
