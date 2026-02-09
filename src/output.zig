//! ANSI color output formatting for log messages.

const std = @import("std");
const decoder = @import("decoder.zig");

/// ANSI color escape codes
pub const Colors = struct {
    pub const debug: []const u8 = "\x1b[36m"; // Cyan
    pub const info: []const u8 = "\x1b[32m"; // Green
    pub const warning: []const u8 = "\x1b[33m"; // Yellow
    pub const err: []const u8 = "\x1b[31m"; // Red
    pub const gray: []const u8 = "\x1b[90m"; // Gray (timestamp)
    pub const reset: []const u8 = "\x1b[0m";
};

/// Get the color code for a log level
pub fn getLogLevelColor(level: decoder.LogLevel) []const u8 {
    return switch (level) {
        .debug => Colors.debug,
        .info => Colors.info,
        .warning => Colors.warning,
        .err => Colors.err,
    };
}

/// Get the display string for a log level (padded to 5 chars)
pub fn getLogLevelString(level: decoder.LogLevel) []const u8 {
    return switch (level) {
        .debug => "DEBUG",
        .info => "INFO ",
        .warning => "WARN ",
        .err => "ERROR",
    };
}

/// Format and print a decoded frame with colors
/// Output format: "     1234 [INFO ] file:line  :message"
pub fn formatOutput(decoded: decoder.DecodedFrame, max_loc_len: usize) void {
    const level_color = getLogLevelColor(decoded.level);
    const level_str = getLogLevelString(decoded.level);

    // Format file:line into a buffer
    var loc_buf: [256]u8 = undefined;
    var loc_stream = std.io.fixedBufferStream(&loc_buf);
    loc_stream.writer().print("{s}:{d}", .{ decoded.file, decoded.line }) catch {};
    const loc = loc_stream.getWritten();

    // Compute padding to align messages
    const pad_len = if (max_loc_len > loc.len) max_loc_len - loc.len else 0;

    // Timestamp (gray) + [LEVEL] + file:line (gray, padded) + :message
    std.debug.print("{s}{d:>9}{s} [{s}{s}{s}] {s}{s}", .{
        Colors.gray,
        decoded.timestamp,
        Colors.reset,
        level_color,
        level_str,
        Colors.reset,
        Colors.gray,
        loc,
    });

    // Padding spaces (still gray)
    var i: usize = 0;
    while (i < pad_len) : (i += 1) {
        std.debug.print(" ", .{});
    }

    std.debug.print("{s}:{s}{s}{s}\n", .{ Colors.reset, level_color, decoded.message, Colors.reset });
}

/// Print an error message for unknown message ID
pub fn printUnknownId(id: u32, timestamp: u32, level: decoder.LogLevel) void {
    const level_color = getLogLevelColor(level);
    const level_str = getLogLevelString(level);

    std.debug.print("{s}{d:>9}{s} [{s}{s}{s}] {s}<unknown message ID: {d}>{s}\n", .{
        Colors.gray,
        timestamp,
        Colors.reset,
        level_color,
        level_str,
        Colors.reset,
        Colors.err,
        id,
        Colors.reset,
    });
}

/// Print an error message for malformed frame
pub fn printMalformedFrame(reason: []const u8) void {
    std.debug.print("{s}[ERROR] Malformed frame: {s}{s}\n", .{
        Colors.err,
        reason,
        Colors.reset,
    });
}

test "getLogLevelString returns correct strings" {
    try std.testing.expectEqualStrings("DEBUG", getLogLevelString(.debug));
    try std.testing.expectEqualStrings("INFO ", getLogLevelString(.info));
    try std.testing.expectEqualStrings("WARN ", getLogLevelString(.warning));
    try std.testing.expectEqualStrings("ERROR", getLogLevelString(.err));
}

test "getLogLevelColor returns correct colors" {
    try std.testing.expectEqualStrings(Colors.debug, getLogLevelColor(.debug));
    try std.testing.expectEqualStrings(Colors.info, getLogLevelColor(.info));
    try std.testing.expectEqualStrings(Colors.warning, getLogLevelColor(.warning));
    try std.testing.expectEqualStrings(Colors.err, getLogLevelColor(.err));
}
