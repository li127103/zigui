//! zigui 顶层 App 组装

const std = @import("std");
const pal = @import("pal/pal.zig");
const gpu = @import("gpu/hal.zig");
const theme_mod = @import("theme/theme.zig");
const animation = @import("animation/animation.zig");

pub const AppConfig = struct {
    title: []const u8 = "zigui app",
    width: u32 = 800,
    height: u32 = 600,
    theme: *const theme_mod.Theme = &theme_mod.light,
    vsync: bool = true,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    config: AppConfig,
    running: bool = false,
    anim_controller: animation.AnimationController,

    pub fn init(allocator: std.mem.Allocator, config: AppConfig) !App {
        return .{
            .allocator = allocator,
            .config = config,
            .anim_controller = animation.AnimationController.init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        self.anim_controller.deinit();
    }

    /// 运行主循环 (阻塞直到窗口关闭)
    pub fn run(self: *App) !void {
        self.running = true;
        while (self.running) {
            try self.tick();
        }
    }

    /// 单帧更新 (非阻塞, 适合集成到外部事件循环)
    pub fn tick(self: *App) !void {
        // 1. 采集事件
        // 2. 分发事件
        // 3. 更新动画
        self.anim_controller.update(16); // ~60fps
        // 4. 布局 (脏子树)
        // 5. 绘制
        // 6. 提交 GPU
    }

    pub fn quit(self: *App) void {
        self.running = false;
    }
};
