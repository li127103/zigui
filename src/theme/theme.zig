//! 主题系统

const math = @import("../math.zig");

pub const ColorPalette = struct {
    primary: math.Color,
    primary_hover: math.Color,
    primary_pressed: math.Color,
    secondary: math.Color,
    background: math.Color,
    surface: math.Color,
    surface_hover: math.Color,
    text_primary: math.Color,
    text_secondary: math.Color,
    text_disabled: math.Color,
    border: math.Color,
    border_focus: math.Color,
    @"error": math.Color,
    warning: math.Color,
    success: math.Color,
    overlay: math.Color,
    shadow: math.Color,
    selection: math.Color,
};

pub const FontPalette = struct {
    family: []const u8 = "system-ui",
    size_body: f32 = 14,
    size_small: f32 = 12,
    size_large: f32 = 16,
    size_title: f32 = 20,
};

pub const MetricsPalette = struct {
    border_radius_sm: f32 = 4,
    border_radius_md: f32 = 6,
    border_radius_lg: f32 = 8,
    border_width: f32 = 1,
    focus_ring_width: f32 = 2,
    spacing_xs: f32 = 4,
    spacing_sm: f32 = 8,
    spacing_md: f32 = 12,
    spacing_lg: f32 = 16,
    spacing_xl: f32 = 24,
    control_height: f32 = 32,
    control_height_sm: f32 = 24,
    control_height_lg: f32 = 40,
    icon_size: f32 = 16,
    scroll_bar_width: f32 = 8,
};

pub const Theme = struct {
    name: []const u8,
    colors: ColorPalette,
    fonts: FontPalette = .{},
    metrics: MetricsPalette = .{},
};

/// 内置亮色主题
pub const light = Theme{
    .name = "light",
    .colors = .{
        .primary = math.Color.hex(0x2563EBFF),
        .primary_hover = math.Color.hex(0x1D4ED8FF),
        .primary_pressed = math.Color.hex(0x1E40AFFF),
        .secondary = math.Color.hex(0x64748BFF),
        .background = math.Color.hex(0xFFFFFFFF),
        .surface = math.Color.hex(0xF8FAFCFF),
        .surface_hover = math.Color.hex(0xF1F5F9FF),
        .text_primary = math.Color.hex(0x0F172AFF),
        .text_secondary = math.Color.hex(0x475569FF),
        .text_disabled = math.Color.hex(0x94A3B8FF),
        .border = math.Color.hex(0xE2E8F0FF),
        .border_focus = math.Color.hex(0x2563EBFF),
        .@"error" = math.Color.hex(0xDC2626FF),
        .warning = math.Color.hex(0xD97706FF),
        .success = math.Color.hex(0x16A34AFF),
        .overlay = math.Color.hex(0x00000066),
        .shadow = math.Color.hex(0x0000001A),
        .selection = math.Color.hex(0x2563EB33),
    },
};

/// 内置暗色主题
pub const dark = Theme{
    .name = "dark",
    .colors = .{
        .primary = math.Color.hex(0x3B82F6FF),
        .primary_hover = math.Color.hex(0x60A5FAFF),
        .primary_pressed = math.Color.hex(0x2563EBFF),
        .secondary = math.Color.hex(0x94A3B8FF),
        .background = math.Color.hex(0x0F172AFF),
        .surface = math.Color.hex(0x1E293BFF),
        .surface_hover = math.Color.hex(0x334155FF),
        .text_primary = math.Color.hex(0xF8FAFCFF),
        .text_secondary = math.Color.hex(0xCBD5E1FF),
        .text_disabled = math.Color.hex(0x475569FF),
        .border = math.Color.hex(0x334155FF),
        .border_focus = math.Color.hex(0x3B82F6FF),
        .@"error" = math.Color.hex(0xEF4444FF),
        .warning = math.Color.hex(0xF59E0BFF),
        .success = math.Color.hex(0x22C55EFF),
        .overlay = math.Color.hex(0x00000099),
        .shadow = math.Color.hex(0x00000040),
        .selection = math.Color.hex(0x3B82F633),
    },
};
