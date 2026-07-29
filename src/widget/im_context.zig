//! GtkIMContext — 输入法上下文接口
//!
//! GTK 对应: GtkIMContext / GtkIMMulticontext / GtkIMContextSimple
//!
//! IME 接口基础，负责文本控件 (Entry/TextView/TextArea) 与输入法之间的交互：
//!   - 焦点进入/离开文本框
//!   - 输入法按键事件过滤 (filter_keypress)
//!   - 管理预编辑字符串 (preedit) 与样式
//!   - 用户确认时触发 commit 回调（写入文本控件真实内容）
//!   - 取文本光标周围上下文 (surrounding) 供输入法智能候选
//!
//! 本模块提供三个实现：
//!   - IMContextIface + IMContext（类型擦除接口，任何具体 IME 可挂接）
//!   - IMMulticontext：IME 调度器，切换 backend_id
//!   - IMContextSimple：内置 Compose Key 实现，支持死键与常见组合序列
//!     如 ` + a → à ， ' + e → é ， ^ + i → î ， " + u → ü ， ~ + n → ñ

const std = @import("std");
const math = @import("../math.zig");
const pal = @import("../pal/pal.zig");
const Widget = @import("widget.zig").Widget;

// ──────────────────────────────────────────────────────────────────────────────
// 预编辑属性（Pango 风格简化版）
// ──────────────────────────────────────────────────────────────────────────────

pub const PreeditUnderline = enum(u8) {
    none,
    single, // 普通候选
    double_, // 多候选
    error_, // 错误/未识别
    low, // GTK PANGO_UNDERLINE_LOW
};

pub const PreeditAttr = struct {
    start_index: u32,
    end_index: u32,
    underline: PreeditUnderline = .single,
    foreground: ?math.Color = null,
    background: ?math.Color = null,
};

pub const PreeditAttrList = struct {
    items: std.ArrayListUnmanaged(PreeditAttr) = .{},
    pub fn deinit(self: *PreeditAttrList, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }
    pub fn append(self: *PreeditAttrList, allocator: std.mem.Allocator, attr: PreeditAttr) !void {
        try self.items.append(allocator, attr);
    }
};

pub const KeyEvent = struct {
    keyval: u32,
    modifiers: u32 = 0, // bit0=Shift, 1=Ctrl, 2=Alt, 3=Meta
    hardware_keycode: u32 = 0,
    is_press: bool = true,
    pub fn shift(self: *const KeyEvent) bool {
        return (self.modifiers & 0x01) != 0;
    }
    pub fn ctrl(self: *const KeyEvent) bool {
        return (self.modifiers & 0x02) != 0;
    }
    pub fn alt(self: *const KeyEvent) bool {
        return (self.modifiers & 0x04) != 0;
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 回调签名
// ──────────────────────────────────────────────────────────────────────────────

pub const CommitFn = *const fn (userdata: ?*anyopaque, str: []const u8) void;
pub const PreeditChangedFn = *const fn (userdata: ?*anyopaque) void;
pub const PreeditEndFn = *const fn (userdata: ?*anyopaque) void;
pub const RetrieveSurroundingFn = *const fn (userdata: ?*anyopaque) bool;
pub const DeleteSurroundingFn = *const fn (userdata: ?*anyopaque, offset: i32, n_chars: i32) bool;

// ──────────────────────────────────────────────────────────────────────────────
// IMContextIface + IMContext 包装
// ──────────────────────────────────────────────────────────────────────────────

pub const IMContextIface = struct {
    set_client_widget: ?*const fn (self: ?*anyopaque, widget: ?*Widget) void = null,
    get_preedit_string: *const fn (
        self: ?*anyopaque,
        out_buf: []u8,
        out_buf_len: *usize,
        attrs: ?*PreeditAttrList,
        cursor_pos: *i32,
    ) void = defaultPreedit,
    filter_keypress: ?*const fn (self: ?*anyopaque, event: *const KeyEvent) bool = null,
    focus_in: ?*const fn (self: ?*anyopaque) void = null,
    focus_out: ?*const fn (self: ?*anyopaque) void = null,
    reset: ?*const fn (self: ?*anyopaque) void = null,
    set_cursor_location: ?*const fn (self: ?*anyopaque, rect: math.Rect) void = null,
    set_use_preedit: ?*const fn (self: ?*anyopaque, use: bool) void = null,
    set_surrounding: ?*const fn (
        self: ?*anyopaque,
        text: []const u8,
        cursor_index: i32,
        selection_index: i32,
    ) bool = null,
    get_surrounding: ?*const fn (
        self: ?*anyopaque,
        out_text: []u8,
        out_max: usize,
        out_cursor: *i32,
        out_sel: *i32,
    ) bool = null,

    fn defaultPreedit(
        _: ?*anyopaque,
        out_buf: []u8,
        out_len: *usize,
        _: ?*PreeditAttrList,
        cursor_pos: *i32,
    ) void {
        out_len.* = 0;
        _ = out_buf;
        cursor_pos.* = 0;
    }
};

pub const IMContext = struct {
    iface: IMContextIface,
    self_ptr: ?*anyopaque = null,
    user_data: ?*anyopaque = null,
    on_commit: ?CommitFn = null,
    on_preedit_changed: ?PreeditChangedFn = null,
    on_preedit_end: ?PreeditEndFn = null,
    on_retrieve_surrounding: ?RetrieveSurroundingFn = null,
    on_delete_surrounding: ?DeleteSurroundingFn = null,

    pub fn setClientWidget(self: *IMContext, w: ?*Widget) void {
        if (self.iface.set_client_widget) |f| f(self.self_ptr, w);
    }
    pub fn getPreeditString(self: *IMContext, out_buf: []u8, out_len: *usize, attrs: ?*PreeditAttrList, cursor_pos: *i32) void {
        self.iface.get_preedit_string(self.self_ptr, out_buf, out_len, attrs, cursor_pos);
    }
    pub fn filterKeypress(self: *IMContext, event: *const KeyEvent) bool {
        if (self.iface.filter_keypress) |f| return f(self.self_ptr, event);
        return false;
    }
    pub fn focusIn(self: *IMContext) void {
        if (self.iface.focus_in) |f| f(self.self_ptr);
    }
    pub fn focusOut(self: *IMContext) void {
        if (self.iface.focus_out) |f| f(self.self_ptr);
    }
    pub fn reset(self: *IMContext) void {
        if (self.iface.reset) |f| f(self.self_ptr);
    }
    pub fn setCursorLocation(self: *IMContext, rect: math.Rect) void {
        if (self.iface.set_cursor_location) |f| f(self.self_ptr, rect);
    }
    pub fn setUsePreedit(self: *IMContext, use: bool) void {
        if (self.iface.set_use_preedit) |f| f(self.self_ptr, use);
    }
    pub fn setSurrounding(self: *IMContext, text: []const u8, cursor_index: i32, selection_index: i32) bool {
        if (self.iface.set_surrounding) |f| return f(self.self_ptr, text, cursor_index, selection_index);
        return false;
    }
    pub fn getSurrounding(self: *IMContext, out_text: []u8, out_max: usize, out_cursor: *i32, out_sel: *i32) bool {
        if (self.iface.get_surrounding) |f| return f(self.self_ptr, out_text, out_max, out_cursor, out_sel);
        return false;
    }

    /// 触发 commit 回调（具体实现调用，最终被文本控件写入内容）
    pub fn emitCommit(self: *IMContext, str: []const u8) void {
        if (self.on_commit) |c| c(self.user_data, str);
    }
    pub fn emitPreeditChanged(self: *IMContext) void {
        if (self.on_preedit_changed) |c| c(self.user_data);
    }
    pub fn emitPreeditEnd(self: *IMContext) void {
        if (self.on_preedit_end) |c| c(self.user_data);
    }

    pub fn wrap(obj_ptr: ?*anyopaque, iface: IMContextIface) IMContext {
        return .{ .iface = iface, .self_ptr = obj_ptr };
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// IMMulticontext — 多 IME 调度器
// ──────────────────────────────────────────────────────────────────────────────

pub const IMMulticontext = struct {
    current_id: []const u8 = "simple",
    current: ?*IMContext = null,
    simple_owned: ?*IMContextSimple = null,

    pub fn create(allocator: std.mem.Allocator) IMMulticontext {
        // 默认：启动 simple 后端
        const simple = allocator.create(IMContextSimple) catch @panic("OOM");
        simple.* = IMContextSimple.init();
        return .{
            .current_id = "simple",
            .simple_owned = simple,
            .current = &simple.base_ctx,
        };
    }
    pub fn deinit(self: *IMMulticontext, allocator: std.mem.Allocator) void {
        if (self.simple_owned) |s| allocator.destroy(s);
        self.* = undefined;
    }
    pub fn setContextId(self: *IMMulticontext, backend_id: []const u8) void {
        self.current_id = backend_id;
        // 简化：除了 "simple" 其他一律也用 simple（复杂 IME 需要平台插件）
        if (std.mem.eql(u8, backend_id, "simple") or std.mem.eql(u8, backend_id, "ibus") or std.mem.eql(u8, backend_id, "fcitx")) {
            if (self.simple_owned) |s| self.current = &s.base_ctx;
        }
    }
    pub fn getContextId(self: *const IMMulticontext) []const u8 {
        return self.current_id;
    }
    pub fn getContext(self: *const IMMulticontext) ?*IMContext {
        return self.current;
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// IMContextSimple — Compose Key / 死键实现
// ──────────────────────────────────────────────────────────────────────────────

const ComposeEntry = struct {
    // 前导字符（dead key） + 后续字母 → 输出 Unicode 字符
    dead: u8,
    letter: u8,
    out: u21,
};

const COMPOSE_TABLE = [_]ComposeEntry{
    // Grave accent: `
    .{ .dead = '`', .letter = 'a', .out = 'à' },
    .{ .dead = '`', .letter = 'e', .out = 'è' },
    .{ .dead = '`', .letter = 'i', .out = 'ì' },
    .{ .dead = '`', .letter = 'o', .out = 'ò' },
    .{ .dead = '`', .letter = 'u', .out = 'ù' },
    .{ .dead = '`', .letter = 'A', .out = 'À' },
    .{ .dead = '`', .letter = 'E', .out = 'È' },
    .{ .dead = '`', .letter = 'I', .out = 'Ì' },
    .{ .dead = '`', .letter = 'O', .out = 'Ò' },
    .{ .dead = '`', .letter = 'U', .out = 'Ù' },
    // Acute accent: '
    .{ .dead = '\'', .letter = 'a', .out = 'á' },
    .{ .dead = '\'', .letter = 'e', .out = 'é' },
    .{ .dead = '\'', .letter = 'i', .out = 'í' },
    .{ .dead = '\'', .letter = 'o', .out = 'ó' },
    .{ .dead = '\'', .letter = 'u', .out = 'ú' },
    .{ .dead = '\'', .letter = 'y', .out = 'ý' },
    .{ .dead = '\'', .letter = 'A', .out = 'Á' },
    .{ .dead = '\'', .letter = 'E', .out = 'É' },
    .{ .dead = '\'', .letter = 'I', .out = 'Í' },
    .{ .dead = '\'', .letter = 'O', .out = 'Ó' },
    .{ .dead = '\'', .letter = 'U', .out = 'Ú' },
    // Circumflex: ^
    .{ .dead = '^', .letter = 'a', .out = 'â' },
    .{ .dead = '^', .letter = 'e', .out = 'ê' },
    .{ .dead = '^', .letter = 'i', .out = 'î' },
    .{ .dead = '^', .letter = 'o', .out = 'ô' },
    .{ .dead = '^', .letter = 'u', .out = 'û' },
    .{ .dead = '^', .letter = 'A', .out = 'Â' },
    .{ .dead = '^', .letter = 'E', .out = 'Ê' },
    .{ .dead = '^', .letter = 'I', .out = 'Î' },
    .{ .dead = '^', .letter = 'O', .out = 'Ô' },
    .{ .dead = '^', .letter = 'U', .out = 'Û' },
    // Diaeresis / Umlaut: "
    .{ .dead = '"', .letter = 'a', .out = 'ä' },
    .{ .dead = '"', .letter = 'e', .out = 'ë' },
    .{ .dead = '"', .letter = 'i', .out = 'ï' },
    .{ .dead = '"', .letter = 'o', .out = 'ö' },
    .{ .dead = '"', .letter = 'u', .out = 'ü' },
    .{ .dead = '"', .letter = 'y', .out = 'ÿ' },
    .{ .dead = '"', .letter = 'A', .out = 'Ä' },
    .{ .dead = '"', .letter = 'E', .out = 'Ë' },
    .{ .dead = '"', .letter = 'I', .out = 'Ï' },
    .{ .dead = '"', .letter = 'O', .out = 'Ö' },
    .{ .dead = '"', .letter = 'U', .out = 'Ü' },
    // Tilde: ~
    .{ .dead = '~', .letter = 'a', .out = 'ã' },
    .{ .dead = '~', .letter = 'o', .out = 'õ' },
    .{ .dead = '~', .letter = 'n', .out = 'ñ' },
    .{ .dead = '~', .letter = 'A', .out = 'Ã' },
    .{ .dead = '~', .letter = 'O', .out = 'Õ' },
    .{ .dead = '~', .letter = 'N', .out = 'Ñ' },
    // Cedilla: , + c
    .{ .dead = ',', .letter = 'c', .out = 'ç' },
    .{ .dead = ',', .letter = 'C', .out = 'Ç' },
    // Caron/hacek: v + c = č, d→ď, e→ě, n→ň, r→ř, s→š, t→ť, z→ž
    .{ .dead = 'v', .letter = 'c', .out = 'č' },
    .{ .dead = 'v', .letter = 'e', .out = 'ě' },
    .{ .dead = 'v', .letter = 'n', .out = 'ň' },
    .{ .dead = 'v', .letter = 'r', .out = 'ř' },
    .{ .dead = 'v', .letter = 's', .out = 'š' },
    .{ .dead = 'v', .letter = 'z', .out = 'ž' },
    .{ .dead = 'v', .letter = 'C', .out = 'Č' },
    .{ .dead = 'v', .letter = 'R', .out = 'Ř' },
    .{ .dead = 'v', .letter = 'S', .out = 'Š' },
    .{ .dead = 'v', .letter = 'Z', .out = 'Ž' },
    // Stroke: /  + l → ł, d → đ, o → ø
    .{ .dead = '/', .letter = 'l', .out = 'ł' },
    .{ .dead = '/', .letter = 'L', .out = 'Ł' },
    .{ .dead = '/', .letter = 'd', .out = 'đ' },
    .{ .dead = '/', .letter = 'D', .out = 'Đ' },
    .{ .dead = '/', .letter = 'o', .out = 'ø' },
    .{ .dead = '/', .letter = 'O', .out = 'Ø' },
};

pub const IMContextSimple = struct {
    base_ctx: IMContext,

    /// 当前死键缓冲（0 表示空，否则是前一个按键，等待下一个字母）
    dead_key_pending: u8 = 0,
    use_compose: bool = true,
    use_preedit: bool = true,
    cursor_rect: math.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    client_widget: ?*Widget = null,
    surrounding_text: []const u8 = "",
    cursor_idx: i32 = 0,
    sel_idx: i32 = 0,

    /// UTF-8 输出缓冲（commit 使用）
    out_buf: [16]u8 = undefined,

    pub fn init() IMContextSimple {
        var simple: IMContextSimple = .{
            .base_ctx = IMContext.wrap(null, .{
                .set_client_widget = setClientWidgetFn,
                .get_preedit_string = preeditFn,
                .filter_keypress = filterKeypressFn,
                .focus_in = focusInFn,
                .focus_out = focusOutFn,
                .reset = resetFn,
                .set_cursor_location = setCursorLocFn,
                .set_use_preedit = setUsePreeditFn,
                .set_surrounding = setSurroundingFn,
                .get_surrounding = getSurroundingFn,
            }),
        };
        // 将 self_ptr 指向自己（base.self_ptr → simple）
        simple.base_ctx.self_ptr = &simple;
        return simple;
    }

    fn asSelf(self_ptr: ?*anyopaque) *IMContextSimple {
        return @ptrCast(@alignCast(self_ptr orelse @panic("SimpleIM: null self_ptr")));
    }

    fn setClientWidgetFn(self_ptr: ?*anyopaque, widget: ?*Widget) void {
        const s = asSelf(self_ptr);
        s.client_widget = widget;
    }

    fn preeditFn(
        self_ptr: ?*anyopaque,
        out_buf: []u8,
        out_len: *usize,
        _: ?*PreeditAttrList,
        cursor_pos: *i32,
    ) void {
        const s = asSelf(self_ptr);
        cursor_pos.* = 0;
        out_len.* = 0;
        if (!s.use_preedit or s.dead_key_pending == 0) return;
        // 显示死键本身（如 "^"），单字符长度 1
        if (out_buf.len > 0) {
            out_buf[0] = s.dead_key_pending;
            out_len.* = 1;
            cursor_pos.* = 1;
        }
    }

    fn filterKeypressFn(self_ptr: ?*anyopaque, event: *const KeyEvent) bool {
        const s = asSelf(self_ptr);
        // 修饰键：全部不过滤，交由文本控件自己处理
        if (event.ctrl() or event.alt()) return false;

        const k = event.keyval;
        // 死键缓冲为空 → 检查是否是死键字符（我们支持的前缀）
        if (s.dead_key_pending == 0) {
            if (s.use_compose and k < 128) {
                const c: u8 = @intCast(k);
                if (isDeadKeyChar(c)) {
                    s.dead_key_pending = c;
                    s.base_ctx.emitPreeditChanged();
                    return true; // 消费：死键不会直接 commit
                }
            }
            // 普通按键，不处理（交给控件）
            return false;
        }

        // 已有死键缓冲 → 尝试查表组合
        const dead = s.dead_key_pending;
        if (k < 128) {
            const letter: u8 = @intCast(k);
            if (lookupCompose(dead, letter)) |cp| {
                // 匹配：输出 Unicode 并提交
                const n = std.unicode.utf8Encode(cp, &s.out_buf) catch 0;
                if (n > 0) {
                    s.base_ctx.emitCommit(s.out_buf[0..n]);
                }
                s.dead_key_pending = 0;
                s.base_ctx.emitPreeditEnd();
                return true;
            }
            // 没有匹配：如果再按一次相同死键 → 输出死键本身
            if (letter == dead) {
                s.out_buf[0] = dead;
                s.base_ctx.emitCommit(s.out_buf[0..1]);
                s.dead_key_pending = 0;
                s.base_ctx.emitPreeditEnd();
                return true;
            }
            // 不匹配且不是同字符：输出死键 + 当前字母（未消费，交由控件继续）
            s.out_buf[0] = dead;
            s.base_ctx.emitCommit(s.out_buf[0..1]);
            s.dead_key_pending = 0;
            s.base_ctx.emitPreeditEnd();
            return false;
        }
        // 非 ASCII：放弃死键，不消费
        s.dead_key_pending = 0;
        s.base_ctx.emitPreeditEnd();
        return false;
    }

    fn isDeadKeyChar(c: u8) bool {
        return switch (c) {
            '`', '\'', '^', '"', '~', ',', 'v', '/' => true,
            else => false,
        };
    }
    fn lookupCompose(dead: u8, letter: u8) ?u21 {
        for (COMPOSE_TABLE) |entry| {
            if (entry.dead == dead and entry.letter == letter) return entry.out;
        }
        return null;
    }

    fn focusInFn(self_ptr: ?*anyopaque) void {
        const s = asSelf(self_ptr);
        s.resetState();
    }
    fn focusOutFn(self_ptr: ?*anyopaque) void {
        const s = asSelf(self_ptr);
        s.resetState();
    }
    fn resetFn(self_ptr: ?*anyopaque) void {
        const s = asSelf(self_ptr);
        s.resetState();
    }
    fn resetState(self: *IMContextSimple) void {
        if (self.dead_key_pending != 0) {
            self.dead_key_pending = 0;
            self.base_ctx.emitPreeditEnd();
        }
    }
    fn setCursorLocFn(self_ptr: ?*anyopaque, rect: math.Rect) void {
        const s = asSelf(self_ptr);
        s.cursor_rect = rect;
    }
    fn setUsePreeditFn(self_ptr: ?*anyopaque, use: bool) void {
        const s = asSelf(self_ptr);
        s.use_preedit = use;
    }
    fn setSurroundingFn(
        self_ptr: ?*anyopaque,
        text: []const u8,
        cursor_index: i32,
        selection_index: i32,
    ) bool {
        const s = asSelf(self_ptr);
        s.surrounding_text = text;
        s.cursor_idx = cursor_index;
        s.sel_idx = selection_index;
        return true;
    }
    fn getSurroundingFn(
        self_ptr: ?*anyopaque,
        out_text: []u8,
        out_max: usize,
        out_cursor: *i32,
        out_sel: *i32,
    ) bool {
        const s = asSelf(self_ptr);
        if (s.surrounding_text.len == 0) return false;
        const copy_len = @min(s.surrounding_text.len, out_max);
        @memcpy(out_text[0..copy_len], s.surrounding_text[0..copy_len]);
        out_cursor.* = s.cursor_idx;
        out_sel.* = s.sel_idx;
        return true;
    }

    /// 便捷：返回一个 *IMContext 指向本对象
    pub fn asIMContext(self: *IMContextSimple) *IMContext {
        return &self.base_ctx;
    }
};
