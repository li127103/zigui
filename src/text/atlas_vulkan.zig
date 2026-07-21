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
        _ = device;
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
        const pos = self.allocateShelf(gw, gh) orelse {
            return error.AtlasFull;
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
};
