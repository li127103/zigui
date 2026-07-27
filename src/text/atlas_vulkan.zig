//! Glyph Atlas (Vulkan + FreeType) - Shelf Packing 纹理图集

const std = @import("std");
const math = @import("../math.zig");
const vulkan = @import("../gpu/vulkan.zig");
const freetype = @import("freetype.zig");

pub const GlyphAtlas = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u8,
    shelves: std.ArrayListUnmanaged(Shelf),
    cache: std.HashMapUnmanaged(GlyphKey, AtlasEntry, GlyphKeyContext, 80),
    texture: ?vulkan.TextureHandle = null,
    texture_in_shader_mode: bool = false,
    dirty: bool = false,
    dirty_rects: std.ArrayListUnmanaged(DirtyRect),

    pub const Shelf = struct {
        y: u32,
        height: u32,
        x_cursor: u32,
    };

    pub const GlyphKey = struct {
        font_id: u64,
        font_size_bits: u32,
        font_weight: u16,
        glyph_id: u32,

        pub fn encode(font_id: u64, size: f32, weight: u16, glyph_id: u32) GlyphKey {
            const size_bits: u32 = @intFromFloat(@round(size * 64.0));
            return .{ .font_id = font_id, .font_size_bits = size_bits, .font_weight = weight, .glyph_id = glyph_id };
        }
    };

    pub const GlyphKeyContext = struct {
        pub fn hash(ctx: @This(), key: GlyphKey) u64 {
            _ = ctx;
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, key.font_id);
            std.hash.autoHash(&hasher, key.font_size_bits);
            std.hash.autoHash(&hasher, key.font_weight);
            std.hash.autoHash(&hasher, key.glyph_id);
            return hasher.final();
        }

        pub fn eql(ctx: @This(), a: GlyphKey, b: GlyphKey) bool {
            _ = ctx;
            return a.font_id == b.font_id and a.font_size_bits == b.font_size_bits and a.font_weight == b.font_weight and a.glyph_id == b.glyph_id;
        }
    };

    pub const AtlasEntry = struct {
        uv_rect: math.Rect(f32),
        width: u32,
        height: u32,
        bearing_x: i32,
        bearing_y: i32,
        advance: i32,
    };

    pub const DirtyRect = struct {
        x: u32,
        y: u32,
        w: u32,
        h: u32,
    };

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !GlyphAtlas {
        const pixels = try allocator.alloc(u8, width * height);
        @memset(pixels, 0);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
            .shelves = .{ .items = &.{}, .capacity = 0 },
            .cache = .{},
            .dirty_rects = .{ .items = &.{}, .capacity = 0 },
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.allocator.free(self.pixels);
        self.shelves.deinit(self.allocator);
        self.cache.deinit(self.allocator);
        self.dirty_rects.deinit(self.allocator);
    }

    /// 创建 GPU 纹理
    pub fn createTexture(self: *GlyphAtlas, device: *vulkan.VulkanDevice) !void {
        const tex = device.createTexture(self.width, self.height) orelse return error.TextureCreationFailed;
        self.texture = tex;
        // createTexture 已转换: UNDEFINED → TRANSFER_DST, 直接上传后转 SHADER_READ_ONLY
        device.updateTextureRegion(tex, 0, 0, self.width, self.height, self.pixels, self.width);
        device.prepareTextureForSampling(tex);
        self.texture_in_shader_mode = true;
    }

    /// 获取或光栅化 glyph
    pub fn getOrRasterize(self: *GlyphAtlas, device: *vulkan.VulkanDevice, font: *const freetype.FtFont, glyph_id: u32, size: f32) !AtlasEntry {
        const key = GlyphKey.encode(font.fontId(), size, font.weight, glyph_id);

        // 缓存命中
        if (self.cache.get(key)) |entry| {
            return entry;
        }

        // 光栅化 glyph
        const max_dim: u32 = @intFromFloat(@ceil(size * 2.0) + 8);
        const buf_size = max_dim * max_dim;
        const tmp_buf = try self.allocator.alloc(u8, buf_size);
        defer self.allocator.free(tmp_buf);

        const metrics = font.rasterizeGlyph(glyph_id, tmp_buf) orelse {
            const empty = AtlasEntry{
                .uv_rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .width = 0,
                .height = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = 0,
            };
            try self.cache.put(self.allocator, key, empty);
            return empty;
        };

        // 零尺寸 glyph (空格等)
        if (metrics.width <= 0 or metrics.height <= 0) {
            const empty = AtlasEntry{
                .uv_rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .width = 0,
                .height = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = metrics.advance,
            };
            try self.cache.put(self.allocator, key, empty);
            return empty;
        }

        const gw: u32 = @intCast(metrics.width);
        const gh: u32 = @intCast(metrics.height);

        // Shelf packing 分配空间
        const pos = self.allocateShelf(gw, gh) orelse blk: {
            // Atlas 满了, 扩容后重试
            try self.grow(device);
            break :blk self.allocateShelf(gw, gh) orelse return error.AtlasFull;
        };

        // 复制像素到 atlas
        const src_w: usize = @intCast(metrics.width);
        const src_h: usize = @intCast(metrics.height);
        var row: usize = 0;
        while (row < src_h) : (row += 1) {
            const src_offset = row * src_w;
            const dst_offset = (@as(usize, pos.y) + row) * self.width + pos.x;
            @memcpy(
                self.pixels[dst_offset .. dst_offset + src_w],
                tmp_buf[src_offset .. src_offset + src_w],
            );
        }

        // 计算 UV
        const entry = AtlasEntry{
            .uv_rect = .{
                .x = @as(f32, @floatFromInt(pos.x)) / @as(f32, @floatFromInt(self.width)),
                .y = @as(f32, @floatFromInt(pos.y)) / @as(f32, @floatFromInt(self.height)),
                .width = @as(f32, @floatFromInt(gw)) / @as(f32, @floatFromInt(self.width)),
                .height = @as(f32, @floatFromInt(gh)) / @as(f32, @floatFromInt(self.height)),
            },
            .width = gw,
            .height = gh,
            .bearing_x = metrics.bearing_x,
            .bearing_y = metrics.bearing_y,
            .advance = metrics.advance,
        };

        try self.cache.put(self.allocator, key, entry);

        // 标记脏区域
        try self.dirty_rects.append(self.allocator, .{ .x = pos.x, .y = pos.y, .w = gw, .h = gh });
        self.dirty = true;

        return entry;
    }

    /// 上传脏区域到 GPU
    pub fn flush(self: *GlyphAtlas, device: *vulkan.VulkanDevice) void {
        if (!self.dirty) return;
        const tex = self.texture orelse return;

        if (self.dirty_rects.items.len > 0) {
            // 如果纹理已在 shader 模式，先转回 transfer
            if (self.texture_in_shader_mode) {
                device.prepareTextureForTransfer(tex);
                self.texture_in_shader_mode = false;
            }

            var min_x: u32 = self.width;
            var min_y: u32 = self.height;
            var max_x: u32 = 0;
            var max_y: u32 = 0;

            for (self.dirty_rects.items) |r| {
                min_x = @min(min_x, r.x);
                min_y = @min(min_y, r.y);
                max_x = @max(max_x, r.x + r.w);
                max_y = @max(max_y, r.y + r.h);
            }

            const rw = max_x - min_x;
            const rh = max_y - min_y;

            // 一次性上传整个脏区域
            const buf_size: usize = @as(usize, rw) * @as(usize, rh);
            if (device.allocator.alloc(u8, buf_size)) |tmp| {
                var row: u32 = 0;
                while (row < rh) : (row += 1) {
                    const src_offset = (@as(usize, min_y) + row) * self.width + min_x;
                    const dst_offset: usize = @as(usize, row) * rw;
                    @memcpy(tmp[dst_offset .. dst_offset + rw], self.pixels[src_offset .. src_offset + rw]);
                }
                device.updateTextureRegion(tex, min_x, min_y, rw, rh, tmp, rw);
                device.allocator.free(tmp);
            } else |_| {}
        }

        // 转换布局: TRANSFER_DST → SHADER_READ_ONLY
        device.prepareTextureForSampling(tex);
        self.texture_in_shader_mode = true;

        self.dirty_rects.clearRetainingCapacity();
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

        // 分配新像素缓冲并迁移旧数据 (行复制, 因 stride 变化)
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

        // 重算所有缓存 entry 的 UV (按旧/新尺寸比例缩放)
        const scale_x = @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(new_width));
        const scale_y = @as(f32, @floatFromInt(self.height)) / @as(f32, @floatFromInt(new_height));
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.uv_rect.x *= scale_x;
            entry.value_ptr.uv_rect.y *= scale_y;
            entry.value_ptr.uv_rect.width *= scale_x;
            entry.value_ptr.uv_rect.height *= scale_y;
        }

        self.width = new_width;
        self.height = new_height;

        // 重建 GPU 纹理 (销毁旧 -> 创建新 -> 上传 -> 转采样布局)
        if (self.texture) |old_tex| device.destroyTexture(old_tex);
        const new_tex = device.createTexture(new_width, new_height) orelse return error.TextureCreationFailed;
        self.texture = new_tex;
        device.updateTextureRegion(new_tex, 0, 0, new_width, new_height, self.pixels, new_width);
        device.prepareTextureForSampling(new_tex);
        self.texture_in_shader_mode = true;

        self.dirty = false;
        self.dirty_rects.clearRetainingCapacity();
    }
};

// ── Tests (shelf packing 逻辑, 无需 GPU 设备) ──────────────────────────────

test "allocateShelf places first glyph at origin" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, 64, 64);
    defer atlas.deinit();

    const pos = atlas.allocateShelf(10, 12).?;
    try std.testing.expectEqual(@as(u32, 0), pos.x);
    try std.testing.expectEqual(@as(u32, 0), pos.y);
    try std.testing.expectEqual(@as(usize, 1), atlas.shelves.items.len);
    // shelf height = glyph height + padding(1)
    try std.testing.expectEqual(@as(u32, 13), atlas.shelves.items[0].height);
    // x_cursor = glyph width + padding(1)
    try std.testing.expectEqual(@as(u32, 11), atlas.shelves.items[0].x_cursor);
}

test "allocateShelf fills same row then creates new shelf" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, 32, 64);
    defer atlas.deinit();

    // 两个 10x12 glyph: 10+1+10+1 = 22 <= 32, 同一 shelf
    _ = atlas.allocateShelf(10, 12).?;
    const p2 = atlas.allocateShelf(10, 12).?;
    try std.testing.expectEqual(@as(u32, 11), p2.x); // 0 + 10 + 1(padding)
    try std.testing.expectEqual(@as(u32, 0), p2.y);
    try std.testing.expectEqual(@as(usize, 1), atlas.shelves.items.len);

    // 第三个放不下同一行 (22+1+10=33 > 32), 创建新 shelf
    const p3 = atlas.allocateShelf(10, 12).?;
    try std.testing.expectEqual(@as(u32, 0), p3.x);
    // shelf0: y=0, height=12+1=13; 新 shelf y = 0 + 13 + 1(padding) = 14
    try std.testing.expectEqual(@as(u32, 14), p3.y);
    try std.testing.expectEqual(@as(usize, 2), atlas.shelves.items.len);
}

test "allocateShelf returns null when atlas full" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, 16, 16);
    defer atlas.deinit();

    // 填满: 16x16 atlas, 10x10 glyph (padding=1 -> 11x11 shelf)
    _ = atlas.allocateShelf(10, 10).?; // shelf at y=0, height=11
    // 下一 shelf 起始 y=11, 11+10+1=22 > 16 -> 返回 null
    try std.testing.expectEqual(@as(?GlyphAtlas.ShelfPos, null), atlas.allocateShelf(10, 10));
}

test "allocateShelf rejects glyph wider than atlas" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, 8, 64);
    defer atlas.deinit();

    // glyph 宽 10 + padding 1 = 11 > 8 (atlas 宽度)
    try std.testing.expectEqual(@as(?GlyphAtlas.ShelfPos, null), atlas.allocateShelf(10, 10));
}

test "grow UV scaling math: doubling dimensions halves UV coordinates" {
    // 模拟 grow() 中的 UV 重算逻辑 (不涉及 GPU 纹理重建)
    var atlas = try GlyphAtlas.init(std.testing.allocator, 64, 64);
    defer atlas.deinit();

    // 手动插入一个缓存 entry, 模拟已光栅化的 glyph
    const key = GlyphAtlas.GlyphKey.encode(1, 16.0, 400, 65);
    const entry = GlyphAtlas.AtlasEntry{
        .uv_rect = .{ .x = 0.0, .y = 0.0, .width = 10.0 / 64.0, .height = 12.0 / 64.0 },
        .width = 10,
        .height = 12,
        .bearing_x = 0,
        .bearing_y = 0,
        .advance = 10,
    };
    try atlas.cache.put(std.testing.allocator, key, entry);

    // 模拟 grow 的 UV 缩放 (宽高各翻倍)
    const new_width: u32 = 128;
    const new_height: u32 = 128;
    const scale_x = @as(f32, @floatFromInt(atlas.width)) / @as(f32, @floatFromInt(new_width));
    const scale_y = @as(f32, @floatFromInt(atlas.height)) / @as(f32, @floatFromInt(new_height));

    var it = atlas.cache.iterator();
    while (it.next()) |e| {
        e.value_ptr.uv_rect.x *= scale_x;
        e.value_ptr.uv_rect.y *= scale_y;
        e.value_ptr.uv_rect.width *= scale_x;
        e.value_ptr.uv_rect.height *= scale_y;
    }

    // 验证: UV 应减半 (因尺寸翻倍)
    const got = atlas.cache.get(key).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), got.uv_rect.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), got.uv_rect.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0 / 128.0), got.uv_rect.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0 / 128.0), got.uv_rect.height, 0.001);
}
