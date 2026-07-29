//! GTK4 Snapshot + GskRenderNode 桥接层
//!
//! GTK4 对应:
//!   - GtkSnapshot  -> 记录绘制操作为渲染节点树
//!   - GskRenderNode -> 渲染节点（场景图节点）
//!
//! 架构桥接:
//!   GTK4 使用 GSK 场景图：Widget.snapshot() -> GtkSnapshot -> GskRenderNode 树 -> 渲染器
//!   ZigUI 使用直接渲染：Widget.paint() -> DrawCmd 列表 -> 渲染器
//!
//!   本模块在两者之间架桥：
//!   1. GtkSnapshot 记录绘制操作为 RenderNode 树（与 GSK 1:1 对应）
//!   2. RenderNode.toDrawCommands() 将节点树展开为 DrawCmd 列表
//!   3. DrawCmd 列表送入现有 render2d 渲染管线
//!
//!   这样既保持了与 GTK4 API 的一致性，又复用了现有渲染后端（Vulkan/Metal/D3D11）。

const std = @import("std");
const math = @import("../math.zig");
const draw_cmd = @import("../render2d/draw_cmd.zig");
const path_mod = @import("../render2d/path.zig");

const Allocator = std.mem.Allocator;
const DrawCmd = draw_cmd.DrawCmd;
const Brush = draw_cmd.Brush;

// ──────────────────────────────────────────────────────────────────────────────
// GskRenderNode (GTK4: GskRenderNode)
// 渲染节点树节点，每个节点代表一个绘制操作或一组操作
// ──────────────────────────────────────────────────────────────────────────────

/// 节点类型（对应 GskRenderNodeType）
pub const RenderNodeType = enum {
    color_node, // 纯色矩形
    texture_node, // 纹理贴图
    linear_gradient_node, // 线性渐变
    border_node, // 边框
    clip_node, // 裁剪
    rounded_clip_node, // 圆角裁剪
    transform_node, // 变换
    opacity_node, // 透明度
    container_node, // 容器（子节点组）
    text_node, // 文本
    shadow_node, // 阴影
};

/// 渲染节点（GskRenderNode 等价物）
pub const RenderNode = struct {
    node_type: RenderNodeType,
    /// 节点边界框（用于裁剪优化）
    bounds: math.Rect(f32),
    /// 子节点列表（仅 container/clip/transform/opacity 有）
    children: std.ArrayListUnmanaged(*RenderNode) = .empty,
    /// 节点特定数据
    payload: Payload,

    const Payload = union(RenderNodeType) {
        color_node: ColorNode,
        texture_node: TextureNode,
        linear_gradient_node: LinearGradientNode,
        border_node: BorderNode,
        clip_node: ClipNode,
        rounded_clip_node: RoundedClipNode,
        transform_node: TransformNode,
        opacity_node: OpacityNode,
        container_node: void,
        text_node: TextNode,
        shadow_node: ShadowNode,
    };

    const ColorNode = struct {
        color: math.Color,
    };

    const TextureNode = struct {
        texture_handle: u64,
        src_rect: math.Rect(f32),
    };

    const LinearGradientNode = struct {
        gradient: draw_cmd.LinearGradient,
    };

    const BorderNode = struct {
        outline: RoundedRect,
        border_widths: [4]f32, // top, right, bottom, left
        colors: [4]math.Color,
    };

    const ClipNode = struct {
        clip_rect: math.Rect(f32),
    };

    const RoundedClipNode = struct {
        clip_rect: RoundedRect,
    };

    const TransformNode = struct {
        transform: math.Mat3x2,
    };

    const OpacityNode = struct {
        opacity: f32,
    };

    const TextNode = struct {
        text: []const u8,
        font_size: f32,
        color: math.Color,
        x: f32,
        y: f32,
    };

    const ShadowNode = struct {
        shadow_rect: math.Rect(f32),
        color: math.Color,
        blur_radius: f32,
        offset_x: f32,
        offset_y: f32,
    };

    /// 创建节点
    fn create(allocator: Allocator, node_type: RenderNodeType, bounds: math.Rect(f32), payload: Payload) !*RenderNode {
        const node = try allocator.create(RenderNode);
        node.* = .{
            .node_type = node_type,
            .bounds = bounds,
            .children = .empty,
            .payload = payload,
        };
        return node;
    }

    /// 销毁节点树（递归）
    pub fn destroy(self: *RenderNode, allocator: Allocator) void {
        for (self.children.items) |child| {
            child.destroy(allocator);
        }
        self.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 将节点树展开为 DrawCmd 列表
    pub fn toDrawCommands(self: *const RenderNode, allocator: Allocator, out: *std.ArrayListUnmanaged(DrawCmd)) !void {
        switch (self.payload) {
            .color_node => |cn| {
                // 纯色矩形 -> fill path
                var path = path_mod.Path{};
                defer path.deinit(allocator);
                path.addRect(allocator, self.bounds) catch return;
                const path_ptr = try allocator.create(path_mod.Path);
                path_ptr.* = path;
                path_ptr.addRect(allocator, self.bounds) catch {};
                try out.append(allocator, .{
                    .fill = .{
                        .path = path_ptr,
                        .brush = .{ .solid = cn.color },
                    },
                });
            },
            .texture_node => |tn| {
                try out.append(allocator, .{
                    .draw_image = .{
                        .texture_handle = tn.texture_handle,
                        .src_rect = tn.src_rect,
                        .dst_rect = self.bounds,
                    },
                });
            },
            .linear_gradient_node => |lgn| {
                var path = path_mod.Path{};
                defer path.deinit(allocator);
                path.addRect(allocator, self.bounds) catch return;
                const path_ptr = try allocator.create(path_mod.Path);
                path_ptr.* = path;
                path_ptr.addRect(allocator, self.bounds) catch {};
                try out.append(allocator, .{
                    .fill = .{
                        .path = path_ptr,
                        .brush = .{ .linear_gradient = lgn.gradient },
                    },
                });
            },
            .clip_node => |cn| {
                try out.append(allocator, .{ .push_clip = cn.clip_rect });
                for (self.children.items) |child| {
                    try child.toDrawCommands(allocator, out);
                }
                try out.append(allocator, .{ .pop_clip = {} });
            },
            .rounded_clip_node => |rcn| {
                // 圆角裁剪用矩形近似
                const r = rcn.clip_rect.bounds;
                try out.append(allocator, .{ .push_clip = r });
                for (self.children.items) |child| {
                    try child.toDrawCommands(allocator, out);
                }
                try out.append(allocator, .{ .pop_clip = {} });
            },
            .transform_node => |tn| {
                try out.append(allocator, .{ .push_transform = tn.transform });
                for (self.children.items) |child| {
                    try child.toDrawCommands(allocator, out);
                }
                try out.append(allocator, .{ .pop_transform = {} });
            },
            .opacity_node => |on| {
                try out.append(allocator, .{ .push_opacity = on.opacity });
                for (self.children.items) |child| {
                    try child.toDrawCommands(allocator, out);
                }
                try out.append(allocator, .{ .pop_opacity = {} });
            },
            .container_node => {
                for (self.children.items) |child| {
                    try child.toDrawCommands(allocator, out);
                }
            },
            .border_node, .text_node, .shadow_node => {
                // 复杂节点：通过 path + fill/stroke 实现，此处简化
                // 实际使用时由 Widget.paint 直接调用 r2d 命令
            },
        }
    }
};

/// 圆角矩形（GTK4: GskRoundedRect）
pub const RoundedRect = struct {
    bounds: math.Rect(f32),
    corner: [4]CornerSpec = .{
        .{}, .{}, .{}, .{},
    },

    pub const CornerSpec = struct {
        width: f32 = 0,
        height: f32 = 0,
    };

    pub fn fromRect(rect: math.Rect(f32)) RoundedRect {
        return .{ .bounds = rect };
    }

    pub fn fromRectRadius(rect: math.Rect(f32), radius: f32) RoundedRect {
        return .{
            .bounds = rect,
            .corner = .{
                .{ .width = radius, .height = radius },
                .{ .width = radius, .height = radius },
                .{ .width = radius, .height = radius },
                .{ .width = radius, .height = radius },
            },
        };
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// GtkSnapshot
// 绘制命令记录器：构建 RenderNode 树
// 使用栈式 API：push_* 开始一个子节点容器，pop_* 结束并附加到父节点
// ──────────────────────────────────────────────────────────────────────────────

pub const Snapshot = struct {
    allocator: Allocator,
    /// 根节点（最终输出）
    root: *RenderNode,
    /// 节点栈（push 后入栈，pop 后出栈）
    stack: std.ArrayListUnmanaged(*RenderNode) = .empty,

    const Self = @This();

    /// 创建 Snapshot
    pub fn create(allocator: Allocator) !*Snapshot {
        const root = try RenderNode.create(
            allocator,
            .container_node,
            .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .{ .container_node = {} },
        );
        const self = try allocator.create(Snapshot);
        self.* = .{
            .allocator = allocator,
            .root = root,
        };
        try self.stack.append(allocator, root);
        return self;
    }

    /// 销毁 Snapshot（及整个节点树）
    pub fn destroy(self: *Self) void {
        self.root.destroy(self.allocator);
        self.stack.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// 当前栈顶节点
    fn current(self: *Self) *RenderNode {
        return self.stack.items[self.stack.items.len - 1];
    }

    /// 将节点附加到当前栈顶
    fn appendNode(self: *Self, node: *RenderNode) !void {
        try self.current().children.append(self.allocator, node);
    }

    // ── GTK4 对齐 API ──────────────────────────────────────────────────────

    /// GTK4: gtk_snapshot_append_color
    pub fn appendColor(self: *Self, color: math.Color, bounds: math.Rect(f32)) !void {
        const node = try RenderNode.create(self.allocator, .color_node, bounds, .{
            .color_node = .{ .color = color },
        });
        try self.appendNode(node);
    }

    /// GTK4: gtk_snapshot_append_texture
    pub fn appendTexture(
        self: *Self,
        texture_handle: u64,
        bounds: math.Rect(f32),
        src_rect: ?math.Rect(f32),
    ) !void {
        const sr = src_rect orelse bounds;
        const node = try RenderNode.create(self.allocator, .texture_node, bounds, .{
            .texture_node = .{
                .texture_handle = texture_handle,
                .src_rect = sr,
            },
        });
        try self.appendNode(node);
    }

    /// GTK4: gtk_snapshot_append_linear_gradient
    pub fn appendLinearGradient(
        self: *Self,
        bounds: math.Rect(f32),
        gradient: draw_cmd.LinearGradient,
    ) !void {
        const node = try RenderNode.create(self.allocator, .linear_gradient_node, bounds, .{
            .linear_gradient_node = .{ .gradient = gradient },
        });
        try self.appendNode(node);
    }

    /// GTK4: gtk_snapshot_append_border
    pub fn appendBorder(
        self: *Self,
        outline: RoundedRect,
        border_widths: [4]f32,
        colors: [4]math.Color,
    ) !void {
        const node = try RenderNode.create(self.allocator, .border_node, outline.bounds, .{
            .border_node = .{
                .outline = outline,
                .border_widths = border_widths,
                .colors = colors,
            },
        });
        try self.appendNode(node);
    }

    /// GTK4: gtk_snapshot_push_clip
    pub fn pushClip(self: *Self, clip_rect: math.Rect(f32)) !void {
        const node = try RenderNode.create(self.allocator, .clip_node, clip_rect, .{
            .clip_node = .{ .clip_rect = clip_rect },
        });
        try self.appendNode(node);
        try self.stack.append(self.allocator, node);
    }

    /// GTK4: gtk_snapshot_push_rounded_clip
    pub fn pushRoundedClip(self: *Self, clip_rect: RoundedRect) !void {
        const node = try RenderNode.create(self.allocator, .rounded_clip_node, clip_rect.bounds, .{
            .rounded_clip_node = .{ .clip_rect = clip_rect },
        });
        try self.appendNode(node);
        try self.stack.append(self.allocator, node);
    }

    /// GTK4: gtk_snapshot_push_transform
    pub fn pushTransform(self: *Self, transform: math.Mat3x2) !void {
        const node = try RenderNode.create(self.allocator, .transform_node, .{
            .x = 0, .y = 0, .width = 0, .height = 0,
        }, .{
            .transform_node = .{ .transform = transform },
        });
        try self.appendNode(node);
        try self.stack.append(self.allocator, node);
    }

    /// GTK4: gtk_snapshot_push_opacity
    pub fn pushOpacity(self: *Self, opacity: f32) !void {
        const node = try RenderNode.create(self.allocator, .opacity_node, .{
            .x = 0, .y = 0, .width = 0, .height = 0,
        }, .{
            .opacity_node = .{ .opacity = opacity },
        });
        try self.appendNode(node);
        try self.stack.append(self.allocator, node);
    }

    /// GTK4: gtk_snapshot_push_container (将后续节点分组)
    pub fn pushContainer(self: *Self, bounds: math.Rect(f32)) !void {
        const node = try RenderNode.create(self.allocator, .container_node, bounds, .{
            .container_node = {},
        });
        try self.appendNode(node);
        try self.stack.append(self.allocator, node);
    }

    /// GTK4: gtk_snapshot_pop (结束当前 push 的节点)
    pub fn pop(self: *Self) void {
        if (self.stack.items.len > 1) {
            _ = self.stack.pop();
        }
    }

    /// GTK4: gtk_snapshot_to_node (获取最终渲染节点树)
    pub fn toNode(self: *Self) *RenderNode {
        return self.root;
    }

    /// 将整棵节点树展开为 DrawCmd 列表（桥接到 render2d 管线）
    pub fn toDrawCommands(self: *Self, allocator: Allocator) !std.ArrayListUnmanaged(DrawCmd) {
        var cmds: std.ArrayListUnmanaged(DrawCmd) = .empty;
        try self.root.toDrawCommands(allocator, &cmds);
        return cmds;
    }

    /// 保存/恢复状态（类似 cairo_save/restore）
    pub fn save(self: *Self) !void {
        try self.pushContainer(.{ .x = 0, .y = 0, .width = 0, .height = 0 });
    }

    pub fn restore(self: *Self) void {
        self.pop();
    }
};
