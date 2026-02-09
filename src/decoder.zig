//! Binary frame decoder for deferred logging system.
//! Handles frame synchronization, parsing, and argument decoding.

const std = @import("std");
const Dictionary = @import("dictionary.zig").Dictionary;
const MessageDef = @import("dictionary.zig").MessageDef;

/// Frame header constants
/// Frame layout: start(1) + data_size(1) + level(1) + id(3) + timestamp(4) + args(N)
/// data_size = 8 + N (includes level+id overhead(4) + timestamp(4) + args(N))
/// total_frame = 2 + data_size = 10 + N
pub const START_BYTE: u8 = 0x55;
pub const PREAMBLE_SIZE: usize = 2; // start(1) + data_size(1)
pub const HEADER_SIZE: usize = 10; // preamble(2) + level(1) + id(3) + timestamp(4)
pub const DATA_SIZE_OVERHEAD: usize = 8; // level(1) + id(3) + timestamp(4)
pub const MAX_FRAME_SIZE: usize = 256;

/// Log levels matching the embedded system
pub const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warning = 2,
    err = 3,

    pub fn fromU8(value: u8) ?LogLevel {
        return switch (value) {
            0 => .debug,
            1 => .info,
            2 => .warning,
            3 => .err,
            else => null,
        };
    }
};

/// Decoded frame result
pub const DecodedFrame = struct {
    timestamp: u32,
    level: LogLevel,
    message: []const u8,
    raw_id: u32,
    file: []const u8 = "",
    line: u32 = 0,
};

/// Argument types for parsing
pub const ArgType = enum {
    u8,
    i8,
    u16,
    i16,
    u32,
    i32,
    f32,

    /// Get the size in bytes for this argument type
    pub fn size(self: ArgType) usize {
        return switch (self) {
            .u8, .i8 => 1,
            .u16, .i16 => 2,
            .u32, .i32, .f32 => 4,
        };
    }
};

/// A decoded argument value
pub const DecodedArg = union(ArgType) {
    u8: u8,
    i8: i8,
    u16: u16,
    i16: i16,
    u32: u32,
    i32: i32,
    f32: f32,

    /// Format the argument as a string (decimal)
    pub fn formatDecimal(self: DecodedArg, buf: []u8) []const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        switch (self) {
            .u8 => |v| writer.print("{d}", .{v}) catch {},
            .i8 => |v| writer.print("{d}", .{v}) catch {},
            .u16 => |v| writer.print("{d}", .{v}) catch {},
            .i16 => |v| writer.print("{d}", .{v}) catch {},
            .u32 => |v| writer.print("{d}", .{v}) catch {},
            .i32 => |v| writer.print("{d}", .{v}) catch {},
            .f32 => |v| writer.print("{d:.6}", .{v}) catch {},
        }

        return stream.getWritten();
    }

    /// Format the argument as a hex string (lowercase)
    pub fn formatHexLower(self: DecodedArg, buf: []u8) []const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        switch (self) {
            .u8 => |v| writer.print("{x}", .{v}) catch {},
            .i8 => |v| writer.print("{x}", .{@as(u8, @bitCast(v))}) catch {},
            .u16 => |v| writer.print("{x}", .{v}) catch {},
            .i16 => |v| writer.print("{x}", .{@as(u16, @bitCast(v))}) catch {},
            .u32 => |v| writer.print("{x}", .{v}) catch {},
            .i32 => |v| writer.print("{x}", .{@as(u32, @bitCast(v))}) catch {},
            .f32 => |v| writer.print("{x}", .{@as(u32, @bitCast(v))}) catch {},
        }

        return stream.getWritten();
    }

    /// Format the argument as a hex string (uppercase)
    pub fn formatHexUpper(self: DecodedArg, buf: []u8) []const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        switch (self) {
            .u8 => |v| writer.print("{X}", .{v}) catch {},
            .i8 => |v| writer.print("{X}", .{@as(u8, @bitCast(v))}) catch {},
            .u16 => |v| writer.print("{X}", .{v}) catch {},
            .i16 => |v| writer.print("{X}", .{@as(u16, @bitCast(v))}) catch {},
            .u32 => |v| writer.print("{X}", .{v}) catch {},
            .i32 => |v| writer.print("{X}", .{@as(u32, @bitCast(v))}) catch {},
            .f32 => |v| writer.print("{X}", .{@as(u32, @bitCast(v))}) catch {},
        }

        return stream.getWritten();
    }
};

/// Frame decoder with state for streaming data
pub const FrameDecoder = struct {
    allocator: std.mem.Allocator,
    dictionary: *const Dictionary,
    /// Internal buffer for accumulating frame data
    buffer: [MAX_FRAME_SIZE]u8 = undefined,
    buffer_len: usize = 0,
    /// State machine
    state: State = .searching,

    const State = enum {
        searching, // Looking for start byte
        reading_header, // Reading header bytes
        reading_payload, // Reading payload bytes
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, dictionary: *const Dictionary) Self {
        return .{
            .allocator = allocator,
            .dictionary = dictionary,
        };
    }

    /// Process incoming bytes and return decoded frame if complete
    /// Returns null if more data is needed
    pub fn processByte(self: *Self, byte: u8) !?DecodedFrame {
        switch (self.state) {
            .searching => {
                if (byte == START_BYTE) {
                    self.buffer[0] = byte;
                    self.buffer_len = 1;
                    self.state = .reading_header;
                }
                return null;
            },
            .reading_header => {
                self.buffer[self.buffer_len] = byte;
                self.buffer_len += 1;

                if (self.buffer_len >= HEADER_SIZE) {
                    const data_size: usize = self.buffer[1];

                    // data_size must be at least 8 (level+id overhead + timestamp)
                    if (data_size < DATA_SIZE_OVERHEAD) {
                        self.reset();
                        return null;
                    }

                    const total_size = PREAMBLE_SIZE + data_size;

                    if (total_size > MAX_FRAME_SIZE) {
                        // Frame too large, corrupted data — resync
                        self.reset();
                        return null;
                    }

                    // Validate level early to detect corrupted frames
                    if (LogLevel.fromU8(self.buffer[2]) == null) {
                        self.reset();
                        return null;
                    }

                    if (total_size <= HEADER_SIZE) {
                        // No args payload, decode now
                        return try self.decodeCurrentFrame();
                    } else {
                        self.state = .reading_payload;
                    }
                }
                return null;
            },
            .reading_payload => {
                if (self.buffer_len >= MAX_FRAME_SIZE) {
                    self.reset();
                    return null;
                }

                self.buffer[self.buffer_len] = byte;
                self.buffer_len += 1;

                const data_size: usize = self.buffer[1];
                const total_size = PREAMBLE_SIZE + data_size;

                if (self.buffer_len >= total_size) {
                    return try self.decodeCurrentFrame();
                }
                return null;
            },
        }
    }

    /// Reset the decoder state
    pub fn reset(self: *Self) void {
        self.buffer_len = 0;
        self.state = .searching;
    }

    /// Decode the current buffer contents
    fn decodeCurrentFrame(self: *Self) !?DecodedFrame {
        defer self.reset();

        if (self.buffer_len < HEADER_SIZE) {
            return null;
        }

        // Parse header
        const level_byte = self.buffer[2];
        const level = LogLevel.fromU8(level_byte) orelse return null;

        // Reconstruct message ID: low | (mid << 8) | (high << 16)
        const id_low: u32 = self.buffer[3];
        const id_mid: u32 = self.buffer[4];
        const id_high: u32 = self.buffer[5];
        const message_id = id_low | (id_mid << 8) | (id_high << 16);

        // Parse timestamp (little-endian u32)
        const timestamp = std.mem.readInt(u32, self.buffer[6..10], .little);

        // Look up message in dictionary
        const msg_def = self.dictionary.lookup(message_id) orelse {
            // Unknown message ID - return with raw ID for error reporting
            return DecodedFrame{
                .timestamp = timestamp,
                .level = level,
                .message = "",
                .raw_id = message_id,
            };
        };

        // Parse arguments if any
        const args_data = self.buffer[HEADER_SIZE..self.buffer_len];
        const message = try self.formatMessage(msg_def.fmt, msg_def.args, args_data);

        return DecodedFrame{
            .timestamp = timestamp,
            .level = level,
            .message = message,
            .raw_id = message_id,
            .file = msg_def.file,
            .line = msg_def.line,
        };
    }

    /// Parse argument types from spec string (e.g., "u8u32" -> [.u8, .u32])
    fn parseArgSpec(spec: []const u8) ![8]?ArgType {
        var types: [8]?ArgType = .{ null, null, null, null, null, null, null, null };
        var type_count: usize = 0;
        var i: usize = 0;

        while (i < spec.len and type_count < 8) {
            // Check for type prefixes
            if (i + 2 <= spec.len and std.mem.eql(u8, spec[i .. i + 2], "u8")) {
                types[type_count] = .u8;
                type_count += 1;
                i += 2;
            } else if (i + 2 <= spec.len and std.mem.eql(u8, spec[i .. i + 2], "i8")) {
                types[type_count] = .i8;
                type_count += 1;
                i += 2;
            } else if (i + 3 <= spec.len and std.mem.eql(u8, spec[i .. i + 3], "u16")) {
                types[type_count] = .u16;
                type_count += 1;
                i += 3;
            } else if (i + 3 <= spec.len and std.mem.eql(u8, spec[i .. i + 3], "i16")) {
                types[type_count] = .i16;
                type_count += 1;
                i += 3;
            } else if (i + 3 <= spec.len and std.mem.eql(u8, spec[i .. i + 3], "u32")) {
                types[type_count] = .u32;
                type_count += 1;
                i += 3;
            } else if (i + 3 <= spec.len and std.mem.eql(u8, spec[i .. i + 3], "i32")) {
                types[type_count] = .i32;
                type_count += 1;
                i += 3;
            } else if (i + 3 <= spec.len and std.mem.eql(u8, spec[i .. i + 3], "f32")) {
                types[type_count] = .f32;
                type_count += 1;
                i += 3;
            } else {
                // Skip unknown character
                i += 1;
            }
        }

        return types;
    }

    /// Read arguments from binary data based on type spec
    fn readArgs(arg_types: [8]?ArgType, data: []const u8) ![8]?DecodedArg {
        var args: [8]?DecodedArg = .{ null, null, null, null, null, null, null, null };
        var offset: usize = 0;

        for (arg_types, 0..) |maybe_type, i| {
            const arg_type = maybe_type orelse break;

            if (offset + arg_type.size() > data.len) {
                break; // Not enough data
            }

            args[i] = switch (arg_type) {
                .u8 => DecodedArg{ .u8 = data[offset] },
                .i8 => DecodedArg{ .i8 = @bitCast(data[offset]) },
                .u16 => DecodedArg{ .u16 = std.mem.readInt(u16, data[offset..][0..2], .little) },
                .i16 => DecodedArg{ .i16 = std.mem.readInt(i16, data[offset..][0..2], .little) },
                .u32 => DecodedArg{ .u32 = std.mem.readInt(u32, data[offset..][0..4], .little) },
                .i32 => DecodedArg{ .i32 = std.mem.readInt(i32, data[offset..][0..4], .little) },
                .f32 => DecodedArg{ .f32 = @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little)) },
            };

            offset += arg_type.size();
        }

        return args;
    }

    /// Format message by substituting placeholders with argument values
    fn formatMessage(self: *Self, fmt: []const u8, args_spec: []const u8, args_data: []const u8) ![]const u8 {
        // If no args, return format string directly
        if (args_spec.len == 0) {
            return fmt;
        }

        // Parse arg types and read values
        const arg_types = try parseArgSpec(args_spec);
        const args = try readArgs(arg_types, args_data);

        // Allocate buffer for formatted message
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        var arg_index: usize = 0;
        var i: usize = 0;

        while (i < fmt.len) {
            if (fmt[i] == '{' and i + 2 < fmt.len and fmt[i + 2] == '}') {
                // Found a placeholder
                const format_char = fmt[i + 1];

                if (args[arg_index]) |arg| {
                    var buf: [32]u8 = undefined;
                    const formatted = switch (format_char) {
                        'd' => arg.formatDecimal(&buf),
                        'x' => arg.formatHexLower(&buf),
                        'X' => arg.formatHexUpper(&buf),
                        else => arg.formatDecimal(&buf),
                    };
                    try result.appendSlice(self.allocator, formatted);
                    arg_index += 1;
                } else {
                    // No more args, output placeholder as-is
                    try result.appendSlice(self.allocator, fmt[i .. i + 3]);
                }
                i += 3;
            } else {
                try result.append(self.allocator, fmt[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(self.allocator);
    }
};

/// Find the start of a frame in a buffer
pub fn findFrameStart(buffer: []const u8) ?usize {
    for (buffer, 0..) |byte, i| {
        if (byte == START_BYTE) {
            return i;
        }
    }
    return null;
}

// Tests

test "LogLevel.fromU8 returns correct values" {
    try std.testing.expectEqual(LogLevel.debug, LogLevel.fromU8(0));
    try std.testing.expectEqual(LogLevel.info, LogLevel.fromU8(1));
    try std.testing.expectEqual(LogLevel.warning, LogLevel.fromU8(2));
    try std.testing.expectEqual(LogLevel.err, LogLevel.fromU8(3));
    try std.testing.expect(LogLevel.fromU8(4) == null);
}

test "parseArgSpec parses type strings" {
    const types1 = try FrameDecoder.parseArgSpec("u8");
    try std.testing.expectEqual(ArgType.u8, types1[0].?);
    try std.testing.expect(types1[1] == null);

    const types2 = try FrameDecoder.parseArgSpec("u8u32");
    try std.testing.expectEqual(ArgType.u8, types2[0].?);
    try std.testing.expectEqual(ArgType.u32, types2[1].?);
    try std.testing.expect(types2[2] == null);

    const types3 = try FrameDecoder.parseArgSpec("i16f32u8");
    try std.testing.expectEqual(ArgType.i16, types3[0].?);
    try std.testing.expectEqual(ArgType.f32, types3[1].?);
    try std.testing.expectEqual(ArgType.u8, types3[2].?);
}

test "DecodedArg.formatDecimal formats correctly" {
    var buf: [32]u8 = undefined;

    const arg_u8 = DecodedArg{ .u8 = 42 };
    try std.testing.expectEqualStrings("42", arg_u8.formatDecimal(&buf));

    const arg_i8 = DecodedArg{ .i8 = -10 };
    try std.testing.expectEqualStrings("-10", arg_i8.formatDecimal(&buf));

    const arg_u32 = DecodedArg{ .u32 = 1000 };
    try std.testing.expectEqualStrings("1000", arg_u32.formatDecimal(&buf));
}

test "DecodedArg.formatHexLower formats correctly" {
    var buf: [32]u8 = undefined;

    const arg = DecodedArg{ .u8 = 255 };
    try std.testing.expectEqualStrings("ff", arg.formatHexLower(&buf));
}

test "findFrameStart finds start byte" {
    const data1 = [_]u8{ 0x00, 0x55, 0x01 };
    try std.testing.expectEqual(@as(?usize, 1), findFrameStart(&data1));

    const data2 = [_]u8{ 0x55, 0x01, 0x02 };
    try std.testing.expectEqual(@as(?usize, 0), findFrameStart(&data2));

    const data3 = [_]u8{ 0x00, 0x01, 0x02 };
    try std.testing.expect(findFrameStart(&data3) == null);
}

test "FrameDecoder decodes simple frame" {
    const allocator = std.testing.allocator;

    // Create a simple dictionary
    const json =
        \\{
        \\  "messages": {
        \\    "331898": { "fmt": "System initialized", "args": "", "file": "main.zig", "line": 70 }
        \\  }
        \\}
    ;

    var dict = try @import("dictionary.zig").Dictionary.loadFromString(allocator, json);
    defer dict.deinit();

    var decoder = FrameDecoder.init(allocator, &dict);

    // Frame: start=0x55, data_size=8 (no args: 8+0), level=1 (INFO), id=331898 (0x05107A)
    // ID bytes: low=0x7A, mid=0x10, high=0x05
    // Timestamp: 1000 (0x000003E8)
    const frame = [_]u8{
        0x55, // start
        0x08, // data_size = 8 + 0 args
        0x01, // level (INFO)
        0x7A, // id low
        0x10, // id mid
        0x05, // id high
        0xE8, 0x03, 0x00, 0x00, // timestamp (1000, little-endian)
    };

    var result: ?DecodedFrame = null;
    for (frame) |byte| {
        result = try decoder.processByte(byte);
    }

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 1000), result.?.timestamp);
    try std.testing.expectEqual(LogLevel.info, result.?.level);
    try std.testing.expectEqualStrings("System initialized", result.?.message);
}

test "FrameDecoder decodes frame with arguments" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "messages": {
        \\    "1048476": { "fmt": "GPIO port {d} pin {d} initialized", "args": "u8u8", "file": "gpio.zig", "line": 88 }
        \\  }
        \\}
    ;

    var dict = try @import("dictionary.zig").Dictionary.loadFromString(allocator, json);
    defer dict.deinit();

    var decoder = FrameDecoder.init(allocator, &dict);

    // ID 1048476 = 0x0FFF9C -> low=0x9C, mid=0xFF, high=0x0F
    const frame = [_]u8{
        0x55, // start
        0x0A, // data_size = 8 + 2 (two u8 args)
        0x00, // level (DEBUG)
        0x9C, // id low
        0xFF, // id mid
        0x0F, // id high
        0x10, 0x27, 0x00, 0x00, // timestamp (10000, little-endian)
        0x02, // arg1: port = 2
        0x05, // arg2: pin = 5
    };

    var result: ?DecodedFrame = null;
    for (frame) |byte| {
        result = try decoder.processByte(byte);
    }

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 10000), result.?.timestamp);
    try std.testing.expectEqual(LogLevel.debug, result.?.level);
    try std.testing.expectEqualStrings("GPIO port 2 pin 5 initialized", result.?.message);

    // Free the formatted message (it was allocated)
    allocator.free(result.?.message);
}
