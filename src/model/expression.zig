//! Expression — 表达式求值系统 (简化版 GtkExpression)
//!
//! GtkExpression 在 GTK4 里用于：
//!   - 属性绑定: `label.set_expression_label(property_expression(other, "title"))`
//!   - Sorter/Filter 的属性抽取: `string_sorter.set_expression(property_expression(item, "name"))`
//!
//! Zig 版本采用简化设计 (类型擦除 + 显式 getter)：
//!   - `Value`：复用 ActionValue (none/bool/int/uint/float/string)，避免重复造轮子
//!   - `Expression`：tagged union (constant / property / closure)
//!   - 内置预设工厂 (StringObject / FileInfo / BookmarkInfo)
//!
//! 典型用法：
//! ```
//! const expr = Expression.propertyForStringObject();  // 抽取 .string
//! const v = expr.evaluate(string_object_item_ptr);
//! // v.string == "Apple"
//! ```

const std = @import("std");
const action_mod = @import("action.zig");
const ActionValue = action_mod.ActionValue;
const string_list = @import("string_list.zig");
const StringObject = string_list.StringObject;
const directory_list = @import("directory_list.zig");
const FileInfo = directory_list.FileInfo;
const bookmark_list = @import("bookmark_list.zig");
const BookmarkInfo = bookmark_list.BookmarkInfo;

pub const Value = ActionValue;

/// 表达式 (简化版 GtkExpression)
pub const Expression = struct {
    pub const Self = @This();

    pub const Kind = enum {
        constant,
        property,
        closure,
    };

    pub const PropertyGetter = *const fn (obj: ?*anyopaque) Value;
    pub const ClosureFunc = *const fn (obj: ?*anyopaque, userdata: ?*anyopaque) Value;

    kind: Kind,
    payload: union(Kind) {
        constant: Value,
        property: struct {
            name: []const u8,
            get: PropertyGetter,
        },
        closure: struct {
            name: []const u8 = "",
            cb: ClosureFunc,
            userdata: ?*anyopaque = null,
        },
    },

    // ── 工厂 ──────────────────────────────────────────────────────────────

    /// 常量表达式
    pub fn constant(v: Value) Self {
        return .{
            .kind = .constant,
            .payload = .{ .constant = v },
        };
    }

    /// 自定义属性表达式
    pub fn property(name: []const u8, getter: PropertyGetter) Self {
        return .{
            .kind = .property,
            .payload = .{ .property = .{ .name = name, .get = getter } },
        };
    }

    /// 闭包表达式
    pub fn closure(name: []const u8, cb: ClosureFunc, userdata: ?*anyopaque) Self {
        return .{
            .kind = .closure,
            .payload = .{ .closure = .{ .name = name, .cb = cb, .userdata = userdata } },
        };
    }

    // ── 预设: StringObject ───────────────────────────────────────────────

    /// 抽取 StringObject.string
    pub fn forStringObjectString() Self {
        return property("string", struct {
            fn get(obj: ?*anyopaque) Value {
                const o: *StringObject = @ptrCast(@alignCast(obj orelse return .none));
                return .{ .string = o.string };
            }
        }.get);
    }

    // ── 预设: FileInfo ────────────────────────────────────────────────────

    /// 抽取 FileInfo.name
    pub fn forFileInfoName() Self {
        return property("name", struct {
            fn get(obj: ?*anyopaque) Value {
                const f: *FileInfo = @ptrCast(@alignCast(obj orelse return .none));
                return .{ .string = f.name };
            }
        }.get);
    }

    /// 抽取 FileInfo.full_path
    pub fn forFileInfoFullPath() Self {
        return property("full_path", struct {
            fn get(obj: ?*anyopaque) Value {
                const f: *FileInfo = @ptrCast(@alignCast(obj orelse return .none));
                return .{ .string = f.full_path };
            }
        }.get);
    }

    /// 抽取 FileInfo.size (uint64)
    pub fn forFileInfoSize() Self {
        return property("size", struct {
            fn get(obj: ?*anyopaque) Value {
                const f: *FileInfo = @ptrCast(@alignCast(obj orelse return .none));
                return .{ .uint = f.size };
            }
        }.get);
    }

    /// 抽取 FileInfo.mtime_sec (int)
    pub fn forFileInfoMtime() Self {
        return property("mtime_sec", struct {
            fn get(obj: ?*anyopaque) Value {
                const f: *FileInfo = @ptrCast(@alignCast(obj orelse return .none));
                return .{ .int = f.mtime_sec };
            }
        }.get);
    }

    /// 抽取 FileInfo.is_dir (bool)
    pub fn forFileInfoIsDir() Self {
        return property("is_dir", struct {
            fn get(obj: ?*anyopaque) Value {
                const f: *FileInfo = @ptrCast(@alignCast(obj orelse return .none));
                return .{ .bool_ = f.is_dir };
            }
        }.get);
    }

    // ── 预设: BookmarkInfo ────────────────────────────────────────────────

    pub fn forBookmarkLabel() Self {
        return property("label", struct {
            fn get(obj: ?*anyopaque) Value {
                const b: *BookmarkInfo = @ptrCast(@alignCast(obj orelse return .none));
                return .{ .string = b.label };
            }
        }.get);
    }

    pub fn forBookmarkPath() Self {
        return property("path", struct {
            fn get(obj: ?*anyopaque) Value {
                const b: *BookmarkInfo = @ptrCast(@alignCast(obj orelse return .none));
                return .{ .string = b.path };
            }
        }.get);
    }

    pub fn forBookmarkUri() Self {
        return property("uri", struct {
            fn get(obj: ?*anyopaque) Value {
                const b: *BookmarkInfo = @ptrCast(@alignCast(obj orelse return .none));
                return .{ .string = b.uri };
            }
        }.get);
    }

    // ── 求值 ──────────────────────────────────────────────────────────────

    /// 对 obj (通常是 ListModel 的 item 指针) 求值，返回 Value
    pub fn evaluate(self: *const Self, obj: ?*anyopaque) Value {
        switch (self.kind) {
            .constant => |c| return c,
            .property => |p| return p.get(obj),
            .closure => |c| return c.cb(obj, c.userdata),
        }
    }

    /// 返回表达式名 (用于调试/排序器属性名)
    pub fn getName(self: *const Self) []const u8 {
        switch (self.kind) {
            .constant => return "constant",
            .property => |p| return p.name,
            .closure => |c| return c.name,
        }
    }
};

/// 值比较 (用于 Sorter)
/// 支持: int / uint / float / bool / string; 跨类型比较先比 type tag
pub fn compareValues(a: Value, b: Value) std.math.Order {
    const tag_a: u8 = @intFromEnum(a);
    const tag_b: u8 = @intFromEnum(b);
    if (tag_a != tag_b) return std.math.order(tag_a, tag_b);
    switch (a) {
        .none => return .eq,
        .bool_ => |x| return std.math.order(@intFromBool(x), @intFromBool(b.bool_)),
        .int => |x| return std.math.order(x, b.int),
        .uint => |x| return std.math.order(x, b.uint),
        .float => |x| return std.math.order(x, b.float),
        .string => |x| return std.ascii.compareIgnoreCase(x, b.string),
    }
}
