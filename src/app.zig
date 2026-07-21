//! zigui 顶层 App (macOS 实现)

const std = @import("std");
const math = @import("math.zig");
const pal = @import("pal/pal.zig");
const cocoa = @import("pal/cocoa.zig");
const metal = @import("gpu/metal.zig");
const renderer2d = @import("render2d/renderer.zig");
const atlas_mod = @import("text/atlas.zig");
const coretext = @import("text/coretext.zig");

pub const AppConfig = struct {
    title: []const u8 = "zigui app",
    width: u32 = 800,
    height: u32 = 600,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    config: AppConfig,
    cocoa_backend: cocoa.CocoaBackend,
    metal_device: metal.MetalDevice,
    renderer: renderer2d.Renderer2D,
    glyph_atlas: atlas_mod.GlyphAtlas,
    event_queue: pal.EventQueue = .{},
    running: bool = false,
    fb_width: u32,
    fb_height: u32,

    pub fn init(allocator: std.mem.Allocator, config: AppConfig) !*App {
        const self = try allocator.create(App);

        // 1. 初始化 Cocoa
        var cocoa_backend = try cocoa.CocoaBackend.init();

        // 2. 创建窗口
        _ = try cocoa_backend.createWindow(.{
            .title = config.title,
            .width = config.width,
            .height = config.height,
        });

        // 3. 初始化 Metal
        const layer = cocoa_backend.getMetalLayer() orelse {
            allocator.destroy(self);
            return error.NoMetalLayer;
        };
        var metal_device = try metal.MetalDevice.init(layer, 65536);

        // 4. 初始化 Glyph Atlas
        var glyph_atlas = try atlas_mod.GlyphAtlas.init(allocator, 2048, 2048);
        try glyph_atlas.createTexture(&metal_device);

        // 5. 初始化 2D 渲染器
        var renderer = renderer2d.Renderer2D.init(allocator, undefined);
        renderer.glyph_atlas = &glyph_atlas;

        self.* = .{
            .allocator = allocator,
            .config = config,
            .cocoa_backend = cocoa_backend,
            .metal_device = metal_device,
            .renderer = renderer,
            .glyph_atlas = glyph_atlas,
            .running = false,
            .fb_width = config.width,
            .fb_height = config.height,
        };
        self.renderer.device = &self.metal_device;
        self.renderer.glyph_atlas = &self.glyph_atlas;

        return self;
    }

    pub fn deinit(self: *App) void {
        self.event_queue.deinit(self.allocator);
        self.renderer.deinit();
        self.glyph_atlas.deinit();
        self.metal_device.deinit();
        self.allocator.destroy(self);
    }

    /// 运行主循环
    pub fn run(self: *App, draw_fn: *const fn (app: *App) void) !void {
        self.running = true;
        while (self.running) {
            // 1. 采集事件
            try self.cocoa_backend.pollEvents(&self.event_queue, self.allocator);

            // 2. 处理事件
            const events = self.event_queue.drain();
            for (events) |ev| {
                switch (ev) {
                    .close_requested => self.running = false,
                    .resize => |r| {
                        self.fb_width = r.width;
                        self.fb_height = r.height;
                        self.metal_device.setDrawableSize(r.width, r.height);
                    },
                    .key => |k| {
                        // Cmd+Q 或 Escape 退出
                        if (k.state == .pressed and k.key == .escape) {
                            self.running = false;
                        }
                    },
                    else => {},
                }
            }

            if (cocoa.CocoaBackend.shouldQuit()) {
                self.running = false;
            }

            if (!self.running) break;

            // 3. 开始帧
            const fb_size = self.metal_device.beginFrame() orelse continue;
            self.fb_width = fb_size[0];
            self.fb_height = fb_size[1];

            // 4. 用户绘制
            self.renderer.beginFrame();
            draw_fn(self);
            self.renderer.submit();

            // 5. 提交帧
            self.metal_device.endFrame();
        }
    }

    /// 获取渲染器 (用于绘制)
    pub fn getRenderer(self: *App) *renderer2d.Renderer2D {
        return &self.renderer;
    }

    /// 获取 framebuffer 尺寸
    pub fn getFramebufferSize(self: *App) math.Size(u32) {
        return .{ .width = self.fb_width, .height = self.fb_height };
    }

    /// 获取 glyph atlas
    pub fn getGlyphAtlas(self: *App) *atlas_mod.GlyphAtlas {
        return &self.glyph_atlas;
    }

    /// 获取 Metal device
    pub fn getMetalDevice(self: *App) *metal.MetalDevice {
        return &self.metal_device;
    }
};
