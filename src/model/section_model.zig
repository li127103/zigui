//! GTK4 SectionModel / SectionListModel — 分段/分组列表模型
//!
//! GTK 对应: GtkSectionModel / GtkSectionListModel (GTK 4.12+)
//!
//! SectionModel 是在 ListModel 之上的扩展：
//! 视图（如 ListView）可以根据 SectionModel 将列表划分为若干段，
//! 每段渲染"段头 + 多行"的布局，实现如通讯录按字母分组、文件列表按文件夹分组等效果。
//!
//! SectionModelIface 提供两个核心查询：
//!   - get_n_sections() → 段落数量
//!   - get_section(idx) → SectionInfo{start,end}（半开区间：[start, end)）
//! 视图通过"任意 item 的下标 in [start,end)" 找到它属于哪一段。
//!
//! 本文件提供：
//!   - SectionInfo (start,end) + SectionModelIface + SectionModel (类型擦除包装)
//!   - SectionListModel: 按 key_extract 函数将输入 ListModel 稳定分段（相同 key 合并）

const std = @import("std");
const list_model_mod = @import("list_model.zig");

pub const ListModel = list_model_mod.ListModel;
pub const Object = list_model_mod.Object;

// ──────────────────────────────────────────────────────────────────────────────
// SectionInfo + SectionModelIface + SectionModel
// ──────────────────────────────────────────────────────────────────────────────

pub const SectionInfo = struct {
    start: u32,
    end: u32,

    pub fn length(self: *const SectionInfo) u32 {
        return if (self.end > self.start) self.end - self.start else 0;
    }
    pub fn contains(self: *const SectionInfo, position: u32) bool {
        return position >= self.start and position < self.end;
    }
};

pub const SectionModelIface = struct {
    get_n_sections: *const fn (self: ?*anyopaque) u32,
    get_section: *const fn (self: ?*anyopaque, idx: u32) SectionInfo,
};

pub const SectionModel = struct {
    iface: SectionModelIface,
    self_ptr: ?*anyopaque = null,

    pub fn getNSections(self: *const SectionModel) u32 {
        return self.iface.get_n_sections(self.self_ptr);
    }
    pub fn getSection(self: *const SectionModel, idx: u32) SectionInfo {
        return self.iface.get_section(self.self_ptr, idx);
    }

    /// 根据位置找到所在段索引 (返回 null 表示未命中)
    pub fn findSection(self: *const SectionModel, position: u32) ?u32 {
        const n = self.getNSections();
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const sec = self.getSection(i);
            if (sec.contains(position)) return i;
        }
        return null;
    }

    pub fn wrap(obj_ptr: ?*anyopaque, iface: SectionModelIface) SectionModel {
        return .{ .iface = iface, .self_ptr = obj_ptr };
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// Key 提取函数：item → 段 key（相同 key 的 item 归入同一段）
// ──────────────────────────────────────────────────────────────────────────────

pub const SectionKey = u32; // 简化：用 u32 整数作为 key（可以是哈希值/枚举）
pub const KeyExtractFn = *const fn (ud: ?*anyopaque, item: ?*Object) SectionKey;

// ──────────────────────────────────────────────────────────────────────────────
// SectionListModel 实现
// ──────────────────────────────────────────────────────────────────────────────

pub const SectionListModel = struct {
    allocator: std.mem.Allocator,
    source: ?ListModel = null,
    key_fn: KeyExtractFn,
    key_ud: ?*anyopaque = null,
    /// 内部：段表（段 start 位置数组，末尾隐含 = n_items）
    sections: std.ArrayListUnmanaged(u32) = .{},
    /// 段 key 表（与段表同长，便于增量重建）
    section_keys: std.ArrayListUnmanaged(SectionKey) = .{},

    pub fn create(
        allocator: std.mem.Allocator,
        source: ?ListModel,
        key_fn: KeyExtractFn,
        key_ud: ?*anyopaque,
    ) SectionListModel {
        var model: SectionListModel = .{
            .allocator = allocator,
            .source = source,
            .key_fn = key_fn,
            .key_ud = key_ud,
        };
        model.rebuildSections();
        return model;
    }

    pub fn deinit(self: *SectionListModel) void {
        self.sections.deinit(self.allocator);
        self.section_keys.deinit(self.allocator);
    }

    pub fn setSource(self: *SectionListModel, source: ?ListModel) void {
        self.source = source;
        self.rebuildSections();
    }

    pub fn getSource(self: *const SectionListModel) ?ListModel {
        return self.source;
    }

    /// 段重建：遍历整个 source ListModel，相邻相同 key 合并为段
    pub fn rebuildSections(self: *SectionListModel) void {
        self.sections.clearRetainingCapacity();
        self.section_keys.clearRetainingCapacity();
        const src = self.source orelse return;
        const n = src.getNItems();
        if (n == 0) return;

        var last_key: ?SectionKey = null;
        var pos: u32 = 0;
        while (pos < n) : (pos += 1) {
            const item = src.getItem(pos);
            const k = self.key_fn(self.key_ud, item);
            if (last_key == null or last_key.? != k) {
                // 新段
                self.sections.append(self.allocator, pos) catch {};
                self.section_keys.append(self.allocator, k) catch {};
                last_key = k;
            }
        }
    }

    // ── SectionModelIface 转发 ─────────────────────────────────────────

    pub fn getNSectionsFn(self_ptr: ?*anyopaque) u32 {
        const s: *SectionListModel = @ptrCast(@alignCast(self_ptr orelse return 0));
        return @intCast(s.sections.items.len);
    }

    pub fn getSectionFn(self_ptr: ?*anyopaque, idx: u32) SectionInfo {
        const s: *SectionListModel = @ptrCast(@alignCast(self_ptr orelse return .{ .start = 0, .end = 0 }));
        const i: usize = @intCast(idx);
        if (i >= s.sections.items.len) return .{ .start = 0, .end = 0 };
        const start = s.sections.items[i];
        const end: u32 = if (i + 1 < s.sections.items.len)
            s.sections.items[i + 1]
        else blk: {
            const n_total = if (s.source) |src| src.getNItems() else start;
            break :blk n_total;
        };
        return .{ .start = start, .end = end };
    }

    /// 生成 iface
    pub fn asIface() SectionModelIface {
        return .{
            .get_n_sections = getNSectionsFn,
            .get_section = getSectionFn,
        };
    }

    /// 生成 SectionModel 包装
    pub fn asSectionModel(self: *SectionListModel) SectionModel {
        return SectionModel.wrap(self, asIface());
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// 便捷：第一个字节哈希（按首字母分组最常用）
// ──────────────────────────────────────────────────────────────────────────────

/// key_fn 适配：默认分段 key（取 obj.id 的低 8 位作为近似分段）
/// 建议用户自定义 key_fn，以实现真正的首字母/类型分段。
pub fn firstByteKey(ud: ?*anyopaque, item: ?*Object) SectionKey {
    _ = ud;
    const obj = item orelse return ' ';
    return @as(u8, @truncate(obj.id));
}
