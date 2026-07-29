//! 打印核心数据结构
//!
//! GTK 对应: GtkPaperSize / GtkPrintSettings / GtkPageSetup
//!
//! 三个独立结构体：
//! - PaperSize    — 纸张尺寸（预设 + 自定义，单位 mm）
//! - PrintSettings — 打印设置（打印机、份数、分页、范围、方向、颜色模式、双面等）
//! - PageSetup    — 页面设置（方向 + 纸张 + 四边 margin）

const std = @import("std");
const math = @import("../math.zig");

// ──────────────────────────────────────────────────────────────────────────────
// Unit 辅助
// ──────────────────────────────────────────────────────────────────────────────

pub const Unit = enum {
    mm, // 毫米
    inch, // 英寸
    point, // 1/72 英寸
    pixel, // 假设 96 DPI
};

fn unitToMm(value: f32, unit: Unit) f32 {
    return switch (unit) {
        .mm => value,
        .inch => value * 25.4,
        .point => value * 25.4 / 72.0,
        .pixel => value * 25.4 / 96.0,
    };
}
fn mmToUnit(mm: f32, unit: Unit) f32 {
    return switch (unit) {
        .mm => mm,
        .inch => mm / 25.4,
        .point => mm * 72.0 / 25.4,
        .pixel => mm * 96.0 / 25.4,
    };
}

// ──────────────────────────────────────────────────────────────────────────────
// PaperSize
// ──────────────────────────────────────────────────────────────────────────────

pub const PaperSize = struct {
    name: []const u8,
    display_name: []const u8,
    width_mm: f32,
    height_mm: f32,
    is_custom: bool = false,

    // 常见预设 (国际 + 北美)
    pub const A3 = PaperSize{ .name = "iso_a3", .display_name = "A3", .width_mm = 297, .height_mm = 420 };
    pub const A4 = PaperSize{ .name = "iso_a4", .display_name = "A4", .width_mm = 210, .height_mm = 297 };
    pub const A5 = PaperSize{ .name = "iso_a5", .display_name = "A5", .width_mm = 148, .height_mm = 210 };
    pub const A6 = PaperSize{ .name = "iso_a6", .display_name = "A6", .width_mm = 105, .height_mm = 148 };
    pub const B4 = PaperSize{ .name = "iso_b4", .display_name = "B4 (JIS)", .width_mm = 257, .height_mm = 364 };
    pub const B5 = PaperSize{ .name = "iso_b5", .display_name = "B5 (JIS)", .width_mm = 182, .height_mm = 257 };
    pub const Letter = PaperSize{ .name = "na_letter", .display_name = "Letter", .width_mm = 215.9, .height_mm = 279.4 };
    pub const Legal = PaperSize{ .name = "na_legal", .display_name = "Legal", .width_mm = 215.9, .height_mm = 355.6 };
    pub const Tabloid = PaperSize{ .name = "na_ledger", .display_name = "Tabloid/Ledger", .width_mm = 279.4, .height_mm = 431.8 };
    pub const Executive = PaperSize{ .name = "na_executive", .display_name = "Executive", .width_mm = 184.15, .height_mm = 266.7 };
    pub const EnvelopeDL = PaperSize{ .name = "env_dl", .display_name = "Envelope DL", .width_mm = 110, .height_mm = 220 };

    pub const PRESETS = &[_]PaperSize{
        A3, A4, A5, A6, B4, B5, Letter, Legal, Tabloid, Executive, EnvelopeDL,
    };

    pub fn getDefault() PaperSize {
        return A4;
    }

    pub fn getPreset(name: []const u8) ?PaperSize {
        for (PRESETS) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    pub fn custom(name: []const u8, display_name: []const u8, width: f32, height: f32, unit: Unit) PaperSize {
        return .{
            .name = name,
            .display_name = display_name,
            .width_mm = unitToMm(width, unit),
            .height_mm = unitToMm(height, unit),
            .is_custom = true,
        };
    }

    pub fn getWidth(self: *const PaperSize, unit: Unit) f32 {
        return mmToUnit(self.width_mm, unit);
    }

    pub fn getHeight(self: *const PaperSize, unit: Unit) f32 {
        return mmToUnit(self.height_mm, unit);
    }

    pub fn isEqual(self: *const PaperSize, other: *const PaperSize) bool {
        return (self.width_mm == other.width_mm and self.height_mm == other.height_mm) or
            std.mem.eql(u8, self.name, other.name);
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// PrintSettings
// ──────────────────────────────────────────────────────────────────────────────

pub const PrintPages = enum {
    all,
    current,
    ranges,
    selection,
};

pub const PageOrientation = enum {
    portrait,
    landscape,
    reverse_portrait,
    reverse_landscape,
};

pub const PrintQuality = enum {
    draft,
    normal,
    high,
};

pub const PrintDuplexMode = enum {
    simplex,
    horizontal, // 长边翻页 (duplex long edge)
    vertical, // 短边翻页 (duplex short edge)
};

pub const PrintColorMode = enum {
    color,
    monochrome,
    grayscale,
};

pub const PrintPageRange = struct {
    start: u32,
    end: u32,
};

pub const PrintSettings = struct {
    printer: []const u8 = "default",
    num_copies: u32 = 1,
    collate: bool = true,
    reverse: bool = false,

    pages: PrintPages = .all,
    page_ranges: std.ArrayListUnmanaged(PrintPageRange) = .empty,

    orientation: PageOrientation = .portrait,

    color_mode: PrintColorMode = .color,
    duplex: PrintDuplexMode = .simplex,
    quality: PrintQuality = .normal,
    resolution_dpi: u32 = 300,

    scale: f32 = 1.0,
    use_media_size: bool = true,
    paper_size: PaperSize = PaperSize.getDefault(),

    n_up: u32 = 1,
    n_up_layout: enum {
        left_to_right_top_to_bottom,
        left_to_right_bottom_to_top,
        right_to_left_top_to_bottom,
        right_to_left_bottom_to_top,
    } = .left_to_right_top_to_bottom,

    // 输出文件 (save to PDF 场景)
    output_file: []const u8 = "",
    output_format: enum { native, pdf, ps, svg } = .native,

    pub fn create(allocator: std.mem.Allocator) !*PrintSettings {
        const self = try allocator.create(PrintSettings);
        self.* = .{ .printer = "default" };
        return self;
    }

    pub fn destroy(self: *PrintSettings, allocator: std.mem.Allocator) void {
        self.page_ranges.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setCopies(self: *PrintSettings, n: u32) void {
        self.num_copies = @max(1, n);
    }

    pub fn addPageRange(self: *PrintSettings, allocator: std.mem.Allocator, start: u32, end: u32) !void {
        try self.page_ranges.append(allocator, .{ .start = start, .end = end });
    }

    pub fn setResolutionDpi(self: *PrintSettings, dpi: u32) void {
        self.resolution_dpi = @max(72, dpi);
    }

    pub fn setOrientation(self: *PrintSettings, o: PageOrientation) void {
        self.orientation = o;
    }

    pub fn setColorMode(self: *PrintSettings, c: PrintColorMode) void {
        self.color_mode = c;
    }

    pub fn setDuplex(self: *PrintSettings, d: PrintDuplexMode) void {
        self.duplex = d;
    }

    pub fn setPaperSize(self: *PrintSettings, ps: PaperSize) void {
        self.paper_size = ps;
    }

    // ── 简化的 KV 序列化 ──────────────────────────────────────────────────────

    pub fn saveToFile(self: *const PrintSettings, allocator: std.mem.Allocator, key: []const u8) !void {
        _ = self;
        _ = allocator;
        _ = key;
        // TODO: 通过 cJSON/KV 文件实现
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, key: []const u8) !*PrintSettings {
        _ = key;
        return try create(allocator);
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// PageSetup
// ──────────────────────────────────────────────────────────────────────────────

pub const PageSetup = struct {
    orientation: PageOrientation = .portrait,
    paper_size: PaperSize = PaperSize.getDefault(),

    /// 页边距（单位 mm）
    margin_top_mm: f32 = 20,
    margin_bottom_mm: f32 = 20,
    margin_left_mm: f32 = 20,
    margin_right_mm: f32 = 20,

    pub fn create() PageSetup {
        return .{};
    }

    pub fn setOrientation(self: *PageSetup, o: PageOrientation) void {
        self.orientation = o;
    }

    pub fn getOrientation(self: *PageSetup) PageOrientation {
        return self.orientation;
    }

    pub fn setPaperSize(self: *PageSetup, ps: PaperSize) void {
        self.paper_size = ps;
    }

    pub fn getPaperSize(self: *PageSetup) PaperSize {
        return self.paper_size;
    }

    pub fn setMargins(self: *PageSetup, top: f32, bottom: f32, left: f32, right: f32, unit: Unit) void {
        self.margin_top_mm = unitToMm(top, unit);
        self.margin_bottom_mm = unitToMm(bottom, unit);
        self.margin_left_mm = unitToMm(left, unit);
        self.margin_right_mm = unitToMm(right, unit);
    }

    pub fn getTopMargin(self: *PageSetup, unit: Unit) f32 {
        return mmToUnit(self.margin_top_mm, unit);
    }
    pub fn getBottomMargin(self: *PageSetup, unit: Unit) f32 {
        return mmToUnit(self.margin_bottom_mm, unit);
    }
    pub fn getLeftMargin(self: *PageSetup, unit: Unit) f32 {
        return mmToUnit(self.margin_left_mm, unit);
    }
    pub fn getRightMargin(self: *PageSetup, unit: Unit) f32 {
        return mmToUnit(self.margin_right_mm, unit);
    }

    /// 计算纸张有效宽度（减去左右边距，单位 mm）
    fn getInnerWidthMm(self: *PageSetup) f32 {
        const w = self.orientedWidthMm();
        return w - (self.margin_left_mm + self.margin_right_mm);
    }

    fn getInnerHeightMm(self: *PageSetup) f32 {
        const h = self.orientedHeightMm();
        return h - (self.margin_top_mm + self.margin_bottom_mm);
    }

    fn orientedWidthMm(self: *PageSetup) f32 {
        return switch (self.orientation) {
            .portrait, .reverse_portrait => self.paper_size.width_mm,
            .landscape, .reverse_landscape => self.paper_size.height_mm,
        };
    }

    fn orientedHeightMm(self: *PageSetup) f32 {
        return switch (self.orientation) {
            .portrait, .reverse_portrait => self.paper_size.height_mm,
            .landscape, .reverse_landscape => self.paper_size.width_mm,
        };
    }

    pub fn getPageWidth(self: *PageSetup, unit: Unit) f32 {
        return mmToUnit(self.orientedWidthMm(), unit);
    }

    pub fn getPageHeight(self: *PageSetup, unit: Unit) f32 {
        return mmToUnit(self.orientedHeightMm(), unit);
    }

    pub fn getInnerWidth(self: *PageSetup, unit: Unit) f32 {
        return mmToUnit(self.getInnerWidthMm(), unit);
    }

    pub fn getInnerHeight(self: *PageSetup, unit: Unit) f32 {
        return mmToUnit(self.getInnerHeightMm(), unit);
    }
};
