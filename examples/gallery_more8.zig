//! zigui gallery - 选择器 / 菜单 / 数据控件 (More 8)
//!
//! 演示:
//!   - Calendar         月历
//!   - Scale            带刻度滑块
//!   - LevelBar         等级指示器 (连续 / 离散)
//!   - MenuBar          顶部菜单栏 (含 Menu)
//!   - SplitButton      分割按钮 (主按钮 + 下拉气泡)
//!   - Popover          弹出气泡
//!   - ColorChooserDialog   颜色选择对话框 (遮罩式)
//!   - FontChooserDialog    字体选择对话框 (遮罩式)
//!   - EmojiChooser        表情选择对话框 (遮罩式)
//!
//! 运行:  zig build run-gallery-more8

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Button = zigui.button.Button;
const Calendar = zigui.calendar.Calendar;
const Scale = zigui.scale.Scale;
const LevelBar = zigui.level_bar.LevelBar;
const MenuBar = zigui.menu_bar.MenuBar;
const Menu = zigui.menu.Menu;
const MenuItem = zigui.menu.MenuItem;
const SplitButton = zigui.split_button.SplitButton;
const Popover = zigui.popover.Popover;
const ColorChooserDialog = zigui.color_chooser.ColorChooserDialog;
const FontChooserDialog = zigui.font_chooser.FontChooserDialog;
const FontDesc = zigui.font_chooser.FontDesc;
const EmojiChooser = zigui.emoji_chooser.EmojiChooser;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

// 需要回调访问的控件
var g_calendar_label: ?*Label = null;
var g_calendar_buf: [128]u8 = undefined;
var g_scale_label: ?*Label = null;
var g_scale_buf: [128]u8 = undefined;
var g_levelbar: ?*LevelBar = null;
var g_level_val: f32 = 0.3;
var g_level_label: ?*Label = null;
var g_level_buf: [128]u8 = undefined;

var g_color_dlg: ?*ColorChooserDialog = null;
var g_color_label: ?*Label = null;
var g_color_buf: [128]u8 = undefined;
var g_font_dlg: ?*FontChooserDialog = null;
var g_font_label: ?*Label = null;
var g_font_buf: [128]u8 = undefined;
var g_emoji_dlg: ?*EmojiChooser = null;
var g_emoji_label: ?*Label = null;
var g_emoji_buf: [128]u8 = undefined;

var g_pop: ?*Popover = null;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - More (8)",
        .width = 760,
        .height = 2400,
    });
    defer app.deinit();

    try buildTree(allocator);
    defer destroyTree();

    try app.run(&drawFrame);
    styled_text.deinitFontCache();
}

fn section(alloc: std.mem.Allocator, root: *Container, name: []const u8) !void {
    const cap = try Label.create(alloc, name, .{ .font_size = 15, .font_weight = 600, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &cap.base);
}

fn buildTree(alloc: std.mem.Allocator) !void {
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .column,
        .padding = .{ .left = 24, .top = 20, .right = 24, .bottom = 20 },
        .gap = .{ .width = 0, .height = 14 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "More (8) — 选择器 / 菜单 / 数据控件", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    // ── Calendar ────────────────────────────────────────────────────────────
    try section(alloc, root, "Calendar (月历)");
    const cal = try Calendar.create(alloc, .{ .year = 2026, .month = 7, .on_change = onCalendarChange });
    try root.base.addChild(alloc, &cal.base);
    g_calendar_label = try Label.create(alloc, "selected: (none)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_calendar_label.?.base);

    // ── Scale ───────────────────────────────────────────────────────────────
    try section(alloc, root, "Scale (带刻度滑块)");
    const sc = try Scale.create(alloc, .{ .value = 0.4, .min = 0, .max = 1, .step = 0.05, .tick_count = 11, .on_change = onScaleChange });
    try root.base.addChild(alloc, &sc.base);
    g_scale_label = try Label.create(alloc, "value: 0.40", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_scale_label.?.base);

    // ── LevelBar ────────────────────────────────────────────────────────────
    try section(alloc, root, "LevelBar (等级指示器)");
    const lb1 = try LevelBar.create(alloc, .{ .value = 0.7, .mode = .continuous });
    try root.base.addChild(alloc, &lb1.base);
    const lb2 = try LevelBar.create(alloc, .{ .value = 0.6, .mode = .discrete, .num_blocks = 5 });
    try root.base.addChild(alloc, &lb2.base);
    g_levelbar = lb1;
    const lb_btn = try Button.create(alloc, "Cycle Level", .{ .on_click = onLevelCycle });
    try root.base.addChild(alloc, &lb_btn.base);
    g_level_label = try Label.create(alloc, "continuous value: 0.30", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_level_label.?.base);

    // ── MenuBar ─────────────────────────────────────────────────────────────
    try section(alloc, root, "MenuBar (菜单栏)");
    const file_menu = try Menu.create(alloc, .{});
    try file_menu.addItem(MenuItem{ .label = "New" });
    try file_menu.addItem(MenuItem{ .label = "Open" });
    try file_menu.addSeparator();
    try file_menu.addItem(MenuItem{ .label = "Quit" });
    const edit_menu = try Menu.create(alloc, .{});
    try edit_menu.addItem(MenuItem{ .label = "Cut" });
    try edit_menu.addItem(MenuItem{ .label = "Copy" });
    try edit_menu.addItem(MenuItem{ .label = "Paste" });
    const mb = try MenuBar.create(alloc, .{});
    try mb.addMenu("File", file_menu);
    try mb.addMenu("Edit", edit_menu);
    try root.base.addChild(alloc, &mb.base);
    const mb_hint = try Label.create(alloc, "点击菜单标题展开下拉", .{ .font_size = 12, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &mb_hint.base);

    // ── SplitButton (固定 tile，保持定位坐标一致) ─────────────────────────────
    try section(alloc, root, "SplitButton (分割按钮)");
    const sb_tile = try Container.create(alloc, .{ .bg_color = math.Color.hex(0x00000000), .direction = .column });
    sb_tile.base.layout_style.width = .{ .px = 300 };
    sb_tile.base.layout_style.height = .{ .px = 160 };
    const sb = try SplitButton.newWithLabel(alloc, "Action");
    try sb_tile.base.addChild(alloc, &sb.base);
    const sb_pop = try Popover.create(alloc, .{ .width = .{ .px = 200 } });
    const sb_pop_label = try Label.create(alloc, "SplitButton popover content", .{ .font_size = 13, .color = math.Color.hex(0xF8FAFCFF) });
    try sb_pop.base.addChild(alloc, &sb_pop_label.base);
    sb.setPopover(sb_pop);
    try sb_tile.base.addChild(alloc, &sb_pop.base);
    try root.base.addChild(alloc, &sb_tile.base);

    // ── Popover (固定 tile) ─────────────────────────────────────────────────
    try section(alloc, root, "Popover (弹出气泡)");
    const pop_tile = try Container.create(alloc, .{ .bg_color = math.Color.hex(0x00000000), .direction = .column });
    pop_tile.base.layout_style.width = .{ .px = 320 };
    pop_tile.base.layout_style.height = .{ .px = 200 };
    const pop_btn = try Button.create(alloc, "Open Popover", .{ .on_click = onTogglePop });
    try pop_tile.base.addChild(alloc, &pop_btn.base);
    const pop = try Popover.create(alloc, .{ .relative_to = &pop_btn.base, .width = .{ .px = 220 } });
    const pop_label = try Label.create(alloc, "Popover bubble content", .{ .font_size = 13, .color = math.Color.hex(0xF8FAFCFF) });
    try pop.base.addChild(alloc, &pop_label.base);
    g_pop = pop;
    try pop_tile.base.addChild(alloc, &pop.base);
    try root.base.addChild(alloc, &pop_tile.base);

    // ── ColorChooserDialog (遮罩式, 默认隐藏) ─────────────────────────────────
    try section(alloc, root, "ColorChooserDialog (颜色选择)");
    const color_btn = try Button.create(alloc, "Show Color Chooser", .{ .on_click = onToggleColor });
    try root.base.addChild(alloc, &color_btn.base);
    const color_tile = try Container.create(alloc, .{ .bg_color = math.Color.hex(0x00000000), .direction = .column });
    color_tile.base.layout_style.width = .{ .px = 460 };
    color_tile.base.layout_style.height = .{ .px = 560 };
    const color_dlg = try ColorChooserDialog.create(alloc, .{
        .initial_color = math.Color.hex(0x3B82F6FF),
        .on_color_selected = onColorChosen,
    });
    g_color_dlg = color_dlg;
    try color_tile.base.addChild(alloc, &color_dlg.base);
    try root.base.addChild(alloc, &color_tile.base);
    g_color_label = try Label.create(alloc, "picked: (none)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_color_label.?.base);

    // ── FontChooserDialog (遮罩式) ───────────────────────────────────────────
    try section(alloc, root, "FontChooserDialog (字体选择)");
    const font_btn = try Button.create(alloc, "Show Font Chooser", .{ .on_click = onToggleFont });
    try root.base.addChild(alloc, &font_btn.base);
    const font_tile = try Container.create(alloc, .{ .bg_color = math.Color.hex(0x00000000), .direction = .column });
    font_tile.base.layout_style.width = .{ .px = 640 };
    font_tile.base.layout_style.height = .{ .px = 540 };
    const font_dlg = try FontChooserDialog.create(alloc, .{
        .initial_family = "Sans",
        .initial_size = 14,
        .on_font_selected = onFontChosen,
    });
    g_font_dlg = font_dlg;
    try font_tile.base.addChild(alloc, &font_dlg.base);
    try root.base.addChild(alloc, &font_tile.base);
    g_font_label = try Label.create(alloc, "picked: (none)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_font_label.?.base);

    // ── EmojiChooser (遮罩式) ────────────────────────────────────────────────
    try section(alloc, root, "EmojiChooser (表情选择)");
    const emoji_btn = try Button.create(alloc, "Show Emoji Chooser", .{ .on_click = onToggleEmoji });
    try root.base.addChild(alloc, &emoji_btn.base);
    const emoji_tile = try Container.create(alloc, .{ .bg_color = math.Color.hex(0x00000000), .direction = .column });
    emoji_tile.base.layout_style.width = .{ .px = 360 };
    emoji_tile.base.layout_style.height = .{ .px = 380 };
    const emoji_dlg = try EmojiChooser.create(alloc, .{
        .panel_width = 320,
        .panel_height = 340,
        .on_emoji_selected = onEmojiChosen,
    });
    g_emoji_dlg = emoji_dlg;
    try emoji_tile.base.addChild(alloc, &emoji_dlg.base);
    try root.base.addChild(alloc, &emoji_tile.base);
    g_emoji_label = try Label.create(alloc, "picked: (none)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_emoji_label.?.base);

    g_root = root;
    g_tree_alloc = alloc;
}

// ── 回调 ─────────────────────────────────────────────────────────────────────

fn onCalendarChange(self: *Calendar, year: u16, month: u4, day: u8) void {
    _ = self;
    if (g_calendar_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_calendar_buf, "selected: {d}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch "selected";
    }
}

fn onScaleChange(self: *Scale, value: f32) void {
    _ = self;
    if (g_scale_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_scale_buf, "value: {d:.2}", .{value}) catch "value";
    }
}

fn onLevelCycle(_: *Button) void {
    g_level_val = if (g_level_val >= 0.9) 0.3 else g_level_val + 0.3;
    if (g_levelbar) |lb| lb.setValue(g_level_val);
    if (g_level_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_level_buf, "continuous value: {d:.2}", .{g_level_val}) catch "value";
    }
}

fn onTogglePop(_: *Button) void {
    if (g_pop) |p| {
        if (p.is_open) p.popdown() else p.popup();
    }
}

fn onToggleColor(_: *Button) void {
    if (g_color_dlg) |d| d.visible = !d.visible;
}
fn onColorChosen(self: *ColorChooserDialog, color: math.Color) void {
    _ = self;
    if (g_color_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_color_buf, "picked: #{X:0>2}{X:0>2}{X:0>2}", .{ color.r, color.g, color.b }) catch "picked";
    }
}

fn onToggleFont(_: *Button) void {
    if (g_font_dlg) |d| d.visible = !d.visible;
}
fn onFontChosen(self: *FontChooserDialog, desc: FontDesc) void {
    _ = self;
    if (g_font_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_font_buf, "picked: {s} {d}", .{ desc.family, desc.size }) catch "picked";
    }
}

fn onToggleEmoji(_: *Button) void {
    if (g_emoji_dlg) |d| d.visible = !d.visible;
}
fn onEmojiChosen(self: *EmojiChooser, emoji: []const u8) void {
    _ = self;
    if (g_emoji_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_emoji_buf, "picked: {s}", .{emoji}) catch "picked";
    }
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

fn drawFrame(app: *zigui.app.App) void {
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    root.base.layout_style.width = .{ .px = w };
    root.base.layout_style.height = .{ .px = h };

    var ctx = widget.PaintContext{ .renderer = app.getRenderer(), .theme = &theme_dark, .allocator = app.allocator };
    root.base.performLayout(&ctx, .{ .max_width = w, .max_height = h });
    dispatchInput(app);
    root.base.paintTree(&ctx);
}

fn dispatchInput(app: *zigui.app.App) void {
    var ectx = widget.EventContext{ .mouse_x = app.mouse_x, .mouse_y = app.mouse_y };
    const mx: i32 = @intFromFloat(app.mouse_x);
    const my: i32 = @intFromFloat(app.mouse_y);
    var ev_move = pal.Event{ .mouse_move = .{ .window_id = 0, .x = mx, .y = my } };
    _ = g_root.?.base.dispatchEvent(&ev_move, &ectx);
    if (app.mouse_clicked) {
        var ev = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .left, .state = .pressed, .x = mx, .y = my } };
        _ = g_root.?.base.dispatchEvent(&ev, &ectx);
    }
    if (!app.mouse_down and g_prev_mouse_down) {
        var ev = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .left, .state = .released, .x = mx, .y = my } };
        _ = g_root.?.base.dispatchEvent(&ev, &ectx);
    }
    g_prev_mouse_down = app.mouse_down;

    if (app.key_hit) |key| {
        var ev = pal.Event{ .key = .{ .window_id = 0, .state = .pressed, .key = key, .modifiers = app.key_mods } };
        _ = g_root.?.base.dispatchEvent(&ev, &ectx);
    }

    for (app.typedCodepoints()) |cp| {
        var ev = pal.Event{ .text_input = .{ .window_id = 0, .codepoint = cp } };
        _ = g_root.?.base.dispatchEvent(&ev, &ectx);
    }
}
