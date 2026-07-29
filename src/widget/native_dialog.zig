//! GtkNativeDialog — GTK4 原生对话框接口基类
//!
//! 对标 GTK4 `GtkNativeDialog`：用于系统原生对话框（文件选择、颜色选择、打印等），
//! 与 `GtkWindow` 无关（无 X11 Window / Wayland Surface 对象），采用 vtable 派发。
//!
//! 典型子类（GTK 命名）：`GtkFileChooserNative`、`GtkColorChooserNative`、`GtkFontChooserNative`、
//! `GtkPageSetupUnixDialog`、`GtkPrintUnixDialog`。本文件只提供接口 + 通用包装。
//!

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════════
//  Response ID 常量（与 GTK4 完全对齐）
// ═══════════════════════════════════════════════════════════════════════════════

pub const ResponseType = enum(i32) {
    none = 0,
    reject = -2,     // GTK_RESPONSE_REJECT
    accept = -3,     // GTK_RESPONSE_ACCEPT
    delete_event = -4, // GTK_RESPONSE_DELETE_EVENT
    ok = -5,
    cancel = -6,
    close = -7,
    yes = -8,
    no = -9,
    apply = -10,
    help = -11,
};

// ═══════════════════════════════════════════════════════════════════════════════
//  NativeDialogIface + NativeDialog
// ═══════════════════════════════════════════════════════════════════════════════

pub const NativeDialogIface = struct {
    /// 显示对话框；返回 true 表示成功开始显示
    show: *const fn (self_ptr: ?*anyopaque) bool = defaultShow,
    /// 隐藏对话框
    hide: *const fn (self_ptr: ?*anyopaque) void = defaultHide,
    /// 销毁（释放资源）
    destroy: *const fn (self_ptr: ?*anyopaque) void = defaultDestroy,
    /// 是否模态
    set_modal: *const fn (self_ptr: ?*anyopaque, modal: bool) void = defaultSetModal,
    get_modal: *const fn (self_ptr: ?*anyopaque) bool = defaultGetModal,
    set_title: *const fn (self_ptr: ?*anyopaque, title: []const u8) void = defaultSetTitle,
    get_title: *const fn (self_ptr: ?*anyopaque) []const u8 = defaultGetTitle,
    set_transient_for: *const fn (self_ptr: ?*anyopaque, parent: ?*anyopaque) void = defaultSetTransientFor,
    get_transient_for: *const fn (self_ptr: ?*anyopaque) ?*anyopaque = defaultGetTransientFor,

    fn defaultShow(_: ?*anyopaque) bool { return false; }
    fn defaultHide(_: ?*anyopaque) void {}
    fn defaultDestroy(_: ?*anyopaque) void {}
    fn defaultSetModal(_: ?*anyopaque, _: bool) void {}
    fn defaultGetModal(_: ?*anyopaque) bool { return false; }
    fn defaultSetTitle(_: ?*anyopaque, _: []const u8) void {}
    fn defaultGetTitle(_: ?*anyopaque) []const u8 { return ""; }
    fn defaultSetTransientFor(_: ?*anyopaque, _: ?*anyopaque) void {}
    fn defaultGetTransientFor(_: ?*anyopaque) ?*anyopaque { return null; }
};

/// 响应回调：response_id 参考 ResponseType 常量
pub const ResponseFn = *const fn (ud: ?*anyopaque, response_id: i32) void;

pub const NativeDialog = struct {
    iface: NativeDialogIface = .{},
    self_ptr: ?*anyopaque = null,
    user_data: ?*anyopaque = null,
    /// 对话框标题
    title: []const u8 = "",
    /// 是否模态
    modal: bool = false,
    /// 父窗口（类型擦除；可为 *Window / *Toplevel / *Widget）
    transient_for: ?*anyopaque = null,
    /// 响应回调钩子
    on_response: ?ResponseFn = null,
    on_response_ud: ?*anyopaque = null,
    /// 是否正在显示（由 iface.show/hide 维护；亦可直接读写）
    visible: bool = false,

    pub fn wrap(obj_ptr: ?*anyopaque, iface: NativeDialogIface) NativeDialog {
        return .{ .iface = iface, .self_ptr = obj_ptr };
    }

    // ── 转发 ──────────────────────────────────────────────────────────────

    pub fn show(self: *NativeDialog) bool {
        const ok = self.iface.show(self.self_ptr);
        if (ok) self.visible = true;
        return ok;
    }

    pub fn hide(self: *NativeDialog) void {
        self.iface.hide(self.self_ptr);
        self.visible = false;
    }

    pub fn destroy(self: *NativeDialog) void {
        self.iface.destroy(self.self_ptr);
        self.visible = false;
    }

    pub fn setModal(self: *NativeDialog, m: bool) void {
        self.modal = m;
        self.iface.set_modal(self.self_ptr, m);
    }

    pub fn getModal(self: *NativeDialog) bool {
        return self.modal or self.iface.get_modal(self.self_ptr);
    }

    pub fn setTitle(self: *NativeDialog, title: []const u8) void {
        self.title = title;
        self.iface.set_title(self.self_ptr, title);
    }

    pub fn getTitle(self: *NativeDialog) []const u8 {
        if (self.title.len > 0) return self.title;
        return self.iface.get_title(self.self_ptr);
    }

    pub fn setTransientFor(self: *NativeDialog, parent: ?*anyopaque) void {
        self.transient_for = parent;
        self.iface.set_transient_for(self.self_ptr, parent);
    }

    pub fn getTransientFor(self: *NativeDialog) ?*anyopaque {
        return self.transient_for orelse self.iface.get_transient_for(self.self_ptr);
    }

    // ── 回调 ──────────────────────────────────────────────────────────────

    pub fn setOnResponse(self: *NativeDialog, cb: ?ResponseFn, ud: ?*anyopaque) void {
        self.on_response = cb;
        self.on_response_ud = ud;
    }

    /// 发射 response（子类实现中在用户确认/取消时调用）
    pub fn emitResponse(self: *NativeDialog, response_id: i32) void {
        if (self.on_response) |cb| cb(self.on_response_ud, response_id);
    }

    /// 便捷：发射 accept / cancel / delete_event
    pub fn accept(self: *NativeDialog) void { self.emitResponse(@intFromEnum(ResponseType.accept)); }
    pub fn cancel(self: *NativeDialog) void { self.emitResponse(@intFromEnum(ResponseType.cancel)); }
    pub fn reject(self: *NativeDialog) void { self.emitResponse(@intFromEnum(ResponseType.reject)); }
};
