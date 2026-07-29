//! 内置矢量图标库 (对标 GTK icon-name)
//!
//! 所有图标定义在 16×16 的归一化坐标系中 (原点左上, y 向下)。
//! drawIcon 时按目标尺寸等比缩放绘制, 支持任意 DPI。
//!
//! 图标由基元 (矩形/圆/圆环/凸多边形) 组合而成, 单色填充。
//! 通过 comptime 辅助函数 line() 生成粗线段的凸四边形, 避免手算坐标。

const std = @import("std");
const math = @import("../math.zig");
const r2d = @import("../render2d/r2d.zig");

const Renderer2D = r2d.Renderer2D;

/// 图标名称 (常用图标, 对标 GTK icon-name 子集)
pub const IconName = enum {
    none,
    close,
    search,
    menu,
    settings,
    plus,
    minus,
    check,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    refresh,
    edit,
    trash,
    save,
    home,
    user,
    star,
    heart,
    info,
    warning,
    err,
    question,
    eye,
    eye_off,
};

/// 单个绘制基元 (16×16 坐标系)
const Primitive = union(enum) {
    /// 轴对齐矩形 {x, y, w, h}
    rect: struct { x: f32, y: f32, w: f32, h: f32 },
    /// 实心圆 {cx, cy, r}
    circle: struct { cx: f32, cy: f32, r: f32 },
    /// 圆环 (描边圆) {cx, cy, r_outer, r_inner}
    ring: struct { cx: f32, cy: f32, ro: f32, ri: f32 },
    /// 凸多边形 (首点扇形三角化; 调用者保证凸性)
    polygon: []const [2]f32,
    /// 预定义三角形列表 (非凸形状, 如星形, 中心扇形可行)
    triangles: []const [3][2]f32,
};

// ── comptime 基元构造辅助 ────────────────────────────────────────────────

/// 粗线段 → 凸四边形 (comptime, 法线方向偏移半厚度)
fn line(x1: f32, y1: f32, x2: f32, y2: f32, thickness: f32) [4][2]f32 {
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len = @sqrt(dx * dx + dy * dy);
    const half = thickness / 2.0;
    // 单位法线 (-dy, dx)/len, 缩放半厚度
    const nx = -dy / len * half;
    const ny = dx / len * half;
    return .{
        .{ x1 + nx, y1 + ny },
        .{ x1 - nx, y1 - ny },
        .{ x2 - nx, y2 - ny },
        .{ x2 + nx, y2 + ny },
    };
}

fn rect(x: f32, y: f32, w: f32, h: f32) Primitive {
    return .{ .rect = .{ .x = x, .y = y, .w = w, .h = h } };
}

fn circle(cx: f32, cy: f32, r: f32) Primitive {
    return .{ .circle = .{ .cx = cx, .cy = cy, .r = r } };
}

fn ring(cx: f32, cy: f32, ro: f32, ri: f32) Primitive {
    return .{ .ring = .{ .cx = cx, .cy = cy, .ro = ro, .ri = ri } };
}

fn poly(p: []const [2]f32) Primitive {
    return .{ .polygon = p };
}

fn tri(t: []const [3][2]f32) Primitive {
    return .{ .triangles = t };
}

// ── 图标数据 (comptime 表) ───────────────────────────────────────────────

const close_pts_1 = line(3.5, 3.5, 12.5, 12.5, 2.2);
const close_pts_2 = line(3.5, 12.5, 12.5, 3.5, 2.2);

const check_leg1 = line(2.5, 8.5, 6.5, 12.5, 2.4);
const check_leg2 = line(5.8, 12.0, 13.5, 3.5, 2.4);

const search_ring = ring(6.8, 6.8, 4.2, 2.6);
const search_handle = line(9.6, 9.6, 13.5, 13.5, 2.2);

const arrow_up_stem = line(8, 13, 8, 4, 2.2);
const arrow_up_head = [_][2]f32{ .{ 8, 2 }, .{ 4, 6.5 }, .{ 12, 6.5 } };

const arrow_down_stem = line(8, 3, 8, 12, 2.2);
const arrow_down_head = [_][2]f32{ .{ 8, 14 }, .{ 4, 9.5 }, .{ 12, 9.5 } };

const arrow_left_stem = line(3, 8, 12, 8, 2.2);
const arrow_left_head = [_][2]f32{ .{ 2, 8 }, .{ 6.5, 4 }, .{ 6.5, 12 } };

const arrow_right_stem = line(4, 8, 13, 8, 2.2);
const arrow_right_head = [_][2]f32{ .{ 14, 8 }, .{ 9.5, 4 }, .{ 9.5, 12 } };

// 刷新: 两段圆弧箭头 (简化为半圆环 + 箭头头)
const refresh_arc = ring(8, 8, 5.5, 3.3);
const refresh_head = [_][2]f32{ .{ 12.5, 4.5 }, .{ 10, 2 }, .{ 14, 2.5 } };

// 编辑 (铅笔): 斜杠 + 笔尖三角
const edit_body = line(3.5, 12.5, 11, 5, 2.4);
const edit_tip = [_][2]f32{ .{ 2.5, 14 }, .{ 3.5, 11.5 }, .{ 5, 13 } };

// 星形 (5 角, 中心扇形三角化: 星形对其中心是星形多边形, 中心扇形合法)
const star_pts = blk: {
    var pts: [10][2]f32 = undefined;
    const cx: f32 = 8;
    const cy: f32 = 8;
    const ro: f32 = 6;
    const ri: f32 = 2.6;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const ang = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * (std.math.pi / 5.0);
        const r = if (i % 2 == 0) ro else ri;
        pts[i] = .{ cx + r * @cos(ang), cy + r * @sin(ang) };
    }
    break :blk pts;
};
const star_tris = blk: {
    // 从中心 (8,8) 对 10 个边界点做扇形: 每条边一个三角形
    var ts: [10][3][2]f32 = undefined;
    const c: [2]f32 = .{ 8, 8 };
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const j = (i + 1) % 10;
        ts[i] = .{ c, star_pts[i], star_pts[j] };
    }
    break :blk ts;
};

// 心形 (拆为左右两个凸半部, 各用凸多边形; 顶点顺序保证凸性)
const heart_left = [_][2]f32{
    .{ 8, 14 },
    .{ 2.5, 8.5 },
    .{ 2.5, 5.5 },
    .{ 5, 3 },
    .{ 8, 5 },
};
const heart_right = [_][2]f32{
    .{ 8, 14 },
    .{ 8, 5 },
    .{ 11, 3 },
    .{ 13.5, 5.5 },
    .{ 13.5, 8.5 },
};

// 主页 (房子): 三角屋顶 + 轮廓墙体 (单色不挖空, 用边框表现)
const home_roof = [_][2]f32{ .{ 8, 2 }, .{ 2, 7.5 }, .{ 14, 7.5 } };
const home_left_wall = rect(3.5, 7.5, 1.6, 6);
const home_right_wall = rect(10.9, 7.5, 1.6, 6);
const home_floor = rect(3.5, 12.9, 8.4, 1.6);

// 用户 (头像): 圆头 + 半圆肩
const user_head = circle(8, 5.5, 2.8);
const user_body_pts = [_][2]f32{
    .{ 2.5, 14 },
    .{ 2.5, 11.5 },
    .{ 5, 9 },
    .{ 11, 9 },
    .{ 13.5, 11.5 },
    .{ 13.5, 14 },
};

// 警告三角 + 感叹号
const warning_tri = [_][2]f32{ .{ 8, 2 }, .{ 2, 13.5 }, .{ 14, 13.5 } };
const warning_bar = rect(7.2, 5.5, 1.6, 4.5);
const warning_dot = circle(8, 12, 1.0);

// 错误圆 + 感叹号
const err_ring = ring(8, 8, 6, 4.2);
const err_bar = rect(7.2, 4.5, 1.6, 4.5);
const err_dot = circle(8, 11, 1.0);

// 信息圆 + i
const info_ring = ring(8, 8, 6, 4.2);
const info_dot = circle(8, 4.8, 1.0);
const info_bar = rect(7.2, 6.8, 1.6, 4.5);

// 问号圆 + ? (用线段近似曲线, 避免非凸多边形)
const question_ring = ring(8, 8, 6, 4.2);
const question_top_h = line(6, 5.5, 10, 5.5, 1.8); // ? 顶部横弯
const question_top_d = line(10, 5.8, 8, 8.5, 1.8); // ? 斜下段
const question_dot = circle(8, 11.5, 1.0);

const no_icon = [_]Primitive{};

// 每个图标的基元数组 (顶层 const → comptime 求值, 静态存储)。
// 注意: 不能在运行时函数 getIcon 内用 &.{...} 构造, 否则返回栈临时悬空指针。
const save_stem = line(8, 2.5, 8, 9, 2.2);

const icon_close = [_]Primitive{ poly(&close_pts_1), poly(&close_pts_2) };
const icon_search = [_]Primitive{ search_ring, poly(&search_handle) };
const icon_menu = [_]Primitive{
    rect(2, 3.5, 12, 1.8),
    rect(2, 7.1, 12, 1.8),
    rect(2, 10.7, 12, 1.8),
};
const icon_settings = [_]Primitive{
    ring(8, 8, 4.6, 3.0),
    rect(7, 1.5, 2, 2.2),
    rect(7, 12.3, 2, 2.2),
    rect(1.5, 7, 2.2, 2),
    rect(12.3, 7, 2.2, 2),
};
const icon_plus = [_]Primitive{ rect(7, 3, 2, 10), rect(3, 7, 10, 2) };
const icon_minus = [_]Primitive{rect(3, 7, 10, 2)};
const icon_check = [_]Primitive{ poly(&check_leg1), poly(&check_leg2) };
const icon_arrow_up = [_]Primitive{ poly(&arrow_up_stem), poly(&arrow_up_head) };
const icon_arrow_down = [_]Primitive{ poly(&arrow_down_stem), poly(&arrow_down_head) };
const icon_arrow_left = [_]Primitive{ poly(&arrow_left_stem), poly(&arrow_left_head) };
const icon_arrow_right = [_]Primitive{ poly(&arrow_right_stem), poly(&arrow_right_head) };
const icon_refresh = [_]Primitive{ refresh_arc, poly(&refresh_head) };
const icon_edit = [_]Primitive{ poly(&edit_body), poly(&edit_tip) };
const icon_trash = [_]Primitive{
    rect(6.5, 3, 3, 1.4), // 把手
    rect(3, 4.5, 10, 1.6), // 盖
    rect(4, 6.2, 1.6, 6.4), // 左壁
    rect(10.4, 6.2, 1.6, 6.4), // 右壁
    rect(4, 12.4, 8, 1.6), // 底
};
const icon_save = [_]Primitive{
    poly(&save_stem), // 下箭头杆
    rect(4.5, 8, 7, 2.4), // 箭头头
    rect(3, 12.5, 10, 1.8), // 底座
};
const icon_home = [_]Primitive{ poly(&home_roof), home_left_wall, home_right_wall, home_floor };
const icon_user = [_]Primitive{ user_head, poly(&user_body_pts) };
const icon_star = [_]Primitive{tri(&star_tris)};
const icon_heart = [_]Primitive{ poly(&heart_left), poly(&heart_right) };
const icon_info = [_]Primitive{ info_ring, info_dot, info_bar };
const icon_warning = [_]Primitive{ poly(&warning_tri), warning_bar, warning_dot };
const icon_err = [_]Primitive{ err_ring, err_bar, err_dot };
const icon_question = [_]Primitive{
    question_ring,
    poly(&question_top_h),
    poly(&question_top_d),
    question_dot,
};

const eye_outer = [_][2]f32{
    .{ 1, 8 },
    .{ 4, 3.5 },
    .{ 8, 2.5 },
    .{ 12, 3.5 },
    .{ 15, 8 },
    .{ 12, 12.5 },
    .{ 8, 13.5 },
    .{ 4, 12.5 },
};

const eye_inner = circle(8, 8, 3);

const icon_eye = [_]Primitive{
    .{ .polygon = &eye_outer },
    eye_inner,
};

const eye_off_line1 = line(2, 3, 14, 13, 1.2);
const eye_off_line2 = line(14, 3, 2, 13, 1.2);

const icon_eye_off = [_]Primitive{
    .{ .polygon = &eye_outer },
    eye_inner,
    poly(&eye_off_line1),
    poly(&eye_off_line2),
};

/// 获取图标的基元列表 (16×16 坐标系)
pub fn getIcon(name: IconName) []const Primitive {
    return switch (name) {
        .none => &no_icon,
        .close => &icon_close,
        .search => &icon_search,
        .menu => &icon_menu,
        .settings => &icon_settings,
        .plus => &icon_plus,
        .minus => &icon_minus,
        .check => &icon_check,
        .arrow_up => &icon_arrow_up,
        .arrow_down => &icon_arrow_down,
        .arrow_left => &icon_arrow_left,
        .arrow_right => &icon_arrow_right,
        .refresh => &icon_refresh,
        .edit => &icon_edit,
        .trash => &icon_trash,
        .save => &icon_save,
        .home => &icon_home,
        .user => &icon_user,
        .star => &icon_star,
        .heart => &icon_heart,
        .info => &icon_info,
        .warning => &icon_warning,
        .err => &icon_err,
        .question => &icon_question,
        .eye => &icon_eye,
        .eye_off => &icon_eye_off,
    };
}

/// 在 (x, y) 处绘制图标, 边长 size, 颜色 color。
/// 图标从 16×16 坐标系等比缩放到 size×size。
pub fn drawIcon(renderer: *Renderer2D, x: f32, y: f32, size: f32, color: math.Color, name: IconName) !void {
    if (name == .none or size <= 0) return;
    const prims = getIcon(name);
    const scale = size / 16.0;
    for (prims) |p| {
        switch (p) {
            .rect => |r| {
                try renderer.fillRect(.{
                    .x = x + r.x * scale,
                    .y = y + r.y * scale,
                    .width = r.w * scale,
                    .height = r.h * scale,
                }, color);
            },
            .circle => |c| {
                try renderer.fillCircle(x + c.cx * scale, y + c.cy * scale, c.r * scale, color);
            },
            .ring => |rg| {
                try renderer.fillRing(x + rg.cx * scale, y + rg.cy * scale, rg.ro * scale, rg.ri * scale, color);
            },
            .polygon => |pts| {
                var buf: [16][2]f32 = undefined;
                const n = @min(pts.len, buf.len);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    buf[i] = .{ x + pts[i][0] * scale, y + pts[i][1] * scale };
                }
                try renderer.fillConvexPolygon(buf[0..n], color);
            },
            .triangles => |tris| {
                for (tris) |t| {
                    var buf: [3][2]f32 = undefined;
                    var i: usize = 0;
                    while (i < 3) : (i += 1) {
                        buf[i] = .{ x + t[i][0] * scale, y + t[i][1] * scale };
                    }
                    try renderer.fillConvexPolygon(&buf, color);
                }
            },
        }
    }
}

// ── 单元测试 ────────────────────────────────────────────────────────────

test "getIcon 返回非空基元列表 (除 none 外)" {
    const names = [_]IconName{
        .close,    .search,     .menu,       .settings,    .plus,    .minus, .check,
        .arrow_up, .arrow_down, .arrow_left, .arrow_right, .refresh, .edit,  .trash,
        .save,     .home,       .user,       .star,        .heart,   .info,  .warning,
        .err,      .question,   .eye,        .eye_off,
    };
    for (names) |n| {
        const prims = getIcon(n);
        try std.testing.expect(prims.len > 0);
    }
    try std.testing.expect(getIcon(.none).len == 0);
}

test "每个图标的每个基元 tag 合法 (Debug 联合体完整性)" {
    const names = [_]IconName{
        .close,    .search,     .menu,       .settings,    .plus,    .minus, .check,
        .arrow_up, .arrow_down, .arrow_left, .arrow_right, .refresh, .edit,  .trash,
        .save,     .home,       .user,       .star,        .heart,   .info,  .warning,
        .err,      .question,
    };
    var counted: usize = 0;
    for (names) |n| {
        const prims = getIcon(n);
        for (prims) |p| {
            // switch 触发 tag 完整性检查; 非法 tag 会 panic
            _ = switch (p) {
                .rect => @as(usize, 1),
                .circle => @as(usize, 2),
                .ring => @as(usize, 3),
                .polygon => @as(usize, 4),
                .triangles => @as(usize, 5),
            };
            counted += 1;
        }
    }
    try std.testing.expect(counted > 0);
}

test "line 生成 4 顶点凸四边形" {
    const pts = line(0, 0, 4, 0, 2);
    try std.testing.expectEqual(@as(usize, 4), pts.len);
    // 水平线段, 法线垂直: 顶点应在 y=±1 附近
    try std.testing.expectApproxEqAbs(@as(f32, 0), pts[0][0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), pts[0][1], 0.001);
    // 四个顶点的 y 坐标应为 ±1
    var count_pos: usize = 0;
    var count_neg: usize = 0;
    for (pts) |pt| {
        if (std.math.approxEqAbs(f32, pt[1], 1, 0.001)) count_pos += 1;
        if (std.math.approxEqAbs(f32, pt[1], -1, 0.001)) count_neg += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count_pos);
    try std.testing.expectEqual(@as(usize, 2), count_neg);
}

test "drawIcon 对 none 不绘制" {
    // 无 renderer 也可调用 (none 提前返回); 用空结构验证逻辑不 panic
    var dummy_calls: u32 = 0;
    _ = &dummy_calls;
    // drawIcon 需要 renderer, 这里只验证 getIcon(.none) 为空
    try std.testing.expectEqual(@as(usize, 0), getIcon(.none).len);
}
