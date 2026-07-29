//! ListModel / ListStore — GTK4 风格的抽象列表模型 (对应 Gio.ListModel / GListStore)
//!
//! 架构:
//! - `ListModelIface` — 纯虚函数表接口 (getItem/getNItems/itemType)
//! - `ListModel` — 胖指针 (iface + instance data)，便于传递
//! - `ListStore(T)` — 泛型动态数组实现，支持 append/prepend/insert/remove/splice
//! - 可选的 itemsChanged 信号回调 (items-changed)
//!
//! 用法示例:
//! ```zig
//! var store = try ListStore([]const u8).new(allocator, "string");
//! try store.append("Hello");
//! try store.append("World");
//! const model = store.model();  // 擦除类型，得到 ListModel
//! const n = model.nItems();     // = 2
//! const first = model.getItem([]const u8, 0); // = "Hello"
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 任何 ListModel 都要实现的虚表
pub const ListModelIface = struct {
    /// 返回第 position 个元素的指针 (可空)。调用者保证 position < nItems()
    getItemFn: *const fn (userdata: ?*anyopaque, position: usize) ?*anyopaque,
    /// 返回元素数量
    getNItemsFn: *const fn (userdata: ?*anyopaque) usize,
    /// 返回项目类型名 (用于调试)
    getItemTypeFn: *const fn (userdata: ?*anyopaque) []const u8,
    /// 销毁 userdata (ListModel 拥有者负责实际 free；这里只是可选钩子)
    destroyFn: ?*const fn (userdata: ?*anyopaque) void = null,
};

/// 擦除类型的 ListModel 胖指针
pub const ListModel = struct {
    iface: *const ListModelIface,
    userdata: ?*anyopaque = null,

    pub fn getItem(self: ListModel, comptime T: type, position: usize) ?*T {
        const raw = self.iface.getItemFn(self.userdata, position);
        return if (raw) |p| @ptrCast(@alignCast(p)) else null;
    }

    pub fn nItems(self: ListModel) usize {
        return self.iface.getNItemsFn(self.userdata);
    }

    pub fn itemType(self: ListModel) []const u8 {
        return self.iface.getItemTypeFn(self.userdata);
    }
};

/// 项目变更回调: (position, removed count, added count)
pub const ItemsChangedFn = *const fn (userdata: ?*anyopaque, position: usize, removed: usize, added: usize) void;

/// 泛型 ListStore: 基于 ArrayListUnmanaged + 可重复 dup 的值语义存储
pub fn ListStore(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        items: std.ArrayListUnmanaged(T) = .{},
        /// 元素 dup 函数 (当 T 是字符串/指针类型时，让 Store 拥有副本)
        dupFn: ?*const fn (allocator: Allocator, value: T) Allocator.Error!T = null,
        /// 元素 free 函数 (匹配 dup)
        freeFn: ?*const fn (allocator: Allocator, value: *T) void = null,

        type_name: []const u8,

        /// 变更信号 (单一回调，够用；需要多 slot 可自行在外部分发)
        on_items_changed: ?ItemsChangedFn = null,
        on_items_changed_userdata: ?*anyopaque = null,

        // 静态 iface 实例 (为 Self 生成)
        const static_iface = ListModelIface{
            .getItemFn = getItemFn,
            .getNItemsFn = getNItemsFn,
            .getItemTypeFn = getTypeFn,
        };

        pub const NewOpts = struct {
            dup_fn: ?*const fn (alloc: Allocator, value: T) Allocator.Error!T = null,
            free_fn: ?*const fn (alloc: Allocator, value: *T) void = null,
        };

        pub fn new(
            allocator: Allocator,
            type_name: []const u8,
            opts: NewOpts,
        ) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .items = .{},
                .dupFn = opts.dup_fn,
                .freeFn = opts.free_fn,
                .type_name = type_name,
            };
            return self;
        }

        pub fn destroy(self: *Self) void {
            // free each with freeFn (若有)
            if (self.freeFn) |free| {
                for (self.items.items) |*it| {
                    free(self.allocator, it);
                }
            }
            self.items.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        /// 取出擦除类型的模型
        pub fn model(self: *Self) ListModel {
            return .{
                .iface = &static_iface,
                .userdata = self,
            };
        }

        pub fn nItems(self: *const Self) usize {
            return self.items.items.len;
        }

        /// 直接索引 (编译期类型安全)
        pub fn at(self: *const Self, position: usize) ?*T {
            if (position >= self.items.items.len) return null;
            return &self.items.items[position];
        }

        /// 追加 (dup 后 append)
        pub fn append(self: *Self, value: T) !void {
            const v = if (self.dupFn) |dup| try dup(self.allocator, value) else value;
            try self.items.append(self.allocator, v);
            self.emitChanged(self.items.items.len - 1, 0, 1);
        }

        /// 追加 (直接窃取所有权，不 dup)
        pub fn appendOwned(self: *Self, value: T) !void {
            try self.items.append(self.allocator, value);
            self.emitChanged(self.items.items.len - 1, 0, 1);
        }

        pub fn prepend(self: *Self, value: T) !void {
            try self.insert(0, value);
        }

        pub fn insert(self: *Self, position: usize, value: T) !void {
            const v = if (self.dupFn) |dup| try dup(self.allocator, value) else value;
            try self.items.insert(self.allocator, position, v);
            self.emitChanged(position, 0, 1);
        }

        pub fn remove(self: *Self, position: usize) void {
            if (position >= self.items.items.len) return;
            if (self.freeFn) |free| {
                free(self.allocator, &self.items.items[position]);
            }
            _ = self.items.orderedRemove(position);
            self.emitChanged(position, 1, 0);
        }

        pub fn clear(self: *Self) void {
            const len = self.items.items.len;
            if (len == 0) return;
            if (self.freeFn) |free| {
                for (self.items.items) |*it| free(self.allocator, it);
            }
            self.items.clearRetainingCapacity();
            self.emitChanged(0, len, 0);
        }

        /// 批量替换 (splice)：从 position 起，删除 removed 个，插入 added_len 个值
        pub fn splice(self: *Self, position: usize, removed: usize, added: []const T) !void {
            const safe_removed = @min(removed, self.items.items.len -| position);
            if (self.freeFn) |free| {
                for (0..safe_removed) |i| {
                    free(self.allocator, &self.items.items[position + i]);
                }
            }
            // 删除
            for (0..safe_removed) |_| {
                _ = self.items.orderedRemove(position);
            }
            // 插入 (dup 后)
            var added_owned: std.ArrayListUnmanaged(T) = .{};
            defer {
                // 如果中途失败，释放我们已 dup 的
                for (added_owned.items) |*it| {
                    if (self.freeFn) |free| free(self.allocator, it);
                }
                added_owned.deinit(self.allocator);
            }
            for (added) |a| {
                const v = if (self.dupFn) |dup| try dup(self.allocator, a) else a;
                try added_owned.append(self.allocator, v);
            }
            // 原子性 insert slice
            try self.items.insertSlice(self.allocator, position, added_owned.items);
            _ = added_owned.toOwnedSlice(self.allocator);
            self.emitChanged(position, safe_removed, added.len);
        }

        pub fn set(self: *Self, position: usize, value: T) void {
            if (position >= self.items.items.len) return;
            if (self.freeFn) |free| free(self.allocator, &self.items.items[position]);
            self.items.items[position] = if (self.dupFn) |dup|
                dup(self.allocator, value) catch self.items.items[position]
            else
                value;
            self.emitChanged(position, 1, 1);
        }

        /// 发出 items-changed 信号
        pub fn emitChanged(self: *Self, position: usize, removed: usize, added: usize) void {
            if (self.on_items_changed) |cb| {
                cb(self.on_items_changed_userdata, position, removed, added);
            }
        }

        fn getItemFn(userdata: ?*anyopaque, position: usize) ?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(userdata orelse return null));
            if (position >= self.items.items.len) return null;
            return @ptrCast(&self.items.items[position]);
        }

        fn getNItemsFn(userdata: ?*anyopaque) usize {
            const self: *Self = @ptrCast(@alignCast(userdata orelse return 0));
            return self.items.items.len;
        }

        fn getTypeFn(userdata: ?*anyopaque) []const u8 {
            const self: *Self = @ptrCast(@alignCast(userdata orelse return "unknown"));
            return self.type_name;
        }
    };
}

/// 便利：基于字符串的 ListStore (dup/free 已自动配置)
pub const StringListStore = ListStore([]const u8);

/// dup 字符串
pub fn dupString(allocator: Allocator, value: []const u8) Allocator.Error![]const u8 {
    return try allocator.dupe(u8, value);
}

/// free 字符串
pub fn freeString(allocator: Allocator, value: *[]const u8) void {
    if (value.len > 0) allocator.free(value.*);
}

/// 创建一个字符串列表 store，自动带 dup/free
pub fn newStringListStore(allocator: Allocator) !*StringListStore {
    return try StringListStore.new(allocator, "string", .{
        .dup_fn = &dupString,
        .free_fn = &freeString,
    });
}
