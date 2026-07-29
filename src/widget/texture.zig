//! GdkTexture + GdkTextureDownloader — GTK4 纹理/像素
//!
//! 对标 GDK4：
//!   - GdkTexture：实现 GdkPaintable 的纹理对象（可直接用 snapshot 绘制）
//!   - GdkMemoryTexture：在 CPU 内存持有 RGBA8888 字节的 Texture 子类
//!   - GdkTextureDownloader：把 GPU 纹理 → 下载回 CPU 字节（GPU 端实现占位）
//!

const std = @import("std");
const paintable_mod = @import("paintable.zig");
const Paintable = paintable_mod.Paintable;
const PaintableIface = paintable_mod.PaintableIface;
const PaintableFlags = paintable_mod.PaintableFlags;

// ═══════════════════════════════════════════════════════════════════════════════
//  GdkTexture
// ═══════════════════════════════════════════════════════════════════════════════

pub const GdkTexture = struct {
    /// 逻辑宽/高（px）
    width: i32 = 0,
    height: i32 = 0,
    /// 若为 MemoryTexture：指向 RGBA8888 字节；若非内存纹理 → null
    bytes: ?[]const u8 = null,
    /// rowstride：每行字节数；bytes==null 时忽略
    rowstride: usize = 0,
    /// GPU 句柄/ID；真正的 Vulkan/GL 后端实现才使用
    gpu_handle: ?*anyopaque = null,
    /// 用户附加数据
    user_data: ?*anyopaque = null,

    const Self = @This();

    // ── Paintable 接口转发（snapshot 占位，仅记录尺寸/flags） ────────────
    fn paintableGetCurrentImage(self_ptr: ?*anyopaque) ?*anyopaque {
        _ = self_ptr;
        return null; // 简化：不单独生成 snapshot Image 对象
    }
    fn paintableGetFlags(self_ptr: ?*anyopaque) PaintableFlags {
        _ = self_ptr;
        return .{};
    }
    fn paintableGetIntrinsicWidth(self_ptr: ?*anyopaque) i32 {
        const t: *const Self = @ptrCast(@alignCast(self_ptr orelse return 0));
        return t.width;
    }
    fn paintableGetIntrinsicHeight(self_ptr: ?*anyopaque) i32 {
        const t: *const Self = @ptrCast(@alignCast(self_ptr orelse return 0));
        return t.height;
    }
    fn paintableGetIntrinsicAspectRatio(self_ptr: ?*anyopaque) f32 {
        const t: *const Self = @ptrCast(@alignCast(self_ptr orelse return 0));
        if (t.height == 0) return 1.0;
        return @as(f32, @floatFromInt(t.width)) / @as(f32, @floatFromInt(t.height));
    }
    fn paintableSnapshot(self_ptr: ?*anyopaque, snapshot_ptr: ?*anyopaque, w: f32, h: f32) void {
        _ = self_ptr;
        _ = snapshot_ptr;
        _ = w;
        _ = h;
        // 真正绘制：调用 GPU 管线把纹理绘制到 (0,0,w,h)；此处留作后端占位
    }

    /// 作为 Paintable 接口包装
    pub fn asPaintable(self: *Self) Paintable {
        const iface = PaintableIface{
            .snapshot = paintableSnapshot,
            .get_current_image = paintableGetCurrentImage,
            .get_flags = paintableGetFlags,
            .get_intrinsic_width = paintableGetIntrinsicWidth,
            .get_intrinsic_height = paintableGetIntrinsicHeight,
            .get_intrinsic_aspect_ratio = paintableGetIntrinsicAspectRatio,
        };
        return Paintable.wrap(self, iface);
    }
};

// 命名别名
pub const Texture = GdkTexture;

// ═══════════════════════════════════════════════════════════════════════════════
//  GdkMemoryTexture — 直接从 CPU RGBA8888 字节构建
// ═══════════════════════════════════════════════════════════════════════════════

pub const GdkMemoryTexture = struct {
    /// 底层共享 Texture 结构（首字段对齐，可安全 `@ptrCast`）
    base: GdkTexture = .{},
    /// 若 bytes 需要释放（由 createFromBytes 分配时为 true）
    owned_bytes: bool = false,
    _allocator: ?std.mem.Allocator = null,

    const MemSelf = @This();

    /// 用给定 RGBA8888 字节构造 MemoryTexture；若 `copy = true`：内部复制一份，调用方立即释放
    pub fn createFromBytes(
        allocator: std.mem.Allocator,
        width: i32,
        height: i32,
        rowstride: usize,
        bytes: []const u8,
        copy: bool,
    ) !*MemSelf {
        var mt = try allocator.create(MemSelf);
        mt.* = .{};
        mt.base.width = width;
        mt.base.height = height;
        mt.base.rowstride = rowstride;
        if (copy) {
            const dup = try allocator.dupe(u8, bytes);
            mt.base.bytes = dup;
            mt.owned_bytes = true;
            mt._allocator = allocator;
        } else {
            mt.base.bytes = bytes;
            mt.owned_bytes = false;
            mt._allocator = null;
        }
        return mt;
    }

    pub fn deinit(self: *MemSelf, allocator: std.mem.Allocator) void {
        if (self.owned_bytes and self._allocator) |a| {
            if (self.base.bytes) |b| a.free(b);
        }
        allocator.destroy(self);
    }

    pub fn asTexture(self: *MemSelf) *Texture {
        return &self.base;
    }
};

pub const MemoryTexture = GdkMemoryTexture;

// ═══════════════════════════════════════════════════════════════════════════════
//  GdkTextureDownloader
// ═══════════════════════════════════════════════════════════════════════════════

pub const GdkTextureDownloader = struct {
    texture: ?*const Texture = null,

    pub fn init(texture: ?*const Texture) GdkTextureDownloader {
        return .{ .texture = texture };
    }

    pub fn setTexture(self: *GdkTextureDownloader, texture: ?*const Texture) void {
        self.texture = texture;
    }

    /// 下载字节：对于 MemoryTexture，直接返回底层 bytes；否则 null
    pub fn downloadBytes(self: *const GdkTextureDownloader, out_rowstride: *usize) ?[]const u8 {
        const t = self.texture orelse return null;
        const bytes = t.bytes orelse return null;
        out_rowstride.* = t.rowstride;
        return bytes;
    }

    /// 下载到 GPU 端图像对象（Vulkan/GL 后端实现；此处占位）
    pub fn download(self: *const GdkTextureDownloader, gpu_image_ptr: ?*anyopaque) void {
        _ = self;
        _ = gpu_image_ptr;
    }
};

pub const TextureDownloader = GdkTextureDownloader;
