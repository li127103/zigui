//! GtkPageSetupUnixDialog — Unix 页面设置对话框
//!
//! GTK 对应: GtkPageSetupUnixDialog
//!
//! 模态对话框，包含：
//!   - PaperSize 下拉（A4 / Letter / A3 / Legal / A5 / 自定义…）
//!   - Orientation 选项卡（纵向 / 横向 / 反向纵向 / 反向横向）
//!   - Margin 四边数值输入（mm 或 inch）
//!   - 预览示意框：显示纸张轮廓 + 可打印区域
//!   - OK / Cancel 按钮 + ESC 键关闭
//!
//! 对应用户在 GTK 下的标准"文件 → 页面设置"流程。

const std = @import("std");
const math = @import("../math.zig");
const pal = @import("../pal/pal.zig");

const Widget = @import("widget.zig").Widget;
const Box = @import("box.zig").Box;
const Label = @import("label.zig").Label;
const Button = @import("button.zig").Button;
const Frame = @import("frame.zig").Frame;
const ComboBox = @import("combo_box.zig").ComboBox;
const SpinButton = @import("spin_button.zig").SpinButton;
const Dialog = @import("dialog.zig").Dialog;
const Window = @import("../window.zig").Window;

const print_mod = @import("../model/print.zig");
pub const PaperSize = print_mod.PaperSize;
pub const PageSetup = print_mod.PageSetup;
pub const PageOrientation = print_mod.PageOrientation;
pub const PrintSettings = print_mod.PrintSettings;
pub const Unit = print_mod.Unit;

// ──────────────────────────────────────────────────────────────────────────────
// 纸张预设下拉项
// ──────────────────────────────────────────────────────────────────────────────

const PaperPreset = struct {
    name: []const u8,
    display: []const u8,
    size: PaperSize,
};

const PRESETS = [_]PaperPreset{
    .{ .name = "iso_a4", .display = "A4 (210 × 297 mm)", .size = PaperSize.A4 },
    .{ .name = "na_letter", .display = "Letter (215.9 × 279.4 mm)", .size = PaperSize.Letter },
    .{ .name = "iso_a3", .display = "A3 (297 × 420 mm)", .size = PaperSize.A3 },
    .{ .name = "iso_a5", .display = "A5 (148 × 210 mm)", .size = PaperSize.A5 },
    .{ .name = "na_legal", .display = "Legal (215.9 × 355.6 mm)", .size = PaperSize.Legal },
    .{ .name = "na_executive", .display = "Executive (184.15 × 266.7 mm)", .size = PaperSize.Executive },
    .{ .name = "jis_b5", .display = "B5 (JIS) (182 × 257 mm)", .size = PaperSize.B5 },
};

// ──────────────────────────────────────────────────────────────────────────────
// PageSetupUnixDialog
// ──────────────────────────────────────────────────────────────────────────────

pub const PageSetupUnixDialog = struct {
    allocator: std.mem.Allocator,

    dialog: *Dialog,
    title_label: *Label,

    // Paper
    paper_combo: *ComboBox,
    current_preset_idx: usize = 0,
    custom_w_mm: f32 = 210,
    custom_h_mm: f32 = 297,

    // Orientation
    orientation_combo: *ComboBox,

    // Margins (mm)
    unit: Unit = .mm,
    margin_top_spin: *SpinButton,
    margin_bottom_spin: *SpinButton,
    margin_left_spin: *SpinButton,
    margin_right_spin: *SpinButton,

    // Preview area: 用 Frame + Label 组合占位
    preview_frame: *Frame,
    preview_label: *Label,

    // 关联设置
    page_setup: PageSetup,
    print_settings: ?PrintSettings,

    // 回调
    on_response: ?*const fn (self: *PageSetupUnixDialog, result: Dialog.ResponseType, new_setup: PageSetup) void = null,
    user_data: ?*anyopaque = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, title: []const u8) *Self {
        const ptr = allocator.create(Self) catch @panic("PageSetupUnixDialog.create: OOM");

        // ── 构建控件树 ──────────────────────────────────────────────
        const dialog = Dialog.create(allocator, title);
        dialog.setModal(true);
        const content = dialog.getContentBox();

        const paper_frame = Frame.create(allocator, "纸张");
        const paper_v = Box.createV(allocator, 8);
        const paper_label = Label.create(allocator, "纸张大小: ");
        const paper_combo = ComboBox.create(allocator);
        for (PRESETS) |p| paper_combo.appendItem(p.display);
        paper_combo.setActive(0);
        paper_v.appendChild(paper_label.widget());
        paper_v.appendChild(paper_combo.widget());
        paper_frame.setChild(paper_v.widget());

        const orient_frame = Frame.create(allocator, "方向");
        const orient_v = Box.createV(allocator, 8);
        const orient_label = Label.create(allocator, "页面方向: ");
        const orient_combo = ComboBox.create(allocator);
        orient_combo.appendItem("纵向");
        orient_combo.appendItem("横向");
        orient_combo.appendItem("反向纵向");
        orient_combo.appendItem("反向横向");
        orient_combo.setActive(0);
        orient_v.appendChild(orient_label.widget());
        orient_v.appendChild(orient_combo.widget());
        orient_frame.setChild(orient_v.widget());

        const margin_frame = Frame.create(allocator, "边距 (mm)");
        const margin_grid = Box.createV(allocator, 4);
        const top_h = Box.createH(allocator, 8);
        const margin_top_label = Label.create(allocator, "上边距:");
        const margin_top_spin = SpinButton.create(allocator, 0, 0, 999, 1);
        margin_top_spin.setValue(10);
        top_h.appendChild(margin_top_label.widget());
        top_h.appendChild(margin_top_spin.widget());

        const bottom_h = Box.createH(allocator, 8);
        const margin_bottom_label = Label.create(allocator, "下边距:");
        const margin_bottom_spin = SpinButton.create(allocator, 0, 0, 999, 1);
        margin_bottom_spin.setValue(10);
        bottom_h.appendChild(margin_bottom_label.widget());
        bottom_h.appendChild(margin_bottom_spin.widget());

        const left_h = Box.createH(allocator, 8);
        const margin_left_label = Label.create(allocator, "左边距:");
        const margin_left_spin = SpinButton.create(allocator, 0, 0, 999, 1);
        margin_left_spin.setValue(15);
        left_h.appendChild(margin_left_label.widget());
        left_h.appendChild(margin_left_spin.widget());

        const right_h = Box.createH(allocator, 8);
        const margin_right_label = Label.create(allocator, "右边距:");
        const margin_right_spin = SpinButton.create(allocator, 0, 0, 999, 1);
        margin_right_spin.setValue(15);
        right_h.appendChild(margin_right_label.widget());
        right_h.appendChild(margin_right_spin.widget());

        margin_grid.appendChild(top_h.widget());
        margin_grid.appendChild(bottom_h.widget());
        margin_grid.appendChild(left_h.widget());
        margin_grid.appendChild(right_h.widget());
        margin_frame.setChild(margin_grid.widget());

        // 预览
        const preview_frame = Frame.create(allocator, "预览");
        const preview_label = Label.create(allocator, previewSummary(PaperSize.A4, .portrait, 10, 10, 15, 15));
        preview_frame.setChild(preview_label.widget());

        // 布局
        const root_v = Box.createV(allocator, 8);
        const top_row = Box.createH(allocator, 8);
        top_row.appendChild(paper_frame.widget());
        top_row.appendChild(orient_frame.widget());
        root_v.appendChild(top_row.widget());

        const bottom_row = Box.createH(allocator, 8);
        bottom_row.appendChild(margin_frame.widget());
        bottom_row.appendChild(preview_frame.widget());
        root_v.appendChild(bottom_row.widget());

        content.appendChild(root_v.widget());

        // OK / Cancel
        dialog.addButton("取消", .cancel);
        dialog.addButton("确定", .ok);

        const title_label = Label.create(allocator, title);

        ptr.* = .{
            .allocator = allocator,
            .dialog = dialog,
            .title_label = title_label,
            .paper_combo = paper_combo,
            .orientation_combo = orient_combo,
            .margin_top_spin = margin_top_spin,
            .margin_bottom_spin = margin_bottom_spin,
            .margin_left_spin = margin_left_spin,
            .margin_right_spin = margin_right_spin,
            .preview_frame = preview_frame,
            .preview_label = preview_label,
            .page_setup = PageSetup.default(),
            .print_settings = null,
        };

        // 连接：OK 按钮提交结果
        dialog.on_response = struct {
            fn onResponse(dlg: *Dialog, result: Dialog.ResponseType) void {
                const self: *Self = @ptrCast(@alignCast(dlg.user_data orelse return));
                const setup = self.collectSetup();
                self.page_setup = setup;
                if (self.on_response) |cb| cb(self, result, setup);
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

    pub fn setPageSetup(self: *Self, setup: PageSetup) void {
        self.page_setup = setup;
        // 尝试匹配预设
        for (PRESETS, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, setup.paper_size.name)) {
                self.paper_combo.setActive(i);
                self.current_preset_idx = i;
                break;
            }
        }
        // 方向
        self.orientation_combo.setActive(@intFromEnum(setup.orientation));
        // 边距
        self.margin_top_spin.setValue(setup.margin_top_mm);
        self.margin_bottom_spin.setValue(setup.margin_bottom_mm);
        self.margin_left_spin.setValue(setup.margin_left_mm);
        self.margin_right_spin.setValue(setup.margin_right_mm);
        self.refreshPreview();
    }

    pub fn getPageSetup(self: *const Self) PageSetup {
        return self.page_setup;
    }

    pub fn setPrintSettings(self: *Self, s: PrintSettings) void {
        self.print_settings = s;
    }
    pub fn getPrintSettings(self: *const Self) ?PrintSettings {
        return self.print_settings;
    }

    pub fn setModal(self: *Self, v: bool) void {
        self.dialog.setModal(v);
    }

    pub fn setTitle(self: *Self, title: []const u8) void {
        self.dialog.setTitle(title);
        self.title_label.setText(title);
    }

    // ── 显示 / 隐藏 ──────────────────────────────────────────────────────

    pub fn present(self: *Self, parent: ?*Window) void {
        self.dialog.present(parent);
        self.refreshPreview();
    }
    pub fn close(self: *Self) void {
        self.dialog.close();
    }

    // ── 内部：从 UI 收集当前 setup ──────────────────────────────────────

    fn collectSetup(self: *Self) PageSetup {
        const active = self.paper_combo.getActive();
        const preset: PaperSize = if (active < PRESETS.len)
            PRESETS[active].size
        else
            PaperSize{
                .name = "custom",
                .display_name = "自定义",
                .width_mm = self.custom_w_mm,
                .height_mm = self.custom_h_mm,
            };

        const orientation: PageOrientation = switch (self.orientation_combo.getActive()) {
            0 => .portrait,
            1 => .landscape,
            2 => .reverse_portrait,
            3 => .reverse_landscape,
            else => .portrait,
        };

        var s = PageSetup.fromPaperSize(preset, orientation);
        s.margin_top_mm = self.margin_top_spin.getValue();
        s.margin_bottom_mm = self.margin_bottom_spin.getValue();
        s.margin_left_mm = self.margin_left_spin.getValue();
        s.margin_right_mm = self.margin_right_spin.getValue();
        return s;
    }

    fn refreshPreview(self: *Self) void {
        const setup = self.collectSetup();
        self.preview_label.setText(previewSummary(
            setup.paper_size,
            setup.orientation,
            setup.margin_top_mm,
            setup.margin_bottom_mm,
            setup.margin_left_mm,
            setup.margin_right_mm,
        ));
    }

    fn previewSummary(
        size: PaperSize,
        orientation: PageOrientation,
        mt: f32,
        mb: f32,
        ml: f32,
        mr: f32,
    ) []const u8 {
        _ = orientation;
        const buf = &[_]u8{0} ** 256;
        const total_w: f32 = size.getWidth(.mm);
        const total_h: f32 = size.getHeight(.mm);
        const print_w: f32 = total_w - ml - mr;
        const print_h: f32 = total_h - mt - mb;
        const print = std.fmt.bufPrint(
            buf,
            "纸张: {s}  {d:.1} × {d:.1} mm\n" ++
                "可打印区域: {d:.1} × {d:.1} mm\n" ++
                "边距 上/下/左/右: {d:.0}/{d:.0}/{d:.0}/{d:.0} mm",
            .{ size.display_name, total_w, total_h, print_w, print_h, mt, mb, ml, mr },
        ) catch return "预览";
        return print;
    }

    pub fn widget(self: *Self) *Widget {
        return self.dialog.widget();
    }
};

// 顶层导出：方便 PageSetupUnixDialog 直接访问
pub const ResponseType = Dialog.ResponseType;
