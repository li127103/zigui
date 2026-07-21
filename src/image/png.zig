//! PNG 解码器
//! 支持: 8-bit 深度, 色彩类型 Gray(0)/RGB(2)/GrayAlpha(4)/RGBA(6), 非交错
//! 输出统一为 RGBA8 (row-major)

const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    /// RGBA8 像素, row-major, len = width*height*4
    pixels: []u8,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const DecodeError = error{
    InvalidSignature,
    Truncated,
    UnsupportedFormat,
    InvalidChunkOrder,
    CorruptedData,
    OutOfMemory,
};

const signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

/// 从内存解码 PNG 为 RGBA8 Image
pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!Image {
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], &signature))
        return error.InvalidSignature;

    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var channels: usize = 0;
    var have_ihdr = false;

    var idat: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 };
    defer idat.deinit(allocator);

    // ── chunk 遍历 ──
    while (pos + 12 <= data.len) {
        const len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const ctype = data[pos + 4 .. pos + 8];
        pos += 8;
        if (pos + @as(usize, len) + 4 > data.len) return error.Truncated;
        const body = data[pos .. pos + len];
        pos += len + 4; // 跳过 CRC (不校验)

        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (len != 13) return error.CorruptedData;
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            const bit_depth = body[8];
            const color_type = body[9];
            const compression = body[10];
            const filter_method = body[11];
            const interlace = body[12];
            if (bit_depth != 8 or compression != 0 or filter_method != 0 or interlace != 0)
                return error.UnsupportedFormat;
            channels = switch (color_type) {
                0 => 1, // Gray
                2 => 3, // RGB
                4 => 2, // Gray + Alpha
                6 => 4, // RGBA
                else => return error.UnsupportedFormat,
            };
            have_ihdr = true;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            if (!have_ihdr) return error.InvalidChunkOrder;
            try idat.appendSlice(allocator, body);
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            break;
        }
        // 其余 chunk (gAMA/cHRM/tEXt/...) 跳过
    }

    if (!have_ihdr or idat.items.len == 0 or width == 0 or height == 0)
        return error.CorruptedData;

    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const stride = w * channels; // 每行像素字节数 (8-bit)
    const raw_len = h * (stride + 1); // 每行多 1 字节滤镜类型

    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);

    // ── zlib 解压 (PNG IDAT = zlib 流) ──
    // 注: 用 stream + fixed Writer 直写目标缓冲 (direct 路径),
    //     readSliceAll 走间接路径要求 >= 64KB 内部窗口缓冲
    var input: std.Io.Reader = .fixed(idat.items);
    var decomp: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    var out_writer: std.Io.Writer = .fixed(raw);
    const inflated = decomp.reader.stream(&out_writer, .limited(raw_len)) catch
        return error.CorruptedData;
    if (inflated != raw_len) return error.CorruptedData;

    // ── 反滤镜 + 转 RGBA8 ──
    const out = try allocator.alloc(u8, w * h * 4);
    errdefer allocator.free(out);

    var prev_row_start: usize = 0; // 上一行像素数据在 raw 中的起点
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row_start = y * (stride + 1);
        const filter = raw[row_start];
        const row = raw[row_start + 1 .. row_start + 1 + stride];
        const prev = if (y > 0) raw[prev_row_start .. prev_row_start + stride] else null;

        switch (filter) {
            0 => {}, // None
            1 => { // Sub
                var x: usize = channels;
                while (x < stride) : (x += 1) row[x] +%= row[x - channels];
            },
            2 => { // Up
                if (prev) |p| {
                    for (row, p) |*r, b| r.* +%= b;
                }
            },
            3 => { // Average
                for (0..stride) |x| {
                    const a: u32 = if (x >= channels) row[x - channels] else 0;
                    const b: u32 = if (prev) |p| p[x] else 0;
                    row[x] +%= @truncate((a + b) / 2);
                }
            },
            4 => { // Paeth
                for (0..stride) |x| {
                    const a: i32 = if (x >= channels) row[x - channels] else 0;
                    const b: i32 = if (prev) |p| p[x] else 0;
                    const c: i32 = if (x >= channels) (if (prev) |p| p[x - channels] else 0) else 0;
                    row[x] +%= @intCast(paethPredictor(a, b, c));
                }
            },
            else => return error.CorruptedData,
        }

        // 转 RGBA8
        const dst_row = out[y * w * 4 .. (y + 1) * w * 4];
        switch (channels) {
            1 => {
                for (0..w) |x| {
                    const v = row[x];
                    dst_row[x * 4] = v;
                    dst_row[x * 4 + 1] = v;
                    dst_row[x * 4 + 2] = v;
                    dst_row[x * 4 + 3] = 255;
                }
            },
            2 => {
                for (0..w) |x| {
                    const v = row[x * 2];
                    dst_row[x * 4] = v;
                    dst_row[x * 4 + 1] = v;
                    dst_row[x * 4 + 2] = v;
                    dst_row[x * 4 + 3] = row[x * 2 + 1];
                }
            },
            3 => {
                for (0..w) |x| {
                    dst_row[x * 4] = row[x * 3];
                    dst_row[x * 4 + 1] = row[x * 3 + 1];
                    dst_row[x * 4 + 2] = row[x * 3 + 2];
                    dst_row[x * 4 + 3] = 255;
                }
            },
            4 => @memcpy(dst_row, row),
            else => unreachable,
        }

        prev_row_start = row_start + 1;
    }

    return .{ .width = width, .height = height, .pixels = out };
}

fn paethPredictor(a: i32, b: i32, c: i32) i32 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

// ── Tests ──────────────────────────────────────────────────────────────────

/// 2x2 RGBA8, filter None: 红 绿 / 蓝 黄(a=128)
const fix_rgba = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d, 0x24, 0x00, 0x00, 0x00,
    0x14, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x1f, 0x0c, 0x81, 0x34, 0x10, 0x30, 0x34, 0x00, 0x00, 0x47, 0x4b, 0x08,
    0x79, 0x13, 0xf1, 0x60, 0xd0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
    0x44, 0xae, 0x42, 0x60, 0x82,
};

/// 2x2 RGB8, row0 filter Sub, row1 filter Up
const fix_rgb_filtered = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x02, 0x00, 0x00, 0x00, 0xfd, 0xd4, 0x9a, 0x73, 0x00, 0x00, 0x00,
    0x11, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xe4, 0x12, 0x91, 0x03,
    0x02, 0x26, 0x56, 0x30, 0x00, 0x00, 0x06, 0x79, 0x00, 0xb8, 0x64, 0xaf,
    0x67, 0x8f, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42,
    0x60, 0x82,
};

/// 1x1 Gray8 (0x80)
const fix_gray = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x00, 0x00, 0x00, 0x00, 0x3a, 0x7e, 0x9b, 0x55, 0x00, 0x00, 0x00,
    0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x68, 0x00, 0x00, 0x00,
    0x82, 0x00, 0x81, 0x77, 0xcd, 0x72, 0xb6, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};

test "png decode RGBA 2x2" {
    const alloc = std.testing.allocator;
    var img = try decode(alloc, &fix_rgba);
    defer img.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
    try std.testing.expectEqual(@as(usize, 16), img.pixels.len);
    // 红 绿 / 蓝 黄(a=128)
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, img.pixels[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.pixels[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 0, 128 }, img.pixels[12..16]);
}

test "png decode RGB with Sub/Up filters" {
    const alloc = std.testing.allocator;
    var img = try decode(alloc, &fix_rgb_filtered);
    defer img.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
    // row0: (10,20,30) (40,50,60); row1: (15,25,35) (45,55,65); alpha 补 255
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, img.pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 40, 50, 60, 255 }, img.pixels[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 15, 25, 35, 255 }, img.pixels[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 45, 55, 65, 255 }, img.pixels[12..16]);
}

test "png decode Gray 1x1" {
    const alloc = std.testing.allocator;
    var img = try decode(alloc, &fix_gray);
    defer img.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 1), img.width);
    try std.testing.expectEqual(@as(u32, 1), img.height);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x80, 255 }, img.pixels[0..4]);
}

test "png decode rejects bad signature" {
    const alloc = std.testing.allocator;
    const bad = fix_rgba;
    var corrupted = bad;
    corrupted[0] = 0x00;
    const result = decode(alloc, &corrupted);
    try std.testing.expectError(error.InvalidSignature, result);
}

test "png decode rejects truncated data" {
    const alloc = std.testing.allocator;
    const result = decode(alloc, fix_rgba[0..30]);
    try std.testing.expectError(error.Truncated, result);
}

test "paeth predictor" {
    // p=15, pa=5, pb=5, pc=0 → 返回 c=15
    try std.testing.expectEqual(@as(i32, 15), paethPredictor(10, 20, 15));
    // p=30, pa=20, pb=10, pc=20 → pb 最小返回 b=20
    try std.testing.expectEqual(@as(i32, 20), paethPredictor(10, 20, 0));
    try std.testing.expectEqual(@as(i32, 0), paethPredictor(0, 0, 0));
}
