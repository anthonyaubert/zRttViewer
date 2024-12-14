const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var defmt_file: []const u8 = undefined;

    if (args.len != 2) {
        //        std.log.warn("Single arg is expected", .{});
        //std.process.exit(1);
        //TODO
        defmt_file = "/Users/anthony/dev/ziglang/zig_on_stm32wb50/src/cfg/logging_defmt_cfg.zig";
    } else {
        defmt_file = args[1];
    }

    // TODO loadDefmtConfigFile(defmt_file);

    std.debug.print(" ------------------------------------------------------------ \n", .{});
    std.debug.print("| Launch JLinkRTTLogger...                                   |\n", .{});
    std.debug.print(" ------------------------------------------------------------ \n\n", .{});

    const log_file_path = "/Users/anthony/dev/rtt_temp/rtt.log";

    //OK const argv = [_][]const u8{ "JLinkRTTLogger", "-device", "STM32WB55RG", "-if", "swd", "-speed", "4000", "-RTTSearchRanges", "0x20000000 0x0000", "-RTTChannel", "0" };
    const argv = [_][]const u8{ "JLinkRTTLogger", "-device", "STM32WB55RG", "-if", "swd", "-speed", "4000", "-RTTChannel", "0", log_file_path };
    //JLinkRTTLogger -device STM32WB55RG -if swd -speed 4000 -RTTChannel 0

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    // const max_output_size = 400 * 1024;
    // const stdout = child.stdout.?.reader().readAllAlloc(allocator, max_output_size) catch {
    //     return error.ReadFailure;
    // };
    // errdefer allocator.free(stdout);
    var array_list = std.ArrayList(u8).init(allocator);
    defer array_list.deinit();

    var skipTansferRate = false;
    var loggerInitOk = false;
    var loggerFile = try std.fs.openFileAbsolute(log_file_path, .{ .mode = .read_only });
    defer loggerFile.close();

    var buffered_file = std.io.bufferedReader(loggerFile.reader());

    var byte_read: [1]u8 = undefined;

    if (child.stdout) |stdout| {
        var stdout_stream = stdout.reader();
        while (true) {
            if (stdout_stream.readByte()) |byte| {

                // Skip "\rTransfer rate: 0 Bytes/s Data written: 0 Bytes "
                if (byte == '\r') {

                    // If we receive transfer rate info => init is ok
                    loggerInitOk = true;

                    skipTansferRate = true;
                }

                if (skipTansferRate == true) {
                    try array_list.append(byte);
                    const len = array_list.items.len;

                    // We received the last
                    if (len >= 6 and std.mem.eql(u8, array_list.items[len - 6 .. len], "Bytes ")) {
                        skipTansferRate = false;
                        array_list.clearAndFree();
                    }
                } else {

                    // It's not a text to skip => print each caracter in the console
                    std.debug.print("{c}", .{byte});
                }

                // It's not necesserary to launch an another process
                // Just read the new data in rtt.log file
                if (loggerInitOk) {
                    while (true) {
                        const number_of_read_bytes = try buffered_file.read(&byte_read);

                        if (number_of_read_bytes == 0) {
                            break; // No more data
                        }

                        // Buffer now has some of the file bytes, do something with it here...
                        std.debug.print("{c}", .{byte_read[0]});

                        //TODO decode deferred log
                    }
                }
            } else |_| {
                break;
            }
        }
        // while (try stdout_stream.readUntilDelimiterOrEofAlloc(allocator, '\n', 4096 * 1000)) |line| {
        //     std.debug.print("tutu:{s}\n", .{line});
        // }
    }

    const exit_status = try child.wait();

    std.debug.print("Exit status: {d}\n", .{exit_status.Exited});
}

// fn loadDefmtConfigFile(cfg_file: []const u8 ) void
// {
//     // Try to load the logging_defmt_cfg.zig which contain the deffered log Id
//     const file = try std.fs.cwd().openFile(defmt_file, .{});
//     defer file.close();

//     var buffered = std.io.bufferedReader(file.reader());
//     var reader = buffered.reader();

//     // lines will get read into this
//     var arr = std.ArrayList(u8).init(allocator);
//     defer arr.deinit();

//     var line_count: usize = 0;
//     var byte_count: usize = 0;
//     while (true) {
//         reader.streamUntilDelimiter(arr.writer(), '\n', null) catch |err| switch (err) {
//         error.EndOfStream => break,
//         else => return err,
//         };
//         line_count += 1;
//         byte_count += arr.items.len;
//         arr.clearRetainingCapacity();
//     }
// }
