//! zigui 顶层 App (macOS 实现)

const std = @import("std");
const math = @import("math.zig");
const pal = @import("pal/pal.zig");
const cocoa = @import("pal/cocoa.zig");
const metal = @import("gpu/metal.zig");
const renderer2d = @import("render2d/renderer.zig");
const dirty_mod = @import("render2d/dirty.zig");
const atlas_mod = @import("text/atlas.zig");
const coretext = @import("text/coretext.zig");

pub const AppConfig = struct {
    title: []const u8 = "zigui app",
    width: u32 = 800,
    height: u32 = 600,
    /// true = 每帧连续渲染 (动画 demo); false = 按需渲染 (脏区驱动, 空闲跳帧)
    continuous: bool = true,
};

/// IME 删除请求 (与 app_linux.zig 对齐)
pub const ImeDelete = struct { before: u32, after: u32 };

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

    // 脏矩形驱动重绘 (continuous=false 时生效; 输入事件自动 invalidate)
    dirty: dirty_mod.DirtyRegion,
    needs_redraw: bool = true,

    // 鼠标状态 (供 drawFrame 做命中检测)
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false, // 左键按住 (level)
    mouse_clicked: bool = false, // 左键本帧按下 (edge, 每帧绘制后清除)

    // 每帧输入状态 (绘制后清除)
    scroll_delta: f32 = 0, // 垂直滚轮累计
    // 本帧输入的码点队列 (来自 IME/键盘)。IME 一次提交可含多个码点
    // (如中文"你好"一次 insertText 提交 2 个码点), 单码点字段会相互覆盖,
    // 故用队列缓存, drawFrame 内消费, 帧末清空。
    typed_cps: [16]u21 = undefined,
    typed_cp_count: usize = 0,
    key_hit: ?pal.KeyCode = null, // 本帧按下的键
    file_drop: ?pal.event.FileDrop = null, // 本帧拖放的文件 (帧末清除)
    // 本帧触摸事件缓冲 (帧末清除)
    touches: [16]pal.event.Touch = undefined,
    touch_count: usize = 0,
    // IME preedit 缓冲 (跨平台 API 使用)
    preedit_buf: [256]u8 = undefined,

    /// 本帧触摸事件 (drawFrame 内调用; 帧末自动清空)
    pub fn touchEvents(self: *App) []const pal.event.Touch {
        return self.touches[0..self.touch_count];
    }

    /// 本帧已输入的码点 (drawFrame 内调用; 帧末自动清空)
    pub fn typedCodepoints(self: *App) []const u21 {
        return self.typed_cps[0..self.typed_cp_count];
    }

    /// 查询当前 IME 组字中的 marked text (如拼音), 写入 buf (UTF-8), 返回字节数
    pub fn getMarkedText(self: *App, buf: []u8) usize {
        return self.cocoa_backend.getMarkedText(buf);
    }

    // ── IME 跨平台 API (与 app_linux.zig 对齐) ────────────────────────

    /// 当前组合中 (preedit/marked) 文本 (UTF-8)
    /// macOS: 从 Cocoa backend 查询; 写入内部缓冲并返回 slice
    pub fn preeditText(self: *App) []const u8 {
        const n = self.cocoa_backend.getMarkedText(&self.preedit_buf);
        return self.preedit_buf[0..n];
    }

    /// 本帧 IME 提交的文本 (macOS: 空, 因为 insertText 已通过 typedCodepoints 发送)
    pub fn imeCommitText(self: *App) []const u8 {
        _ = self;
        return "";
    }

    /// 取出并清除待处理的 IME 删除请求 (macOS: 无, 返回 null)
    pub fn takeImeDelete(self: *App) ?ImeDelete {
        _ = self;
        return null;
    }

    /// 设置 IME 光标矩形 (macOS: 空操作, 候选窗由 AppKit 自动定位)
    pub fn setImeCursorRect(self: *App, x: i32, y: i32, w: i32, h: i32) void {
        _ = .{ self, x, y, w, h };
    }

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
            .dirty = dirty_mod.DirtyRegion.init(allocator),
        };
        self.renderer.device = &self.metal_device;
        self.renderer.glyph_atlas = &self.glyph_atlas;

        return self;
    }

    pub fn deinit(self: *App) void {
        self.event_queue.deinit(self.allocator);
        self.dirty.deinit();
        self.renderer.deinit();
        self.glyph_atlas.deinit();
        self.metal_device.deinit();
        self.allocator.destroy(self);
    }

    /// 标记全屏重绘
    pub fn invalidate(self: *App) void {
        self.needs_redraw = true;
    }

    /// 标记局部区域重绘 (device px)
    pub fn invalidateRect(self: *App, rect: math.Rect(f32)) void {
        self.dirty.add(rect) catch {};
        self.needs_redraw = true;
    }

    /// 获取脏区域 (供控件树裁剪)
    pub fn getDirtyRegion(self: *App) *dirty_mod.DirtyRegion {
        return &self.dirty;
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
                        self.invalidate();
                    },
                    .key => |k| {
                        if (k.state == .pressed) {
                            self.key_hit = k.key;
                            self.invalidate();
                            // Escape 退出
                            if (k.key == .escape) {
                                self.running = false;
                            }
                        }
                    },
                    .scroll => |s| {
                        if (s.axis == .vertical) {
                            self.scroll_delta += s.delta;
                        }
                        self.invalidate();
                    },
                    .text_input => |t| {
                        if (self.typed_cp_count < self.typed_cps.len) {
                            self.typed_cps[self.typed_cp_count] = t.codepoint;
                            self.typed_cp_count += 1;
                        }
                        self.invalidate();
                    },
                    .mouse_move => |m| {
                        // 点击挂起期间不让 move 覆盖坐标: 物理点击瞬间常伴随 move 事件,
                        // 若其在同批事件中排在 down 之后, 会覆盖点击坐标导致命中检测错位
                        if (!self.mouse_clicked) {
                            self.mouse_x = @floatFromInt(m.x);
                            self.mouse_y = @floatFromInt(m.y);
                        }
                        self.invalidate();
                    },
                    .mouse_button => |mb| {
                        self.mouse_x = @floatFromInt(mb.x);
                        self.mouse_y = @floatFromInt(mb.y);
                        if (mb.button == .left) {
                            if (mb.state == .pressed) {
                                self.mouse_down = true;
                                self.mouse_clicked = true;
                            } else {
                                self.mouse_down = false;
                            }
                        }
                        self.invalidate();
                    },
                    .file_drop => |fd| {
                        self.file_drop = fd;
                        self.invalidate();
                    },
                    .touch => |t| {
                        if (self.touch_count < self.touches.len) {
                            self.touches[self.touch_count] = t;
                            self.touch_count += 1;
                        }
                        self.invalidate();
                    },
                    else => {},
                }
            }

            if (cocoa.CocoaBackend.shouldQuit()) {
                self.running = false;
            }

            if (!self.running) break;

            // 3. 重绘决策: 按需模式下无脏区则跳帧
            const dirty_bounds = self.dirty.bounds();
            if (!self.config.continuous and !self.needs_redraw and dirty_bounds == null) {
                continue;
            }

            // 4. 开始帧 (有脏区走离屏画布 + scissor 路径, 限制重绘像素)
            const fb_size = if (dirty_bounds) |b|
                self.metal_device.beginFrameDirty(
                    @intFromFloat(@max(0.0, b.x)),
                    @intFromFloat(@max(0.0, b.y)),
                    @intFromFloat(@max(0.0, b.width)),
                    @intFromFloat(@max(0.0, b.height)),
                )
            else
                self.metal_device.beginFrame();
            const size = fb_size orelse continue;
            self.fb_width = size[0];
            self.fb_height = size[1];

            // 5. 用户绘制
            self.renderer.beginFrame();
            draw_fn(self);
            self.renderer.submit();

            // 消费本帧的点击边沿标志
            self.mouse_clicked = false;
            self.scroll_delta = 0;
            self.typed_cp_count = 0;
            self.key_hit = null;
            self.file_drop = null;
            self.touch_count = 0;
            self.dirty.clear();
            self.needs_redraw = false;

            // 6. 提交帧
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
