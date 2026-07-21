//! 文本引擎 - 字体管理

pub const FontWeight = enum(u16) {
    thin = 100,
    extra_light = 200,
    light = 300,
    regular = 400,
    medium = 500,
    semi_bold = 600,
    bold = 700,
    extra_bold = 800,
    black = 900,
};

pub const FontStyle = enum { normal, italic, oblique };

pub const FontDesc = struct {
    family: []const u8,
    size: f32,
    weight: FontWeight = .regular,
    style: FontStyle = .normal,
};

pub const FontFace = struct {
    id: u16,
    family: []const u8,
    weight: FontWeight,
    style: FontStyle,
};

pub const FontCollection = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FontCollection {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FontCollection) void {
        _ = self;
    }

    pub fn loadFontFile(self: *FontCollection, path: []const u8) !void {
        _ = self;
        _ = path;
        return error.NotImplemented;
    }

    pub fn resolve(self: *FontCollection, desc: FontDesc) ?*FontFace {
        _ = self;
        _ = desc;
        return null;
    }
};

const std = @import("std");
