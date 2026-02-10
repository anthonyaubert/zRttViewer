const std = @import("std");
const Dictionary = @import("dictionary.zig").Dictionary;
const decoder = @import("decoder.zig");
const FrameDecoder = decoder.FrameDecoder;
const DecodedFrame = decoder.DecodedFrame;
const output = @import("output.zig");

const cfg_file = "zrtt_viewer_cfg.ini";

const usage =
    \\Usage: zRttViewer [dictionary.json] [options]
    \\       zRttViewer [dictionary.json] --file <binary_log_file>
    \\
    \\Options:
    \\  --file <path>   Read from binary log file instead of JLinkRTTLogger
    \\  --raw           Raw text mode: display RTT data as text (no decoding)
    \\  --help          Show this help message
    \\
    \\If no dictionary is specified, the last used dictionary is loaded
    \\automatically (saved in zrtt_viewer_cfg.ini).
    \\
    \\Examples:
    \\  zRttViewer log_dictionary.json              # Live mode with JLinkRTTLogger
    \\  zRttViewer log_dictionary.json --file rtt.bin  # Decode from file
    \\  zRttViewer                                     # Reuse last dictionary
    \\  zRttViewer --raw                               # Raw text mode (no decoding)
    \\
;

const Config = struct {
    dictionary_path: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    show_help: bool = false,
    raw_mode: bool = false,
};

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};

    var i: usize = 1; // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            config.show_help = true;
            return config;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            config.raw_mode = true;
        } else if (std.mem.eql(u8, arg, "--file")) {
            if (i + 1 >= args.len) {
                return error.MissingFileArgument;
            }
            i += 1;
            config.file_path = args[i];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (config.dictionary_path == null) {
                config.dictionary_path = arg;
            } else {
                return error.UnexpectedArgument;
            }
        } else {
            return error.UnknownOption;
        }
    }

    return config;
}

/// Get the directory containing the executable
fn getExeDir(buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    const exe_path = std.fs.selfExePath(buf) catch return null;
    return std.fs.path.dirname(exe_path);
}

/// Build full path to config file next to the executable
fn getCfgPath(allocator: std.mem.Allocator) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = getExeDir(&buf) orelse return null;
    return std.fs.path.join(allocator, &.{ dir, cfg_file }) catch null;
}

/// Save dictionary path to config file for future reuse
fn saveLastDictionary(allocator: std.mem.Allocator, path: []const u8) void {
    const full_path = getCfgPath(allocator) orelse return;
    defer allocator.free(full_path);
    const file = std.fs.createFileAbsolute(full_path, .{}) catch return;
    defer file.close();
    file.writeAll(path) catch return;
}

/// Load last used dictionary path from config file
fn loadLastDictionary(allocator: std.mem.Allocator) ?[]const u8 {
    const full_path = getCfgPath(allocator) orelse return null;
    defer allocator.free(full_path);
    const file = std.fs.openFileAbsolute(full_path, .{}) catch return null;
    defer file.close();
    const content = file.readToEndAlloc(allocator, 4096) catch return null;
    // Trim trailing whitespace/newlines
    const trimmed = std.mem.trimRight(u8, content, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(content);
        return null;
    }
    if (trimmed.len == content.len) return content;
    // Shrink allocation to trimmed size
    allocator.free(content);
    return allocator.dupe(u8, trimmed) catch null;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = parseArgs(args) catch |err| {
        std.debug.print("{s}", .{usage});
        std.debug.print("\nError: {}\n", .{err});
        std.process.exit(1);
    };

    if (config.show_help) {
        std.debug.print("{s}", .{usage});
        return;
    }

    if (config.raw_mode) {
        std.debug.print("Raw text mode (no decoding)\n", .{});
        if (config.file_path) |file_path| {
            try runFileModeRaw(file_path);
        } else {
            try runLiveMode(allocator, null);
        }
        return;
    }

    // Resolve dictionary path: from argument or from last saved config
    const dict_path = config.dictionary_path orelse loadLastDictionary(allocator) orelse {
        std.debug.print("{s}", .{usage});
        std.debug.print("\nError: No dictionary specified and no previous dictionary found.\n", .{});
        std.debug.print("Run once with a dictionary path to save it for future use.\n", .{});
        std.process.exit(1);
    };

    // Load dictionary
    var dictionary = Dictionary.load(allocator, dict_path) catch |err| {
        std.debug.print("Error loading dictionary '{s}': {}\n", .{ dict_path, err });
        std.process.exit(1);
    };
    defer dictionary.deinit();

    // Save the dictionary path for future reuse
    saveLastDictionary(allocator, dict_path);

    std.debug.print("Loaded dictionary from: {s}\n", .{dict_path});

    // Initialize frame decoder
    var frame_decoder = FrameDecoder.init(allocator, &dictionary);

    if (config.file_path) |file_path| {
        // File mode: Read from binary log file
        try runFileMode(allocator, &frame_decoder, file_path);
    } else {
        // Live mode: Spawn JLinkRTTLogger and decode stream
        try runLiveMode(allocator, &frame_decoder);
    }
}

fn handleDecodedFrame(allocator: std.mem.Allocator, frame_decoder: *FrameDecoder, frame: DecodedFrame) void {
    if (frame.message.len == 0) {
        output.printUnknownId(frame.raw_id, frame.timestamp, frame.level);
    } else {
        output.formatOutput(frame, frame_decoder.dictionary.max_location_len);
        const dict_msg = frame_decoder.dictionary.lookup(frame.raw_id);
        if (dict_msg) |msg| {
            if (frame.message.ptr != msg.fmt.ptr) {
                allocator.free(frame.message);
            }
        }
    }
}

fn runFileMode(allocator: std.mem.Allocator, frame_decoder: *FrameDecoder, file_path: []const u8) !void {
    std.debug.print("Reading from file: {s}\n\n", .{file_path});

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("Error opening file '{s}': {}\n", .{ file_path, err });
        std.process.exit(1);
    };
    defer file.close();

    var byte_buf: [1]u8 = undefined;

    while (true) {
        const bytes_read = file.read(&byte_buf) catch |err| {
            std.debug.print("Read error: {}\n", .{err});
            break;
        };

        if (bytes_read == 0) break; // EOF

        if (try frame_decoder.processByte(byte_buf[0])) |frame| {
            handleDecodedFrame(allocator, frame_decoder, frame);
        }
    }

    std.debug.print("\nEnd of file.\n", .{});
}

fn drainLogFile(allocator: std.mem.Allocator, loggerFile: std.fs.File, frame_decoder: *FrameDecoder) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = loggerFile.read(&buf) catch break;
        if (n == 0) break;

        for (buf[0..n]) |byte| {
            if (try frame_decoder.processByte(byte)) |frame| {
                handleDecodedFrame(allocator, frame_decoder, frame);
            }
        }
    }
}

fn runLiveMode(allocator: std.mem.Allocator, frame_decoder: ?*FrameDecoder) !void {
    const banner = if (frame_decoder != null)
        "| Launch JLinkRTTLogger...                                   |"
    else
        "| Launch JLinkRTTLogger (raw text mode)...                    |";

    std.debug.print(" ------------------------------------------------------------ \n", .{});
    std.debug.print("{s}\n", .{banner});
    std.debug.print(" ------------------------------------------------------------ \n\n", .{});

    const log_file_path = "/tmp/zRttViewer_rtt.log";

    // Create or truncate the log file
    {
        const f = try std.fs.createFileAbsolute(log_file_path, .{ .truncate = true });
        f.close();
    }

    const argv = [_][]const u8{
        "JLinkRTTLogger",
        "-device",
        "STM32WB55RG",
        "-if",
        "swd",
        "-speed",
        "4000",
        "-RTTChannel",
        "0",
        log_file_path,
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    var array_list = std.ArrayListUnmanaged(u8){};
    defer array_list.deinit(allocator);

    var skipTransferRate = false;
    var loggerInitOk = false;
    const loggerFile = try std.fs.openFileAbsolute(log_file_path, .{ .mode = .read_only });
    defer loggerFile.close();

    if (child.stdout) |stdout| {
        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = stdout.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };

        while (true) {
            poll_fds[0].revents = 0;
            const poll_result = std.posix.poll(&poll_fds, 10) catch 0;

            if (poll_result > 0) {
                // Check for hangup (process exited)
                if (poll_fds[0].revents & std.posix.POLL.HUP != 0) {
                    if (loggerInitOk) {
                        if (frame_decoder) |fd| {
                            try drainLogFile(allocator, loggerFile, fd);
                        } else {
                            drainLogFileRaw(loggerFile);
                        }
                    }
                    break;
                }

                // Read available stdout data
                if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                    var stdout_buf: [256]u8 = undefined;
                    const n = stdout.read(&stdout_buf) catch break;
                    if (n == 0) break;

                    for (stdout_buf[0..n]) |byte| {
                        // Skip "\rTransfer rate: 0 Bytes/s Data written: 0 Bytes "
                        if (byte == '\r') {
                            loggerInitOk = true;
                            skipTransferRate = true;
                        }

                        if (skipTransferRate) {
                            try array_list.append(allocator, byte);
                            const len = array_list.items.len;

                            if (len >= 6 and std.mem.eql(u8, array_list.items[len - 6 .. len], "Bytes ")) {
                                skipTransferRate = false;
                                array_list.clearAndFree(allocator);
                            }
                        } else {
                            std.debug.print("{c}", .{byte});
                        }
                    }
                }
            }

            // Read log file data on every iteration (data available or timeout)
            if (loggerInitOk) {
                if (frame_decoder) |fd| {
                    try drainLogFile(allocator, loggerFile, fd);
                } else {
                    drainLogFileRaw(loggerFile);
                }
            }
        }
    }

    const exit_status = try child.wait();
    std.debug.print("JLinkRTTLogger exit status: {d}\n", .{exit_status.Exited});
}

fn drainLogFileRaw(loggerFile: std.fs.File) void {
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = loggerFile.read(&buf) catch break;
        if (n == 0) break;
        stdout.writeAll(buf[0..n]) catch break;
    }
}

fn runFileModeRaw(file_path: []const u8) !void {
    std.debug.print("Reading raw from file: {s}\n\n", .{file_path});

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("Error opening file '{s}': {}\n", .{ file_path, err });
        std.process.exit(1);
    };
    defer file.close();

    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = file.read(&buf) catch |err| {
            std.debug.print("Read error: {}\n", .{err});
            break;
        };
        if (n == 0) break;
        stdout.writeAll(buf[0..n]) catch break;
    }

    std.debug.print("\nEnd of file.\n", .{});
}

