//! A wrapper over a byte-slice, providing useful methods for parsing string and number values.

const std = @import("std");
const StringStream = @This();

slice: []const u8,
offset: usize,

pub fn init(s: []const u8) StringStream {
    return .{ .slice = s, .offset = 0 };
}

pub fn reset(self: *StringStream) void {
    self.offset = 0;
}

pub fn len(self: StringStream) usize {
    if (self.offset > self.slice.len) {
        return 0;
    }
    return self.slice.len - self.offset;
}

pub fn hasLen(self: StringStream, n: usize) bool {
    return self.offset + n <= self.slice.len;
}

pub fn firstUnchecked(self: StringStream) u8 {
    return self.slice[self.offset];
}

pub fn first(self: StringStream) ?u8 {
    return if (self.hasLen(1))
        return self.firstUnchecked()
    else
        null;
}

pub fn isEmpty(self: StringStream) bool {
    return !self.hasLen(1);
}

pub fn firstIs(self: StringStream, comptime cs: []const u8) bool {
    if (self.first()) |ok| {
        inline for (cs) |c| if (ok == c) return true;
    }
    return false;
}
pub fn firstIsWhitespace(self: StringStream) bool {
    if (self.first()) |ok| {
        if (std.ascii.isWhitespace(ok)) return true;
    }
    return false;
}

pub fn firstIsLower(self: StringStream, comptime cs: []const u8) bool {
    if (self.first()) |ok| {
        inline for (cs) |c| if (ok | 0x20 == c) return true;
    }
    return false;
}

pub fn firstIsDigit(self: StringStream, comptime base: u8) bool {
    comptime std.debug.assert(base == 10 or base == 16);

    if (self.first()) |ok| {
        return std.common.isDigit(ok, base);
    }
    return false;
}

pub fn advance(self: *StringStream, n: usize) void {
    self.offset += n;
}

pub fn advanceToChars(self: *StringStream, comptime cs: []const u8, comptime skip_chars: bool) bool {
    while (self.len() >= cs.len) : (self.advance(1)) {
        if (std.mem.eql(u8, self.slice[self.offset .. self.offset + cs.len], cs)) {
            if (skip_chars) self.advance(cs.len);
            return true;
        }
    }
    return false;
}

pub fn skipChars(self: *StringStream, comptime cs: []const u8) void {
    while (self.firstIs(cs)) : (self.advance(1)) {}
}

pub fn skipWhitespace(self: *StringStream) void {
    while (self.firstIsWhitespace()) : (self.advance(1)) {}
}

pub fn nextWord(self: *StringStream) []const u8 {
    self.skipWhitespace();

    const start = self.offset;
    var cursor = start;
    while (cursor < self.slice.len) {
        if ((false == std.ascii.isAlphanumeric(self.slice[cursor])) and (self.slice[cursor] != '_')) {
            break;
        }
        cursor += 1;
        self.advance(1);
    }
    return self.slice[start..cursor];
}

pub fn readU64Unchecked(self: StringStream) u64 {
    return std.mem.readInt(u64, self.slice[self.offset..][0..8], .little);
}

pub fn readU64(self: StringStream) ?u64 {
    if (self.hasLen(8)) {
        return self.readU64Unchecked();
    }
    return null;
}

pub fn atUnchecked(self: *StringStream, i: usize) u8 {
    return self.slice[self.offset + i];
}

pub fn scanDigit(self: *StringStream, comptime base: u8) ?u8 {
    comptime std.debug.assert(base == 10 or base == 16);

    while (true) {
        if (self.first()) |ok| {
            if ('0' <= ok and ok <= '9') {
                self.advance(1);
                return ok - '0';
            } else if (base == 16 and 'a' <= ok and ok <= 'f') {
                self.advance(1);
                return ok - 'a' + 10;
            } else if (base == 16 and 'A' <= ok and ok <= 'F') {
                self.advance(1);
                return ok - 'A' + 10;
            }
        }
        return null;
    }
}

test "StringStream" {
    const content =
        \\
        \\MEMORY
        \\{
        \\     FLASH (rx)                 : ORIGIN = 0x08000000, LENGTH = 512K
        \\     RAM1 (xrw)                 : ORIGIN = 0x20000008, LENGTH = 0xFFF8
        \\     RAM_SHARED (xrw)           : ORIGIN = 0x20030000, LENGTH = 10K
        \\ }
    ;

    var stream = StringStream.init(content);

    try std.testing.expectEqual(220, stream.len());
    try std.testing.expectEqualStrings("MEMORY", stream.nextWord());
    stream.skipWhitespace();
    try std.testing.expectEqual('{', stream.first());
    try std.testing.expect(true == stream.advanceToChars(":", false));
    try std.testing.expectEqual(':', stream.first());
    stream.advance(1);
    try std.testing.expectEqualStrings("ORIGIN", stream.nextWord());
    try std.testing.expect(false == stream.advanceToChars("!", false));
}
