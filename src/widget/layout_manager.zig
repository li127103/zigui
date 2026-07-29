//! GTK4 LayoutManager 家族
//!
//! GTK 对应: GtkLayoutManager + BoxLayout / CenterLayout / GridLayout /
//!           OverlayLayout / BinLayout / FixedLayout / CustomLayout
//!
//! 所有具体布局都暴露 4 个标准函数，使 LayoutManager 类型擦除包装可以直接转发：
//!   1. get_request_mode(widget)    → SizeRequestMode
//!   2. measure(widget, orientation, for_size) → (min, nat, baseline_min?, baseline_nat?)
//!   3. allocate(widget, width, height, baseline) → 按容器逐个分配子控件
//!   4. layout_child(widget)       → 返回当前布局下 widget 的布局子项（可选）
//!
//! 对齐 GTK：LayoutManager 持有布局相关的"子项附加数据"（LayoutChild），
//! 父 Widget 只是布局被测量/分配的主体。

const std = @import("std");
const math = @import("../math.zig");

const Widget = @import("widget.zig").Widget;

// ──────────────────────────────────────────────────────────────────────────────
// 基础枚举
// ──────────────────────────────────────────────────────────────────────────────

pub const Orientation = enum(u8) {
    horizontal = 0,
    vertical = 1,
};

pub const SizeRequestMode = enum(u8) {
    height_for_width = 0, // 高度依赖宽度（文本/标签等）
    width_for_height = 1, // 宽度依赖高度
    constant_size = 2, // 独立（图片/图标等）
};

pub const Alignment = enum(u8) {
    fill = 0, // 拉伸填满（默认）
    start = 1, // 起点
    center = 2, // 中心
    end = 3, // 终点
    baseline = 4, // 基线对齐（仅水平布局有意义）
};

// ──────────────────────────────────────────────────────────────────────────────
// LayoutChild — 每个子控件在具体布局下的附加属性
// ──────────────────────────────────────────────────────────────────────────────

/// LayoutChild：记录"子控件在某个布局管理器中的附加属性"
/// 与 GTK4 LayoutChild 对应。字段按位复用：具体布局使用特定字段集合。
pub const LayoutChild = struct {
    /// 对应哪个 Widget
    widget: ?*Widget = null,
    /// BinLayout: 对齐方式
    xalign: Alignment = .fill,
    yalign: Alignment = .fill,

    /// BoxLayout:
    expand: bool = false,
    fill: bool = true,
    padding: f32 = 0,
    position: i32 = -1, // -1 表示尾部追加
    box_order: i32 = -1, // 用于 BoxLayout 排序

    /// GridLayout: 单元格位置
    grid_row: i32 = 0,
    grid_col: i32 = 0,
    grid_row_span: i32 = 1,
    grid_col_span: i32 = 1,

    /// OverlayLayout:
    overlay_measured: bool = true,
    overlay_clip: bool = false,

    /// FixedLayout: 绝对坐标
    fixed_x: f32 = 0,
    fixed_y: f32 = 0,

    /// CenterLayout: 位置位 0=start,1=center,2=end
    center_slot: u2 = 1,

    /// 自定义布局用户数据
    user_data: ?*anyopaque = null,
};

// ──────────────────────────────────────────────────────────────────────────────
// LayoutManagerIface + LayoutManager 类型擦除包装
// ──────────────────────────────────────────────────────────────────────────────

/// LayoutManagerIface：7 个具体布局各自实现
pub const LayoutManagerIface = struct {
    get_request_mode: *const fn (self: ?*anyopaque, widget: *Widget) SizeRequestMode = defaultMode,
    measure: *const fn (
        self: ?*anyopaque,
        widget: *Widget,
        orientation: Orientation,
        for_size: f32,
    ) MeasureResult = defaultMeasure,
    allocate: *const fn (
        self: ?*anyopaque,
        widget: *Widget,
        width: f32,
        height: f32,
        baseline: i32,
    ) void = defaultAllocate,
    layout_child: ?*const fn (self: ?*anyopaque, widget: *Widget, child: *Widget) LayoutChild = null,

    fn defaultMode(_: ?*anyopaque, _: *Widget) SizeRequestMode {
        return .constant_size;
    }
    fn defaultMeasure(_: ?*anyopaque, _: *Widget, _: Orientation, _: f32) MeasureResult {
        return .{};
    }
    fn defaultAllocate(_: ?*anyopaque, _: *Widget, _: f32, _: f32, _: i32) void {}
};

/// 测量返回值：最小宽度/高度、自然宽度/高度，以及可选的基线 min/nat
pub const MeasureResult = struct {
    min: f32 = 0,
    nat: f32 = 0,
    min_baseline: ?i32 = null,
    nat_baseline: ?i32 = null,
};

pub const LayoutManager = struct {
    iface: LayoutManagerIface,
    self_ptr: ?*anyopaque = null,

    pub fn getRequestMode(self: *const LayoutManager, widget: *Widget) SizeRequestMode {
        return self.iface.get_request_mode(self.self_ptr, widget);
    }
    pub fn measure(self: *const LayoutManager, widget: *Widget, o: Orientation, for_size: f32) MeasureResult {
        return self.iface.measure(self.self_ptr, widget, o, for_size);
    }
    pub fn allocate(self: *const LayoutManager, widget: *Widget, width: f32, height: f32, baseline: i32) void {
        self.iface.allocate(self.self_ptr, widget, width, height, baseline);
    }
    pub fn layoutChild(self: *const LayoutManager, widget: *Widget, child: *Widget) LayoutChild {
        if (self.iface.layout_child) |f| return f(self.self_ptr, widget, child);
        return .{ .widget = child };
    }

    pub fn wrap(obj_ptr: ?*anyopaque, iface: LayoutManagerIface) LayoutManager {
        return .{ .iface = iface, .self_ptr = obj_ptr };
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 辅助：对 Widget.children 按 LayoutChild 做遍历（所有具体布局共用）
// ──────────────────────────────────────────────────────────────────────────────

fn childCount(widget: *Widget) usize {
    const list = widget.children;
    return list.len;
}

/// 根据索引获取子 Widget（简化实现：直接访问 children）
fn childAt(widget: *Widget, idx: usize) ?*Widget {
    const list = widget.children;
    if (idx >= list.len) return null;
    return list.items[idx];
}

// ──────────────────────────────────────────────────────────────────────────────
// 1. BinLayout — 单子控件布局
// ──────────────────────────────────────────────────────────────────────────────

pub const BinLayout = struct {
    xalign: Alignment = .fill,
    yalign: Alignment = .fill,

    pub fn create(xa: Alignment, ya: Alignment) BinLayout {
        return .{ .xalign = xa, .yalign = ya };
    }

    pub fn getRequestModeFn(_: ?*anyopaque, widget: *Widget) SizeRequestMode {
        const child = childAt(widget, 0) orelse return .constant_size;
        // 简单取第一个子控件的 request_mode（没有就用 constant）
        _ = child;
        return .constant_size;
    }

    pub fn measureFn(
        self_: ?*anyopaque,
        widget: *Widget,
        orientation: Orientation,
        for_size: f32,
    ) MeasureResult {
        const s: *BinLayout = @ptrCast(@alignCast(self_ orelse return .{}));
        _ = s;
        const child = childAt(widget, 0) orelse return .{};
        const cs = child.measure(orientation, for_size);
        return .{ .min = cs.min, .nat = cs.nat };
    }

    pub fn allocateFn(
        self_: ?*anyopaque,
        widget: *Widget,
        width: f32,
        height: f32,
        baseline: i32,
    ) void {
        const s: *BinLayout = @ptrCast(@alignCast(self_ orelse return));
        const child = childAt(widget, 0) orelse return;
        const cs_min = child.measure(.horizontal, -1);
        const cs_v = child.measure(.vertical, width);
        _ = baseline;

        const child_w: f32 = switch (s.xalign) {
            .fill => width,
            else => @min(cs_min.nat, width),
        };
        const child_h: f32 = switch (s.yalign) {
            .fill => height,
            else => @min(cs_v.nat, height),
        };
        const x: f32 = switch (s.xalign) {
            .fill, .start => 0,
            .center => @max(0, (width - child_w) / 2),
            .end => @max(0, width - child_w),
            .baseline => 0,
        };
        const y: f32 = switch (s.yalign) {
            .fill, .start => 0,
            .center => @max(0, (height - child_h) / 2),
            .end => @max(0, height - child_h),
            .baseline => 0,
        };
        child.allocate(x, y, child_w, child_h);
    }

    pub fn asIface() LayoutManagerIface {
        return .{
            .get_request_mode = getRequestModeFn,
            .measure = measureFn,
            .allocate = allocateFn,
        };
    }

    pub fn asLayoutManager(self: *BinLayout) LayoutManager {
        return LayoutManager.wrap(self, asIface());
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 2. BoxLayout — 盒子布局（horizontal/vertical + spacing + homogeneous + expand）
// ──────────────────────────────────────────────────────────────────────────────

pub const BoxLayout = struct {
    orientation: Orientation = .horizontal,
    spacing: f32 = 0,
    homogeneous: bool = false,

    pub fn create(o: Orientation, spacing: f32) BoxLayout {
        return .{ .orientation = o, .spacing = spacing };
    }

    pub fn getRequestModeFn(self_: ?*anyopaque, _: *Widget) SizeRequestMode {
        const s: *BoxLayout = @ptrCast(@alignCast(self_ orelse return .constant_size));
        return switch (s.orientation) {
            .horizontal => .height_for_width,
            .vertical => .width_for_height,
        };
    }

    pub fn measureFn(
        self_: ?*anyopaque,
        widget: *Widget,
        orientation: Orientation,
        for_size: f32,
    ) MeasureResult {
        const s: *BoxLayout = @ptrCast(@alignCast(self_ orelse return .{}));
        const count = childCount(widget);
        if (count == 0) return .{};

        const main_axis = s.orientation;
        const cross_axis: Orientation = if (main_axis == .horizontal) .vertical else .horizontal;

        if (orientation == main_axis) {
            // 主轴：累加子控件自然尺寸 + spacing
            var sum_min: f32 = 0;
            var sum_nat: f32 = 0;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const c = childAt(widget, i).?;
                const m = c.measure(orientation, for_size);
                if (s.homogeneous) {
                    sum_min = @max(sum_min, m.min);
                    sum_nat = @max(sum_nat, m.nat);
                } else {
                    sum_min += m.min;
                    sum_nat += m.nat;
                }
            }
            const n: f32 = @floatFromInt(count);
            const total_spacing: f32 = @max(0, n - 1) * s.spacing;
            if (s.homogeneous) {
                return .{ .min = sum_min * n + total_spacing, .nat = sum_nat * n + total_spacing };
            }
            return .{ .min = sum_min + total_spacing, .nat = sum_nat + total_spacing };
        } else {
            // 交叉轴：取最大子控件尺寸（与主轴无关，简化）
            var max_min: f32 = 0;
            var max_nat: f32 = 0;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const c = childAt(widget, i).?;
                const m = c.measure(cross_axis, for_size);
                max_min = @max(max_min, m.min);
                max_nat = @max(max_nat, m.nat);
            }
            return .{ .min = max_min, .nat = max_nat };
        }
    }

    pub fn allocateFn(
        self_: ?*anyopaque,
        widget: *Widget,
        width: f32,
        height: f32,
        baseline: i32,
    ) void {
        const s: *BoxLayout = @ptrCast(@alignCast(self_ orelse return));
        const count = childCount(widget);
        if (count == 0) return;
        _ = baseline;

        const main_axis = s.orientation;
        const n: f32 = @floatFromInt(count);
        const total_space: f32 = if (main_axis == .horizontal) width else height;
        const spacing_total: f32 = @max(0, n - 1) * s.spacing;
        const avail: f32 = @max(0, total_space - spacing_total);

        var i: usize = 0;
        var offset: f32 = 0;
        while (i < count) : (i += 1) {
            const c = childAt(widget, i).?;
            const main_size: f32 = if (s.homogeneous)
                avail / n
            else blk: {
                const m = c.measure(main_axis, -1);
                break :blk @min(m.nat, avail / n); // 简化：均分，expand 控件填剩余
            };

            const cross_avail: f32 = if (main_axis == .horizontal) height else width;
            const cross = c.measure(
                if (main_axis == .horizontal) .vertical else .horizontal,
                main_size,
            );
            const cross_size: f32 = @min(cross.nat, cross_avail);

            const x: f32 = if (main_axis == .horizontal) offset else 0;
            const y: f32 = if (main_axis == .vertical) offset else 0;
            const w: f32 = if (main_axis == .horizontal) main_size else cross_size;
            const h: f32 = if (main_axis == .vertical) main_size else cross_size;

            c.allocate(x, y, w, h);
            offset += main_size + s.spacing;
        }
    }

    pub fn asIface() LayoutManagerIface {
        return .{
            .get_request_mode = getRequestModeFn,
            .measure = measureFn,
            .allocate = allocateFn,
        };
    }

    pub fn asLayoutManager(self: *BoxLayout) LayoutManager {
        return LayoutManager.wrap(self, asIface());
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 3. CenterLayout — 三段式中心布局（start / center / end）
// ──────────────────────────────────────────────────────────────────────────────

pub const CenterLayout = struct {
    shrink_center_last: bool = false,

    pub fn create() CenterLayout {
        return .{};
    }

    fn getSlot(self_: ?*anyopaque, widget: *Widget, idx: usize) u2 {
        // 简化：前 1/3 为 start(0)，中间为 center(1)，后 1/3 为 end(2)
        _ = self_;
        const n = childCount(widget);
        if (n == 0) return 1;
        if (idx * 3 < n) return 0;
        if (idx * 3 < 2 * n) return 1;
        return 2;
    }

    pub fn measureFn(
        self_: ?*anyopaque,
        widget: *Widget,
        orientation: Orientation,
        for_size: f32,
    ) MeasureResult {
        _ = self_;
        const count = childCount(widget);
        // 横向：start + center + end（主方向累加）；纵向：取最大
        var main_min: f32 = 0;
        var main_nat: f32 = 0;
        var cross_min: f32 = 0;
        var cross_nat: f32 = 0;

        const main_axis: Orientation = orientation;
        const cross_axis: Orientation = if (orientation == .horizontal) .vertical else .horizontal;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const c = childAt(widget, i).?;
            const m_main = c.measure(main_axis, for_size);
            const m_cross = c.measure(cross_axis, for_size);
            // 简化：三个槽在主方向堆叠
            main_min += m_main.min;
            main_nat += m_main.nat;
            cross_min = @max(cross_min, m_cross.min);
            cross_nat = @max(cross_nat, m_cross.nat);
        }
        // 主轴：累加主方向值；交叉轴：取最大交叉值
        if (orientation == main_axis) {
            return .{ .min = main_min, .nat = main_nat };
        } else {
            return .{ .min = cross_min, .nat = cross_nat };
        }
    }

    pub fn allocateFn(
        self_: ?*anyopaque,
        widget: *Widget,
        width: f32,
        height: f32,
        baseline: i32,
    ) void {
        const s: *CenterLayout = @ptrCast(@alignCast(self_ orelse return));
        const count = childCount(widget);
        _ = s.shrink_center_last;
        _ = baseline;
        // 按 slot=0/1/2 各占 1/3
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const c = childAt(widget, i).?;
            const slot = getSlot(self_, widget, i);
            const w_slot = width / 3;
            const x: f32 = @as(f32, @floatFromInt(slot)) * w_slot;
            // 子控件水平居中于 slot，垂直填 height
            const m = c.measure(.horizontal, height);
            const child_w = @min(m.nat, w_slot);
            const off_x = (w_slot - child_w) / 2;
            c.allocate(x + off_x, 0, child_w, height);
        }
    }

    pub fn asIface() LayoutManagerIface {
        return .{
            .measure = measureFn,
            .allocate = allocateFn,
        };
    }

    pub fn asLayoutManager(self: *CenterLayout) LayoutManager {
        return LayoutManager.wrap(self, asIface());
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 4. GridLayout — 网格布局（row/col/row_span/col_span + homogeneous + 行列间距）
// ──────────────────────────────────────────────────────────────────────────────

pub const GridLayout = struct {
    row_spacing: f32 = 0,
    col_spacing: f32 = 0,
    row_homogeneous: bool = false,
    col_homogeneous: bool = false,

    pub fn create(row_spacing: f32, col_spacing: f32) GridLayout {
        return .{ .row_spacing = row_spacing, .col_spacing = col_spacing };
    }

    pub fn measureFn(
        self_: ?*anyopaque,
        widget: *Widget,
        orientation: Orientation,
        for_size: f32,
    ) MeasureResult {
        const s: *GridLayout = @ptrCast(@alignCast(self_ orelse return .{}));
        const count = childCount(widget);
        if (count == 0) return .{};
        _ = for_size;

        // 简化：统计最大列/行数（假定 row/col 不超过 N-1）
        var max_row: i32 = 0;
        var max_col: i32 = 0;
        const cols: i32 = if (count <= 1) 1 else if (count <= 4) 2 else 3;
        var r: usize = 0;
        while (r < count) : (r += 1) {
            const idx: i32 = @intCast(r);
            var lc: LayoutChild = .{ .grid_row_span = 1, .grid_col_span = 1 };
            lc.grid_row = @divFloor(idx, cols);
            lc.grid_col = @rem(idx, cols);
            max_row = @max(max_row, lc.grid_row + lc.grid_row_span - 1);
            max_col = @max(max_col, lc.grid_col + lc.grid_col_span - 1);
        }
        const n_rows: f32 = @floatFromInt(max_row + 1);
        const n_cols: f32 = @floatFromInt(max_col + 1);

        const cell_w: f32 = 80;
        const cell_h: f32 = 24;
        if (orientation == .horizontal) {
            const total = n_cols * cell_w + @max(0, n_cols - 1) * s.col_spacing;
            return .{ .min = total, .nat = total };
        } else {
            const total = n_rows * cell_h + @max(0, n_rows - 1) * s.row_spacing;
            return .{ .min = total, .nat = total };
        }
    }

    pub fn allocateFn(
        self_: ?*anyopaque,
        widget: *Widget,
        width: f32,
        height: f32,
        baseline: i32,
    ) void {
        const s: *GridLayout = @ptrCast(@alignCast(self_ orelse return));
        const count = childCount(widget);
        if (count == 0) return;
        _ = baseline;

        const cols: i32 = if (count <= 1) 1 else if (count <= 4) 2 else 3;
        const rows: i32 = @divTrunc(@as(i32, @intCast(count)) + cols - 1, cols);

        const col_sp = if (cols > 1) s.col_spacing else 0;
        const row_sp = if (rows > 1) s.row_spacing else 0;
        const cell_w: f32 = (width - (@as(f32, @floatFromInt(cols - 1)) * col_sp)) / @as(f32, @floatFromInt(cols));
        const cell_h: f32 = (height - (@as(f32, @floatFromInt(rows - 1)) * row_sp)) / @as(f32, @floatFromInt(rows));

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const c = childAt(widget, i).?;
            const idx: i32 = @intCast(i);
            const r: i32 = @divFloor(idx, cols);
            const col: i32 = @rem(idx, cols);
            const x: f32 = @as(f32, @floatFromInt(col)) * (cell_w + col_sp);
            const y: f32 = @as(f32, @floatFromInt(r)) * (cell_h + row_sp);
            c.allocate(x, y, cell_w, cell_h);
        }
    }

    pub fn asIface() LayoutManagerIface {
        return .{
            .measure = measureFn,
            .allocate = allocateFn,
        };
    }

    pub fn asLayoutManager(self: *GridLayout) LayoutManager {
        return LayoutManager.wrap(self, asIface());
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 5. OverlayLayout — 叠加布局（第一个 child 为 base，其余叠加）
// ──────────────────────────────────────────────────────────────────────────────

pub const OverlayLayout = struct {
    pub fn create() OverlayLayout {
        return .{};
    }

    pub fn measureFn(
        self_: ?*anyopaque,
        widget: *Widget,
        orientation: Orientation,
        for_size: f32,
    ) MeasureResult {
        _ = self_;
        // 取 base 子控件（index 0）的测量，叠加层不影响总尺寸
        const base = childAt(widget, 0) orelse return .{};
        const m = base.measure(orientation, for_size);
        return .{ .min = m.min, .nat = m.nat };
    }

    pub fn allocateFn(
        self_: ?*anyopaque,
        widget: *Widget,
        width: f32,
        height: f32,
        baseline: i32,
    ) void {
        _ = self_;
        _ = baseline;
        const count = childCount(widget);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const c = childAt(widget, i).?;
            // base 填 full，overlay 填满尺寸（简化：全填）
            c.allocate(0, 0, width, height);
        }
    }

    pub fn asIface() LayoutManagerIface {
        return .{
            .measure = measureFn,
            .allocate = allocateFn,
        };
    }

    pub fn asLayoutManager(self: *OverlayLayout) LayoutManager {
        return LayoutManager.wrap(self, asIface());
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 6. FixedLayout — 固定位置布局（LayoutChild.fixed_x/fixed_y）
// ──────────────────────────────────────────────────────────────────────────────

pub const FixedLayout = struct {
    pub fn create() FixedLayout {
        return .{};
    }

    pub fn measureFn(
        self_: ?*anyopaque,
        widget: *Widget,
        orientation: Orientation,
        for_size: f32,
    ) MeasureResult {
        _ = self_;
        _ = for_size;
        const count = childCount(widget);
        var max_x: f32 = 0;
        var max_y: f32 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const c = childAt(widget, i).?;
            // 简化：使用 Widget 现有 allocation
            const x = c.x + c.width;
            const y = c.y + c.height;
            max_x = @max(max_x, x);
            max_y = @max(max_y, y);
        }
        return .{
            .min = if (orientation == .horizontal) max_x else max_y,
            .nat = if (orientation == .horizontal) max_x else max_y,
        };
    }

    pub fn allocateFn(
        self_: ?*anyopaque,
        widget: *Widget,
        _: f32,
        _: f32,
        baseline: i32,
    ) void {
        _ = self_;
        _ = baseline;
        const count = childCount(widget);
        // FixedLayout: 子控件保持自己的 fixed_x/fixed_y 坐标（已在 widget.x/y 体现）
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const c = childAt(widget, i).?;
            c.allocate(c.x, c.y, c.width, c.height);
        }
    }

    pub fn asIface() LayoutManagerIface {
        return .{
            .measure = measureFn,
            .allocate = allocateFn,
        };
    }

    pub fn asLayoutManager(self: *FixedLayout) LayoutManager {
        return LayoutManager.wrap(self, asIface());
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 7. CustomLayout — 自定义布局（函数指针 3 个）
// ──────────────────────────────────────────────────────────────────────────────

pub const CustomRequestModeFn = *const fn (ud: ?*anyopaque, widget: *Widget) SizeRequestMode;
pub const CustomMeasureFn = *const fn (ud: ?*anyopaque, widget: *Widget, orientation: Orientation, for_size: f32) MeasureResult;
pub const CustomAllocateFn = *const fn (ud: ?*anyopaque, widget: *Widget, width: f32, height: f32, baseline: i32) void;

pub const CustomLayout = struct {
    user_data: ?*anyopaque = null,
    request_mode_fn: ?CustomRequestModeFn = null,
    measure_fn: CustomMeasureFn,
    allocate_fn: CustomAllocateFn,

    pub fn create(
        ud: ?*anyopaque,
        mfn: CustomMeasureFn,
        afn: CustomAllocateFn,
        rfn: ?CustomRequestModeFn,
    ) CustomLayout {
        return .{
            .user_data = ud,
            .request_mode_fn = rfn,
            .measure_fn = mfn,
            .allocate_fn = afn,
        };
    }

    pub fn getRequestModeFn(self_: ?*anyopaque, widget: *Widget) SizeRequestMode {
        const s: *CustomLayout = @ptrCast(@alignCast(self_ orelse return .constant_size));
        if (s.request_mode_fn) |f| return f(s.user_data, widget);
        return .constant_size;
    }

    pub fn measureFn(
        self_: ?*anyopaque,
        widget: *Widget,
        orientation: Orientation,
        for_size: f32,
    ) MeasureResult {
        const s: *CustomLayout = @ptrCast(@alignCast(self_ orelse return .{}));
        return s.measure_fn(s.user_data, widget, orientation, for_size);
    }

    pub fn allocateFn(
        self_: ?*anyopaque,
        widget: *Widget,
        width: f32,
        height: f32,
        baseline: i32,
    ) void {
        const s: *CustomLayout = @ptrCast(@alignCast(self_ orelse return));
        s.allocate_fn(s.user_data, widget, width, height, baseline);
    }

    pub fn asIface() LayoutManagerIface {
        return .{
            .get_request_mode = getRequestModeFn,
            .measure = measureFn,
            .allocate = allocateFn,
        };
    }

    pub fn asLayoutManager(self: *CustomLayout) LayoutManager {
        return LayoutManager.wrap(self, asIface());
    }
};
