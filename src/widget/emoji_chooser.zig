//! EmojiChooser 控件 - 表情选择器
//!
//! 类似 GtkEmojiChooser: 弹出式表情选择面板, 支持分类浏览、搜索、最近使用。
//! 点击表情后触发 on_emoji_selected 回调。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const button_mod = @import("button.zig");
const scrolled_window_mod = @import("scrolled_window.zig");
const entry_mod = @import("entry.zig");
const grid_mod = @import("grid.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Button = button_mod.Button;
const ScrolledWindow = scrolled_window_mod.ScrolledWindow;
const Entry = entry_mod.Entry;

/// 表情分类
pub const EmojiCategory = enum {
    smileys,
    people,
    animals,
    food,
    travel,
    activities,
    objects,
    symbols,
    flags,
    recently_used,
};

/// 单个表情定义
pub const EmojiItem = struct {
    emoji: []const u8,
    name: []const u8,
    category: EmojiCategory,
};

/// 常用表情数据 (精选集合)
const default_emojis = [_]EmojiItem{
    .{ .emoji = "😀", .name = "grinning face", .category = .smileys },
    .{ .emoji = "😃", .name = "grinning face with big eyes", .category = .smileys },
    .{ .emoji = "😄", .name = "grinning face with smiling eyes", .category = .smileys },
    .{ .emoji = "😁", .name = "beaming face with smiling eyes", .category = .smileys },
    .{ .emoji = "😆", .name = "grinning squinting face", .category = .smileys },
    .{ .emoji = "😅", .name = "grinning face with sweat", .category = .smileys },
    .{ .emoji = "🤣", .name = "rolling on the floor laughing", .category = .smileys },
    .{ .emoji = "😂", .name = "face with tears of joy", .category = .smileys },
    .{ .emoji = "🙂", .name = "slightly smiling face", .category = .smileys },
    .{ .emoji = "🙃", .name = "upside-down face", .category = .smileys },
    .{ .emoji = "😉", .name = "winking face", .category = .smileys },
    .{ .emoji = "😊", .name = "smiling face with smiling eyes", .category = .smileys },
    .{ .emoji = "😇", .name = "smiling face with halo", .category = .smileys },
    .{ .emoji = "🥰", .name = "smiling face with hearts", .category = .smileys },
    .{ .emoji = "😍", .name = "smiling face with heart-eyes", .category = .smileys },
    .{ .emoji = "🤩", .name = "star-struck", .category = .smileys },
    .{ .emoji = "😘", .name = "face blowing a kiss", .category = .smileys },
    .{ .emoji = "😗", .name = "kissing face", .category = .smileys },
    .{ .emoji = "😚", .name = "kissing face with closed eyes", .category = .smileys },
    .{ .emoji = "😙", .name = "kissing face with smiling eyes", .category = .smileys },
    .{ .emoji = "🥲", .name = "smiling face with tear", .category = .smileys },
    .{ .emoji = "😋", .name = "face savoring food", .category = .smileys },
    .{ .emoji = "😋", .name = "face with tongue", .category = .smileys },
    .{ .emoji = "😛", .name = "face with tongue", .category = .smileys },
    .{ .emoji = "😜", .name = "winking face with tongue", .category = .smileys },
    .{ .emoji = "🤪", .name = "zany face", .category = .smileys },
    .{ .emoji = "😝", .name = "squinting face with tongue", .category = .smileys },
    .{ .emoji = "🤑", .name = "money-mouth face", .category = .smileys },
    .{ .emoji = "🤗", .name = "hugging face", .category = .smileys },
    .{ .emoji = "🤭", .name = "face with hand over mouth", .category = .smileys },
    .{ .emoji = "🤫", .name = "shushing face", .category = .smileys },
    .{ .emoji = "🤔", .name = "thinking face", .category = .smileys },

    .{ .emoji = "👍", .name = "thumbs up", .category = .people },
    .{ .emoji = "👎", .name = "thumbs down", .category = .people },
    .{ .emoji = "👌", .name = "OK hand", .category = .people },
    .{ .emoji = "🤌", .name = "pinched fingers", .category = .people },
    .{ .emoji = "🤏", .name = "pinching hand", .category = .people },
    .{ .emoji = "✌️", .name = "victory hand", .category = .people },
    .{ .emoji = "🤞", .name = "crossed fingers", .category = .people },
    .{ .emoji = "🤟", .name = "love-you gesture", .category = .people },
    .{ .emoji = "🤙", .name = "call me hand", .category = .people },
    .{ .emoji = "👋", .name = "waving hand", .category = .people },
    .{ .emoji = "🤚", .name = "raised back of hand", .category = .people },
    .{ .emoji = "🖐️", .name = "hand with fingers splayed", .category = .people },
    .{ .emoji = "✋", .name = "raised hand", .category = .people },
    .{ .emoji = "🖖", .name = "vulcan salute", .category = .people },
    .{ .emoji = "👈", .name = "backhand index pointing left", .category = .people },
    .{ .emoji = "👉", .name = "backhand index pointing right", .category = .people },
    .{ .emoji = "👆", .name = "backhand index pointing up", .category = .people },
    .{ .emoji = "👇", .name = "backhand index pointing down", .category = .people },
    .{ .emoji = "☝️", .name = "index pointing up", .category = .people },
    .{ .emoji = "👏", .name = "clapping hands", .category = .people },
    .{ .emoji = "🙌", .name = "raising hands", .category = .people },
    .{ .emoji = "👐", .name = "open hands", .category = .people },
    .{ .emoji = "🤲", .name = "palms up together", .category = .people },
    .{ .emoji = "🙏", .name = "folded hands", .category = .people },
    .{ .emoji = "💪", .name = "flexed biceps", .category = .people },
    .{ .emoji = "🦾", .name = "mechanical arm", .category = .people },

    .{ .emoji = "🐶", .name = "dog face", .category = .animals },
    .{ .emoji = "🐱", .name = "cat face", .category = .animals },
    .{ .emoji = "🐭", .name = "mouse face", .category = .animals },
    .{ .emoji = "🐹", .name = "hamster face", .category = .animals },
    .{ .emoji = "🐰", .name = "rabbit face", .category = .animals },
    .{ .emoji = "🦊", .name = "fox", .category = .animals },
    .{ .emoji = "🐻", .name = "bear face", .category = .animals },
    .{ .emoji = "🐼", .name = "panda", .category = .animals },
    .{ .emoji = "🐨", .name = "koala", .category = .animals },
    .{ .emoji = "🐯", .name = "tiger face", .category = .animals },
    .{ .emoji = "🦁", .name = "lion", .category = .animals },
    .{ .emoji = "🐮", .name = "cow face", .category = .animals },
    .{ .emoji = "🐷", .name = "pig face", .category = .animals },
    .{ .emoji = "🐸", .name = "frog", .category = .animals },
    .{ .emoji = "🐵", .name = "monkey face", .category = .animals },
    .{ .emoji = "🐔", .name = "chicken", .category = .animals },
    .{ .emoji = "🐧", .name = "penguin", .category = .animals },
    .{ .emoji = "🐦", .name = "bird", .category = .animals },
    .{ .emoji = "🐤", .name = "baby chick", .category = .animals },
    .{ .emoji = "🦆", .name = "duck", .category = .animals },
    .{ .emoji = "🦉", .name = "owl", .category = .animals },
    .{ .emoji = "🦋", .name = "butterfly", .category = .animals },
    .{ .emoji = "🐝", .name = "honeybee", .category = .animals },
    .{ .emoji = "🐛", .name = "bug", .category = .animals },
    .{ .emoji = "🦄", .name = "unicorn", .category = .animals },
    .{ .emoji = "🐝", .name = "honeybee", .category = .animals },

    .{ .emoji = "🍎", .name = "red apple", .category = .food },
    .{ .emoji = "🍊", .name = "tangerine", .category = .food },
    .{ .emoji = "🍋", .name = "lemon", .category = .food },
    .{ .emoji = "🍌", .name = "banana", .category = .food },
    .{ .emoji = "🍉", .name = "watermelon", .category = .food },
    .{ .emoji = "🍇", .name = "grapes", .category = .food },
    .{ .emoji = "🍓", .name = "strawberry", .category = .food },
    .{ .emoji = "🍒", .name = "cherries", .category = .food },
    .{ .emoji = "🍑", .name = "peach", .category = .food },
    .{ .emoji = "🍍", .name = "pineapple", .category = .food },
    .{ .emoji = "🥝", .name = "kiwi fruit", .category = .food },
    .{ .emoji = "🍅", .name = "tomato", .category = .food },
    .{ .emoji = "🥑", .name = "avocado", .category = .food },
    .{ .emoji = "🍔", .name = "hamburger", .category = .food },
    .{ .emoji = "🍕", .name = "pizza", .category = .food },
    .{ .emoji = "🌭", .name = "hot dog", .category = .food },
    .{ .emoji = "🍟", .name = "french fries", .category = .food },
    .{ .emoji = "🌮", .name = "taco", .category = .food },
    .{ .emoji = "🍣", .name = "sushi", .category = .food },
    .{ .emoji = "🍜", .name = "steaming bowl", .category = .food },
    .{ .emoji = "🍝", .name = "spaghetti", .category = .food },
    .{ .emoji = "🍦", .name = "soft ice cream", .category = .food },
    .{ .emoji = "🍰", .name = "shortcake", .category = .food },
    .{ .emoji = "🎂", .name = "birthday cake", .category = .food },
    .{ .emoji = "🍩", .name = "doughnut", .category = .food },
    .{ .emoji = "🍪", .name = "cookie", .category = .food },
    .{ .emoji = "☕", .name = "hot beverage", .category = .food },
    .{ .emoji = "🍵", .name = "teacup without handle", .category = .food },
    .{ .emoji = "🍺", .name = "beer mug", .category = .food },
    .{ .emoji = "🍷", .name = "wine glass", .category = .food },

    .{ .emoji = "🚗", .name = "car", .category = .travel },
    .{ .emoji = "🚕", .name = "taxi", .category = .travel },
    .{ .emoji = "🚙", .name = "sport utility vehicle", .category = .travel },
    .{ .emoji = "🚌", .name = "bus", .category = .travel },
    .{ .emoji = "🚎", .name = "trolleybus", .category = .travel },
    .{ .emoji = "🏎️", .name = "racing car", .category = .travel },
    .{ .emoji = "🚓", .name = "police car", .category = .travel },
    .{ .emoji = "🚑", .name = "ambulance", .category = .travel },
    .{ .emoji = "🚒", .name = "fire engine", .category = .travel },
    .{ .emoji = "🚐", .name = "minibus", .category = .travel },
    .{ .emoji = "🚚", .name = "delivery truck", .category = .travel },
    .{ .emoji = "🚛", .name = "articulated lorry", .category = .travel },
    .{ .emoji = "🚜", .name = "tractor", .category = .travel },
    .{ .emoji = "🏍️", .name = "motorcycle", .category = .travel },
    .{ .emoji = "🛵", .name = "motor scooter", .category = .travel },
    .{ .emoji = "🚲", .name = "bicycle", .category = .travel },
    .{ .emoji = "🛴", .name = "kick scooter", .category = .travel },
    .{ .emoji = "⛵", .name = "sailboat", .category = .travel },
    .{ .emoji = "✈️", .name = "airplane", .category = .travel },
    .{ .emoji = "🚀", .name = "rocket", .category = .travel },
    .{ .emoji = "🛸", .name = "flying saucer", .category = .travel },
    .{ .emoji = "🚁", .name = "helicopter", .category = .travel },
    .{ .emoji = "🚂", .name = "locomotive", .category = .travel },
    .{ .emoji = "🚆", .name = "train", .category = .travel },
    .{ .emoji = "🚇", .name = "metro", .category = .travel },
    .{ .emoji = "🚈", .name = "light rail", .category = .travel },

    .{ .emoji = "⚽", .name = "soccer ball", .category = .activities },
    .{ .emoji = "🏀", .name = "basketball", .category = .activities },
    .{ .emoji = "🏈", .name = "american football", .category = .activities },
    .{ .emoji = "⚾", .name = "baseball", .category = .activities },
    .{ .emoji = "🎾", .name = "tennis", .category = .activities },
    .{ .emoji = "🏐", .name = "volleyball", .category = .activities },
    .{ .emoji = "🏉", .name = "rugby football", .category = .activities },
    .{ .emoji = "🎱", .name = "pool 8 ball", .category = .activities },
    .{ .emoji = "🏓", .name = "ping pong", .category = .activities },
    .{ .emoji = "🏸", .name = "badminton", .category = .activities },
    .{ .emoji = "🥊", .name = "boxing glove", .category = .activities },
    .{ .emoji = "🏆", .name = "trophy", .category = .activities },
    .{ .emoji = "🥇", .name = "1st place medal", .category = .activities },
    .{ .emoji = "🥈", .name = "2nd place medal", .category = .activities },
    .{ .emoji = "🥉", .name = "3rd place medal", .category = .activities },
    .{ .emoji = "🎯", .name = "bullseye", .category = .activities },
    .{ .emoji = "🎮", .name = "video game", .category = .activities },
    .{ .emoji = "🎲", .name = "game die", .category = .activities },
    .{ .emoji = "🎭", .name = "performing arts", .category = .activities },
    .{ .emoji = "🎨", .name = "artist palette", .category = .activities },
    .{ .emoji = "🎬", .name = "clapper board", .category = .activities },
    .{ .emoji = "🎤", .name = "microphone", .category = .activities },
    .{ .emoji = "🎧", .name = "headphone", .category = .activities },
    .{ .emoji = "🎼", .name = "musical score", .category = .activities },
    .{ .emoji = "🎹", .name = "musical keyboard", .category = .activities },
    .{ .emoji = "🎸", .name = "guitar", .category = .activities },

    .{ .emoji = "💻", .name = "laptop", .category = .objects },
    .{ .emoji = "🖥️", .name = "desktop computer", .category = .objects },
    .{ .emoji = "⌨️", .name = "keyboard", .category = .objects },
    .{ .emoji = "🖱️", .name = "computer mouse", .category = .objects },
    .{ .emoji = "🖨️", .name = "printer", .category = .objects },
    .{ .emoji = "💾", .name = "floppy disk", .category = .objects },
    .{ .emoji = "💿", .name = "optical disk", .category = .objects },
    .{ .emoji = "📀", .name = "dvd", .category = .objects },
    .{ .emoji = "📱", .name = "mobile phone", .category = .objects },
    .{ .emoji = "📞", .name = "telephone receiver", .category = .objects },
    .{ .emoji = "☎️", .name = "telephone", .category = .objects },
    .{ .emoji = "📻", .name = "radio", .category = .objects },
    .{ .emoji = "📺", .name = "television", .category = .objects },
    .{ .emoji = "📷", .name = "camera", .category = .objects },
    .{ .emoji = "📸", .name = "camera with flash", .category = .objects },
    .{ .emoji = "📹", .name = "video camera", .category = .objects },
    .{ .emoji = "📹", .name = "video camera", .category = .objects },
    .{ .emoji = "🔍", .name = "magnifying glass tilted left", .category = .objects },
    .{ .emoji = "🔎", .name = "magnifying glass tilted right", .category = .objects },
    .{ .emoji = "💡", .name = "light bulb", .category = .objects },
    .{ .emoji = "🔦", .name = "flashlight", .category = .objects },
    .{ .emoji = "📖", .name = "open book", .category = .objects },
    .{ .emoji = "📚", .name = "books", .category = .objects },
    .{ .emoji = "📝", .name = "memo", .category = .objects },
    .{ .emoji = "✏️", .name = "pencil", .category = .objects },
    .{ .emoji = "✒️", .name = "black nib", .category = .objects },

    .{ .emoji = "❤️", .name = "red heart", .category = .symbols },
    .{ .emoji = "🧡", .name = "orange heart", .category = .symbols },
    .{ .emoji = "💛", .name = "yellow heart", .category = .symbols },
    .{ .emoji = "💚", .name = "green heart", .category = .symbols },
    .{ .emoji = "💙", .name = "blue heart", .category = .symbols },
    .{ .emoji = "💜", .name = "purple heart", .category = .symbols },
    .{ .emoji = "🖤", .name = "black heart", .category = .symbols },
    .{ .emoji = "🤍", .name = "white heart", .category = .symbols },
    .{ .emoji = "🤎", .name = "brown heart", .category = .symbols },
    .{ .emoji = "💔", .name = "broken heart", .category = .symbols },
    .{ .emoji = "💕", .name = "two hearts", .category = .symbols },
    .{ .emoji = "💖", .name = "sparkling heart", .category = .symbols },
    .{ .emoji = "💗", .name = "growing heart", .category = .symbols },
    .{ .emoji = "💓", .name = "beating heart", .category = .symbols },
    .{ .emoji = "💞", .name = "revolving hearts", .category = .symbols },
    .{ .emoji = "💘", .name = "heart with arrow", .category = .symbols },
    .{ .emoji = "💝", .name = "heart with ribbon", .category = .symbols },
    .{ .emoji = "⭐", .name = "star", .category = .symbols },
    .{ .emoji = "🌟", .name = "glowing star", .category = .symbols },
    .{ .emoji = "✨", .name = "sparkles", .category = .symbols },
    .{ .emoji = "🔥", .name = "fire", .category = .symbols },
    .{ .emoji = "💫", .name = "dizzy", .category = .symbols },
    .{ .emoji = "💥", .name = "collision", .category = .symbols },
    .{ .emoji = "✅", .name = "check mark button", .category = .symbols },
    .{ .emoji = "❌", .name = "cross mark", .category = .symbols },
    .{ .emoji = "⚠️", .name = "warning", .category = .symbols },
    .{ .emoji = "❓", .name = "question mark", .category = .symbols },
    .{ .emoji = "❗", .name = "exclamation mark", .category = .symbols },
    .{ .emoji = "💯", .name = "hundred points", .category = .symbols },
    .{ .emoji = "🔔", .name = "bell", .category = .symbols },
    .{ .emoji = "🔕", .name = "bell with slash", .category = .symbols },

    .{ .emoji = "🏳️", .name = "white flag", .category = .flags },
    .{ .emoji = "🏴", .name = "black flag", .category = .flags },
    .{ .emoji = "🏁", .name = "chequered flag", .category = .flags },
    .{ .emoji = "🚩", .name = "triangular flag", .category = .flags },
    .{ .emoji = "🎌", .name = "crossed flags", .category = .flags },
    .{ .emoji = "🏴‍☠️", .name = "pirate flag", .category = .flags },
    .{ .emoji = "🇺🇸", .name = "United States", .category = .flags },
    .{ .emoji = "🇨🇳", .name = "China", .category = .flags },
    .{ .emoji = "🇯🇵", .name = "Japan", .category = .flags },
    .{ .emoji = "🇰🇷", .name = "South Korea", .category = .flags },
    .{ .emoji = "🇬🇧", .name = "United Kingdom", .category = .flags },
    .{ .emoji = "🇫🇷", .name = "France", .category = .flags },
    .{ .emoji = "🇩🇪", .name = "Germany", .category = .flags },
    .{ .emoji = "🇮🇹", .name = "Italy", .category = .flags },
    .{ .emoji = "🇪🇸", .name = "Spain", .category = .flags },
    .{ .emoji = "🇷🇺", .name = "Russia", .category = .flags },
    .{ .emoji = "🇧🇷", .name = "Brazil", .category = .flags },
    .{ .emoji = "🇮🇳", .name = "India", .category = .flags },
    .{ .emoji = "🇨🇦", .name = "Canada", .category = .flags },
    .{ .emoji = "🇦🇺", .name = "Australia", .category = .flags },
};

/// 表情分类名称
const category_names = std.EnumArray(EmojiCategory, []const u8).init(.{
    .smileys = "😀",
    .people = "👋",
    .animals = "🐶",
    .food = "🍔",
    .travel = "🚗",
    .activities = "⚽",
    .objects = "💻",
    .symbols = "❤️",
    .flags = "🏳️",
    .recently_used = "🕐",
});

pub const EmojiChooser = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    visible: bool = false,
    current_category: EmojiCategory = .smileys,
    search_query: []const u8 = "",

    recently_used: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 },

    on_emoji_selected: ?*const fn (self: *EmojiChooser, emoji: []const u8) void = null,
    on_close: ?*const fn (self: *EmojiChooser) void = null,

    panel_width: f32 = 320,
    panel_height: f32 = 340,
    emoji_size: f32 = 24,
    columns: usize = 8,

    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    header_bg: math.Color = math.Color.hex(0x0F172AFF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    text_secondary: math.Color = math.Color.hex(0x94A3B8FF),
    border_color: math.Color = math.Color.hex(0x334155FF),
    hover_color: math.Color = math.Color.hex(0x334155FF),
    select_color: math.Color = math.Color.hex(0x3B82F644),
    corner_radius: f32 = 12.0,

    category_buttons: std.ArrayListUnmanaged(*Button) = .{ .items = &.{}, .capacity = 0 },
    search_input: ?*Entry = null,
    scroll_view: ?*ScrolledWindow = null,

    hovered_emoji: ?usize = null,
    emoji_gap: f32 = 4.0,
    emoji_padding: f32 = 6.0,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        on_emoji_selected: ?*const fn (self: *EmojiChooser, emoji: []const u8) void = null,
        on_close: ?*const fn (self: *EmojiChooser) void = null,
        panel_width: f32 = 320,
        panel_height: f32 = 340,
    }) !*EmojiChooser {
        const self = try allocator.create(EmojiChooser);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .on_emoji_selected = opts.on_emoji_selected,
            .on_close = opts.on_close,
            .panel_width = opts.panel_width,
            .panel_height = opts.panel_height,
        };
        self.base.accessibility = .{ .role = .dialog, .label = "Emoji Chooser" };
        try self.buildUI();
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        for (self.recently_used.items) |emoji| {
            allocator.free(emoji);
        }
        self.recently_used.deinit(allocator);

        for (self.category_buttons.items) |btn| {
            btn.destroy(allocator);
        }
        self.category_buttons.deinit(allocator);

        if (self.search_query.len > 0) {
            allocator.free(self.search_query);
        }

        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn show(self: *Self) void {
        self.visible = true;
        self.base.markDirty();
    }

    pub fn hide(self: *Self) void {
        self.visible = false;
        self.base.markDirty();
        if (self.on_close) |cb| cb(self);
    }

    fn buildUI(self: *Self) !void {
        const categories = [_]EmojiCategory{ .smileys, .people, .animals, .food, .travel, .activities, .objects, .symbols, .flags };
        for (categories) |cat| {
            const btn = try Button.create(self.allocator, category_names.get(cat), .{
                .on_click = onCategoryClick,
                .bg_color = math.Color.hex(0x00000000),
                .bg_hover = self.hover_color,
                .bg_pressed = self.select_color,
                .text_color = self.text_color,
                .corner_radius = 6.0,
                .padding_h = 8.0,
                .padding_v = 6.0,
                .font_size = 16,
            });
            btn.base.user_data = @as(*anyopaque, @ptrFromInt(@as(usize, @intFromEnum(cat))));
            btn.base.parent = &self.base;
            try self.category_buttons.append(self.allocator, btn);
            try self.base.addChild(self.allocator, &btn.base);
        }

        const search = try Entry.create(self.allocator, .{
            .placeholder = "搜索表情...",
            .on_change = onSearchChanged,
            .text_color = self.text_color,
            .font_size = 13,
        });
        search.base.parent = &self.base;
        self.search_input = search;
        try self.base.addChild(self.allocator, &search.base);
    }

    fn onCategoryClick(btn: *Button) void {
        const self: *Self = @fieldParentPtr("base", btn.base.parent.?);
        const cat: EmojiCategory = @enumFromInt(@intFromPtr(btn.base.user_data.?));
        self.current_category = cat;
        self.hovered_emoji = null;
        self.base.markDirty();
    }

    fn onSearchChanged(input: *Entry, text: []const u8) void {
        const self: *Self = @fieldParentPtr("base", input.base.parent.?);
        if (self.search_query.len > 0) {
            self.allocator.free(self.search_query);
        }
        self.search_query = self.allocator.dupe(u8, text) catch "";
        self.hovered_emoji = null;
        self.base.markDirty();
    }

    fn getFilteredEmojis(self: *Self) []const EmojiItem {
        if (self.search_query.len > 0) {
            return &default_emojis;
        }
        return &default_emojis;
    }

    fn getEmojiCount(self: *Self) usize {
        if (self.current_category == .recently_used) {
            return self.recently_used.items.len;
        }
        if (self.search_query.len > 0) {
            var count: usize = 0;
            for (default_emojis) |emoji| {
                if (containsIgnoreCase(emoji.name, self.search_query)) {
                    count += 1;
                }
            }
            return count;
        }
        var count: usize = 0;
        for (default_emojis) |emoji| {
            if (emoji.category == self.current_category) {
                count += 1;
            }
        }
        return count;
    }

    fn getEmojiAt(self: *Self, index: usize) ?[]const u8 {
        if (self.current_category == .recently_used) {
            if (index < self.recently_used.items.len) {
                return self.recently_used.items[index];
            }
            return null;
        }
        if (self.search_query.len > 0) {
            var idx: usize = 0;
            for (default_emojis) |emoji| {
                if (containsIgnoreCase(emoji.name, self.search_query)) {
                    if (idx == index) return emoji.emoji;
                    idx += 1;
                }
            }
            return null;
        }
        var idx: usize = 0;
        for (default_emojis) |emoji| {
            if (emoji.category == self.current_category) {
                if (idx == index) return emoji.emoji;
                idx += 1;
            }
        }
        return null;
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i <= haystack.len - needle.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
                return true;
            }
        }
        return false;
    }

    fn addToRecentlyUsed(self: *Self, emoji: []const u8) void {
        for (self.recently_used.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, emoji)) {
                const duped = self.allocator.dupe(u8, emoji) catch return;
                self.allocator.free(self.recently_used.items[i]);
                _ = self.recently_used.orderedRemove(i);
                self.recently_used.insert(self.allocator, 0, duped) catch {};
                return;
            }
        }
        const duped = self.allocator.dupe(u8, emoji) catch return;
        self.recently_used.insert(self.allocator, 0, duped) catch {};
        if (self.recently_used.items.len > 24) {
            const old = self.recently_used.pop();
            if (old) |o| self.allocator.free(o);
        }
    }

    const vtable = Widget.VTable{
        .type_name = "emoji_chooser",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ctx;
        _ = constraints;
        return .{ .width = self.panel_width, .height = self.panel_height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.visible) return;

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const pw = self.panel_width;
        const ph = self.panel_height;

        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = pw, .height = ph },
            self.corner_radius,
            self.bg_color,
        ) catch {};

        ctx.renderer.strokeRoundedRect(
            .{ .x = rx, .y = ry, .width = pw, .height = ph },
            self.corner_radius,
            1.0,
            self.border_color,
        ) catch {};

        var y_offset: f32 = ry + 8;

        if (self.search_input) |search| {
            const search_h: f32 = 32;
            search.base.rect.x = w.rect.x + 10;
            search.base.rect.y = y_offset - ry;
            search.base.rect.width = pw - 20;
            search.base.rect.height = search_h;
            search.base.paintTree(ctx);
            y_offset += search_h + 8;
        }

        const cat_bar_h: f32 = 36;
        ctx.renderer.fillRect(
            .{ .x = rx, .y = ry + y_offset - ry, .width = pw, .height = cat_bar_h },
            self.header_bg,
        ) catch {};

        const cat_count = self.category_buttons.items.len;
        const cat_btn_w = pw / @as(f32, @floatFromInt(cat_count));
        for (self.category_buttons.items, 0..) |btn, i| {
            const cat: EmojiCategory = @enumFromInt(@intFromPtr(btn.base.user_data.?));
            btn.base.rect.x = w.rect.x + @as(f32, @floatFromInt(i)) * cat_btn_w;
            btn.base.rect.y = y_offset - ry;
            btn.base.rect.width = cat_btn_w;
            btn.base.rect.height = cat_bar_h;
            if (cat == self.current_category) {
                btn.base.state.pressed = true;
            } else {
                btn.base.state.pressed = false;
            }
            btn.base.paintTree(ctx);
        }
        y_offset += cat_bar_h + 4;

        const emoji_area_y = y_offset;
        const emoji_area_h = ph - (y_offset - ry) - 10;
        const emoji_total = self.getEmojiCount();
        const rows = (emoji_total + self.columns - 1) / self.columns;
        const emoji_cell_w = (pw - 20) / @as(f32, @floatFromInt(self.columns));
        const emoji_cell_h = self.emoji_size + self.emoji_padding * 2;
        const content_h = @max(emoji_area_h, @as(f32, @floatFromInt(rows)) * emoji_cell_h + self.emoji_gap * @as(f32, @floatFromInt(rows -| 1)));

        var scroll_offset: f32 = 0;
        const view_h = emoji_area_h;
        if (content_h > view_h) {
            scroll_offset = 0;
        }

        var emoji_idx: usize = 0;
        var row: usize = 0;
        while (emoji_idx < emoji_total) : (row += 1) {
            var col: usize = 0;
            while (col < self.columns and emoji_idx < emoji_total) : (col += 1) {
                const emoji = self.getEmojiAt(emoji_idx);
                if (emoji) |e| {
                    const cell_x = rx + 10 + @as(f32, @floatFromInt(col)) * emoji_cell_w;
                    const cell_y = ry + emoji_area_y - ry + @as(f32, @floatFromInt(row)) * (emoji_cell_h + self.emoji_gap) - scroll_offset;

                    if (cell_y + emoji_cell_h < ry + emoji_area_y - ry or cell_y > ry + emoji_area_y - ry + emoji_area_h) {
                        emoji_idx += 1;
                        continue;
                    }

                    const is_hovered = if (self.hovered_emoji) |h| h == emoji_idx else false;
                    if (is_hovered) {
                        ctx.renderer.fillRoundedRect(
                            .{ .x = cell_x, .y = cell_y, .width = emoji_cell_w, .height = emoji_cell_h },
                            6.0,
                            self.hover_color,
                        ) catch {};
                    }

                    const emoji_size_measured = styled_text.measureText(ctx.allocator, e, .{
                        .font_size = self.emoji_size,
                    });
                    const emoji_x = cell_x + (emoji_cell_w - emoji_size_measured.width) / 2;
                    const emoji_y = cell_y + (emoji_cell_h - emoji_size_measured.height) / 2;
                    styled_text.drawText(
                        ctx.renderer,
                        ctx.allocator,
                        e,
                        emoji_x,
                        emoji_y,
                        .{ .font_size = self.emoji_size },
                    );
                }
                emoji_idx += 1;
            }
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.visible) return .ignored;

        switch (event.*) {
            .key => |key| {
                if (key.state == .pressed and key.key == .escape) {
                    self.hide();
                    return .handled;
                }
                return .ignored;
            },
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const local_x = @as(f32, @floatFromInt(mb.x)) - w.absoluteRect().x;
                    const local_y = @as(f32, @floatFromInt(mb.y)) - w.absoluteRect().y;

                    if (local_x < 0 or local_x > self.panel_width or local_y < 0 or local_y > self.panel_height) {
                        self.hide();
                        return .handled;
                    }

                    const emoji_idx = self.getEmojiAtPos(local_x, local_y);
                    if (emoji_idx) |idx| {
                        if (self.getEmojiAt(idx)) |emoji| {
                            self.addToRecentlyUsed(emoji);
                            if (self.on_emoji_selected) |cb| {
                                cb(self, emoji);
                            }
                            self.hide();
                        }
                        return .handled;
                    }

                    for (self.category_buttons.items) |btn| {
                        const result = btn.base.dispatchEvent(event, ectx);
                        if (result == .handled) return .handled;
                    }
                    if (self.search_input) |search| {
                        const result = search.base.dispatchEvent(event, ectx);
                        if (result == .handled) return .handled;
                    }

                    return .handled;
                }
                return .handled;
            },
            .mouse_move => |mm| {
                const local_x = @as(f32, @floatFromInt(mm.x)) - w.absoluteRect().x;
                const local_y = @as(f32, @floatFromInt(mm.y)) - w.absoluteRect().y;

                const emoji_idx = self.getEmojiAtPos(local_x, local_y);
                if (emoji_idx != self.hovered_emoji) {
                    self.hovered_emoji = emoji_idx;
                    w.markDirty();
                }

                for (self.category_buttons.items) |btn| {
                    const result = btn.base.dispatchEvent(event, ectx);
                    if (result == .handled) break;
                }
                if (self.search_input) |search| {
                    _ = search.base.dispatchEvent(event, ectx);
                }

                return .handled;
            },
            else => {
                for (self.category_buttons.items) |btn| {
                    const result = btn.base.dispatchEvent(event, ectx);
                    if (result == .handled) return .handled;
                }
                if (self.search_input) |search| {
                    const result = search.base.dispatchEvent(event, ectx);
                    if (result == .handled) return .handled;
                }
                return .ignored;
            },
        }
    }

    fn getEmojiAtPos(self: *Self, x: f32, y: f32) ?usize {
        const search_h: f32 = 32;
        const cat_bar_h: f32 = 36;
        const emoji_area_y = 8 + search_h + 8 + cat_bar_h + 4;

        if (x < 10 or x > self.panel_width - 10) return null;
        if (y < emoji_area_y) return null;

        const emoji_cell_w = (self.panel_width - 20) / @as(f32, @floatFromInt(self.columns));
        const emoji_cell_h = self.emoji_size + self.emoji_padding * 2;

        const rel_x = x - 10;
        const rel_y = y - emoji_area_y;

        const col = @as(usize, @intFromFloat(rel_x / emoji_cell_w));
        const row = @as(usize, @intFromFloat(rel_y / (emoji_cell_h + self.emoji_gap)));

        if (col >= self.columns) return null;

        const idx = row * self.columns + col;
        if (idx >= self.getEmojiCount()) return null;

        return idx;
    }
};
