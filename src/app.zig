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
const clipboard = @import("pal/clipboard.zig");
const perf_mod = @import("perf.zig");

pub const AppConfig = struct {
    title: []const u8 = "zigui app",
    width: u32 = 800,
    height: u32 = 600,
    /// true = 每帧连续渲染 (动画 demo); false = 按需渲染 (脏区驱动, 空闲跳帧)
    continuous: bool = true,
};

/// IME 删除请求 (与 app_linux.zig 对齐)
pub const ImeDelete = struct { before: u32, after: u32 };

/// macOS 子窗口 (每个窗口有独立的 Metal 设备、渲染器、事件队列)
pub const CocoaSubWindow = struct {
    allocator: std.mem.Allocator,
    window_id: u32,
    title: []const u8,
    width: u32,
    height: u32,
    scale_factor: f32,

    metal_device: metal.MetalDevice,
    renderer: renderer2d.Renderer2D,
    glyph_atlas: atlas_mod.GlyphAtlas,

    event_queue: pal.EventQueue = .{},

    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false,
    right_clicked: bool = false,
    scroll_delta: f32 = 0,
    key_hit: ?pal.event.KeyCode = null,
    key_mods: pal.event.Modifiers = .{},
    file_drop: ?pal.event.FileDrop = null,

    touches: [16]pal.event.Touch = undefined,
    touch_count: usize = 0,

    dirty: dirty_mod.DirtyRegion,
    needs_redraw: bool = true,

    frame_stats: perf_mod.FrameStats = .{},

    visible: bool = true,
    should_close: bool = false,

    user_data: ?*anyopaque = null,
    on_draw: ?*const fn (win: *CocoaSubWindow) void = null,
    on_close: ?*const fn (win: *CocoaSubWindow) void = null,

    pub fn init(
        allocator: std.mem.Allocator,
        metal_layer: *anyopaque,
        window_id: u32,
        title: []const u8,
        width: u32,
        height: u32,
        scale_factor: f32,
    ) !*CocoaSubWindow {
        const self = try allocator.create(CocoaSubWindow);
        errdefer allocator.destroy(self);

        var metal_device = try metal.MetalDevice.init(metal_layer, 65536);
        errdefer metal_device.deinit();

        var glyph_atlas = try atlas_mod.GlyphAtlas.init(allocator, 2048, 2048);
        errdefer glyph_atlas.deinit();
        try glyph_atlas.createTexture(&metal_device);

        var renderer = renderer2d.Renderer2D.init(allocator, undefined);
        renderer.glyph_atlas = &glyph_atlas;

        const dirty = dirty_mod.DirtyRegion.init(allocator);
        errdefer dirty.deinit();

        const owned_title = try allocator.alloc(u8, title.len);
        @memcpy(owned_title, title);

        self.* = .{
            .allocator = allocator,
            .window_id = window_id,
            .title = owned_title,
            .width = width,
            .height = height,
            .scale_factor = scale_factor,
            .metal_device = metal_device,
            .renderer = renderer,
            .glyph_atlas = glyph_atlas,
            .dirty = dirty,
        };
        self.renderer.device = &self.metal_device;
        self.renderer.glyph_atlas = &self.glyph_atlas;

        return self;
    }

    pub fn deinit(self: *CocoaSubWindow) void {
        self.event_queue.deinit(self.allocator);
        self.dirty.deinit();
        self.renderer.deinit();
        self.glyph_atlas.deinit();
        self.metal_device.deinit();
        self.allocator.free(self.title);
        self.allocator.destroy(self);
    }

    pub fn setTitle(self: *CocoaSubWindow, title: []const u8) void {
        self.allocator.free(self.title);
        const owned_title = self.allocator.alloc(u8, title.len) catch return;
        @memcpy(owned_title, title);
        self.title = owned_title;
    }

    pub fn markDirty(self: *CocoaSubWindow) void {
        self.needs_redraw = true;
    }

    pub fn getRenderer(self: *CocoaSubWindow) *renderer2d.Renderer2D {
        return &self.renderer;
    }

    pub fn getWidth(self: *const CocoaSubWindow) u32 {
        return self.width;
    }

    pub fn getHeight(self: *const CocoaSubWindow) u32 {
        return self.height;
    }

    /// 处理窗口事件队列中的事件，更新窗口状态
    pub fn processEvents(self: *CocoaSubWindow) void {
        const events = self.event_queue.drain();
        for (events) |ev| {
            switch (ev) {
                .close_requested => {
                    self.should_close = true;
                    if (self.on_close) |cb| cb(self);
                },
                .resize => |r| {
                    self.width = r.width;
                    self.height = r.height;
                    self.metal_device.setDrawableSize(r.width, r.height);
                    self.markDirty();
                },
                .mouse_move => |m| {
                    self.mouse_x = @floatFromInt(m.x);
                    self.mouse_y = @floatFromInt(m.y);
                },
                .mouse_button => |m| {
                    self.mouse_x = @floatFromInt(m.x);
                    self.mouse_y = @floatFromInt(m.y);
                    if (m.button == .left) {
                        if (m.state == .pressed) {
                            self.mouse_down = true;
                            self.mouse_clicked = true;
                        } else {
                            self.mouse_down = false;
                        }
                    }
                    if (m.button == .right and m.state == .pressed) {
                        self.right_clicked = true;
                    }
                },
                .scroll => |s| {
                    if (s.axis == .vertical) {
                        self.scroll_delta += s.delta;
                    }
                },
                .key => |k| {
                    self.key_mods = k.modifiers;
                    if (k.state == .pressed) {
                        self.key_hit = k.key;
                    }
                },
                else => {},
            }
        }
    }
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
    /// 性能监控 (帧时间/FPS 统计)
    frame_stats: perf_mod.FrameStats = .{},

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
    key_mods: pal.event.Modifiers = .{}, // 当前修饰键状态 (随按键事件更新)
    file_drop: ?pal.event.FileDrop = null, // 本帧拖放的文件 (帧末清除)
    // 本帧触摸事件缓冲 (帧末清除)
    touches: [16]pal.event.Touch = undefined,
    touch_count: usize = 0,
    // IME preedit 缓冲 (跨平台 API 使用)
    preedit_buf: [256]u8 = undefined,

    // 子窗口
    sub_windows: std.AutoHashMapUnmanaged(u32, *CocoaSubWindow) = .{},

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

    // ── 剪贴板 API (Cmd+C/V 快捷键使用) ──────────────────────────

    /// 读取系统剪贴板文本 (调用者拥有返回内存)
    pub fn clipboardGetText(self: *App) ![]u8 {
        return clipboard.getText(self.allocator);
    }

    /// 写入文本到系统剪贴板
    pub fn clipboardSetText(self: *App, text: []const u8) !void {
        _ = self;
        return clipboard.setText(text);
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
        // 销毁所有子窗口
        var it = self.sub_windows.valueIterator();
        while (it.next()) |win| {
            win.*.deinit();
        }
        self.sub_windows.deinit(self.allocator);
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
                // 获取事件的 window_id (主窗口为 0)
                const ev_window_id: u32 = switch (ev) {
                    .close_requested => |e| e.window_id,
                    .resize => |e| e.window_id,
                    .key => |e| e.window_id,
                    .scroll => |e| e.window_id,
                    .text_input => |e| e.window_id,
                    .mouse_move => |e| e.window_id,
                    .mouse_button => |e| e.window_id,
                    .mouse_leave => |e| e.window_id,
                    .file_drop => |e| e.window_id,
                    .touch => |e| e.window_id,
                    else => 0,
                };

                // 子窗口事件 → 路由到对应子窗口的事件队列
                if (ev_window_id != 0) {
                    if (self.sub_windows.get(ev_window_id)) |win| {
                        win.event_queue.push(self.allocator, ev) catch {};
                        win.needs_redraw = true;
                    }
                    continue;
                }

                // 主窗口事件 → 原有的处理逻辑
                switch (ev) {
                    .close_requested => self.running = false,
                    .resize => |r| {
                        self.fb_width = r.width;
                        self.fb_height = r.height;
                        self.metal_device.setDrawableSize(r.width, r.height);
                        self.invalidate();
                    },
                    .key => |k| {
                        self.key_mods = k.modifiers;
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
                        // Ctrl/Cmd+字母 为快捷键, 不作为文本插入
                        if (self.key_mods.ctrl or self.key_mods.super_key) continue;
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

            // 2.1 处理子窗口事件
            self.processSubWindowEvents();

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
            self.frame_stats.beginFrame();
            draw_fn(self);
            self.renderer.submit();
            self.frame_stats.endFrame();

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

            // 7. 渲染子窗口
            self.renderSubWindows();
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

    /// 高 DPI 缩放因子 (逻辑坐标 × scale = 物理像素; Retina 屏通常为 2.0)
    pub fn getScaleFactor(self: *App) f32 {
        if (self.cocoa_backend.window_handle) |h| return h.scale_factor;
        return 1.0;
    }

    /// 性能监控统计 (FPS / 帧耗时 / 百分位)
    pub fn getFrameStats(self: *App) *const perf_mod.FrameStats {
        return &self.frame_stats;
    }

    /// 获取上一帧到当前帧的时间差 (ms), 用于驱动动画
    pub fn getDeltaMs(self: *App) u32 {
        return self.frame_stats.getDeltaMs();
    }

    /// 获取 glyph atlas
    pub fn getGlyphAtlas(self: *App) *atlas_mod.GlyphAtlas {
        return &self.glyph_atlas;
    }

    /// 获取 Metal device
    pub fn getMetalDevice(self: *App) *metal.MetalDevice {
        return &self.metal_device;
    }

    // ── 子窗口 API ────────────────────────────────────────────────────

    /// 创建子窗口，返回 window_id (> 0)
    pub fn createSubWindow(self: *App, title: []const u8, width: u32, height: u32) !u32 {
        const wid = self.cocoa_backend.createSubWindow(title, width, height);
        if (wid == 0) return error.SubWindowCreateFailed;

        const layer = self.cocoa_backend.getSubWindowMetalLayer(wid) orelse {
            self.cocoa_backend.destroySubWindow(wid);
            return error.NoMetalLayer;
        };

        const scale = self.cocoa_backend.getSubWindowScaleFactor(wid);

        const win = try CocoaSubWindow.init(
            self.allocator,
            layer,
            wid,
            title,
            width,
            height,
            scale,
        );
        errdefer win.deinit();

        try self.sub_windows.put(self.allocator, wid, win);
        return wid;
    }

    /// 销毁子窗口
    pub fn destroySubWindow(self: *App, wid: u32) void {
        if (self.sub_windows.fetchRemove(wid)) |entry| {
            entry.value.deinit();
        }
        self.cocoa_backend.destroySubWindow(wid);
    }

    /// 获取子窗口指针
    pub fn getSubWindow(self: *App, wid: u32) ?*CocoaSubWindow {
        return self.sub_windows.get(wid);
    }

    /// 显示子窗口
    pub fn showSubWindow(self: *App, wid: u32) void {
        if (self.sub_windows.get(wid)) |win| {
            win.visible = true;
        }
        self.cocoa_backend.showSubWindow(wid);
    }

    /// 隐藏子窗口
    pub fn hideSubWindow(self: *App, wid: u32) void {
        if (self.sub_windows.get(wid)) |win| {
            win.visible = false;
        }
        self.cocoa_backend.hideSubWindow(wid);
    }

    /// 设置子窗口标题
    pub fn setSubWindowTitle(self: *App, wid: u32, title: []const u8) void {
        if (self.sub_windows.get(wid)) |win| {
            win.setTitle(title);
        }
        self.cocoa_backend.setSubWindowTitle(wid, title);
    }

    /// 处理子窗口事件 (按 window_id 路由)
    fn processSubWindowEvents(self: *App) void {
        // 注意: 事件已在事件处理阶段通过 window_id 路由到对应的子窗口 event_queue
        // 这里调用每个子窗口的 processEvents 来更新状态
        var it = self.sub_windows.valueIterator();
        while (it.next()) |win| {
            win.*.processEvents();
        }
    }

    /// 渲染所有可见子窗口
    fn renderSubWindows(self: *App) void {
        var it = self.sub_windows.valueIterator();
        while (it.next()) |win| {
            if (!win.*.visible) continue;
            if (!win.*.needs_redraw) continue;

            const fb_size = win.*.metal_device.beginFrame() orelse continue;
            win.*.width = fb_size[0];
            win.*.height = fb_size[1];

            win.*.renderer.beginFrame();
            win.*.frame_stats.beginFrame();
            if (win.*.on_draw) |cb| {
                cb(win.*);
            }
            win.*.renderer.submit();
            win.*.frame_stats.endFrame();

            win.*.metal_device.endFrame();
            win.*.needs_redraw = false;
            win.*.mouse_clicked = false;
            win.*.right_clicked = false;
            win.*.scroll_delta = 0;
            win.*.key_hit = null;
            win.*.file_drop = null;
            win.*.touch_count = 0;
            win.*.dirty.clear();
        }
    }
};
