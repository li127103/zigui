//! UI 构建器 - 从 JSON 描述构建控件树
//!
//! 类似 GTK 的 GtkBuilder, 支持从 JSON 描述文件构建 UI.
//!
//! JSON 格式示例:
//! ```json
//! {
//!   "type": "container",
//!   "direction": "column",
//!   "children": [
//!     { "type": "label", "text": "Hello", "font_size": 18 },
//!     { "type": "button", "text": "Click Me", "id": "btn1" }
//!   ]
//! }
//! ```

const std = @import("std");
const math = @import("math.zig");
const layout_mod = @import("layout/engine.zig");

const Widget = @import("widget/widget.zig").Widget;
const Container = @import("widget/container.zig").Container;
const Label = @import("widget/label.zig").Label;
const Button = @import("widget/button.zig").Button;
const TextInput = @import("widget/text_input.zig").TextInput;
const ScrollView = @import("widget/scroll_view.zig").ScrollView;
const CheckBox = @import("widget/checkbox.zig").Checkbox;
const Switch = @import("widget/switch.zig").Switch;
const Slider = @import("widget/slider.zig").Slider;
const ProgressBar = @import("widget/progress_bar.zig").ProgressBar;
const Spinner = @import("widget/spinner.zig").Spinner;
const Separator = @import("widget/separator.zig").Separator;
const SeparatorOrientation = @import("widget/separator.zig").SeparatorOrientation;
const Frame = @import("widget/frame.zig").Frame;
const Expander = @import("widget/expander.zig").Expander;
const Stack = @import("widget/stack.zig").Stack;
const Grid = @import("widget/grid.zig").Grid;

const FlexDirection = layout_mod.FlexDirection;

/// 构建器错误集
pub const BuilderError = error{
    InvalidJson,
    MissingType,
    InvalidType,
    UnknownWidgetType,
    NotImplemented,
    OutOfMemory,
};

/// UI 构建器
pub const Builder = struct {
    allocator: std.mem.Allocator,
    /// 已构建的控件 (按 id 索引)
    widgets: std.StringHashMap(*Widget),
    /// 从字符串解析的 JSON 对象 (持有字符串内存)
    parsed_values: std.ArrayListUnmanaged(std.json.Parsed(std.json.Value)),

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .widgets = std.StringHashMap(*Widget).init(allocator),
            .parsed_values = std.ArrayListUnmanaged(std.json.Parsed(std.json.Value)){ .items = &.{}, .capacity = 0 },
        };
    }

    pub fn deinit(self: *Builder) void {
        var it = self.widgets.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.widgets.deinit();
        for (self.parsed_values.items) |*p| {
            p.deinit();
        }
        self.parsed_values.deinit(self.allocator);
    }

    /// 从 JSON 字符串构建控件树, 返回根控件
    pub fn buildFromString(self: *Builder, json_str: []const u8) !*Widget {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_str, .{});
        try self.parsed_values.append(self.allocator, parsed);
        return try self.buildFromValue(self.parsed_values.items[self.parsed_values.items.len - 1].value);
    }

    /// 从 JSON 值构建控件树
    pub fn buildFromValue(self: *Builder, value: std.json.Value) anyerror!*Widget {
        if (value != .object) return error.InvalidJson;
        const obj = value.object;

        const type_val = obj.get("type") orelse return error.MissingType;
        if (type_val != .string) return error.InvalidType;
        const type_name = type_val.string;

        const w = try self.createWidget(type_name, obj);

        // 如果有 id, 注册到查找表
        if (obj.get("id")) |id_val| {
            if (id_val == .string) {
                const id = try self.allocator.dupe(u8, id_val.string);
                try self.widgets.put(id, w);
            }
        }

        return w;
    }

    /// 按 id 查找控件
    pub fn find(self: *Builder, id: []const u8) ?*Widget {
        return self.widgets.get(id);
    }

    /// 按 id 查找并转换为指定类型
    pub fn findTyped(self: *Builder, comptime T: type, id: []const u8) ?*T {
        const w = self.find(id) orelse return null;
        const result: *T = @fieldParentPtr("base", w);
        return result;
    }

    fn createWidget(self: *Builder, type_name: []const u8, obj: std.json.ObjectMap) !*Widget {
        if (std.mem.eql(u8, type_name, "container")) {
            return try self.buildContainer(obj);
        } else if (std.mem.eql(u8, type_name, "label")) {
            return try self.buildLabel(obj);
        } else if (std.mem.eql(u8, type_name, "button")) {
            return try self.buildButton(obj);
        } else if (std.mem.eql(u8, type_name, "text_input")) {
            return try self.buildTextInput(obj);
        } else if (std.mem.eql(u8, type_name, "scroll_view")) {
            return try self.buildScrollView(obj);
        } else if (std.mem.eql(u8, type_name, "checkbox")) {
            return try self.buildCheckBox(obj);
        } else if (std.mem.eql(u8, type_name, "switch")) {
            return try self.buildSwitch(obj);
        } else if (std.mem.eql(u8, type_name, "slider")) {
            return try self.buildSlider(obj);
        } else if (std.mem.eql(u8, type_name, "progress_bar")) {
            return try self.buildProgressBar(obj);
        } else if (std.mem.eql(u8, type_name, "spinner")) {
            return try self.buildSpinner(obj);
        } else if (std.mem.eql(u8, type_name, "separator")) {
            return try self.buildSeparator(obj);
        } else if (std.mem.eql(u8, type_name, "frame")) {
            return try self.buildFrame(obj);
        } else if (std.mem.eql(u8, type_name, "expander")) {
            return try self.buildExpander(obj);
        } else if (std.mem.eql(u8, type_name, "stack")) {
            return try self.buildStack(obj);
        } else if (std.mem.eql(u8, type_name, "grid")) {
            return try self.buildGrid(obj);
        }
        return error.UnknownWidgetType;
    }

    fn getString(obj: std.json.ObjectMap, key: []const u8, default: []const u8) []const u8 {
        const v = obj.get(key) orelse return default;
        if (v == .string) return v.string;
        return default;
    }

    fn getFloat(obj: std.json.ObjectMap, key: []const u8, default: f32) f32 {
        const v = obj.get(key) orelse return default;
        switch (v) {
            .float => |f| return @floatCast(f),
            .integer => |i| return @floatFromInt(i),
            else => return default,
        }
    }

    fn getBool(obj: std.json.ObjectMap, key: []const u8, default: bool) bool {
        const v = obj.get(key) orelse return default;
        if (v == .bool) return v.bool;
        return default;
    }

    fn getColor(obj: std.json.ObjectMap, key: []const u8, default: math.Color) math.Color {
        const v = obj.get(key) orelse return default;
        if (v == .string) {
            var s = v.string;
            // 支持 #RRGGBB / #RRGGBBAA / 0xRRGGBBAA / 0xRRGGBB
            var start: usize = 0;
            if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
                start = 2;
            } else if (s.len >= 1 and s[0] == '#') {
                start = 1;
            }
            const hex_part = s[start..];
            if (hex_part.len >= 6) {
                const r = std.fmt.parseInt(u8, hex_part[0..2], 16) catch return default;
                const g = std.fmt.parseInt(u8, hex_part[2..4], 16) catch return default;
                const b = std.fmt.parseInt(u8, hex_part[4..6], 16) catch return default;
                const a: u8 = if (hex_part.len >= 8)
                    std.fmt.parseInt(u8, hex_part[6..8], 16) catch 0xFF
                else
                    0xFF;
                return math.Color.rgba(r, g, b, a);
            }
        }
        return default;
    }

    fn buildChildren(self: *Builder, parent: *Widget, children: std.json.Array) !void {
        for (children.items) |child_val| {
            const child = try self.buildFromValue(child_val);
            try parent.addChild(self.allocator, child);
        }
    }

    fn buildContainer(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        const dir_str = getString(obj, "direction", "column");
        const direction: FlexDirection = if (std.mem.eql(u8, dir_str, "row")) .row else .column;

        const gap_w = getFloat(obj, "gap_width", 0);
        const gap_h = getFloat(obj, "gap_height", 0);

        const c = try Container.create(self.allocator, .{
            .direction = direction,
            .gap = .{ .width = gap_w, .height = gap_h },
        });

        if (obj.get("children")) |children_val| {
            if (children_val == .array) {
                try self.buildChildren(&c.base, children_val.array);
            }
        }

        return &c.base;
    }

    fn buildLabel(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        const text = getString(obj, "text", "");
        const font_size = getFloat(obj, "font_size", 14);
        const color = getColor(obj, "color", math.Color.hex(0xF8FAFCFF));
        const use_markup = getBool(obj, "use_markup", false);

        const l = try Label.create(self.allocator, text, .{
            .font_size = font_size,
            .color = color,
            .use_markup = use_markup,
        });
        return &l.base;
    }

    fn buildButton(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        const text = getString(obj, "text", "");
        const b = try Button.create(self.allocator, text, .{});
        return &b.base;
    }

    fn buildTextInput(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        const placeholder = getString(obj, "placeholder", "");
        const max_length: u32 = @intFromFloat(getFloat(obj, "max_length", 0));
        const visibility = getBool(obj, "visibility", true);

        const ti = try TextInput.create(self.allocator, .{
            .placeholder = placeholder,
            .max_length = max_length,
            .visibility = visibility,
        });
        return &ti.base;
    }

    fn buildScrollView(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        const width = getFloat(obj, "width", 200);
        const height = getFloat(obj, "height", 200);

        const sv = try ScrollView.create(self.allocator, .{
            .width = width,
            .height = height,
        });

        if (obj.get("child")) |child_val| {
            const child = try self.buildFromValue(child_val);
            try sv.base.addChild(self.allocator, child);
        } else if (obj.get("children")) |children_val| {
            if (children_val == .array and children_val.array.items.len > 0) {
                const child = try self.buildFromValue(children_val.array.items[0]);
                try sv.base.addChild(self.allocator, child);
            }
        }

        return &sv.base;
    }

    fn buildCheckBox(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        const label = getString(obj, "label", "");
        const checked = getBool(obj, "checked", false);
        const cb = try CheckBox.create(self.allocator, label, .{ .checked = checked });
        return &cb.base;
    }

    fn buildSwitch(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        const on = getBool(obj, "on", false);
        const s = try Switch.create(self.allocator, .{ .on = on });
        return &s.base;
    }

    fn buildSlider(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        const min = getFloat(obj, "min", 0);
        const max = getFloat(obj, "max", 100);
        const value = getFloat(obj, "value", 0);
        const s = try Slider.create(self.allocator, .{ .min = min, .max = max, .value = value });
        return &s.base;
    }

    fn buildProgressBar(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        const value = getFloat(obj, "value", 0);
        const pb = try ProgressBar.create(self.allocator, .{ .fraction = value });
        return &pb.base;
    }

    fn buildSpinner(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        _ = obj;
        const s = try Spinner.create(self.allocator, .{});
        return &s.base;
    }

    fn buildSeparator(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        const orient = getString(obj, "orientation", "horizontal");
        const orientation: SeparatorOrientation = if (std.mem.eql(u8, orient, "vertical")) .vertical else .horizontal;
        const s = try Separator.create(self.allocator, .{ .orientation = orientation });
        return &s.base;
    }

    fn buildFrame(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        const title = getString(obj, "title", "");
        const f = try Frame.create(self.allocator, title, .{});

        if (obj.get("child")) |child_val| {
            const child = try self.buildFromValue(child_val);
            try f.base.addChild(self.allocator, child);
        } else if (obj.get("children")) |children_val| {
            if (children_val == .array and children_val.array.items.len > 0) {
                const child = try self.buildFromValue(children_val.array.items[0]);
                try f.base.addChild(self.allocator, child);
            }
        }

        return &f.base;
    }

    fn buildExpander(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        const label = getString(obj, "label", "");
        const expanded = getBool(obj, "expanded", false);
        const e = try Expander.create(self.allocator, label, .{});
        e.expanded = expanded;

        if (obj.get("child")) |child_val| {
            const child = try self.buildFromValue(child_val);
            try e.base.addChild(self.allocator, child);
        } else if (obj.get("children")) |children_val| {
            if (children_val == .array and children_val.array.items.len > 0) {
                const child = try self.buildFromValue(children_val.array.items[0]);
                try e.base.addChild(self.allocator, child);
            }
        }

        return &e.base;
    }

    fn buildStack(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        const s = try Stack.create(self.allocator, .{});

        if (obj.get("children")) |children_val| {
            if (children_val == .array) {
                for (children_val.array.items) |child_val| {
                    const child = try self.buildFromValue(child_val);
                    try s.base.addChild(self.allocator, child);
                }
            }
        }

        return &s.base;
    }

    fn buildGrid(self: *Builder, obj: std.json.ObjectMap) !*Widget {
        _ = obj;
        _ = self;
        return error.NotImplemented;
    }
};

// ── 测试 ──────────────────────────────────────────────────────────────────

test "Builder: basic container with label" {
    const alloc = std.testing.allocator;

    const json_str =
        \\{
        \\  "type": "container",
        \\  "direction": "column",
        \\  "children": [
        \\    { "type": "label", "text": "Hello", "id": "lbl1" },
        \\    { "type": "button", "text": "Click", "id": "btn1" }
        \\  ]
        \\}
    ;

    var builder = Builder.init(alloc);
    defer builder.deinit();

    const root = try builder.buildFromString(json_str);
    defer root.vtable.destroy(root, alloc);

    // 检查 find 和 findTyped
    const lbl = builder.findTyped(Label, "lbl1");
    try std.testing.expect(lbl != null);
    try std.testing.expectEqualStrings("Hello", lbl.?.text);

    const btn = builder.findTyped(Button, "btn1");
    try std.testing.expect(btn != null);

    // 检查找不到的情况
    try std.testing.expect(builder.find("nonexistent") == null);
}

test "Builder: text_input with placeholder" {
    const alloc = std.testing.allocator;

    const json_str =
        \\{
        \\  "type": "text_input",
        \\  "placeholder": "Enter text...",
        \\  "id": "input1"
        \\}
    ;

    var builder = Builder.init(alloc);
    defer builder.deinit();

    const root = try builder.buildFromString(json_str);
    defer root.vtable.destroy(root, alloc);

    const ti = builder.findTyped(TextInput, "input1");
    try std.testing.expect(ti != null);
}

test "Builder: nested containers" {
    const alloc = std.testing.allocator;

    const json_str =
        \\{
        \\  "type": "container",
        \\  "direction": "column",
        \\  "children": [
        \\    {
        \\      "type": "container",
        \\      "direction": "row",
        \\      "id": "row1",
        \\      "children": [
        \\        { "type": "label", "text": "A" },
        \\        { "type": "label", "text": "B" }
        \\      ]
        \\    },
        \\    { "type": "separator", "orientation": "horizontal" }
        \\  ]
        \\}
    ;

    var builder = Builder.init(alloc);
    defer builder.deinit();

    const root = try builder.buildFromString(json_str);
    defer root.vtable.destroy(root, alloc);

    const row = builder.find("row1");
    try std.testing.expect(row != null);
}
