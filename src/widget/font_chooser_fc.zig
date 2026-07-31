//! Linux 字体族枚举 - 通过 fontconfig 枚举系统所有字体族
//!
//! 仅在 Linux 目标下被 font_chooser.zig 引入 (build.zig 中 fontconfig 也仅 Linux 链接)。

const std = @import("std");
const fc = @cImport(@cInclude("fontconfig/fontconfig.h"));

/// 枚举系统可用字体族, 追加到 list (去重后的 owned slice)。
pub fn enumerate(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8)) void {
    const config = fc.FcInitLoadConfigAndFonts();
    if (config == null) return;
    defer fc.FcConfigDestroy(config);

    const pat = fc.FcPatternCreate();
    if (pat == null) return;
    defer fc.FcPatternDestroy(pat);

    const null_ptr: [*c]u8 = null;
    const os = fc.FcObjectSetBuild(fc.FC_FAMILY, null_ptr);
    if (os == null) return;
    defer fc.FcObjectSetDestroy(os);

    const font_set = fc.FcFontList(config, pat, os);
    if (font_set == null) return;
    defer fc.FcFontSetDestroy(font_set);

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var i: c_int = 0;
    while (i < font_set.*.nfont) : (i += 1) {
        var family: [*c]u8 = null;
        const idx: usize = @intCast(i);
        if (fc.FcPatternGetString(font_set.*.fonts[idx], fc.FC_FAMILY, 0, @ptrCast(&family)) != fc.FcResultMatch) continue;
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(family)), 0);
        if (name.len == 0) continue;

        const gop = seen.getOrPut(name) catch continue;
        if (!gop.found_existing) {
            const owned = allocator.dupe(u8, name) catch continue;
            list.append(allocator, owned) catch {
                allocator.free(owned);
                continue;
            };
        }
    }
}
