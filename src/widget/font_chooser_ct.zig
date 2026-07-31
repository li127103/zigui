//! macOS 字体族枚举 - 通过 CoreText 枚举系统所有字体族
//!
//! 仅在 macOS 目标下被 font_chooser.zig 引入。不直接 @cImport CoreText.h
//! (新版 SDK 的 nullability 注解会让 Zig 的 translate-c 失败), 而是调用
//! coretext_backend.h 中声明的纯 C 函数, 由 .m 后端用 CoreText 实现。

const std = @import("std");
const ct = @cImport(@cInclude("coretext_backend.h"));

const EnumCtx = struct {
    alloc: std.mem.Allocator,
    list: *std.ArrayListUnmanaged([]const u8),
};

fn fontEnumCallback(name: [*c]const u8, name_len: c_int, context: ?*anyopaque) callconv(.c) void {
    const ctx: *EnumCtx = @ptrCast(@alignCast(context orelse return));
    const slice = name[0..@intCast(name_len)];
    const owned = ctx.alloc.dupe(u8, slice) catch return;
    ctx.list.append(ctx.alloc, owned) catch {
        ctx.alloc.free(owned);
    };
}

/// 枚举系统可用字体族, 追加到 list (owned slice)。
pub fn enumerate(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8)) void {
    var ctx = EnumCtx{ .alloc = allocator, .list = list };
    _ = ct.zigui_ct_enumerate_font_families(fontEnumCallback, &ctx);
}
