const std = @import("std");
const c = @import("c.zig");
const constants = @import("constants.zig");

const glyph_lib = @import("glyphee.zig");
const TypeSetter = glyph_lib.TypeSetter;

const helpers = @import("helpers.zig");
const Vector2 = helpers.Vector2;
const Camera = helpers.Camera;
const SingleInput = helpers.SingleInput;
const MouseState = helpers.MouseState;
const EditableText = helpers.EditableText;
const TYPING_BUFFER_SIZE = 16;
const TYPEROO_LINE_WIDTH = 66;
// This was checked and addede here.
const TYPEROO_FONT_WIDTH = 11.6129035;
const TYPEROO_NUM_LINES = 5;
const TYPEROO_NUM_BACKSPACE = 8;

const NOTEBOOK_PATH = "C:\\Users\\user\\notebook.txt";

const InputKey = enum {
    shift,
    tab,
    enter,
    space,
    escape,
    ctrl,
};
const INPUT_KEYS_COUNT = @typeInfo(InputKey).Enum.fields.len;
const InputMap = struct {
    key: c.SDL_Keycode,
    input: InputKey,
};

const INPUT_MAPPING = [_]InputMap{
    .{ .key = c.SDLK_LSHIFT, .input = .shift },
    .{ .key = c.SDLK_LCTRL, .input = .ctrl },
    .{ .key = c.SDLK_TAB, .input = .tab },
    .{ .key = c.SDLK_RETURN, .input = .enter },
    .{ .key = c.SDLK_SPACE, .input = .space },
    .{ .key = c.SDLK_ESCAPE, .input = .escape },
};

pub const InputState = struct {
    const Self = @This();
    keys: [INPUT_KEYS_COUNT]SingleInput = [_]SingleInput{.{}} ** INPUT_KEYS_COUNT,
    mouse: MouseState = MouseState{},
    typed: [TYPING_BUFFER_SIZE]u8 = [_]u8{0} ** TYPING_BUFFER_SIZE,
    num_typed: usize = 0,

    pub fn get_key(self: *Self, key: InputKey) *SingleInput {
        return &self.keys[@enumToInt(key)];
    }

    pub fn type_key(self: *Self, k: u8) void {
        if (self.num_typed >= TYPING_BUFFER_SIZE) {
            std.debug.print("Typing buffer already filled.\n", .{});
            return;
        }
        self.typed[self.num_typed] = k;
        self.num_typed += 1;
    }

    pub fn reset(self: *Self) void {
        for (self.keys) |*key| key.reset();
        self.mouse.reset_mouse();
        self.num_typed = 0;
    }
};

const Line = struct {
    start: usize = 0,
    end: usize = 0,
};

pub const App = struct {
    const Self = @This();
    typesetter: TypeSetter = undefined,
    camera: Camera = .{},
    allocator: *std.mem.Allocator,
    arena: *std.mem.Allocator,
    ticks: u32 = 0,
    quit: bool = false,
    inputs: InputState = .{},
    typed: EditableText,
    lines: std.ArrayList(Line),
    backspace_used: usize = 0,
    total_line_width: f32 = 0.0,

    pub fn new(allocator: *std.mem.Allocator, arena: *std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .arena = arena,
            .typed = EditableText.init(allocator),
            .lines = std.ArrayList(Line).init(allocator),
        };
    }

    pub fn init(self: *Self) !void {
        try self.typesetter.init(&self.camera, self.allocator);
        var buf: [TYPEROO_LINE_WIDTH]u8 = undefined;
        var i: usize = 0;
        while (i < TYPEROO_LINE_WIDTH) : (i += 1) buf[i] = 'a';
        self.total_line_width = self.typesetter.get_text_width_font(buf[0..], .debug).x;
        self.print_current_day();
    }

    pub fn deinit(self: *Self) void {
        self.save_note_to_file();
        self.typesetter.deinit();
        self.typed.deinit();
        self.lines.deinit();
    }

    fn backspace_allowed(self: *Self) bool {
        return self.backspace_used < TYPEROO_NUM_BACKSPACE;
    }

    fn print_current_day(self: *Self) void {
        _ = self;
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(u64, std.time.timestamp()) };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        std.debug.print("Year: {d}, Month: {d}, Day: {d}\n", .{ year_day.year, @enumToInt(month_day.month), month_day.day_index + 1 });
    }

    fn check_backspace(self: *Self, event: c.SDL_Event) bool {
        if (!self.backspace_allowed()) return false;
        const name = c.SDL_GetKeyName(event.key.keysym.sym);
        var len: usize = 0;
        while (name[len] != 0) : (len += 1) {}
        if (len == 0) return false;
        if (std.mem.eql(u8, name[0..len], "Backspace")) {
            return true;
        }
        return false;
    }

    fn save_note_to_file(self: *Self) void {
        var notebook_file = std.fs.cwd().openFile(NOTEBOOK_PATH, .{ .read = true, .write = true }) catch {
            std.debug.print("Could not open file to save.\n {s} \n", .{self.typed.text.items});
            return;
        };
        defer notebook_file.close();
        notebook_file.seekFromEnd(0) catch unreachable;
        var buffer: [256]u8 = undefined;
        // By default this gives us time in UTC. So just a simple translation to IST
        const timestamp_ist: u64 = @intCast(u64, std.time.timestamp()) + (60 * 60 * 5) + (60 * 30);
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(u64, timestamp_ist) };
        const epoch_day = epoch_seconds.getEpochDay();
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        var line = std.fmt.bufPrint(buffer[0..], "--- {d} {s} {d} - {d}:{d} ---\n", .{ month_day.day_index + 1, self.month_str(month_day.month), year_day.year, day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour() }) catch unreachable;
        notebook_file.writeAll(line) catch unreachable;
        notebook_file.writeAll(self.typed.text.items) catch unreachable;
        notebook_file.writeAll("\n\n") catch unreachable;
    }

    fn month_str(self: *Self, month: std.time.epoch.Month) []const u8 {
        _ = self;
        return switch (month) {
            .jan => "Jan",
            .feb => "Feb",
            .mar => "Mar",
            .apr => "Apr",
            .may => "May",
            .jun => "Jun",
            .jul => "Jul",
            .aug => "Aug",
            .sep => "Sep",
            .oct => "Oct",
            .nov => "Nov",
            .dec => "Dec",
        };
    }

    fn update_backspace(self: *Self) void {
        for (self.inputs.typed[0..self.inputs.num_typed]) |char| {
            if (char == 8) {
                self.backspace_used += 1;
            } else if (self.backspace_used > 0) {
                self.backspace_used -= 1;
            }
        }
    }

    pub fn handle_inputs(self: *Self, event: c.SDL_Event) void {
        if (event.@"type" == c.SDL_KEYDOWN and event.key.keysym.sym == c.SDLK_END)
            self.quit = true;
        self.inputs.mouse.handle_input(event, self.ticks, &self.camera);
        if (event.@"type" == c.SDL_KEYDOWN) {
            for (INPUT_MAPPING) |map| {
                if (event.key.keysym.sym == map.key) self.inputs.get_key(map.input).set_down(self.ticks);
            }
            if (helpers.get_char(event)) |k| self.inputs.type_key(k);
            if (self.check_backspace(event)) self.inputs.type_key(8);
        } else if (event.@"type" == c.SDL_KEYUP) {
            for (INPUT_MAPPING) |map| {
                if (event.key.keysym.sym == map.key) self.inputs.get_key(map.input).set_release();
            }
        }
    }

    pub fn check_line(self: *Self) void {
        self.lines.shrinkRetainingCapacity(0);
        var start: usize = 0;
        for (self.typed.text.items) |char, i| {
            var new_line = false;
            if (i - start > TYPEROO_LINE_WIDTH) new_line = true;
            if (char == '\n' or (new_line and char == ' ')) {
                const line = Line{ .start = start, .end = i };
                self.lines.append(line) catch unreachable;
                start = i + 1;
            }
        }
        const line = Line{ .start = start, .end = self.typed.text.items.len };
        self.lines.append(line) catch unreachable;
    }

    pub fn update(self: *Self, ticks: u32, arena: *std.mem.Allocator) void {
        self.ticks = ticks;
        self.arena = arena;
        self.typed.handle_inputs(self.inputs.typed[0..self.inputs.num_typed]);
        self.check_line();
        const xpos = (constants.DEFAULT_WINDOW_WIDTH - self.total_line_width) / 2.0;
        var ypos = 0.5 * constants.DEFAULT_WINDOW_HEIGHT;
        var i: usize = self.lines.items.len - 1;
        var lines_typed: usize = 0;
        while (true) : (i -= 1) {
            const line = self.lines.items[i];
            const alpha: f32 = 1.0 - (@intToFloat(f32, lines_typed) / @intToFloat(f32, TYPEROO_NUM_LINES));
            self.typesetter.draw_text_world_font_color(.{ .x = xpos, .y = ypos }, self.typed.text.items[line.start..line.end], .debug, .{ .x = 254.0 / 255.0, .y = 206.0 / 255.0, .z = 0.0, .w = alpha });
            ypos -= 1.2 * glyph_lib.FONT_SIZE;
            if (i == 0) break;
            lines_typed += 1;
            if (lines_typed > TYPEROO_NUM_LINES) break;
        }
        self.update_backspace();
    }

    pub fn reset_inputs(self: *Self) void {
        self.inputs.reset();
    }
};
