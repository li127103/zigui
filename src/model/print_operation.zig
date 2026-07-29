//! GTK4 PrintOperation — 打印运行时操作
//!
//! GTK 对应: GtkPrintOperation
//! 负责在模型层封装"打印一次文档"的完整状态机：
//!   initial → preparing → generating_data → sending_data → finished
//!                                                         → finished_aborted
//!
//! 典型流程（对齐 GTK4）：
//!   1. 用户创建 PrintOperation，传入 settings + page_setup
//!   2. 设置 on_begin_print 回调（决定总页数）
//!   3. 设置 on_draw_page 回调（逐页绘制）
//!   4. 调用 .run(parent, .print_dialog) → 弹窗确认 → 开始打印
//!   5. 内部逐页 emit draw_page，emit on_status_changed / on_progress
//!   6. emit on_end_print 清理、on_done 返回最终结果
//!
//! 使用"类型擦除 user_data + 回调指针"保持 Zig API 简洁，不依赖泛型实例。

const std = @import("std");
const print_mod = @import("print.zig");

pub const Unit = print_mod.Unit;
pub const PrintSettings = print_mod.PrintSettings;
pub const PageSetup = print_mod.PageSetup;
pub const PaperSize = print_mod.PaperSize;
pub const PageOrientation = print_mod.PageOrientation;
pub const PrintPages = print_mod.PrintPages;
pub const PrintQuality = print_mod.PrintQuality;
pub const PrintDuplexMode = print_mod.PrintDuplexMode;
pub const PrintColorMode = print_mod.PrintColorMode;
pub const PrintPageRange = print_mod.PrintPageRange;

// ──────────────────────────────────────────────────────────────────────────────
// 运行动作 / 结果 / 状态
// ──────────────────────────────────────────────────────────────────────────────

pub const PrintOperationAction = enum(u8) {
    print, // 直接打印（不弹对话框）
    print_dialog, // 先弹打印对话框，然后打印（最常用）
    preview, // 预览模式（调用 on_preview 回调）
    export_, // 导出为 PDF/PS/SVG，必须设置 export_filename
};

pub const PrintOperationResult = enum(u8) {
    success,
    error_,
    applied, // 对话框"应用"设置但未打印
    in_progress, // 异步：正在后台处理
    user_cancel, // 用户取消
};

pub const PrintOperationStatus = enum(u8) {
    initial,
    preparing,
    generating_data,
    sending_data,
    pending,
    pending_issue,
    finished,
    finished_aborted,
};

// ──────────────────────────────────────────────────────────────────────────────
// 打印上下文 (opaque + 基本访问器)
// ──────────────────────────────────────────────────────────────────────────────

/// GtkPrintContext 简化：传递给 begin_print / draw_page / end_print
pub const PrintContext = opaque {
    /// 从操作对象恢复句柄（由内部使用）
    pub fn fromOperation(op: *PrintOperation) *PrintContext {
        return @ptrCast(@alignCast(op));
    }
    /// 获取当前 PageSetup（默认页设置）
    pub fn getPageSetup(ctx: *PrintContext) PageSetup {
        const op: *PrintOperation = @ptrCast(@alignCast(ctx));
        return op.default_page_setup orelse PageSetup.default();
    }
    /// 获取当前页面宽度（mm）
    pub fn getWidth(ctx: *PrintContext) f32 {
        return ctx.getPageSetup().getPageWidth(.mm);
    }
    /// 获取当前页面高度（mm）
    pub fn getHeight(ctx: *PrintContext) f32 {
        return ctx.getPageSetup().getPageHeight(.mm);
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// PrintPreview / Draw 回调签名
// ──────────────────────────────────────────────────────────────────────────────

/// on_begin_print: 决定总页数（设置 op.setNPages）
pub const BeginPrintFn = *const fn (op: *PrintOperation, ctx: *PrintContext) void;
/// on_draw_page: 绘制指定页（0-based）
pub const DrawPageFn = *const fn (op: *PrintOperation, ctx: *PrintContext, page_nr: i32) void;
/// on_end_print: 打印完成（成功或取消后）清理
pub const EndPrintFn = *const fn (op: *PrintOperation, ctx: *PrintContext) void;
/// on_status_changed: 状态变化时回调（可选）
pub const StatusChangedFn = *const fn (op: *PrintOperation) void;
/// on_done: 最终结果回调
pub const DoneFn = *const fn (op: *PrintOperation, result: PrintOperationResult) void;
/// on_preview: 预览回调（返回是否接管预览）
pub const PreviewFn = *const fn (
    op: *PrintOperation,
    preview: ?*PrintContext,
    ctx: ?*PrintContext,
) bool;

// ──────────────────────────────────────────────────────────────────────────────
// PrintOperation 主体
// ──────────────────────────────────────────────────────────────────────────────

pub const PrintOperation = struct {
    allocator: std.mem.Allocator,

    // 基本配置
    job_name: []const u8,
    unit: Unit,
    /// 导出文件名：当 action=.export 时生效（留空走默认 "output.pdf"）
    export_filename: []const u8 = "output.pdf",

    print_settings: ?PrintSettings,
    default_page_setup: ?PageSetup,

    // UI/反馈
    show_progress: bool = true,
    allow_async: bool = true,
    track_print_status: bool = true,

    // 运行时状态
    status: PrintOperationStatus = .initial,
    current_page: i32 = -1,
    n_pages_to_print: i32 = 0,
    last_error: ?[]const u8 = null,
    user_data: ?*anyopaque = null,

    // 回调
    on_begin_print: ?BeginPrintFn = null,
    on_draw_page: ?DrawPageFn = null,
    on_end_print: ?EndPrintFn = null,
    on_status_changed: ?StatusChangedFn = null,
    on_done: ?DoneFn = null,
    on_preview: ?PreviewFn = null,

    const Self = @This();

    pub fn create(
        allocator: std.mem.Allocator,
        settings: ?PrintSettings,
        default_setup: ?PageSetup,
        begin: ?BeginPrintFn,
        draw: ?DrawPageFn,
        end: ?EndPrintFn,
    ) *Self {
        const ptr = allocator.create(Self) catch @panic("PrintOperation.create: OOM");
        ptr.* = .{
            .allocator = allocator,
            .job_name = "ZigUI Print Job",
            .unit = .mm,
            .print_settings = settings,
            .default_page_setup = default_setup,
            .on_begin_print = begin,
            .on_draw_page = draw,
            .on_end_print = end,
        };
        return ptr;
    }

    pub fn destroy(self: *Self) void {
        self.allocator.destroy(self);
    }

    // ── 配置 setter ──────────────────────────────────────────────────────

    pub fn setJobName(self: *Self, name: []const u8) void {
        self.job_name = name;
    }
    pub fn getJobName(self: *const Self) []const u8 {
        return self.job_name;
    }
    pub fn setExportFilename(self: *Self, path: []const u8) void {
        self.export_filename = path;
    }
    pub fn getExportFilename(self: *const Self) []const u8 {
        return self.export_filename;
    }
    pub fn setUnit(self: *Self, u: Unit) void {
        self.unit = u;
    }
    pub fn setShowProgress(self: *Self, v: bool) void {
        self.show_progress = v;
    }
    pub fn setAllowAsync(self: *Self, v: bool) void {
        self.allow_async = v;
    }
    pub fn setTrackPrintStatus(self: *Self, v: bool) void {
        self.track_print_status = v;
    }
    pub fn setPrintSettings(self: *Self, s: PrintSettings) void {
        self.print_settings = s;
    }
    pub fn getPrintSettings(self: *const Self) ?PrintSettings {
        return self.print_settings;
    }
    pub fn setDefaultPageSetup(self: *Self, s: PageSetup) void {
        self.default_page_setup = s;
    }
    pub fn getDefaultPageSetup(self: *const Self) ?PageSetup {
        return self.default_page_setup;
    }

    // ── 运行时信息 ────────────────────────────────────────────────────────

    pub fn setNPages(self: *Self, n: i32) void {
        self.n_pages_to_print = n;
    }
    pub fn getNPages(self: *const Self) i32 {
        return self.n_pages_to_print;
    }
    pub fn getCurrentPage(self: *const Self) i32 {
        return self.current_page;
    }
    pub fn getStatus(self: *const Self) PrintOperationStatus {
        return self.status;
    }
    /// 0.0 → 1.0 进度（n_pages_to_print=0 时返回 0）
    pub fn getProgress(self: *const Self) f32 {
        if (self.n_pages_to_print <= 0) return 0;
        const p: f32 = @floatFromInt(self.current_page + 1);
        const total: f32 = @floatFromInt(self.n_pages_to_print);
        return std.math.clamp(p / total, 0, 1);
    }
    pub fn getStatusString(self: *const Self) []const u8 {
        return switch (self.status) {
            .initial => "未开始",
            .preparing => "准备打印中…",
            .generating_data => "生成打印数据…",
            .sending_data => "发送数据到打印机…",
            .pending => "等待中…",
            .pending_issue => "等待中（有问题）",
            .finished => "打印完成",
            .finished_aborted => "打印已中止",
        };
    }
    pub fn getError(self: *const Self) ?[]const u8 {
        return self.last_error;
    }
    /// 绘制指定页完成（对齐 GTK4 op.draw_page_finish）
    pub fn drawPageFinish(self: *Self) void {
        // 当前默认同步实现：无额外处理，仅更新状态
        if (self.status == .generating_data and
            self.current_page + 1 >= self.n_pages_to_print)
        {
            self.setStatusInternal(.sending_data);
        }
    }

    // ── 核心：run（简化实现，模拟同步执行） ──────────────────────────────────

    /// 简化版 GtkPrintOperation.run
    /// parent_window 预留，当前无需；返回结果枚举
    pub fn run(self: *Self, action: PrintOperationAction) PrintOperationResult {
        if (action == .export_ and self.export_filename.len == 0) {
            self.last_error = "export_filename 为空";
            self.setStatusInternal(.finished_aborted);
            if (self.on_done) |d| d(self, .error_);
            return .error_;
        }

        // 1) dialog 类动作本应弹窗，此处简化为直接 applied/success 结果
        if (action == .print_dialog) {
            self.setStatusInternal(.preparing);
            if (self.on_status_changed) |c| c(self);
        }

        if (action == .preview) {
            const ctx = PrintContext.fromOperation(self);
            const handled = if (self.on_preview) |p| p(self, ctx, ctx) else false;
            if (handled) return .success;
        }

        // 2) begin_print: 决定页数
        self.setStatusInternal(.preparing);
        const ctx = PrintContext.fromOperation(self);
        if (self.on_begin_print) |b| b(self, ctx);

        if (self.n_pages_to_print <= 0) {
            self.last_error = "没有可打印的页面";
            self.setStatusInternal(.finished_aborted);
            if (self.on_end_print) |e| e(self, ctx);
            if (self.on_done) |d| d(self, .error_);
            return .error_;
        }

        // 3) draw_page 逐页
        self.setStatusInternal(.generating_data);
        var i: i32 = 0;
        while (i < self.n_pages_to_print) : (i += 1) {
            self.current_page = i;
            if (self.on_status_changed) |c| c(self);
            if (self.on_draw_page) |d| d(self, ctx, i);
        }

        // 4) end_print
        self.setStatusInternal(.sending_data);
        if (self.on_status_changed) |c| c(self);

        if (action == .export_) {
            // 模拟导出：保留文件名到设置
            if (self.print_settings) |*s| s.output_uri = self.export_filename;
        }

        self.setStatusInternal(.finished);
        if (self.on_end_print) |e| e(self, ctx);
        if (self.on_done) |d| d(self, .success);
        return .success;
    }

    fn setStatusInternal(self: *Self, s: PrintOperationStatus) void {
        if (self.status != s) {
            self.status = s;
            if (self.on_status_changed) |c| c(self);
        }
    }

    // ── 便捷：取消正在进行的打印 ────────────────────────────────────────

    pub fn cancel(self: *Self) void {
        switch (self.status) {
            .initial, .finished, .finished_aborted => {},
            else => {
                self.setStatusInternal(.finished_aborted);
                if (self.on_done) |d| d(self, .user_cancel);
            },
        }
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 便捷：创建一份测试用的空 PDF 打印设置
// ──────────────────────────────────────────────────────────────────────────────

pub fn defaultExportSettings() PrintSettings {
    var s = PrintSettings.default();
    s.printer = "Print to File";
    s.output_uri = "output.pdf";
    s.n_copies = 1;
    s.collate = true;
    s.reverse = false;
    s.quality = .normal;
    s.duplex = .simplex;
    s.color_mode = .color;
    return s;
}
