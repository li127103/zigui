//! GTK4 通用接口定义：Orientable / Scrollable / Root / Toplevel / Native / Buildable
//!
//! GTK 对应:
//!  - GtkOrientable   - 所有带方向属性的控件 (Box/Scale/Paned/Scrollbar/Separator/LevelBar)
//!  - GtkScrollable   - 可被 ScrolledWindow 包裹滚动的控件 (TextView/TreeView/ColumnView/IconView/Viewport)
//!  - GtkRoot         - 所有根控件 (Window / ApplicationWindow / Popover / Dialog 的顶层)
//!  - GtkToplevel     - 顶层窗口 (Window / ApplicationWindow)
//!  - GtkNative       - 原生表面接口 (获取控件所在的原生窗口/surface/renderer)
//!  - GtkBuildable    - 可构建接口 (Builder UI 描述的解析钩子)
//!
//! 所有接口均采用与 TreeModel 相同的 "iface + self_ptr" 类型擦除模式，
//! 并提供具体控件实现时可直接用 `InterfaceName.wrap(&impl)` 包装。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const adjustment_mod = @import("../model/adjustment.zig");

const Widget = widget_mod.Widget;
pub const Adjustment = adjustment_mod.Adjustment;

// ──────────────────────────────────────────────────────────────────────────────
// 通用枚举
// ──────────────────────────────────────────────────────────────────────────────

pub const Orientation = enum(u8) {
    horizontal = 0,
    vertical = 1,
};

pub const ScrollablePolicy = enum(u8) {
    minimum = 0, // 按照最小尺寸分配滚动区域
    natural = 1, // 按照自然尺寸分配滚动区域
};

pub const WindowEdge = enum(u8) {
    north_west,
    north,
    north_east,
    west,
    east,
    south_west,
    south,
    south_east,
};

// ──────────────────────────────────────────────────────────────────────────────
// OrientableIface + Orientable (方向接口)
// ──────────────────────────────────────────────────────────────────────────────

pub const OrientableIface = struct {
    get_orientation: *const fn (self: ?*anyopaque) Orientation,
    set_orientation: *const fn (self: ?*anyopaque, orientation: Orientation) void,
};

/// 类型擦除包装对象（可传递给任何接受 Orientable 的函数）
pub const Orientable = struct {
    iface: OrientableIface,
    self_ptr: ?*anyopaque = null,

    pub fn getOrientation(self: *const Orientable) Orientation {
        return self.iface.get_orientation(self.self_ptr);
    }
    pub fn setOrientation(self: *const Orientable, o: Orientation) void {
        self.iface.set_orientation(self.self_ptr, o);
    }

    /// 生成包装（impl.* 需实现接口方法）
    pub fn wrap(
        obj_ptr: ?*anyopaque,
        comptime getFn: fn (self: ?*anyopaque) Orientation,
        comptime setFn: fn (self: ?*anyopaque, o: Orientation) void,
    ) Orientable {
        return .{
            .iface = .{
                .get_orientation = getFn,
                .set_orientation = setFn,
            },
            .self_ptr = obj_ptr,
        };
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// ScrollableIface + Scrollable (可滚动接口)
// ──────────────────────────────────────────────────────────────────────────────

pub const ScrollableIface = struct {
    get_hadjustment: *const fn (self: ?*anyopaque) ?*Adjustment = defaultGetHadjustment,
    set_hadjustment: *const fn (self: ?*anyopaque, adj: ?*Adjustment) void = defaultSetHadjustment,
    get_vadjustment: *const fn (self: ?*anyopaque) ?*Adjustment = defaultGetVadjustment,
    set_vadjustment: *const fn (self: ?*anyopaque, adj: ?*Adjustment) void = defaultSetVadjustment,
    get_hscroll_policy: ?*const fn (self: ?*anyopaque) ScrollablePolicy = null,
    set_hscroll_policy: ?*const fn (self: ?*anyopaque, policy: ScrollablePolicy) void = null,
    get_vscroll_policy: ?*const fn (self: ?*anyopaque) ScrollablePolicy = null,
    set_vscroll_policy: ?*const fn (self: ?*anyopaque, policy: ScrollablePolicy) void = null,

    fn defaultGetHadjustment(_: ?*anyopaque) ?*Adjustment {
        return null;
    }
    fn defaultSetHadjustment(_: ?*anyopaque, _: ?*Adjustment) void {}
    fn defaultGetVadjustment(_: ?*anyopaque) ?*Adjustment {
        return null;
    }
    fn defaultSetVadjustment(_: ?*anyopaque, _: ?*Adjustment) void {}
};

pub const Scrollable = struct {
    iface: ScrollableIface,
    self_ptr: ?*anyopaque = null,
    /// 控件实现层通常直接维护：
    hadjustment: ?*Adjustment = null,
    vadjustment: ?*Adjustment = null,
    hscroll_policy: ScrollablePolicy = .minimum,
    vscroll_policy: ScrollablePolicy = .minimum,

    pub fn getHadjustment(self: *Scrollable) ?*Adjustment {
        return self.iface.get_hadjustment(self.self_ptr);
    }
    pub fn setHadjustment(self: *Scrollable, adj: ?*Adjustment) void {
        self.iface.set_hadjustment(self.self_ptr, adj);
    }
    pub fn getVadjustment(self: *Scrollable) ?*Adjustment {
        return self.iface.get_vadjustment(self.self_ptr);
    }
    pub fn setVadjustment(self: *Scrollable, adj: ?*Adjustment) void {
        self.iface.set_vadjustment(self.self_ptr, adj);
    }
    pub fn getHscrollPolicy(self: *Scrollable) ScrollablePolicy {
        if (self.iface.get_hscroll_policy) |f| return f(self.self_ptr);
        return self.hscroll_policy;
    }
    pub fn setHscrollPolicy(self: *Scrollable, p: ScrollablePolicy) void {
        if (self.iface.set_hscroll_policy) |f| f(self.self_ptr, p);
        self.hscroll_policy = p;
    }
    pub fn getVscrollPolicy(self: *Scrollable) ScrollablePolicy {
        if (self.iface.get_vscroll_policy) |f| return f(self.self_ptr);
        return self.vscroll_policy;
    }
    pub fn setVscrollPolicy(self: *Scrollable, p: ScrollablePolicy) void {
        if (self.iface.set_vscroll_policy) |f| f(self.self_ptr, p);
        self.vscroll_policy = p;
    }

    pub fn wrap(obj_ptr: ?*anyopaque, iface: ScrollableIface) Scrollable {
        return .{
            .iface = iface,
            .self_ptr = obj_ptr,
        };
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// RootIface + Root (根接口)
// ──────────────────────────────────────────────────────────────────────────────

pub const Display = opaque {}; // 顶层抽象：Display (跨平台屏幕/显示器)

pub const RootIface = struct {
    get_display: *const fn (self: ?*anyopaque) ?*Display = defaultGetDisplay,
    get_focus: *const fn (self: ?*anyopaque) ?*Widget = defaultGetFocus,
    set_focus: *const fn (self: ?*anyopaque, focus: ?*Widget) void = defaultSetFocus,

    fn defaultGetDisplay(_: ?*anyopaque) ?*Display {
        return null;
    }
    fn defaultGetFocus(_: ?*anyopaque) ?*Widget {
        return null;
    }
    fn defaultSetFocus(_: ?*anyopaque, _: ?*Widget) void {}
};

pub const Root = struct {
    iface: RootIface,
    self_ptr: ?*anyopaque = null,
    /// 焦点控件（默认状态）
    current_focus: ?*Widget = null,

    pub fn getDisplay(self: *Root) ?*Display {
        return self.iface.get_display(self.self_ptr);
    }
    pub fn getFocus(self: *Root) ?*Widget {
        return self.iface.get_focus(self.self_ptr);
    }
    pub fn setFocus(self: *Root, w: ?*Widget) void {
        self.iface.set_focus(self.self_ptr, w);
        self.current_focus = w;
    }

    pub fn wrap(obj_ptr: ?*anyopaque, iface: RootIface) Root {
        return .{
            .iface = iface,
            .self_ptr = obj_ptr,
        };
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// ToplevelIface + Toplevel (顶级窗口接口)
// ──────────────────────────────────────────────────────────────────────────────

pub const ToplevelState = packed struct(u32) {
    maximized: bool = false,
    minimized: bool = false,
    fullscreen: bool = false,
    modal: bool = false,
    sticky: bool = false,
    above: bool = false,
    below: bool = false,
    focused: bool = false,
    tiled_top: bool = false,
    tiled_bottom: bool = false,
    tiled_left: bool = false,
    tiled_right: bool = false,
    _pad: u20 = 0,
};

pub const ToplevelIface = struct {
    present: ?*const fn (self: ?*anyopaque) void = null,
    present_with_time: ?*const fn (self: ?*anyopaque, timestamp: u32) void = null,
    close: ?*const fn (self: ?*anyopaque) void = null,
    minimize: ?*const fn (self: ?*anyopaque) void = null,
    maximize: ?*const fn (self: ?*anyopaque) void = null,
    unmaximize: ?*const fn (self: ?*anyopaque) void = null,
    fullscreen: ?*const fn (self: ?*anyopaque) void = null,
    unfullscreen: ?*const fn (self: ?*anyopaque) void = null,
    get_title: ?*const fn (self: ?*anyopaque) []const u8 = null,
    set_title: ?*const fn (self: ?*anyopaque, title: []const u8) void = null,
    get_modal: ?*const fn (self: ?*anyopaque) bool = null,
    set_modal: ?*const fn (self: ?*anyopaque, modal: bool) void = null,
    begin_resize: ?*const fn (
        self: ?*anyopaque,
        edge: WindowEdge,
        button: u32,
        x: f32,
        y: f32,
        timestamp: u32,
    ) void = null,
    begin_move: ?*const fn (
        self: ?*anyopaque,
        button: u32,
        x: f32,
        y: f32,
        timestamp: u32,
    ) void = null,
};

pub const Toplevel = struct {
    iface: ToplevelIface,
    self_ptr: ?*anyopaque = null,
    state: ToplevelState = .{},
    title: []const u8 = "",

    pub fn present(self: *Toplevel) void {
        if (self.iface.present) |f| f(self.self_ptr);
    }
    pub fn presentWithTime(self: *Toplevel, ts: u32) void {
        if (self.iface.present_with_time) |f| f(self.self_ptr, ts);
    }
    pub fn close(self: *Toplevel) void {
        if (self.iface.close) |f| f(self.self_ptr);
    }
    pub fn minimize(self: *Toplevel) void {
        if (self.iface.minimize) |f| {
            f(self.self_ptr);
            self.state.minimized = true;
        }
    }
    pub fn maximize(self: *Toplevel) void {
        if (self.iface.maximize) |f| {
            f(self.self_ptr);
            self.state.maximized = true;
        }
    }
    pub fn unmaximize(self: *Toplevel) void {
        if (self.iface.unmaximize) |f| {
            f(self.self_ptr);
            self.state.maximized = false;
        }
    }
    pub fn fullscreen(self: *Toplevel) void {
        if (self.iface.fullscreen) |f| {
            f(self.self_ptr);
            self.state.fullscreen = true;
        }
    }
    pub fn unfullscreen(self: *Toplevel) void {
        if (self.iface.unfullscreen) |f| {
            f(self.self_ptr);
            self.state.fullscreen = false;
        }
    }
    pub fn getTitle(self: *Toplevel) []const u8 {
        if (self.iface.get_title) |f| return f(self.self_ptr);
        return self.title;
    }
    pub fn setTitle(self: *Toplevel, title: []const u8) void {
        if (self.iface.set_title) |f| f(self.self_ptr, title);
        self.title = title;
    }
    pub fn getModal(self: *Toplevel) bool {
        if (self.iface.get_modal) |f| return f(self.self_ptr);
        return self.state.modal;
    }
    pub fn setModal(self: *Toplevel, modal: bool) void {
        if (self.iface.set_modal) |f| f(self.self_ptr, modal);
        self.state.modal = modal;
    }
    pub fn beginResize(self: *Toplevel, edge: WindowEdge, button: u32, x: f32, y: f32, timestamp: u32) void {
        if (self.iface.begin_resize) |f| f(self.self_ptr, edge, button, x, y, timestamp);
    }
    pub fn beginMove(self: *Toplevel, button: u32, x: f32, y: f32, timestamp: u32) void {
        if (self.iface.begin_move) |f| f(self.self_ptr, button, x, y, timestamp);
    }

    pub fn wrap(obj_ptr: ?*anyopaque, iface: ToplevelIface) Toplevel {
        return .{
            .iface = iface,
            .self_ptr = obj_ptr,
        };
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 便捷：使用默认实现的 "占位" wrapper
// 用于临时不关心实际行为，仅需要对象存在的场景
// ──────────────────────────────────────────────────────────────────────────────

/// 创建一个带默认 no-op 行为的 Orientable（初始方向 horizontal）
pub fn dummyOrientable(orientation: Orientation) Orientable {
    const Opaque = struct {
        var s_orientation: Orientation = .horizontal;
        fn get(_: ?*anyopaque) Orientation {
            return s_orientation;
        }
        fn set(_: ?*anyopaque, o: Orientation) void {
            s_orientation = o;
        }
    };
    Opaque.s_orientation = orientation;
    return .{
        .iface = .{ .get_orientation = Opaque.get, .set_orientation = Opaque.set },
        .self_ptr = null,
    };
}

/// 创建一个带默认 no-op 行为的 Toplevel
pub fn dummyToplevel(title: []const u8) Toplevel {
    return .{
        .iface = .{},
        .self_ptr = null,
        .title = title,
    };
}

// ──────────────────────────────────────────────────────────────────────────────
// NativeIface + Native (原生表面接口)
// GTK4: GtkNative — 桥接控件树到平台原生 surface / renderer
// Window/Popover 等实现此接口，子控件可通过 gtk_widget_get_native() 向上查找
// ──────────────────────────────────────────────────────────────────────────────

/// 原生表面句柄（平台相关：X11 Window / Wayland surface / NSWindow）
pub const NativeSurface = opaque {};

pub const NativeIface = struct {
    /// 获取原生 surface 句柄
    get_surface: *const fn (self: ?*anyopaque) ?*NativeSurface = defaultGetSurface,
    /// 获取该 native 关联的 Widget（通常是 Window/Popover 的根控件）
    get_widget: *const fn (self: ?*anyopaque) ?*Widget = defaultGetWidget,
    /// 实现（realize）原生表面，分配 GPU 资源
    realize: *const fn (self: ?*anyopaque) void = defaultRealize,
    /// 取消实现（unrealize）原生表面，释放 GPU 资源
    unrealize: *const fn (self: ?*anyopaque) void = defaultUnrealize,

    fn defaultGetSurface(_: ?*anyopaque) ?*NativeSurface {
        return null;
    }
    fn defaultGetWidget(_: ?*anyopaque) ?*Widget {
        return null;
    }
    fn defaultRealize(_: ?*anyopaque) void {}
    fn defaultUnrealize(_: ?*anyopaque) void {}
};

pub const Native = struct {
    iface: NativeIface,
    self_ptr: ?*anyopaque = null,

    /// GTK4: gtk_native_get_surface
    pub fn getSurface(self: *const Native) ?*NativeSurface {
        return self.iface.get_surface(self.self_ptr);
    }

    /// GTK4: gtk_native_get_for_surface (逆查找) — 简化为直接返回 widget
    pub fn getWidget(self: *const Native) ?*Widget {
        return self.iface.get_widget(self.self_ptr);
    }

    /// GTK4: gtk_native_realize
    pub fn realize(self: *Native) void {
        self.iface.realize(self.self_ptr);
    }

    /// GTK4: gtk_native_unrealize
    pub fn unrealize(self: *Native) void {
        self.iface.unrealize(self.self_ptr);
    }

    /// 包装一个实现了 NativeIface 的对象
    pub fn wrap(iface: NativeIface, obj_ptr: ?*anyopaque) Native {
        return .{
            .iface = iface,
            .self_ptr = obj_ptr,
        };
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// BuildableIface + Buildable (可构建接口)
// GTK4: GtkBuildable — 让控件支持从 GtkBuilder UI 描述（JSON/XML）解析属性和子元素
// ──────────────────────────────────────────────────────────────────────────────

/// 构建器解析上下文，传递给 Buildable 回调
pub const BuildableParseContext = struct {
    /// 当前正在解析的元素标签名
    tag_name: []const u8,
    /// 当前元素属性列表
    attributes: []const struct {
        name: []const u8,
        value: []const u8,
    },
    /// Builder 自定义数据指针
    builder_data: ?*anyopaque = null,
};

pub const BuildableIface = struct {
    /// 设置构建器属性（从 UI 描述中解析出的键值对）
    /// GTK4: GtkBuildable.set_buildable_property
    set_buildable_property: ?*const fn (
        self: ?*anyopaque,
        builder: ?*anyopaque,
        name: []const u8,
        value: []const u8,
    ) void = null,

    /// 解析自定义子元素开始标签
    /// GTK4: GtkBuildable.parser_start
    parser_start: ?*const fn (
        self: ?*anyopaque,
        ctx: *const BuildableParseContext,
    ) void = null,

    /// 解析自定义子元素结束标签
    /// GTK4: GtkBuildable.parser_end
    parser_end: ?*const fn (
        self: ?*anyopaque,
        tag_name: []const u8,
    ) void = null,

    /// 获取内部子控件（如 ComboBox 的 internal-entry）
    /// GTK4: GtkBuildable.get_internal_child
    get_internal_child: ?*const fn (
        self: ?*anyopaque,
        builder: ?*anyopaque,
        child_name: []const u8,
    ) ?*Widget = null,

    /// 构建完成通知
    /// GTK4: GtkBuildable.builder_finished
    builder_finished: ?*const fn (
        self: ?*anyopaque,
        builder: ?*anyopaque,
    ) void = null,
};

pub const Buildable = struct {
    iface: BuildableIface,
    self_ptr: ?*anyopaque = null,

    /// GTK4: gtk_buildable_set_buildable_property
    pub fn setBuildableProperty(
        self: *const Buildable,
        builder: ?*anyopaque,
        name: []const u8,
        value: []const u8,
    ) void {
        if (self.iface.set_buildable_property) |f| {
            f(self.self_ptr, builder, name, value);
        }
    }

    /// GTK4: gtk_buildable_parser_start
    pub fn parserStart(self: *const Buildable, ctx: *const BuildableParseContext) void {
        if (self.iface.parser_start) |f| f(self.self_ptr, ctx);
    }

    /// GTK4: gtk_buildable_parser_end
    pub fn parserEnd(self: *const Buildable, tag_name: []const u8) void {
        if (self.iface.parser_end) |f| f(self.self_ptr, tag_name);
    }

    /// GTK4: gtk_buildable_get_internal_child
    pub fn getInternalChild(
        self: *const Buildable,
        builder: ?*anyopaque,
        child_name: []const u8,
    ) ?*Widget {
        if (self.iface.get_internal_child) |f| {
            return f(self.self_ptr, builder, child_name);
        }
        return null;
    }

    /// GTK4: gtk_buildable_builder_finished
    pub fn builderFinished(self: *const Buildable, builder: ?*anyopaque) void {
        if (self.iface.builder_finished) |f| f(self.self_ptr, builder);
    }

    /// 包装一个实现了 BuildableIface 的对象
    pub fn wrap(iface: BuildableIface, obj_ptr: ?*anyopaque) Buildable {
        return .{
            .iface = iface,
            .self_ptr = obj_ptr,
        };
    }
};
