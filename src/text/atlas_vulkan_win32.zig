//! Vulkan Glyph Atlas (Windows)
//!
//! Windows 上的 Vulkan 字形图集: 用 DirectWrite 做 shaping, D2D1+WIC 光栅化到单通道
//! alpha 像素 (与 atlas_vulkan 的像素布局一致), 再上传到 Vulkan 纹理。
//! 接口 (createTexture / getOrRasterize / flush / texture 字段) 与 atlas_vulkan 对齐,
//! 以便 vulkan_renderer 在 Windows 上直接复用。
//!
//! 注意: 仅在 Windows 目标下真正运行; 非 Windows 下 cImport 为 void, 真实逻辑被
//! `if (comptime is_windows)` 守卫, 仅做类型/结构校验。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const math = @import("../math.zig");
const vulkan = @import("../gpu/vulkan.zig");
const dwmod = @import("dwrite.zig");
const dwrite = if (is_windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("dwrite.h");
    @cInclude("d2d1.h");
    @cInclude("wincodec.h");
}) else void;

/// 释放任意 COM 接口指针。cImport 中 D2D1/WIC 接口把 IUnknown 方法嵌在 `Base` 字段里,
/// 直接 `ptr.lpVtbl.*.Release` 取不到; 统一转成 `*dwrite.IUnknown` (vtbl 首三个槽即
/// IUnknown 方法, 内存布局一致) 再调用。非 Windows 目标下是空操作。
fn releaseCom(ptr: anytype) void {
    if (comptime !is_windows) return;
    if (ptr) |p| {
        const unk: *dwrite.IUnknown = @alignCast(@ptrCast(p));
        _ = unk.lpVtbl.*.Release.?(unk);
    }
}

pub const AtlasEntry = struct {
    uv_rect: math.Rect(f32),
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
    advance: i32,
};

pub const GlyphAtlas = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    /// 单通道 alpha 像素 (与 atlas_vulkan 布局一致)
    pixels: []u8,
    texture: ?vulkan.TextureHandle = null,
    dirty: bool = false,
    dirty_x0: u32 = 0,
    dirty_y0: u32 = 0,
    dirty_x1: u32 = 0,
    dirty_y1: u32 = 0,

    // D2D1/WIC 光栅化资源 (懒初始化, 仅 Windows)
    d2d_factory: if (is_windows) ?*dwrite.ID2D1Factory else void = null,
    wic_factory: if (is_windows) ?*dwrite.IWICImagingFactory else void = null,
    cell_bitmap: if (is_windows) ?*dwrite.IWICBitmap else void = null,
    rt: if (is_windows) ?*dwrite.ID2D1RenderTarget else void = null,
    brush: if (is_windows) ?*dwrite.ID2D1SolidColorBrush else void = null,
    cell_size: u32 = 64,
    initialized: bool = false,

    // shelf packing
    shelves: std.ArrayListUnmanaged(Shelf) = .{ .items = &.{}, .capacity = 0 },

    pub const Shelf = struct {
        y: u32,
        height: u32,
        x_cursor: u32,
    };

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !GlyphAtlas {
        const pixels = try allocator.alloc(u8, width * height);
        @memset(pixels, 0);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        if (is_windows) {
            releaseCom(self.brush);
            releaseCom(self.rt);
            releaseCom(self.cell_bitmap);
            releaseCom(self.wic_factory);
            releaseCom(self.d2d_factory);
        }
        self.shelves.deinit(self.allocator);
        self.allocator.free(self.pixels);
    }

    /// 创建 GPU 纹理 (Vulkan)
    pub fn createTexture(self: *GlyphAtlas, device: *vulkan.VulkanDevice) !void {
        if (!is_windows) return error.NotImplemented;
        const tex = device.createTexture(self.width, self.height) orelse return error.TextureCreationFailed;
        self.texture = tex;
        device.updateTextureRegion(tex, 0, 0, self.width, self.height, self.pixels, self.width);
        device.prepareTextureForSampling(tex);
    }

    fn ensureRenderTargets(self: *GlyphAtlas) !void {
        if (self.initialized) return;
        if (!is_windows) return error.NotImplemented;

        _ = dwrite.CoInitializeEx(null, dwrite.COINIT_MULTITHREADED);

        // D2D1 工厂
        var d2d_f: ?*dwrite.ID2D1Factory = null;
        if (dwrite.D2D1CreateFactory(dwrite.D2D1_FACTORY_TYPE_SINGLE_THREADED, &dwrite.IID_ID2D1Factory, null, @ptrCast(&d2d_f)) != dwrite.S_OK or d2d_f == null) {
            return error.D2D1FactoryFailed;
        }
        self.d2d_factory = d2d_f;

        // WIC 工厂
        var wic_f: ?*dwrite.IWICImagingFactory = null;
        if (dwrite.CoCreateInstance(&dwrite.CLSID_WICImagingFactory, null, dwrite.CLSCTX_INPROC_SERVER, &dwrite.IID_IWICImagingFactory, @ptrCast(&wic_f)) != dwrite.S_OK or wic_f == null) {
            return error.WicFactoryFailed;
        }
        self.wic_factory = wic_f;

        // 单元位图 (cell_size × cell_size, 32bppPBGRA)
        var bmp: ?*dwrite.IWICBitmap = null;
        if (wic_f.?.*.lpVtbl.*.CreateBitmap.?(wic_f.?, self.cell_size, self.cell_size, &dwrite.GUID_WICPixelFormat32bppPBGRA, dwrite.WICBitmapCacheOnLoad, &bmp) != dwrite.S_OK or bmp == null) {
            return error.WicBitmapFailed;
        }
        self.cell_bitmap = bmp;

        // D2D1 渲染目标 (绑定到 WIC 位图)
        var rt: ?*dwrite.ID2D1RenderTarget = null;
        var props: dwrite.D2D1_RENDER_TARGET_PROPERTIES = std.mem.zeroes(dwrite.D2D1_RENDER_TARGET_PROPERTIES);
        props.type = dwrite.D2D1_RENDER_TARGET_TYPE_DEFAULT;
        props.pixelFormat = .{ .format = dwrite.DXGI_FORMAT_B8G8R8A8_UNORM, .alphaMode = dwrite.D2D1_ALPHA_MODE_PREMULTIPLIED };
        props.dpiX = 96.0;
        props.dpiY = 96.0;
        if (d2d_f.?.*.lpVtbl.*.CreateWicBitmapRenderTarget.?(d2d_f.?, bmp.?, &props, &rt) != dwrite.S_OK or rt == null) {
            return error.D2D1RTFailed;
        }
        self.rt = rt;

        // 白色纯色画刷
        var brush: ?*dwrite.ID2D1SolidColorBrush = null;
        const white: dwrite.D2D1_COLOR_F = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
        if (rt.?.*.lpVtbl.*.CreateSolidColorBrush.?(rt.?, &white, null, &brush) != dwrite.S_OK or brush == null) {
            return error.D2D1BrushFailed;
        }
        self.brush = brush;

        self.initialized = true;
    }

    pub fn getOrRasterize(
        self: *GlyphAtlas,
        device: *vulkan.VulkanDevice,
        font: *const dwmod.DwFont,
        glyph_id: u32,
        size: f32,
    ) !AtlasEntry {
        if (!is_windows) return error.NotImplemented;
        try self.ensureRenderTargets();

        const cell = self.cell_size;
        const em = font.design_units_per_em;
        const scale = size / em;

        // 取字形设计度量
        var gm: dwrite.DWRITE_GLYPH_METRICS = std.mem.zeroes(dwrite.DWRITE_GLYPH_METRICS);
        var indices: [1]u16 = .{@intCast(glyph_id)};
        font.font_face.?.*.lpVtbl.*.GetDesignGlyphMetrics.?(font.font_face.?, &indices, 1, &gm, 0);

        const advance: f32 = @as(f32, @floatFromInt(gm.advanceWidth)) * scale;
        const left_bearing: f32 = @as(f32, @floatFromInt(gm.leftSideBearing)) * scale;
        const top_bearing: f32 = @as(f32, @floatFromInt(gm.topSideBearing)) * scale;
        const ascent = font.metrics.ascent;

        // shelf packing 分配位置
        const pos = self.allocateShelf(cell, cell) orelse blk: {
            try self.grow(device);
            break :blk self.allocateShelf(cell, cell) orelse return error.AtlasFull;
        };
        const ox: u32 = pos.x;
        const oy: u32 = pos.y;

        // 光栅化到单元位图 (D2D1/WIC), 取 alpha 通道写入图集
        const rt = self.rt.?;
        _ = rt.*.lpVtbl.*.BeginDraw.?(rt);
        const clear = dwrite.D2D1_COLOR_F{ .r = 0, .g = 0, .b = 0, .a = 0 };
        rt.*.lpVtbl.*.Clear.?(rt, &clear);
        const origin = dwrite.D2D1_POINT_2F{
            .x = @floatFromInt(@as(i32, @intFromFloat(-left_bearing)) + 2),
            .y = @floatFromInt(@as(i32, @intFromFloat(ascent)) + 2),
        };
        var run: dwrite.DWRITE_GLYPH_RUN = std.mem.zeroes(dwrite.DWRITE_GLYPH_RUN);
        var adv: f32 = advance;
        var offset: dwrite.DWRITE_GLYPH_OFFSET = std.mem.zeroes(dwrite.DWRITE_GLYPH_OFFSET);
        run.fontFace = font.font_face.?;
        run.fontEmSize = size;
        run.glyphCount = 1;
        run.glyphIndices = &indices;
        run.glyphAdvances = &adv;
        run.glyphOffsets = &offset;
        run.isSideways = 0;
        run.bidiLevel = 0;
        rt.*.lpVtbl.*.DrawGlyphRun.?(rt, origin, &run, self.brush.?, dwrite.D2D1_DRAW_TEXT_OPTIONS_NONE, dwrite.DWRITE_MEASURING_MODE_NATURAL);
        if (rt.*.lpVtbl.*.EndDraw.?(rt, null, null) != dwrite.S_OK) return error.GlyphRenderFailed;

        // 读回单元位图像素 (BGRA), 取 alpha 通道写入图集单通道缓冲
        var lock: ?*dwrite.IWICBitmapLock = null;
        const rc = dwrite.WICRect{ .X = 0, .Y = 0, .Width = @intCast(cell), .Height = @intCast(cell) };
        if (self.cell_bitmap.?.*.lpVtbl.*.Lock.?(self.cell_bitmap.?, &rc, dwrite.WICBitmapLockRead, &lock) != dwrite.S_OK or lock == null) {
            return error.WicLockFailed;
        }
        var data_size: u32 = 0;
        var data_ptr: [*]u8 = undefined;
        _ = lock.?.*.lpVtbl.*.GetDataPointer.?(lock.?, &data_size, &data_ptr);
        const stride: u32 = cell * 4;

        var py: u32 = 0;
        while (py < cell) : (py += 1) {
            var px: u32 = 0;
            while (px < cell) : (px += 1) {
                const a = data_ptr[py * stride + px * 4 + 3]; // BGRA 中 alpha 在最高字节
                self.pixels[(oy + py) * self.width + (ox + px)] = a;
            }
        }
        releaseCom(lock);

        // 扩展脏矩形
        if (!self.dirty) {
            self.dirty_x0 = ox;
            self.dirty_y0 = oy;
            self.dirty_x1 = ox + cell;
            self.dirty_y1 = oy + cell;
            self.dirty = true;
        } else {
            self.dirty_x0 = @min(self.dirty_x0, ox);
            self.dirty_y0 = @min(self.dirty_y0, oy);
            self.dirty_x1 = @max(self.dirty_x1, ox + cell);
            self.dirty_y1 = @max(self.dirty_y1, oy + cell);
        }

        const uv_x0 = @as(f32, @floatFromInt(ox)) / @as(f32, @floatFromInt(self.width));
        const uv_y0 = @as(f32, @floatFromInt(oy)) / @as(f32, @floatFromInt(self.height));
        const uv_x1 = @as(f32, @floatFromInt(ox + cell)) / @as(f32, @floatFromInt(self.width));
        const uv_y1 = @as(f32, @floatFromInt(oy + cell)) / @as(f32, @floatFromInt(self.height));

        return .{
            .uv_rect = .{ .x = uv_x0, .y = uv_y0, .width = uv_x1 - uv_x0, .height = uv_y1 - uv_y0 },
            .width = cell,
            .height = cell,
            .bearing_x = @intFromFloat(left_bearing),
            .bearing_y = @intFromFloat(ascent - top_bearing),
            .advance = @intFromFloat(advance),
        };
    }

    pub fn flush(self: *GlyphAtlas, device: *vulkan.VulkanDevice) void {
        if (!self.dirty) return;
        const tex = self.texture orelse return;

        device.prepareTextureForTransfer(tex);

        const rw = self.dirty_x1 - self.dirty_x0;
        const rh = self.dirty_y1 - self.dirty_y0;
        if (rw == 0 or rh == 0) {
            self.dirty = false;
            return;
        }

        // 构造脏区单通道上传缓冲
        const tmp = self.allocator.alloc(u8, rw * rh) catch {
            self.dirty = false;
            return;
        };
        defer self.allocator.free(tmp);
        var row: u32 = 0;
        while (row < rh) : (row += 1) {
            const src = (self.dirty_y0 + row) * self.width + self.dirty_x0;
            const dst = row * rw;
            @memcpy(tmp[dst .. dst + rw], self.pixels[src .. src + rw]);
        }
        device.updateTextureRegion(tex, self.dirty_x0, self.dirty_y0, rw, rh, tmp, rw);
        device.prepareTextureForSampling(tex);

        self.dirty = false;
    }

    pub const ShelfPos = struct { x: u32, y: u32 };

    fn allocateShelf(self: *GlyphAtlas, w: u32, h: u32) ?ShelfPos {
        const padding: u32 = 1;

        for (self.shelves.items) |*shelf| {
            if (shelf.height >= h and shelf.x_cursor + w + padding <= self.width) {
                const pos = ShelfPos{ .x = shelf.x_cursor, .y = shelf.y };
                shelf.x_cursor += w + padding;
                return pos;
            }
        }

        var next_y: u32 = 0;
        for (self.shelves.items) |shelf| {
            next_y = @max(next_y, shelf.y + shelf.height + padding);
        }

        if (next_y + h + padding > self.height) return null;
        if (w + padding > self.width) return null;

        self.shelves.append(self.allocator, .{
            .y = next_y,
            .height = h + padding,
            .x_cursor = w + padding,
        }) catch return null;

        return ShelfPos{ .x = 0, .y = next_y };
    }

    /// 扩容: 翻倍宽高 (上限 8192), 迁移像素, 重算缓存 UV, 重建 GPU 纹理
    fn grow(self: *GlyphAtlas, device: *vulkan.VulkanDevice) !void {
        const max_dim: u32 = 8192;
        if (self.width >= max_dim and self.height >= max_dim) return error.AtlasFull;

        const new_width = @min(self.width * 2, max_dim);
        const new_height = @min(self.height * 2, max_dim);

        const new_pixels = try self.allocator.alloc(u8, new_width * new_height);
        @memset(new_pixels, 0);
        var row: usize = 0;
        while (row < self.height) : (row += 1) {
            const src = row * self.width;
            const dst = row * new_width;
            @memcpy(new_pixels[dst .. dst + self.width], self.pixels[src .. src + self.width]);
        }
        self.allocator.free(self.pixels);
        self.pixels = new_pixels;

        self.width = new_width;
        self.height = new_height;

        if (self.texture) |old_tex| device.destroyTexture(old_tex);
        const new_tex = device.createTexture(new_width, new_height) orelse return error.TextureCreationFailed;
        self.texture = new_tex;
        device.updateTextureRegion(new_tex, 0, 0, new_width, new_height, self.pixels, new_width);
        device.prepareTextureForSampling(new_tex);

        self.dirty = false;
    }
};
