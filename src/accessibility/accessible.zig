//! Accessibility 无障碍系统
//!
//! 提供无障碍支持的基础框架，包括角色定义、状态集、
//! 无障碍属性和事件通知。
//!
//! 使用方法:
//! ```
//! var accessible = try Accessible.create(allocator, .{
//!     .role = .button,
//!     .name = "确定按钮",
//!     .description = "点击确认操作",
//! });
//! accessible.setState(.focused, true);
//! ```

const std = @import("std");
const math = @import("../math.zig");

/// 无障碍角色 - 定义控件的语义类型
pub const AccessibleRole = enum {
    none,
    button,
    check_button,
    radio_button,
    toggle_button,
    link,
    label,
    entry,
    text,
    search_entry,
    password_text,
    combo_box,
    list,
    list_item,
    tree,
    tree_item,
    menu,
    menu_bar,
    menu_item,
    check_menu_item,
    radio_menu_item,
    separator,
    tool_bar,
    tool_item,
    tool_tip,
    scroll_bar,
    scroll_view,
    progress_bar,
    slider,
    spin_button,
    switch_widget,
    icon_view,
    table,
    table_cell,
    table_row,
    table_column,
    tab,
    tab_list,
    window,
    dialog,
    message_box,
    file_chooser,
    color_chooser,
    font_chooser,
    status_bar,
    info_bar,
    expander,
    accordion,
    panel,
    frame,
    aspect_frame,
    drawing_area,
    image,
    calendar,
    level_bar,
    scale,
};

/// 无障碍状态 - 控件的各种状态标志
pub const AccessibleState = packed struct(u64) {
    sensitive: bool = true,
    enabled: bool = true,
    visible: bool = true,
    showing: bool = true,
    focused: bool = false,
    selected: bool = false,
    pressed: bool = false,
    checked: bool = false,
    indeterminate: bool = false,
    expanded: bool = false,
    collapsed: bool = false,
    busy: bool = false,
    read_only: bool = false,
    editable: bool = true,
    multiline: bool = false,
    selectable: bool = false,
    modal: bool = false,
    has_popup: bool = false,
    has_tooltip: bool = false,
    invalid_entry: bool = false,
    truncated: bool = false,
    wraps: bool = false,
    horizontal: bool = false,
    vertical: bool = false,
    default_button: bool = false,
    resizable: bool = false,
    selectable_text: bool = false,
    manages_descendants: bool = false,
    focusable: bool = true,
    active: bool = false,
    live_polite: bool = false,
    live_assertive: bool = false,
    _padding: u32 = 0,

    pub fn empty() AccessibleState {
        return .{ .sensitive = false, .enabled = false, .visible = false, .showing = false, .editable = false, .focusable = false };
    }

    pub fn set(self: *AccessibleState, comptime field: @typeInfo(AccessibleState).Struct.fields[0].type, value: bool) void {
        @field(self, @tagName(field)) = value;
    }

    pub fn get(self: *const AccessibleState, comptime field: @typeInfo(AccessibleState).Struct.fields[0].type) bool {
        return @field(self, @tagName(field));
    }
};

/// 无障碍关系类型
pub const AccessibleRelation = enum {
    label_for,
    labelled_by,
    controller_for,
    controlled_by,
    member_of,
    flows_to,
    flows_from,
    subwindow_of,
    parent_window_of,
    popup_for,
    details,
    description_for,
    described_by,
    error_message,
    error_for,
};

/// 无障碍属性集合
pub const Accessible = struct {
    allocator: std.mem.Allocator,
    role: AccessibleRole = .none,
    name: []const u8 = "",
    description: []const u8 = "",
    placeholder: []const u8 = "",
    value: f64 = 0,
    min_value: f64 = 0,
    max_value: f64 = 100,
    value_text: []const u8 = "",
    state: AccessibleState = .{},
    parent: ?*anyopaque = null,

    on_state_changed: ?*const fn (self: *Accessible, state: AccessibleState) void = null,
    on_name_changed: ?*const fn (self: *Accessible, name: []const u8) void = null,
    on_focus: ?*const fn (self: *Accessible) void = null,
    on_activate: ?*const fn (self: *Accessible) void = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        role: AccessibleRole = .none,
        name: []const u8 = "",
        description: []const u8 = "",
        placeholder: []const u8 = "",
        value: f64 = 0,
        min_value: f64 = 0,
        max_value: f64 = 100,
        state: AccessibleState = .{},
        parent: ?*anyopaque = null,
        on_state_changed: ?*const fn (self: *Accessible, state: AccessibleState) void = null,
        on_name_changed: ?*const fn (self: *Accessible, name: []const u8) void = null,
        on_focus: ?*const fn (self: *Accessible) void = null,
        on_activate: ?*const fn (self: *Accessible) void = null,
    }) !*Accessible {
        const self = try allocator.create(Accessible);
        self.* = .{
            .allocator = allocator,
            .role = opts.role,
            .name = if (opts.name.len > 0) try allocator.dupe(u8, opts.name) else "",
            .description = if (opts.description.len > 0) try allocator.dupe(u8, opts.description) else "",
            .placeholder = if (opts.placeholder.len > 0) try allocator.dupe(u8, opts.placeholder) else "",
            .value = opts.value,
            .min_value = opts.min_value,
            .max_value = opts.max_value,
            .state = opts.state,
            .parent = opts.parent,
            .on_state_changed = opts.on_state_changed,
            .on_name_changed = opts.on_name_changed,
            .on_focus = opts.on_focus,
            .on_activate = opts.on_activate,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        if (self.name.len > 0) self.allocator.free(self.name);
        if (self.description.len > 0) self.allocator.free(self.description);
        if (self.placeholder.len > 0) self.allocator.free(self.placeholder);
        if (self.value_text.len > 0) self.allocator.free(self.value_text);
        self.allocator.destroy(self);
    }

    pub fn setName(self: *Self, name: []const u8) void {
        if (self.name.len > 0) {
            self.allocator.free(self.name);
            self.name = "";
        }
        if (name.len > 0) {
            self.name = self.allocator.dupe(u8, name) catch return;
        }
        if (self.on_name_changed) |cb| cb(self, self.name);
    }

    pub fn setDescription(self: *Self, description: []const u8) void {
        if (self.description.len > 0) {
            self.allocator.free(self.description);
            self.description = "";
        }
        if (description.len > 0) {
            self.description = self.allocator.dupe(u8, description) catch return;
        }
    }

    pub fn setPlaceholder(self: *Self, placeholder: []const u8) void {
        if (self.placeholder.len > 0) {
            self.allocator.free(self.placeholder);
            self.placeholder = "";
        }
        if (placeholder.len > 0) {
            self.placeholder = self.allocator.dupe(u8, placeholder) catch return;
        }
    }

    pub fn setStateFlag(self: *Self, comptime flag: @typeInfo(AccessibleState).Struct.fields[0].type, value: bool) void {
        if (@as(bool, @field(self.state, @tagName(flag))) != value) {
            @field(self.state, @tagName(flag)) = value;
            if (self.on_state_changed) |cb| cb(self, self.state);
        }
    }

    pub fn getStateFlag(self: *const Self, comptime flag: @typeInfo(AccessibleState).Struct.fields[0].type) bool {
        return @field(self.state, @tagName(flag));
    }

    pub fn setValue(self: *Self, value: f64) void {
        self.value = value;
    }

    pub fn setRange(self: *Self, min: f64, max: f64) void {
        self.min_value = min;
        self.max_value = max;
    }

    pub fn setValueText(self: *Self, text: []const u8) void {
        if (self.value_text.len > 0) {
            self.allocator.free(self.value_text);
            self.value_text = "";
        }
        if (text.len > 0) {
            self.value_text = self.allocator.dupe(u8, text) catch return;
        }
    }

    pub fn focus(self: *Self) void {
        self.state.focused = true;
        if (self.on_focus) |cb| cb(self);
        if (self.on_state_changed) |cb| cb(self, self.state);
    }

    pub fn blur(self: *Self) void {
        self.state.focused = false;
        if (self.on_state_changed) |cb| cb(self, self.state);
    }

    pub fn activate(self: *Self) void {
        if (self.on_activate) |cb| cb(self);
    }

    pub fn getRoleName(self: *const Self) []const u8 {
        return switch (self.role) {
            .none => "none",
            .button => "button",
            .check_button => "check button",
            .radio_button => "radio button",
            .toggle_button => "toggle button",
            .link => "link",
            .label => "label",
            .entry => "entry",
            .text => "text",
            .search_entry => "search entry",
            .password_text => "password text",
            .combo_box => "combo box",
            .list => "list",
            .list_item => "list item",
            .tree => "tree",
            .tree_item => "tree item",
            .menu => "menu",
            .menu_bar => "menu bar",
            .menu_item => "menu item",
            .check_menu_item => "check menu item",
            .radio_menu_item => "radio menu item",
            .separator => "separator",
            .tool_bar => "tool bar",
            .tool_item => "tool item",
            .tool_tip => "tool tip",
            .scroll_bar => "scroll bar",
            .scroll_view => "scroll view",
            .progress_bar => "progress bar",
            .slider => "slider",
            .spin_button => "spin button",
            .switch_widget => "switch",
            .icon_view => "icon view",
            .table => "table",
            .table_cell => "table cell",
            .table_row => "table row",
            .table_column => "table column",
            .tab => "tab",
            .tab_list => "tab list",
            .window => "window",
            .dialog => "dialog",
            .message_box => "message box",
            .file_chooser => "file chooser",
            .color_chooser => "color chooser",
            .font_chooser => "font chooser",
            .status_bar => "status bar",
            .info_bar => "info bar",
            .expander => "expander",
            .accordion => "accordion",
            .panel => "panel",
            .frame => "frame",
            .aspect_frame => "aspect frame",
            .drawing_area => "drawing area",
            .image => "image",
            .calendar => "calendar",
            .level_bar => "level bar",
            .scale => "scale",
        };
    }
};

/// 无障碍事件类型
pub const AccessibleEventType = enum {
    name_changed,
    description_changed,
    state_changed,
    value_changed,
    focus,
    blur,
    activate,
    selection_changed,
    text_changed,
    caret_moved,
    show,
    hide,
    popup_menu,
    close_popup,
};

/// 无障碍事件
pub const AccessibleEvent = struct {
    event_type: AccessibleEventType,
    source: *Accessible,
    timestamp: u64 = 0,
    data: ?*anyopaque = null,
};

/// 无障碍监听器
pub const AccessibleListener = struct {
    on_event: *const fn (event: *const AccessibleEvent) void,
    user_data: ?*anyopaque = null,
};

/// 无障碍管理器 - 全局无障碍事件分发
pub const AccessibilityManager = struct {
    allocator: std.mem.Allocator,
    listeners: std.ArrayListUnmanaged(AccessibleListener) = .{ .items = &.{}, .capacity = 0 },
    focus_object: ?*Accessible = null,
    root_object: ?*Accessible = null,
    enabled: bool = true,

    var instance: ?*AccessibilityManager = null;

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*AccessibilityManager {
        if (instance) |inst| return inst;
        const self = try allocator.create(AccessibilityManager);
        self.* = .{
            .allocator = allocator,
        };
        instance = self;
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.listeners.deinit(self.allocator);
        self.allocator.destroy(self);
        if (instance == self) instance = null;
    }

    pub fn getInstance() ?*AccessibilityManager {
        return instance;
    }

    pub fn addListener(self: *Self, listener: AccessibleListener) !void {
        try self.listeners.append(self.allocator, listener);
    }

    pub fn removeListener(self: *Self, on_event: *const fn (event: *const AccessibleEvent) void) void {
        for (self.listeners.items, 0..) |l, i| {
            if (l.on_event == on_event) {
                _ = self.listeners.orderedRemove(i);
                break;
            }
        }
    }

    pub fn notify(self: *Self, event: AccessibleEvent) void {
        if (!self.enabled) return;
        for (self.listeners.items) |listener| {
            listener.on_event(&event);
        }
    }

    pub fn setFocus(self: *Self, accessible: ?*Accessible) void {
        if (self.focus_object) |old| {
            old.blur();
        }
        self.focus_object = accessible;
        if (accessible) |acc| {
            acc.focus();
        }
    }

    pub fn getFocus(self: *const Self) ?*Accessible {
        return self.focus_object;
    }

    pub fn setRoot(self: *Self, root: ?*Accessible) void {
        self.root_object = root;
    }

    pub fn getRoot(self: *const Self) ?*Accessible {
        return self.root_object;
    }

    pub fn setEnabled(self: *Self, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn isEnabled(self: *const Self) bool {
        return self.enabled;
    }

    pub fn clear(self: *Self) void {
        self.listeners.clearRetainingCapacity();
        self.focus_object = null;
        self.root_object = null;
    }
};

/// 文本无障碍扩展
pub const AccessibleText = struct {
    text: []const u8 = "",
    cursor_position: usize = 0,
    selection_start: usize = 0,
    selection_end: usize = 0,
    editable: bool = true,
    multiline: bool = false,
    wrap_mode: enum { none, character, word, word_char } = .none,

    const Self = @This();

    pub fn init() AccessibleText {
        return .{};
    }

    pub fn getText(self: *const Self) []const u8 {
        return self.text;
    }

    pub fn getCharCount(self: *const Self) usize {
        return self.text.len;
    }

    pub fn setCursorPosition(self: *Self, pos: usize) void {
        self.cursor_position = pos;
    }

    pub fn getCursorPosition(self: *const Self) usize {
        return self.cursor_position;
    }

    pub fn setSelection(self: *Self, start: usize, end: usize) void {
        self.selection_start = start;
        self.selection_end = end;
    }

    pub fn getSelection(self: *const Self) struct { start: usize, end: usize } {
        return .{ .start = self.selection_start, .end = self.selection_end };
    }

    pub fn getSelectedText(self: *const Self) []const u8 {
        if (self.selection_start >= self.selection_end) return "";
        if (self.selection_end > self.text.len) return "";
        return self.text[self.selection_start..self.selection_end];
    }
};

/// 数值无障碍扩展
pub const AccessibleValue = struct {
    current_value: f64 = 0,
    min_value: f64 = 0,
    max_value: f64 = 100,
    step_increment: f64 = 1,
    page_increment: f64 = 10,

    const Self = @This();

    pub fn init() AccessibleValue {
        return .{};
    }

    pub fn getCurrentValue(self: *const Self) f64 {
        return self.current_value;
    }

    pub fn setCurrentValue(self: *Self, value: f64) void {
        self.current_value = @max(self.min_value, @min(self.max_value, value));
    }

    pub fn increment(self: *Self) void {
        self.setCurrentValue(self.current_value + self.step_increment);
    }

    pub fn decrement(self: *Self) void {
        self.setCurrentValue(self.current_value - self.step_increment);
    }

    pub fn pageIncrement(self: *Self) void {
        self.setCurrentValue(self.current_value + self.page_increment);
    }

    pub fn pageDecrement(self: *Self) void {
        self.setCurrentValue(self.current_value - self.page_increment);
    }

    pub fn getMinimumValue(self: *const Self) f64 {
        return self.min_value;
    }

    pub fn getMaximumValue(self: *const Self) f64 {
        return self.max_value;
    }

    pub fn setRange(self: *Self, min: f64, max: f64) void {
        self.min_value = min;
        self.max_value = max;
        if (self.current_value < min) self.current_value = min;
        if (self.current_value > max) self.current_value = max;
    }
};
