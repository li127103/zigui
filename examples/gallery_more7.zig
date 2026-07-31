//! zigui gallery - 容器/输入/选择控件 (More 7)
//!
//! 演示:
//!   - Notebook        标签页容器
//!   - Expander        可折叠面板
//!   - SpinButton      数值步进器
//!   - Spinner         加载动画
//!   - ProgressBar     进度条
//!   - InfoBar         信息栏
//!   - Revealer        可展开/收起容器
//!   - SearchEntry     搜索输入框
//!   - RadioButton     单选按钮 (RadioGroup)
//!   - ToggleButton    切换按钮
//!   - Slider          滑动条
//!   - DropDown        下拉选择
//!   - ListBox         列表框
//!   - AboutDialog     关于对话框 (嵌入固定尺寸 tile)
//!
//! 运行:  zig build run-gallery-more7

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Button = zigui.button.Button;
const Notebook = zigui.notebook.Notebook;
const Expander = zigui.expander.Expander;
const SpinButton = zigui.spin_button.SpinButton;
const Spinner = zigui.spinner.Spinner;
const ProgressBar = zigui.progress_bar.ProgressBar;
const InfoBar = zigui.info_bar.InfoBar;
const Revealer = zigui.revealer.Revealer;
const SearchEntry = zigui.search_entry.SearchEntry;
const RadioButton = zigui.radio_button.RadioButton;
const RadioGroup = zigui.radio_button.RadioGroup;
const ToggleButton = zigui.toggle_button.ToggleButton;
const Slider = zigui.slider.Slider;
const DropDown = zigui.drop_down.DropDown;
const ListBox = zigui.list_box.ListBox;
const AboutDialog = zigui.about_dialog.AboutDialog;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

// 需要回调访问的控件 / 分组
var g_revealer: ?*Revealer = null;
var g_spinner: ?*Spinner = null;
var g_about: ?*AboutDialog = null;

// 结果展示标签 + 长生命周期缓冲 (Label.text 必须指向稳定内存)
var g_spin_label: ?*Label = null;
var g_spin_buf: [128]u8 = undefined;
var g_slider_label: ?*Label = null;
var g_slider_buf: [128]u8 = undefined;
var g_search_label: ?*Label = null;
var g_search_buf: [256]u8 = undefined;
var g_radio_label: ?*Label = null;
var g_radio_buf: [128]u8 = undefined;
var g_toggle_label: ?*Label = null;
var g_toggle_buf: [128]u8 = undefined;
var g_dropdown_label: ?*Label = null;
var g_dropdown_buf: [128]u8 = undefined;
var g_listbox_label: ?*Label = null;
var g_listbox_buf: [128]u8 = undefined;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - More (7)",
        .width = 760,
        .height = 1560,
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

    const title = try Label.create(alloc, "More (7) — 容器 / 输入 / 选择", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    // ── Notebook ───────────────────────────────────────────────────────────
    try section(alloc, root, "Notebook (标签页)");
    const nb = try Notebook.create(alloc, .{ .font_size = 14 });
    const nb_page1 = try Container.create(alloc, .{ .bg_color = math.Color.hex(0x1E293BFF), .padding = .{ .left = 16, .top = 16, .right = 16, .bottom = 16 } });
    const nb_p1_label = try Label.create(alloc, "Content of Tab One", .{ .font_size = 14, .color = math.Color.hex(0xF8FAFCFF) });
    try nb_page1.base.addChild(alloc, &nb_p1_label.base);
    const nb_page2 = try Container.create(alloc, .{ .bg_color = math.Color.hex(0x1E293BFF), .padding = .{ .left = 16, .top = 16, .right = 16, .bottom = 16 } });
    const nb_p2_label = try Label.create(alloc, "Content of Tab Two", .{ .font_size = 14, .color = math.Color.hex(0xF8FAFCFF) });
    try nb_page2.base.addChild(alloc, &nb_p2_label.base);
    _ = try nb.appendPage("First", &nb_page1.base);
    _ = try nb.appendPage("Second", &nb_page2.base);
    try root.base.addChild(alloc, &nb.base);

    // ── Expander ────────────────────────────────────────────────────────────
    try section(alloc, root, "Expander (可折叠面板)");
    const exp = try Expander.create(alloc, "Click to expand", .{ .expanded = true });
    const exp_content = try Label.create(alloc, "Hidden details revealed here.", .{ .font_size = 13, .color = math.Color.hex(0xCBD5E1FF) });
    try exp.base.addChild(alloc, &exp_content.base);
    try root.base.addChild(alloc, &exp.base);

    // ── SpinButton ──────────────────────────────────────────────────────────
    try section(alloc, root, "SpinButton (数值步进器)");
    const sb = try SpinButton.create(alloc, .{ .value = 42, .min = 0, .max = 100, .step = 1, .on_change = onSpinChange });
    try root.base.addChild(alloc, &sb.base);
    g_spin_label = try Label.create(alloc, "value: 42", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_spin_label.?.base);

    // ── Spinner + 控制 ──────────────────────────────────────────────────────
    try section(alloc, root, "Spinner (加载动画)");
    const sp = try Spinner.create(alloc, .{ .size = 32 });
    try root.base.addChild(alloc, &sp.base);
    g_spinner = sp;
    const sp_row = try Container.create(alloc, .{ .direction = .row, .gap = .{ .width = 12, .height = 0 } });
    const sp_start = try Button.create(alloc, "Start", .{ .on_click = onSpinnerStart });
    try sp_row.base.addChild(alloc, &sp_start.base);
    const sp_stop = try Button.create(alloc, "Stop", .{ .on_click = onSpinnerStop });
    try sp_row.base.addChild(alloc, &sp_stop.base);
    try root.base.addChild(alloc, &sp_row.base);

    // ── ProgressBar ─────────────────────────────────────────────────────────
    try section(alloc, root, "ProgressBar (进度条)");
    const pb1 = try ProgressBar.create(alloc, .{ .fraction = 0.65, .show_text = true });
    try root.base.addChild(alloc, &pb1.base);
    const pb2 = try ProgressBar.create(alloc, .{ .pulse = true });
    try root.base.addChild(alloc, &pb2.base);

    // ── InfoBar ─────────────────────────────────────────────────────────────
    try section(alloc, root, "InfoBar (信息栏)");
    const ib = try InfoBar.create(alloc, .{ .message_type = .info, .text = "Operation completed successfully." });
    _ = try ib.addButton("OK", 1);
    _ = try ib.addButton("Details", 2);
    try root.base.addChild(alloc, &ib.base);

    // ── Revealer ────────────────────────────────────────────────────────────
    try section(alloc, root, "Revealer (展开/收起)");
    const rev = try Revealer.create(alloc, .{ .reveal_child = true, .transition_type = .slide_down });
    const rev_content = try Label.create(alloc, "Revealable content shown below the toggle.", .{ .font_size = 13, .color = math.Color.hex(0xCBD5E1FF) });
    try rev.setChild(&rev_content.base);
    g_revealer = rev;
    try root.base.addChild(alloc, &rev.base);
    const rev_btn = try Button.create(alloc, "Toggle Reveal", .{ .on_click = onToggleReveal });
    try root.base.addChild(alloc, &rev_btn.base);

    // ── SearchEntry ─────────────────────────────────────────────────────────
    try section(alloc, root, "SearchEntry (搜索输入)");
    const se = try SearchEntry.create(alloc, .{ .placeholder = "Search items...", .on_search = onSearch });
    try root.base.addChild(alloc, &se.base);
    g_search_label = try Label.create(alloc, "query: (empty)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_search_label.?.base);

    // ── RadioButton ─────────────────────────────────────────────────────────
    try section(alloc, root, "RadioButton (单选)");
    const grp = try alloc.create(RadioGroup);
    grp.* = RadioGroup.init(0, .{ .on_change = onRadioChange });
    const rb_row = try Container.create(alloc, .{ .direction = .column, .gap = .{ .width = 0, .height = 6 } });
    const rb0 = try RadioButton.create(alloc, grp, 0, "Option A", .{});
    try rb_row.base.addChild(alloc, &rb0.base);
    const rb1 = try RadioButton.create(alloc, grp, 1, "Option B", .{});
    try rb_row.base.addChild(alloc, &rb1.base);
    const rb2 = try RadioButton.create(alloc, grp, 2, "Option C", .{});
    try rb_row.base.addChild(alloc, &rb2.base);
    try root.base.addChild(alloc, &rb_row.base);
    g_radio_label = try Label.create(alloc, "selected: 0", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_radio_label.?.base);

    // ── ToggleButton ────────────────────────────────────────────────────────
    try section(alloc, root, "ToggleButton (切换)");
    const tgl = try ToggleButton.create(alloc, "Wi-Fi", .{ .active = true, .on_toggle = onToggle });
    try root.base.addChild(alloc, &tgl.base);
    g_toggle_label = try Label.create(alloc, "state: on", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_toggle_label.?.base);

    // ── Slider ──────────────────────────────────────────────────────────────
    try section(alloc, root, "Slider (滑动条)");
    const sl = try Slider.create(alloc, .{ .value = 0.3, .min = 0, .max = 1, .on_change = onSliderChange });
    try root.base.addChild(alloc, &sl.base);
    g_slider_label = try Label.create(alloc, "value: 0.30", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_slider_label.?.base);

    // ── DropDown ────────────────────────────────────────────────────────────
    try section(alloc, root, "DropDown (下拉选择)");
    const dd = try DropDown.create(alloc, .{ .on_change = onDropdownChange });
    try dd.addItem("Red", 0);
    try dd.addItem("Green", 1);
    try dd.addItem("Blue", 2);
    try root.base.addChild(alloc, &dd.base);
    g_dropdown_label = try Label.create(alloc, "selected: 0 (Red)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_dropdown_label.?.base);

    // ── ListBox ─────────────────────────────────────────────────────────────
    try section(alloc, root, "ListBox (列表框)");
    const lb = try ListBox.create(alloc, .{ .selection_mode = .single });
    const lb0 = try Label.create(alloc, "Item One", .{ .font_size = 14, .color = math.Color.hex(0xF8FAFCFF) });
    try lb.append(&lb0.base);
    const lb1 = try Label.create(alloc, "Item Two", .{ .font_size = 14, .color = math.Color.hex(0xF8FAFCFF) });
    try lb.append(&lb1.base);
    const lb2 = try Label.create(alloc, "Item Three", .{ .font_size = 14, .color = math.Color.hex(0xF8FAFCFF) });
    try lb.append(&lb2.base);
    lb.on_row_selected = onListBoxSelect;
    try root.base.addChild(alloc, &lb.base);
    g_listbox_label = try Label.create(alloc, "selected row: (none)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_listbox_label.?.base);

    // ── AboutDialog (嵌入固定尺寸 tile, 默认显示) ─────────────────────────────
    try section(alloc, root, "AboutDialog (关于对话框)");
    const about_tile = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x00000000),
        .direction = .column,
    });
    about_tile.base.layout_style.width = .{ .px = 460 };
    about_tile.base.layout_style.height = .{ .px = 380 };
    const about = try AboutDialog.create(alloc, .{
        .program_name = "zigui",
        .version = "0.16.0",
        .copyright = "Copyright (C) 2026 zigui contributors",
        .comments = "A cross-platform GPU-accelerated GUI framework written in Zig.",
        .website = "https://github.com/zigui/zigui",
        .license = "MIT License",
        .authors = &[_][]const u8{"caesar", "contributors"},
    });
    about.show();
    g_about = about;
    try about_tile.base.addChild(alloc, &about.base);
    try root.base.addChild(alloc, &about_tile.base);

    g_root = root;
    g_tree_alloc = alloc;
}

// ── 回调 ─────────────────────────────────────────────────────────────────────

fn onSpinChange(self: *SpinButton, value: f64) void {
    _ = self;
    if (g_spin_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_spin_buf, "value: {d}", .{value}) catch "value";
    }
}

fn onSpinnerStart(_: *Button) void {
    if (g_spinner) |s| s.start();
}
fn onSpinnerStop(_: *Button) void {
    if (g_spinner) |s| s.stop();
}

fn onToggleReveal(_: *Button) void {
    if (g_revealer) |r| r.setRevealChild(!r.getRevealChild());
}

fn onSearch(self: *SearchEntry, text: []const u8) void {
    _ = self;
    if (g_search_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_search_buf, "query: {s}", .{text}) catch "query";
    }
}

fn onRadioChange(self: *RadioGroup, index: usize) void {
    _ = self;
    if (g_radio_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_radio_buf, "selected: {d}", .{index}) catch "selected";
    }
}

fn onToggle(self: *ToggleButton, active: bool) void {
    _ = self;
    if (g_toggle_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_toggle_buf, "state: {s}", .{if (active) "on" else "off"}) catch "state";
    }
}

fn onSliderChange(self: *Slider, value: f32) void {
    _ = self;
    if (g_slider_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_slider_buf, "value: {d:.2}", .{value}) catch "value";
    }
}

fn onDropdownChange(self: *DropDown, index: usize) void {
    _ = self;
    if (g_dropdown_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_dropdown_buf, "selected: {d}", .{index}) catch "selected";
    }
}

fn onListBoxSelect(self: *ListBox, row: usize, _w: *widget.Widget) void {
    _ = self;
    _ = _w;
    if (g_listbox_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_listbox_buf, "selected row: {d}", .{row}) catch "selected";
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
