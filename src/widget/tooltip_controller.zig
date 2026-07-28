//! Tooltip 控制器 - 自动管理 Widget 级别的工具提示
//!
//! 使用方式:
//!   1. 在根控件下添加一个 Tooltip 控件
//!   2. 创建 TooltipController
//!   3. 每帧调用 update(hover_widget, mouse_x, mouse_y, delta_ms)
//!   4. 给任意控件设置 widget.tooltip_text = "..."
//!
//! 控制器会自动:
//!   - 检测鼠标下方有 tooltip_text 的控件
//!   - 延迟 500ms 显示 tooltip
//!   - 鼠标移开时隐藏

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const tooltip_mod = @import("tooltip.zig");

const Widget = widget_mod.Widget;
const Tooltip = tooltip_mod.Tooltip;

pub const TooltipController = struct {
    tooltip: *Tooltip,
    /// 悬停延迟 (ms)
    delay_ms: u32 = 500,
    hover_ms: u32 = 0,
    last_widget_id: ?u64 = null,

    pub fn init(tooltip: *Tooltip) TooltipController {
        return .{ .tooltip = tooltip };
    }

    /// 每帧更新: 检测 hover 控件并管理 tooltip 显示
    pub fn update(self: *TooltipController, root: *Widget, mouse_x: f32, mouse_y: f32, delta_ms: u32) void {
        const hit = root.hitTest(mouse_x, mouse_y);

        if (hit) |w| {
            const tip_text = w.findTooltip();
            const wid = w.id;

            if (tip_text) |text| {
                if (self.last_widget_id != wid) {
                    self.last_widget_id = wid;
                    self.hover_ms = 0;
                    self.tooltip.hideTooltip();
                }

                self.hover_ms += delta_ms;
                if (self.hover_ms >= self.delay_ms) {
                    if (!self.tooltip.visible or !std.mem.eql(u8, self.tooltip.text, text)) {
                        self.tooltip.text = text;
                        self.tooltip.showAt(mouse_x, mouse_y);
                    } else if (self.tooltip.visible) {
                        self.tooltip.pos_x = mouse_x;
                        self.tooltip.pos_y = mouse_y;
                    }
                }
            } else {
                if (self.tooltip.visible) {
                    self.tooltip.hideTooltip();
                }
                self.last_widget_id = null;
                self.hover_ms = 0;
            }
        } else {
            if (self.tooltip.visible) {
                self.tooltip.hideTooltip();
            }
            self.last_widget_id = null;
            self.hover_ms = 0;
        }
    }
};
