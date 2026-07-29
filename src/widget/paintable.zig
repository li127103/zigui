//! GdkPaintable — 可绘制对象接口
//!
//! GTK 对应: GdkPaintable
//! 这是 GTK4 用来替代 GdkPixbuf + 旧 GtkImage 自定义绘制接口的核心抽象。
//! 任何"可以按指定宽高被绘制到 snapshot"的东西都应该实现 PaintableIface，
//! 常见实现：纹理贴图（TexturePaintable）、SVG/图标（SymbolPaintable）、
//! 空占位（EmptyPaintable）、视频帧（MediaPaintable，留作扩展）。
//!
//! Paintable 接口同样采用 "iface + self_ptr" 类型擦除模式，
//! snapshot_ptr 使用 *anyopaque 以避免强耦合具体的 renderer 模块。

const std = @import("std");
const math = @import("../math.zig");

// ──────────────────────────────────────────────────────────────────────────────
// Flags / 请求模式枚举
// ──────────────────────────────────────────────────────────────────────────────

pub const PaintableFlags = packed struct(u32) {
    /// 尺寸不可变，get_intrinsic_width/height 永远相同
    static_sizes: bool = false,
    /// 可以无损缩放（矢量），否则默认按线性放大
    scalable: bool = false,
    /// 当前 paintable 是空占位，不绘制任何内容
    empty: bool = false,
    /// 尺寸可按比例动态计算
    contents_scalable: bool = false,
    _pad: u28 = 0,
};

// ──────────────────────────────────────────────────────────────────────────────
// PaintableIface + Paintable 类型擦除包装
// ──────────────────────────────────────────────────────────────────────────────

pub const PaintableIface = struct {
    get_flags: *const fn (self: ?*anyopaque) PaintableFlags = defaultFlags,
    get_intrinsic_width: *const fn (self: ?*anyopaque) i32 = defaultZeroI32,
    get_intrinsic_height: *const fn (self: ?*anyopaque) i32 = defaultZeroI32,
    get_intrinsic_aspect_ratio: *const fn (self: ?*anyopaque) f32 = defaultZeroF32,
    snapshot: *const fn (
        self: ?*anyopaque,
        snapshot_ptr: ?*anyopaque,
        width: f32,
        height: f32,
    ) void = defaultSnapshot,

    fn defaultFlags(_: ?*anyopaque) PaintableFlags {
        return .{};
    }
    fn defaultZeroI32(_: ?*anyopaque) i32 {
        return 0;
    }
    fn defaultZeroF32(_: ?*anyopaque) f32 {
        return 0;
    }
    fn defaultSnapshot(_: ?*anyopaque, _: ?*anyopaque, _: f32, _: f32) void {}
};

pub const Paintable = struct {
    iface: PaintableIface,
    self_ptr: ?*anyopaque = null,

    pub fn getFlags(self: *const Paintable) PaintableFlags {
        return self.iface.get_flags(self.self_ptr);
    }
    pub fn getIntrinsicWidth(self: *const Paintable) i32 {
        return self.iface.get_intrinsic_width(self.self_ptr);
    }
    pub fn getIntrinsicHeight(self: *const Paintable) i32 {
        return self.iface.get_intrinsic_height(self.self_ptr);
    }
    pub fn getIntrinsicAspectRatio(self: *const Paintable) f32 {
        const custom = self.iface.get_intrinsic_aspect_ratio(self.self_ptr);
        if (custom > 0) return custom;
        const w: f32 = @floatFromInt(self.getIntrinsicWidth());
        const h: f32 = @floatFromInt(self.getIntrinsicHeight());
        if (w <= 0 or h <= 0) return 0;
        return w / h;
    }
    pub fn snapshot(self: *const Paintable, snapshot_ptr: ?*anyopaque, width: f32, height: f32) void {
        self.iface.snapshot(self.self_ptr, snapshot_ptr, width, height);
    }

    pub fn wrap(obj_ptr: ?*anyopaque, iface: PaintableIface) Paintable {
        return .{ .iface = iface, .self_ptr = obj_ptr };
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// TexturePaintable — 基于纹理的 Paintable（最常见）
// ──────────────────────────────────────────────────────────────────────────────

pub const TexturePaintable = struct {
    url: []const u8 = "",   // 纹理资源路径
    intrinsic_width: i32 = 0,
    intrinsic_height: i32 = 0,
    can_shrink: bool = true,
    user_texture_ptr: ?*anyopaque = null, // 实际平台纹理句柄

    const Self = @This();

    pub fn create(url: []const u8, w: i32, h: i32) Self {
        return .{
            .url = url,
            .intrinsic_width = w,
            .intrinsic_height = h,
        };
    }

    // PaintableIface 转发
    pub fn flagsFn(self: ?*anyopaque) PaintableFlags {
        const s: *Self = @ptrCast(@alignCast(self orelse return .{}));
        _ = s;
        return .{ .static_sizes = true };
    }
    pub fn widthFn(self: ?*anyopaque) i32 {
        const s: *Self = @ptrCast(@alignCast(self orelse return 0));
        return s.intrinsic_width;
    }
    pub fn heightFn(self: ?*anyopaque) i32 {
        const s: *Self = @ptrCast(@alignCast(self orelse return 0));
        return s.intrinsic_height;
    }
    pub fn aspectRatioFn(self: ?*anyopaque) f32 {
        const s: *Self = @ptrCast(@alignCast(self orelse return 0));
        if (s.intrinsic_width <= 0 or s.intrinsic_height <= 0) return 0;
        const w: f32 = @floatFromInt(s.intrinsic_width);
        const h: f32 = @floatFromInt(s.intrinsic_height);
        return w / h;
    }
    pub fn snapshotFn(
        self: ?*anyopaque,
        snapshot_ptr: ?*anyopaque,
        width: f32,
        height: f32,
    ) void {
        // 实际绘制留给具体的 renderer 后端：
        // 这里只保证"有纹理句柄"与尺寸可用，避免引入渲染器依赖。
        const s: *Self = @ptrCast(@alignCast(self orelse return));
        _ = s;
        _ = snapshot_ptr;
        _ = width;
        _ = height;
    }

    /// 生成可被 Paintable.wrap() 使用的 iface
    pub fn asIface() PaintableIface {
        return .{
            .get_flags = flagsFn,
            .get_intrinsic_width = widthFn,
            .get_intrinsic_height = heightFn,
            .get_intrinsic_aspect_ratio = aspectRatioFn,
            .snapshot = snapshotFn,
        };
    }

    /// 直接生成 Paintable 包装（self 需存在于外部生命周期）
    pub fn asPaintable(self: *Self) Paintable {
        return Paintable.wrap(self, asIface());
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// SymbolPaintable — 矢量/符号 Paintable（可无损缩放）
// ──────────────────────────────────────────────────────────────────────────────

pub const SymbolPaintable = struct {
    icon_name: []const u8 = "",
    symbol_name: []const u8 = "",
    color: math.Color = math.Color.new(0, 0, 0, 1),
    /// 1.0 = 100% 原尺寸；>1 放大，<1 缩小
    font_size_scale: f32 = 1.0,
    intrinsic_size: i32 = 16,

    pub fn create(name: []const u8, color_argb: u32, size: i32) SymbolPaintable {
        return .{
            .icon_name = name,
            .color = math.Color.fromARGB32(color_argb),
            .intrinsic_size = size,
        };
    }

    pub fn flagsFn(_: ?*anyopaque) PaintableFlags {
        return .{ .static_sizes = false, .scalable = true };
    }
    pub fn wFn(self_: ?*anyopaque) i32 {
        const s: *SymbolPaintable = @ptrCast(@alignCast(self_ orelse return 0));
        return s.intrinsic_size;
    }
    pub fn hFn(self_: ?*anyopaque) i32 {
        const s: *SymbolPaintable = @ptrCast(@alignCast(self_ orelse return 0));
        return s.intrinsic_size;
    }
    pub fn arFn(_: ?*anyopaque) f32 {
        return 1.0; // 图标默认 1:1
    }
    pub fn snapshotFn_(
        self_: ?*anyopaque,
        snapshot_ptr: ?*anyopaque,
        width: f32,
        height: f32,
    ) void {
        const s: *SymbolPaintable = @ptrCast(@alignCast(self_ orelse return));
        _ = s;
        _ = snapshot_ptr;
        _ = width;
        _ = height;
    }

    pub fn asIface() PaintableIface {
        return .{
            .get_flags = flagsFn,
            .get_intrinsic_width = wFn,
            .get_intrinsic_height = hFn,
            .get_intrinsic_aspect_ratio = arFn,
            .snapshot = snapshotFn_,
        };
    }

    pub fn asPaintable(self: *SymbolPaintable) Paintable {
        return Paintable.wrap(self, asIface());
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// EmptyPaintable — 空占位（flags.empty = true）
// ──────────────────────────────────────────────────────────────────────────────

pub const EmptyPaintable = struct {
    intrinsic_width: i32 = 0,
    intrinsic_height: i32 = 0,

    pub fn create(w: i32, h: i32) EmptyPaintable {
        return .{ .intrinsic_width = w, .intrinsic_height = h };
    }

    pub fn flagsFn(_: ?*anyopaque) PaintableFlags {
        return .{ .empty = true };
    }
    pub fn wFn(self_: ?*anyopaque) i32 {
        const s: *EmptyPaintable = @ptrCast(@alignCast(self_ orelse return 0));
        return s.intrinsic_width;
    }
    pub fn hFn(self_: ?*anyopaque) i32 {
        const s: *EmptyPaintable = @ptrCast(@alignCast(self_ orelse return 0));
        return s.intrinsic_height;
    }
    pub fn snapshotFn_(_: ?*anyopaque, _: ?*anyopaque, _: f32, _: f32) void {}

    pub fn asIface() PaintableIface {
        return .{
            .get_flags = flagsFn,
            .get_intrinsic_width = wFn,
            .get_intrinsic_height = hFn,
            .snapshot = snapshotFn_,
        };
    }

    pub fn asPaintable(self: *EmptyPaintable) Paintable {
        return Paintable.wrap(self, asIface());
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 便捷：创建一个纯尺寸的占位 Paintable（无需管理生命周期）
// ──────────────────────────────────────────────────────────────────────────────

/// 返回一个 flags=empty, intrinsic=(w, h) 的临时 Paintable
pub fn makeEmpty(w: i32, h: i32) Paintable {
    const Opaque = struct {
        threadlocal var s_w: i32 = 0;
        threadlocal var s_h: i32 = 0;
        fn flags(_: ?*anyopaque) PaintableFlags {
            return .{ .empty = true };
        }
        fn w_(_: ?*anyopaque) i32 {
            return s_w;
        }
        fn h_(_: ?*anyopaque) i32 {
            return s_h;
        }
    };
    Opaque.s_w = w;
    Opaque.s_h = h;
    return .{
        .iface = .{
            .get_flags = Opaque.flags,
            .get_intrinsic_width = Opaque.w_,
            .get_intrinsic_height = Opaque.h_,
        },
        .self_ptr = null,
    };
}
