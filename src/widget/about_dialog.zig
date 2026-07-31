//! AboutDialog 控件 - 关于对话框
//!
//! 类似 GtkAboutDialog: 显示应用程序信息的对话框, 包括程序名称、版本、
//! 版权信息、开发者、文档作者、艺术设计者、翻译者、许可证和网站链接。
//!
//! 使用方法:
//! ```
//! var dlg = try AboutDialog.create(allocator, .{
//!     .program_name = "MyApp",
//!     .version = "1.0.0",
//!     .copyright = "Copyright (C) 2024",
//!     .comments = "一个很棒的应用程序",
//!     .website = "https://example.com",
//!     .authors = &[_][]const u8{"Author 1", "Author 2"},
//! });
//! dlg.show();
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const AboutDialog = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    program_name: []const u8 = "",
    version: []const u8 = "",
    copyright: []const u8 = "",
    comments: []const u8 = "",
    website: []const u8 = "",
    website_label: []const u8 = "",
    license: []const u8 = "",
    wrap_license: bool = true,

    authors: []const []const u8 = &.{},
    documenters: []const []const u8 = &.{},
    artists: []const []const u8 = &.{},
    translators: []const u8 = "",

    logo: ?*anyopaque = null,
    logo_width: u32 = 64,
    logo_height: u32 = 64,

    visible: bool = false,
    show_license: bool = false,

    on_close: ?*const fn (self: *AboutDialog) void = null,
    on_activate_link: ?*const fn (self: *AboutDialog, uri: []const u8) void = null,

    overlay_color: math.Color = math.Color.hex(0x000000AA),
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    title_color: math.Color = math.Color.hex(0xF8FAFCFF),
    text_color: math.Color = math.Color.hex(0xCBD5E1FF),
    link_color: math.Color = math.Color.hex(0x3B82F6FF),
    button_bg: math.Color = math.Color.hex(0x334155FF),
    button_hover: math.Color = math.Color.hex(0x475569FF),
    corner_radius: f32 = 14.0,
    dialog_width: f32 = 450,
    dialog_max_height: f32 = 500,
    title_size: f32 = 22.0,
    version_size: f32 = 14.0,
    text_size: f32 = 13.0,

    close_btn_hovered: bool = false,
    license_btn_hovered: bool = false,
    website_hovered: bool = false,

    scroll_offset: f32 = 0,
    license_content_height: f32 = 0,
    last_dw: f32 = 0,
    last_dh: f32 = 0,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        program_name: []const u8 = "",
        version: []const u8 = "",
        copyright: []const u8 = "",
        comments: []const u8 = "",
        website: []const u8 = "",
        website_label: []const u8 = "",
        license: []const u8 = "",
        wrap_license: bool = true,
        authors: []const []const u8 = &.{},
        documenters: []const []const u8 = &.{},
        artists: []const []const u8 = &.{},
        translators: []const u8 = "",
        logo: ?*anyopaque = null,
        logo_width: u32 = 64,
        logo_height: u32 = 64,
        on_close: ?*const fn (self: *AboutDialog) void = null,
        on_activate_link: ?*const fn (self: *AboutDialog, uri: []const u8) void = null,
    }) !*AboutDialog {
        const self = try allocator.create(AboutDialog);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .program_name = opts.program_name,
            .version = opts.version,
            .copyright = opts.copyright,
            .comments = opts.comments,
            .website = opts.website,
            .website_label = if (opts.website_label.len > 0) opts.website_label else opts.website,
            .license = opts.license,
            .wrap_license = opts.wrap_license,
            .authors = opts.authors,
            .documenters = opts.documenters,
            .artists = opts.artists,
            .translators = opts.translators,
            .logo = opts.logo,
            .logo_width = opts.logo_width,
            .logo_height = opts.logo_height,
            .on_close = opts.on_close,
            .on_activate_link = opts.on_activate_link,
        };
        self.base.accessibility = .{ .role = .dialog };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn show(self: *Self) void {
        self.visible = true;
        self.show_license = false;
        self.scroll_offset = 0;
        self.last_dw = self.dialog_width;
        self.last_dh = self.dialog_max_height;
        self.base.markDirty();
    }

    pub fn hide(self: *Self) void {
        self.visible = false;
        self.base.markDirty();
        if (self.on_close) |cb| cb(self);
    }

    pub fn setProgramName(self: *Self, name: []const u8) void {
        self.program_name = name;
        self.base.markDirty();
    }

    pub fn setVersion(self: *Self, version: []const u8) void {
        self.version = version;
        self.base.markDirty();
    }

    pub fn setCopyright(self: *Self, copyright: []const u8) void {
        self.copyright = copyright;
        self.base.markDirty();
    }

    pub fn setComments(self: *Self, comments: []const u8) void {
        self.comments = comments;
        self.base.markDirty();
    }

    pub fn setWebsite(self: *Self, website: []const u8) void {
        self.website = website;
        if (self.website_label.len == 0) {
            self.website_label = website;
        }
        self.base.markDirty();
    }

    pub fn setLicense(self: *Self, license: []const u8) void {
        self.license = license;
        self.base.markDirty();
    }

    const vtable = Widget.VTable{
        .type_name = "about_dialog",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        _ = w;
        return .{ .width = constraints.max_width, .height = constraints.max_height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.visible) return;

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;
        const r2d = ctx.renderer;

        r2d.fillRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.overlay_color) catch {};

        const dw = @min(self.dialog_width, rw - 40);
        const dh = @min(self.calcContentHeight(ctx) + 80, self.dialog_max_height);
        const dx = rx + (rw - dw) / 2;
        const dy = ry + (rh - dh) / 2;

        self.last_dw = dw;
        self.last_dh = dh;

        r2d.fillRoundedRect(.{ .x = dx, .y = dy, .width = dw, .height = dh }, self.corner_radius, self.bg_color) catch {};

        if (self.show_license) {
            self.paintLicense(ctx, dx, dy, dw, dh);
        } else {
            self.paintAbout(ctx, dx, dy, dw, dh);
        }
    }

    fn calcContentHeight(self: *Self, ctx: *PaintContext) f32 {
        var h: f32 = 20;

        if (self.program_name.len > 0) {
            const size = styled_text.measureText(ctx.allocator, self.program_name, .{ .font_size = self.title_size, .font_weight = 700 });
            h += size.height + 4;
        }
        if (self.version.len > 0) {
            const size = styled_text.measureText(ctx.allocator, self.version, .{ .font_size = self.version_size });
            h += size.height + 12;
        }
        if (self.comments.len > 0) {
            h += 30;
        }
        if (self.website.len > 0) {
            h += 24;
        }
        if (self.authors.len > 0) {
            h += 20 + @as(f32, @floatFromInt(self.authors.len)) * 18;
        }
        if (self.documenters.len > 0) {
            h += 20 + @as(f32, @floatFromInt(self.documenters.len)) * 18;
        }
        if (self.artists.len > 0) {
            h += 20 + @as(f32, @floatFromInt(self.artists.len)) * 18;
        }
        if (self.translators.len > 0) {
            h += 30;
        }
        if (self.copyright.len > 0) {
            h += 24;
        }
        if (self.license.len > 0) {
            h += 36;
        }

        return h + 16;
    }

    fn paintAbout(self: *Self, ctx: *PaintContext, dx: f32, dy: f32, dw: f32, dh: f32) void {
        const r2d = ctx.renderer;
        const padding: f32 = 24;
        var y = dy + padding;

        if (self.program_name.len > 0) {
            const size = styled_text.measureText(ctx.allocator, self.program_name, .{ .font_size = self.title_size, .font_weight = 700 });
            const x = dx + (dw - size.width) / 2;
            styled_text.drawText(r2d, ctx.allocator, self.program_name, x, y, .{
                .font_size = self.title_size,
                .font_weight = 700,
                .color = self.title_color,
            });
            y += size.height + 4;
        }

        if (self.version.len > 0) {
            const size = styled_text.measureText(ctx.allocator, self.version, .{ .font_size = self.version_size });
            const x = dx + (dw - size.width) / 2;
            styled_text.drawText(r2d, ctx.allocator, self.version, x, y, .{
                .font_size = self.version_size,
                .color = self.text_color,
            });
            y += size.height + 12;
        }

        if (self.comments.len > 0) {
            const text = self.comments;
            const max_w = dw - padding * 2;
            _ = max_w;
            const size = styled_text.measureText(ctx.allocator, text, .{ .font_size = self.text_size });
            const x = dx + (dw - size.width) / 2;
            styled_text.drawText(r2d, ctx.allocator, text, x, y, .{
                .font_size = self.text_size,
                .color = self.text_color,
            });
            y += size.height + 12;
        }

        if (self.website.len > 0) {
            const label = if (self.website_label.len > 0) self.website_label else self.website;
            const size = styled_text.measureText(ctx.allocator, label, .{ .font_size = self.text_size });
            const x = dx + (dw - size.width) / 2;
            styled_text.drawText(r2d, ctx.allocator, label, x, y, .{
                .font_size = self.text_size,
                .color = self.link_color,
            });
            y += size.height + 16;
        }

        if (self.authors.len > 0) {
            const label = "作者";
            const label_size = styled_text.measureText(ctx.allocator, label, .{ .font_size = self.text_size, .font_weight = 600 });
            styled_text.drawText(r2d, ctx.allocator, label, dx + padding, y, .{
                .font_size = self.text_size,
                .font_weight = 600,
                .color = self.title_color,
            });
            y += label_size.height + 4;
            for (self.authors) |author| {
                const size = styled_text.measureText(ctx.allocator, author, .{ .font_size = self.text_size });
                styled_text.drawText(r2d, ctx.allocator, author, dx + padding + 12, y, .{
                    .font_size = self.text_size,
                    .color = self.text_color,
                });
                y += size.height + 2;
            }
            y += 8;
        }

        if (self.documenters.len > 0) {
            const label = "文档作者";
            const label_size = styled_text.measureText(ctx.allocator, label, .{ .font_size = self.text_size, .font_weight = 600 });
            styled_text.drawText(r2d, ctx.allocator, label, dx + padding, y, .{
                .font_size = self.text_size,
                .font_weight = 600,
                .color = self.title_color,
            });
            y += label_size.height + 4;
            for (self.documenters) |doc| {
                const size = styled_text.measureText(ctx.allocator, doc, .{ .font_size = self.text_size });
                styled_text.drawText(r2d, ctx.allocator, doc, dx + padding + 12, y, .{
                    .font_size = self.text_size,
                    .color = self.text_color,
                });
                y += size.height + 2;
            }
            y += 8;
        }

        if (self.artists.len > 0) {
            const label = "美术设计";
            const label_size = styled_text.measureText(ctx.allocator, label, .{ .font_size = self.text_size, .font_weight = 600 });
            styled_text.drawText(r2d, ctx.allocator, label, dx + padding, y, .{
                .font_size = self.text_size,
                .font_weight = 600,
                .color = self.title_color,
            });
            y += label_size.height + 4;
            for (self.artists) |artist| {
                const size = styled_text.measureText(ctx.allocator, artist, .{ .font_size = self.text_size });
                styled_text.drawText(r2d, ctx.allocator, artist, dx + padding + 12, y, .{
                    .font_size = self.text_size,
                    .color = self.text_color,
                });
                y += size.height + 2;
            }
            y += 8;
        }

        if (self.translators.len > 0) {
            const label = "翻译者";
            const label_size = styled_text.measureText(ctx.allocator, label, .{ .font_size = self.text_size, .font_weight = 600 });
            styled_text.drawText(r2d, ctx.allocator, label, dx + padding, y, .{
                .font_size = self.text_size,
                .font_weight = 600,
                .color = self.title_color,
            });
            y += label_size.height + 4;
            const size = styled_text.measureText(ctx.allocator, self.translators, .{ .font_size = self.text_size });
            styled_text.drawText(r2d, ctx.allocator, self.translators, dx + padding + 12, y, .{
                .font_size = self.text_size,
                .color = self.text_color,
            });
            y += size.height + 8;
        }

        if (self.copyright.len > 0) {
            const size = styled_text.measureText(ctx.allocator, self.copyright, .{ .font_size = self.text_size });
            const x = dx + (dw - size.width) / 2;
            styled_text.drawText(r2d, ctx.allocator, self.copyright, x, dy + dh - padding - size.height - 40, .{
                .font_size = self.text_size,
                .color = self.text_color,
            });
        }

        const btn_y = dy + dh - padding - 32;
        if (self.license.len > 0) {
            const btn_w: f32 = 100;
            const btn_h: f32 = 32;
            const btn_x = dx + padding;
            const bg = if (self.license_btn_hovered) self.button_hover else self.button_bg;
            r2d.fillRoundedRect(.{ .x = btn_x, .y = btn_y, .width = btn_w, .height = btn_h }, 6, bg) catch {};
            const label = "许可证";
            const label_size = styled_text.measureText(ctx.allocator, label, .{ .font_size = self.text_size });
            styled_text.drawText(r2d, ctx.allocator, label, btn_x + (btn_w - label_size.width) / 2, btn_y + (btn_h - label_size.height) / 2, .{
                .font_size = self.text_size,
                .color = self.title_color,
            });
        }

        const close_btn_w: f32 = 80;
        const close_btn_h: f32 = 32;
        const close_btn_x = dx + dw - padding - close_btn_w;
        const close_bg = if (self.close_btn_hovered) self.button_hover else self.button_bg;
        r2d.fillRoundedRect(.{ .x = close_btn_x, .y = btn_y, .width = close_btn_w, .height = close_btn_h }, 6, close_bg) catch {};
        const close_label = "关闭";
        const close_size = styled_text.measureText(ctx.allocator, close_label, .{ .font_size = self.text_size });
        styled_text.drawText(r2d, ctx.allocator, close_label, close_btn_x + (close_btn_w - close_size.width) / 2, btn_y + (close_btn_h - close_size.height) / 2, .{
            .font_size = self.text_size,
            .color = self.title_color,
        });
    }

    fn paintLicense(self: *Self, ctx: *PaintContext, dx: f32, dy: f32, dw: f32, dh: f32) void {
        const r2d = ctx.renderer;
        const padding: f32 = 24;

        const title = "许可证";
        const title_size = styled_text.measureText(ctx.allocator, title, .{ .font_size = self.title_size, .font_weight = 700 });
        styled_text.drawText(r2d, ctx.allocator, title, dx + padding, dy + padding, .{
            .font_size = self.title_size,
            .font_weight = 700,
            .color = self.title_color,
        });

        const content_y = dy + padding + title_size.height + 16;
        const content_h = dh - padding * 2 - title_size.height - 48;
        const content_x = dx + padding;
        const content_w = dw - padding * 2;

        r2d.fillRect(.{ .x = content_x, .y = content_y, .width = content_w, .height = content_h }, math.Color.hex(0x0F172AFF)) catch {};

        const text_y = content_y - self.scroll_offset;
        if (self.license.len > 0) {
            styled_text.drawText(r2d, ctx.allocator, self.license, content_x + 8, text_y + 8, .{
                .font_size = self.text_size,
                .color = self.text_color,
            });
            const license_size = styled_text.measureText(ctx.allocator, self.license, .{ .font_size = self.text_size });
            self.license_content_height = license_size.height + 16;
        }

        const close_btn_w: f32 = 80;
        const close_btn_h: f32 = 32;
        const close_btn_x = dx + dw - padding - close_btn_w;
        const close_btn_y = dy + dh - padding - close_btn_h;
        const close_bg = if (self.close_btn_hovered) self.button_hover else self.button_bg;
        r2d.fillRoundedRect(.{ .x = close_btn_x, .y = close_btn_y, .width = close_btn_w, .height = close_btn_h }, 6, close_bg) catch {};
        const close_label = "返回";
        const close_size = styled_text.measureText(ctx.allocator, close_label, .{ .font_size = self.text_size });
        styled_text.drawText(r2d, ctx.allocator, close_label, close_btn_x + (close_btn_w - close_size.width) / 2, close_btn_y + (close_btn_h - close_size.height) / 2, .{
            .font_size = self.text_size,
            .color = self.title_color,
        });
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.visible) return .ignored;
        _ = ectx;

        const rx = w.rect.x;
        const ry = w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        const dw = self.last_dw;
        const dh = self.last_dh;
        const dx = rx + (rw - dw) / 2;
        const dy = ry + (rh - dh) / 2;

        switch (event.*) {
            .mouse_button => |mb| {
                const mx = @as(f32, @floatFromInt(mb.x));
                const my = @as(f32, @floatFromInt(mb.y));

                const close_btn_w: f32 = 80;
                const close_btn_h: f32 = 32;
                const close_btn_x = dx + dw - 24 - close_btn_w;
                const close_btn_y = dy + dh - 24 - close_btn_h;

                if (mx >= close_btn_x and mx <= close_btn_x + close_btn_w and
                    my >= close_btn_y and my <= close_btn_y + close_btn_h)
                {
                    if (mb.state == .pressed) {
                        if (self.show_license) {
                            self.show_license = false;
                            self.scroll_offset = 0;
                        } else {
                            self.hide();
                        }
                        w.markDirty();
                    }
                    return .handled;
                }

                if (!self.show_license and self.license.len > 0) {
                    const btn_w: f32 = 100;
                    const btn_h: f32 = 32;
                    const btn_x = dx + 24;
                    const btn_y = dy + dh - 24 - 32;
                    if (mx >= btn_x and mx <= btn_x + btn_w and
                        my >= btn_y and my <= btn_y + btn_h)
                    {
                        if (mb.state == .pressed) {
                            self.show_license = true;
                            w.markDirty();
                        }
                        return .handled;
                    }
                }

                if (!self.show_license and self.website.len > 0) {
                    const label = if (self.website_label.len > 0) self.website_label else self.website;
                    const size = styled_text.measureText(self.allocator, label, .{ .font_size = self.text_size });
                    const wx = dx + (dw - size.width) / 2;
                    var wy = dy + 24;
                    if (self.program_name.len > 0) {
                        const pn_size = styled_text.measureText(self.allocator, self.program_name, .{ .font_size = self.title_size, .font_weight = 700 });
                        wy += pn_size.height + 4;
                    }
                    if (self.version.len > 0) {
                        const v_size = styled_text.measureText(self.allocator, self.version, .{ .font_size = self.version_size });
                        wy += v_size.height + 12;
                    }
                    if (self.comments.len > 0) {
                        const c_size = styled_text.measureText(self.allocator, self.comments, .{ .font_size = self.text_size });
                        wy += c_size.height + 12;
                    }
                    if (mx >= wx and mx <= wx + size.width and my >= wy and my <= wy + size.height) {
                        if (mb.state == .pressed) {
                            if (self.on_activate_link) |cb| {
                                cb(self, self.website);
                            }
                        }
                        return .handled;
                    }
                }

                if (mx < dx or mx > dx + dw or my < dy or my > dy + dh) {
                    if (mb.state == .pressed) {
                        self.hide();
                    }
                    return .handled;
                }

                return .handled;
            },
            .mouse_move => |mm| {
                const mx = @as(f32, @floatFromInt(mm.x));
                const my = @as(f32, @floatFromInt(mm.y));

                const close_btn_w: f32 = 80;
                const close_btn_h: f32 = 32;
                const close_btn_x = dx + dw - 24 - close_btn_w;
                const close_btn_y = dy + dh - 24 - close_btn_h;

                const new_close_hovered = mx >= close_btn_x and mx <= close_btn_x + close_btn_w and
                    my >= close_btn_y and my <= close_btn_y + close_btn_h;

                var license_hovered = false;
                if (!self.show_license and self.license.len > 0) {
                    const btn_w: f32 = 100;
                    const btn_h: f32 = 32;
                    const btn_x = dx + 24;
                    const btn_y = dy + dh - 24 - 32;
                    license_hovered = mx >= btn_x and mx <= btn_x + btn_w and
                        my >= btn_y and my <= btn_y + btn_h;
                }

                if (new_close_hovered != self.close_btn_hovered or license_hovered != self.license_btn_hovered) {
                    self.close_btn_hovered = new_close_hovered;
                    self.license_btn_hovered = license_hovered;
                    w.markDirty();
                }

                return .handled;
            },
            .key => |key| {
                if (key.state == .pressed) {
                    if (key.key == .escape) {
                        if (self.show_license) {
                            self.show_license = false;
                            self.scroll_offset = 0;
                        } else {
                            self.hide();
                        }
                        w.markDirty();
                        return .handled;
                    }
                }
                return .handled;
            },
            .scroll => |scr| {
                if (self.show_license) {
                    if (scr.delta < 0) {
                        self.scroll_offset = @max(0, self.scroll_offset - 20);
                    } else {
                        const max_scroll = @max(0, self.license_content_height - (dh - 48 - 80));
                        self.scroll_offset = @min(max_scroll, self.scroll_offset + 20);
                    }
                    w.markDirty();
                    return .handled;
                }
                return .ignored;
            },
            else => return .ignored,
        }
    }
};
