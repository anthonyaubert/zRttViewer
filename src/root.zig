const std = @import("std");

// Public API exports
pub const dictionary = @import("dictionary.zig");
pub const decoder = @import("decoder.zig");
pub const output = @import("output.zig");
pub const string_stream = @import("string_stream.zig");

// Re-export commonly used types
pub const Dictionary = dictionary.Dictionary;
pub const MessageDef = dictionary.MessageDef;
pub const FrameDecoder = decoder.FrameDecoder;
pub const DecodedFrame = decoder.DecodedFrame;
pub const LogLevel = decoder.LogLevel;

test {
    // Run tests from all modules
    std.testing.refAllDecls(@This());
}
