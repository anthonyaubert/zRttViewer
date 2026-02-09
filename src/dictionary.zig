//! Dictionary loading and message lookup for deferred logging.
//! Parses JSON dictionary files containing message definitions.

const std = @import("std");
const StringStream = @import("string_stream.zig");

/// Definition of a log message from the dictionary
pub const MessageDef = struct {
    fmt: []const u8,
    args: []const u8,
    file: []const u8,
    line: u32,
};

/// Dictionary containing message definitions indexed by ID
pub const Dictionary = struct {
    allocator: std.mem.Allocator,
    messages: std.AutoHashMap(u32, MessageDef),
    /// Storage for allocated strings
    string_storage: std.ArrayListUnmanaged([]const u8),
    /// Max length of "file:line" string across all entries (for aligned output)
    max_location_len: usize = 0,

    const Self = @This();

    /// Initialize an empty dictionary
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .messages = std.AutoHashMap(u32, MessageDef).init(allocator),
            .string_storage = std.ArrayListUnmanaged([]const u8){},
        };
    }

    /// Count the number of decimal digits in a u32
    fn countDigits(n: u32) usize {
        if (n == 0) return 1;
        var count: usize = 0;
        var val = n;
        while (val > 0) {
            val /= 10;
            count += 1;
        }
        return count;
    }

    /// Load dictionary from a JSON file
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Self {
        var self = Self.init(allocator);
        errdefer self.deinit();

        // Read file content
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
        defer allocator.free(content);

        try self.parseJson(content);

        return self;
    }

    /// Load dictionary from a JSON string (useful for testing)
    pub fn loadFromString(allocator: std.mem.Allocator, content: []const u8) !Self {
        var self = Self.init(allocator);
        errdefer self.deinit();

        try self.parseJson(content);

        return self;
    }

    /// Parse JSON content and populate the messages map
    fn parseJson(self: *Self, content: []const u8) !void {
        var stream = StringStream.init(content);

        // Find "messages" section
        if (!stream.advanceToChars("\"messages\"", true)) {
            return error.MissingMessagesSection;
        }

        // Skip to opening brace of messages object
        stream.skipWhitespace();
        if (stream.first() != ':') {
            return error.InvalidJsonFormat;
        }
        stream.advance(1);
        stream.skipWhitespace();
        if (stream.first() != '{') {
            return error.InvalidJsonFormat;
        }
        stream.advance(1);

        // Parse each message entry
        while (true) {
            stream.skipWhitespace();

            // Check for end of messages object
            if (stream.first() == '}') {
                break;
            }

            // Skip comma between entries
            if (stream.first() == ',') {
                stream.advance(1);
                stream.skipWhitespace();
            }

            // Parse message ID (quoted string)
            if (stream.first() != '"') {
                return error.ExpectedQuotedId;
            }
            stream.advance(1);

            // Read message ID as number
            var id: u32 = 0;
            while (stream.scanDigit(10)) |digit| {
                id = id * 10 + digit;
            }

            // Skip closing quote
            if (stream.first() != '"') {
                return error.ExpectedClosingQuote;
            }
            stream.advance(1);

            // Skip to colon and opening brace
            stream.skipWhitespace();
            if (stream.first() != ':') {
                return error.ExpectedColon;
            }
            stream.advance(1);
            stream.skipWhitespace();
            if (stream.first() != '{') {
                return error.ExpectedOpenBrace;
            }
            stream.advance(1);

            // Parse fields within message object
            var fmt: []const u8 = "";
            var args: []const u8 = "";
            var file: []const u8 = "";
            var line_val: u32 = 0;

            while (true) {
                stream.skipWhitespace();

                if (stream.first() == '}') {
                    break;
                }

                if (stream.first() == ',') {
                    stream.advance(1);
                    stream.skipWhitespace();
                }

                if (stream.first() == '}') {
                    break;
                }

                if (stream.first() != '"') {
                    return error.ExpectedFieldName;
                }
                stream.advance(1);

                // Check field name
                const is_fmt = stream.len() >= 3 and std.mem.eql(u8, stream.slice[stream.offset .. stream.offset + 3], "fmt");
                const is_args = stream.len() >= 4 and std.mem.eql(u8, stream.slice[stream.offset .. stream.offset + 4], "args");
                const is_file = stream.len() >= 4 and std.mem.eql(u8, stream.slice[stream.offset .. stream.offset + 4], "file");
                const is_line = stream.len() >= 4 and std.mem.eql(u8, stream.slice[stream.offset .. stream.offset + 4], "line");

                // Skip field name
                while (stream.first() != '"' and !stream.isEmpty()) {
                    stream.advance(1);
                }
                if (stream.first() != '"') {
                    return error.ExpectedClosingQuote;
                }
                stream.advance(1);

                // Skip to colon and value
                stream.skipWhitespace();
                if (stream.first() != ':') {
                    return error.ExpectedColon;
                }
                stream.advance(1);
                stream.skipWhitespace();

                if (stream.first() == '"') {
                    // Parse string value
                    stream.advance(1);

                    const value_start = stream.offset;
                    // Find end of string, handling escapes
                    while (!stream.isEmpty()) {
                        if (stream.first() == '\\') {
                            stream.advance(2); // Skip escape sequence
                        } else if (stream.first() == '"') {
                            break;
                        } else {
                            stream.advance(1);
                        }
                    }
                    const value_end = stream.offset;

                    if (stream.first() != '"') {
                        return error.ExpectedClosingQuote;
                    }
                    stream.advance(1);

                    // Store the value
                    const value = try self.allocator.dupe(u8, stream.slice[value_start..value_end]);
                    try self.string_storage.append(self.allocator, value);

                    if (is_fmt) {
                        fmt = value;
                    } else if (is_args) {
                        args = value;
                    } else if (is_file) {
                        file = value;
                    }
                } else {
                    // Parse numeric value (for "line")
                    var num: u32 = 0;
                    var has_digits = false;
                    while (stream.scanDigit(10)) |digit| {
                        num = num * 10 + digit;
                        has_digits = true;
                    }
                    if (has_digits and is_line) {
                        line_val = num;
                    }
                }
            }

            // Skip closing brace of message object
            stream.skipWhitespace();
            if (stream.first() != '}') {
                return error.ExpectedCloseBrace;
            }
            stream.advance(1);

            // Store the message (keep first occurrence for duplicate IDs)
            if (!self.messages.contains(id)) {
                try self.messages.put(id, .{ .fmt = fmt, .args = args, .file = file, .line = line_val });
                // Update max location length for aligned output ("file:line")
                const loc_len = file.len + 1 + countDigits(line_val);
                if (loc_len > self.max_location_len) {
                    self.max_location_len = loc_len;
                }
            }
        }
    }

    /// Look up a message by ID
    pub fn lookup(self: *const Self, id: u32) ?MessageDef {
        return self.messages.get(id);
    }

    /// Free all allocated memory
    pub fn deinit(self: *Self) void {
        // Free all stored strings
        for (self.string_storage.items) |s| {
            self.allocator.free(s);
        }
        self.string_storage.deinit(self.allocator);
        self.messages.deinit();
    }
};

test "Dictionary.loadFromString parses valid JSON" {
    const json =
        \\{
        \\  "version": "1.1",
        \\  "messages": {
        \\    "331898": { "fmt": "System initialized", "args": "", "file": "main.zig", "line": 70 },
        \\    "1016184": { "fmt": "Warm reset (count={d})", "args": "u32", "file": "reset.zig", "line": 12 },
        \\    "1048476": { "fmt": "GPIO port {d} pin {d} initialized", "args": "u8u8", "file": "gpio.zig", "line": 88 }
        \\  }
        \\}
    ;

    var dict = try Dictionary.loadFromString(std.testing.allocator, json);
    defer dict.deinit();

    // Check message 331898
    const msg1 = dict.lookup(331898);
    try std.testing.expect(msg1 != null);
    try std.testing.expectEqualStrings("System initialized", msg1.?.fmt);
    try std.testing.expectEqualStrings("", msg1.?.args);
    try std.testing.expectEqualStrings("main.zig", msg1.?.file);
    try std.testing.expectEqual(@as(u32, 70), msg1.?.line);

    // Check message 1016184
    const msg2 = dict.lookup(1016184);
    try std.testing.expect(msg2 != null);
    try std.testing.expectEqualStrings("Warm reset (count={d})", msg2.?.fmt);
    try std.testing.expectEqualStrings("u32", msg2.?.args);
    try std.testing.expectEqualStrings("reset.zig", msg2.?.file);
    try std.testing.expectEqual(@as(u32, 12), msg2.?.line);

    // Check message 1048476
    const msg3 = dict.lookup(1048476);
    try std.testing.expect(msg3 != null);
    try std.testing.expectEqualStrings("GPIO port {d} pin {d} initialized", msg3.?.fmt);
    try std.testing.expectEqualStrings("u8u8", msg3.?.args);
    try std.testing.expectEqualStrings("gpio.zig", msg3.?.file);
    try std.testing.expectEqual(@as(u32, 88), msg3.?.line);

    // Check non-existent message
    const msg4 = dict.lookup(999999);
    try std.testing.expect(msg4 == null);
}

test "Dictionary.loadFromString handles empty messages" {
    const json =
        \\{
        \\  "messages": {
        \\  }
        \\}
    ;

    var dict = try Dictionary.loadFromString(std.testing.allocator, json);
    defer dict.deinit();

    try std.testing.expect(dict.lookup(1) == null);
}

test "Dictionary.loadFromString keeps first occurrence for duplicate IDs" {
    const json =
        \\{
        \\  "messages": {
        \\    "100": { "fmt": "first", "args": "", "file": "a.zig", "line": 1 },
        \\    "100": { "fmt": "second", "args": "", "file": "b.zig", "line": 2 }
        \\  }
        \\}
    ;

    var dict = try Dictionary.loadFromString(std.testing.allocator, json);
    defer dict.deinit();

    const msg = dict.lookup(100);
    try std.testing.expect(msg != null);
    try std.testing.expectEqualStrings("first", msg.?.fmt);
}
