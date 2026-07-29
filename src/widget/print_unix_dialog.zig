//! GtkPrintUnixDialog — UNIX/Linux 打印对话框
//!
//! GTK 对应: GtkPrintUnixDialog
//!
//! 标准"打印"对话框控件，包含：
//!   - 打印机下拉（可自定义列表）
//!   - 份数 + 逐份打印（Collate）+ 逆序（Reverse）
//!   - 页面范围：全部 / 当前页 / 页码范围（"1-5, 8, 10-12" 语法）
//!   - 双面模式（Duplex）：Simplex / Long Edge / Short Edge
//!   - 页设置按钮（点击弹出 PageSetupUnixDialog）
//!   - 纸张尺寸 / 方向 / 边距文本预览
//!   - 打印质量（草稿/普通/高）、颜色模式（颜色/灰阶）、页面集合（全部/偶数/奇数）
//!
//! OK 按钮返回 .ok 并应用设置；Cancel 返回 .cancel；ESC 关闭。

const std = @import("std");
const math = @import("../math.zig");

const Widget = @import("widget.zig").Widget;
const Box = @import("box.zig").Box;
const Label = @import("label.zig").Label;
const Button = @import("button.zig").Button;
const Frame = @import("frame.zig").Frame;
const ComboBox = @import("combo_box.zig").ComboBox;
const SpinButton = @import("spin_button.zig").SpinButton;
const Entry = @import("entry.zig").Entry;
const CheckButton = @import("check_button.zig").CheckButton;
const Dialog = @import("dialog.zig").Dialog;
const Window = @import("../window.zig").Window;

const print_mod = @import("../model/print.zig");
pub const PaperSize = print_mod.PaperSize;
pub const PageSetup = print_mod.PageSetup;
pub const PrintSettings = print_mod.PrintSettings;
pub const PageOrientation = print_mod.PageOrientation;
pub const PrintPages = print_mod.PrintPages;
pub const PrintQuality = print_mod.PrintQuality;
pub const PrintDuplexMode = print_mod.PrintDuplexMode;
pub const PrintColorMode = print_mod.PrintColorMode;
pub const PrintPageRange = print_mod.PrintPageRange;
pub const Unit = print_mod.Unit;

// ──────────────────────────────────────────────────────────────────────────────
// 打印能力 flags
// ──────────────────────────────────────────────────────────────────────────────

pub const PrintCapabilities = packed struct(u32) {
    page_set: bool = true, // 奇数/偶数页
    copies: bool = true, // 多份
    collate: bool = true, // 逐份
    reverse: bool = true, // 逆序
    scale: bool = false, // 缩放 1%-500%
    paper_size: bool = true, // 切换纸张
    orientation: bool = true, // 切换方向
    color_mode: bool = true, // 颜色/灰阶
    duplex: bool = true, // 双面
    quality: bool = true, // 打印质量
    generate_pdf: bool = true, // 导出 PDF
    generate_ps: bool = false, // 导出 PS
    number_up: bool = false, // N-up
    custom_page_ranges: bool = true, // 自定义页码范围
    current_page: bool = true, // 当前页
    _pad: u17 = 0,
};

pub const PageSet = enum(u8) {
    all,
    even,
    odd,
};

// ──────────────────────────────────────────────────────────────────────────────
// PrintUnixDialog 主体
// ──────────────────────────────────────────────────────────────────────────────

pub const PrintUnixDialog = struct {
    allocator: std.mem.Allocator,
    dialog: *Dialog,

    // 打印机
    printer_combo: *ComboBox,

    // 范围
    range_all_radio: *CheckButton,
    range_current_radio: *CheckButton,
    range_custom_radio: *CheckButton,
    custom_range_entry: *Entry,

    // 份数 & 选项
    copies_spin: *SpinButton,
    collate_check: *CheckButton,
    reverse_check: *CheckButton,
    page_set_combo: *ComboBox,

    // 双面
    duplex_combo: *ComboBox,

    // 质量
    quality_combo: *ComboBox,
    color_combo: *ComboBox,

    // 页设置按钮 & 预览
    page_setup_btn: *Button,
    preview_label: *Label,

    // 当前状态
    settings: PrintSettings,
    page_setup: PageSetup,
    n_pages: i32 = 1,
    current_page: i32 = 0,
    caps: PrintCapabilities = .{},

    // 回调
    on_response: ?*const fn (self: *PrintUnixDialog, result: Dialog.ResponseType, out_settings: PrintSettings, out_setup: PageSetup) void = null,
    user_data: ?*anyopaque = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, title: []const u8) *Self {
        const ptr = allocator.create(Self) catch @panic("PrintUnixDialog.create: OOM");

        const dialog = Dialog.create(allocator, title);
        dialog.setModal(true);
        const content = dialog.getContentBox();

        // ── 打印机 ──────────────────────────────────────────────────────
        const printer_frame = Frame.create(allocator, "打印机");
        const pv = Box.createV(allocator, 6);
        const printer_combo = ComboBox.create(allocator);
        printer_combo.appendItem("Print to File (PDF)");
        printer_combo.appendItem("Default Printer");
        printer_combo.appendItem("CUPS / 网络打印机…");
        printer_combo.setActive(0);
        pv.appendChild(printer_combo.widget());
        printer_frame.setChild(pv.widget());

        // ── 范围 ────────────────────────────────────────────────────────
        const range_frame = Frame.create(allocator, "页面范围");
        const rv = Box.createV(allocator, 4);
        const range_all_radio = CheckButton.createWithLabel(allocator, "全部");
        range_all_radio.setActive(true);
        const range_current_radio = CheckButton.createWithLabel(allocator, "当前页");
        const range_custom_radio = CheckButton.createWithLabel(allocator, "页码范围:");
        const range_row = Box.createH(allocator, 4);
        const custom_range_entry = Entry.create(allocator);
        custom_range_entry.setPlaceholderText("如: 1-5, 8, 10-12");
        range_row.appendChild(range_custom_radio.widget());
        range_row.appendChild(custom_range_entry.widget());
        rv.appendChild(range_all_radio.widget());
        rv.appendChild(range_current_radio.widget());
        rv.appendChild(range_row.widget());
        range_frame.setChild(rv.widget());

        // ── 份数 ────────────────────────────────────────────────────────
        const copies_frame = Frame.create(allocator, "份数");
        const cv = Box.createV(allocator, 4);
        const copies_row = Box.createH(allocator, 6);
        const copies_label = Label.create(allocator, "份数:");
        const copies_spin = SpinButton.create(allocator, 1, 1, 999, 1);
        copies_row.appendChild(copies_label.widget());
        copies_row.appendChild(copies_spin.widget());
        cv.appendChild(copies_row.widget());
        const collate_check = CheckButton.createWithLabel(allocator, "逐份打印 (Collate)");
        const reverse_check = CheckButton.createWithLabel(allocator, "逆序输出 (Reverse)");
        cv.appendChild(collate_check.widget());
        cv.appendChild(reverse_check.widget());
        const ps_row = Box.createH(allocator, 6);
        const ps_label = Label.create(allocator, "页面集合:");
        const page_set_combo = ComboBox.create(allocator);
        page_set_combo.appendItem("全部页");
        page_set_combo.appendItem("奇数页");
        page_set_combo.appendItem("偶数页");
        page_set_combo.setActive(0);
        ps_row.appendChild(ps_label.widget());
        ps_row.appendChild(page_set_combo.widget());
        cv.appendChild(ps_row.widget());
        copies_frame.setChild(cv.widget());

        // ── 质量 ────────────────────────────────────────────────────────
        const q_frame = Frame.create(allocator, "质量 & 颜色");
        const qv = Box.createV(allocator, 4);
        const d_row = Box.createH(allocator, 6);
        const duplex_label = Label.create(allocator, "双面:");
        const duplex_combo = ComboBox.create(allocator);
        duplex_combo.appendItem("单面 (Simplex)");
        duplex_combo.appendItem("双面 (长边翻转 / Long Edge)");
        duplex_combo.appendItem("双面 (短边翻转 / Short Edge)");
        duplex_combo.setActive(0);
        d_row.appendChild(duplex_label.widget());
        d_row.appendChild(duplex_combo.widget());
        qv.appendChild(d_row.widget());
        const q_row = Box.createH(allocator, 6);
        const q_label = Label.create(allocator, "质量:");
        const quality_combo = ComboBox.create(allocator);
        quality_combo.appendItem("草稿 (Draft)");
        quality_combo.appendItem("普通 (Normal)");
        quality_combo.appendItem("高 (High)");
        quality_combo.setActive(1);
        q_row.appendChild(q_label.widget());
        q_row.appendChild(quality_combo.widget());
        qv.appendChild(q_row.widget());
        const c_row = Box.createH(allocator, 6);
        const c_label = Label.create(allocator, "颜色:");
        const color_combo = ComboBox.create(allocator);
        color_combo.appendItem("颜色");
        color_combo.appendItem("灰阶 / 黑白");
        color_combo.setActive(0);
        c_row.appendChild(c_label.widget());
        c_row.appendChild(color_combo.widget());
        qv.appendChild(c_row.widget());
        q_frame.setChild(qv.widget());

        // ── 页设置按钮 & 预览 ───────────────────────────────────────────
        const setup_frame = Frame.create(allocator, "页设置");
        const sv = Box.createV(allocator, 6);
        const page_setup_btn = Button.createWithLabel(allocator, "页面设置…");
        const preview_label = Label.create(allocator, "A4  纵向  上/下/左/右 = 10/10/15/15 mm");
        sv.appendChild(page_setup_btn.widget());
        sv.appendChild(preview_label.widget());
        setup_frame.setChild(sv.widget());

        // ── 整体布局: 2 行 x 2 列网格 ───────────────────────────────────
        const grid_top = Box.createH(allocator, 8);
        grid_top.appendChild(printer_frame.widget());
        grid_top.appendChild(range_frame.widget());
        const grid_mid = Box.createH(allocator, 8);
        grid_mid.appendChild(copies_frame.widget());
        grid_mid.appendChild(q_frame.widget());

        const root_v = Box.createV(allocator, 8);
        root_v.appendChild(grid_top.widget());
        root_v.appendChild(grid_mid.widget());
        root_v.appendChild(setup_frame.widget());
        content.appendChild(root_v.widget());

        dialog.addButton("取消", .cancel);
        dialog.addButton("打印", .ok);

        ptr.* = .{
            .allocator = allocator,
            .dialog = dialog,
            .printer_combo = printer_combo,
            .range_all_radio = range_all_radio,
            .range_current_radio = range_current_radio,
            .range_custom_radio = range_custom_radio,
            .custom_range_entry = custom_range_entry,
            .copies_spin = copies_spin,
            .collate_check = collate_check,
            .reverse_check = reverse_check,
            .page_set_combo = page_set_combo,
            .duplex_combo = duplex_combo,
            .quality_combo = quality_combo,
            .color_combo = color_combo,
            .page_setup_btn = page_setup_btn,
            .preview_label = preview_label,
            .settings = PrintSettings.default(),
            .page_setup = PageSetup.default(),
        };

        dialog.on_response = struct {
            fn onResponse(dlg: *Dialog, result: Dialog.ResponseType) void {
                const self: *Self = @ptrCast(@alignCast(dlg.user_data orelse return));
                self.applyUIFieldsToSettings();
                if (self.on_response) |cb| cb(self, result, self.settings, self.page_setup);
            }
        }.onResponse;
        dialog.user_data = ptr;

        return ptr;
    }

    pub fn destroy(self: *Self) void {
        self.dialog.destroy();
        self.allocator.destroy(self);
    }

    // ── 属性 API ────────────────────────────────────────────────────────

    pub fn setPrintSettings(self: *Self, s: PrintSettings) void {
        self.settings = s;
        self.refreshUIFromSettings();
    }
    pub fn getPrintSettings(self: *const Self) PrintSettings {
        return self.settings;
    }
    pub fn setPageSetup(self: *Self, s: PageSetup) void {
        self.page_setup = s;
        self.refreshPreview();
    }
    pub fn getPageSetup(self: *const Self) PageSetup {
        return self.page_setup;
    }
    pub fn setNPages(self: *Self, n: i32) void {
        self.n_pages = n;
    }
    pub fn getNPages(self: *const Self) i32 {
        return self.n_pages;
    }
    pub fn setCurrentPage(self: *Self, n: i32) void {
        self.current_page = n;
    }
    pub fn setManualCapabilities(self: *Self, caps: PrintCapabilities) void {
        self.caps = caps;
    }

    // ── 显示/隐藏 ──────────────────────────────────────────────────────

    pub fn present(self: *Self, parent: ?*Window) void {
        self.dialog.present(parent);
        self.refreshUIFromSettings();
        self.refreshPreview();
    }
    pub fn close(self: *Self) void {
        self.dialog.close();
    }

    pub fn widget(self: *Self) *Widget {
        return self.dialog.widget();
    }

    // ── 内部：UI ↔ 设置同步 ───────────────────────────────────────────

    fn applyUIFieldsToSettings(self: *Self) void {
        var s = self.settings;
        s.n_copies = @intCast(self.copies_spin.getValue());
        s.collate = self.collate_check.getActive();
        s.reverse = self.reverse_check.getActive();
        s.duplex = switch (self.duplex_combo.getActive()) {
            0 => .simplex,
            1 => .long_edge,
            else => .short_edge,
        };
        s.quality = switch (self.quality_combo.getActive()) {
            0 => .draft,
            1 => .normal,
            else => .high,
        };
        s.color_mode = if (self.color_combo.getActive() == 0) .color else .grayscale;
        s.page_set = switch (self.page_set_combo.getActive()) {
            0 => .all,
            1 => .odd,
            else => .even,
        };
        if (self.printer_combo.getActive() == 0) {
            s.output_uri = "output.pdf";
        }
        self.settings = s;
    }

    fn refreshUIFromSettings(self: *Self) void {
        const s = self.settings;
        self.copies_spin.setValue(@floatFromInt(s.n_copies));
        self.collate_check.setActive(s.collate);
        self.reverse_check.setActive(s.reverse);
        self.duplex_combo.setActive(switch (s.duplex) {
            .simplex => 0,
            .long_edge => 1,
            .short_edge => 2,
        });
        self.quality_combo.setActive(switch (s.quality) {
            .draft => 0,
            .normal => 1,
            .high => 2,
        });
        self.color_combo.setActive(if (s.color_mode == .color) 0 else 1);
        self.page_set_combo.setActive(switch (s.page_set) {
            .all => 0,
            .odd => 1,
            .even => 2,
        });
    }

    fn refreshPreview(self: *Self) void {
        const setup = self.page_setup;
        const buf = &[_]u8{0} ** 256;
        const text = std.fmt.bufPrint(
            buf,
            "{s}  {s}  上下左右 = {d:.0}/{d:.0}/{d:.0}/{d:.0} mm",
            .{
                setup.paper_size.display_name,
                @tagName(setup.orientation),
                setup.margin_top_mm,
                setup.margin_bottom_mm,
                setup.margin_left_mm,
                setup.margin_right_mm,
            },
        ) catch return;
        self.preview_label.setText(text);
    }
};

pub const ResponseType = Dialog.ResponseType;
