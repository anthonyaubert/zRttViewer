# zRttViewer

A real-time RTT (Real-Time Transfer) log viewer for embedded systems using SEGGER J-Link. It decodes binary deferred log frames from a SEGGER RTT channel into human-readable, color-coded terminal output.

## How it works

### Deferred logging

Instead of formatting log strings on the embedded target (which is slow and blocks execution), the firmware sends compact binary frames over RTT. Each frame contains only a numeric message ID, a log level, a timestamp, and optional raw argument values. The host-side viewer (this tool) reconstructs the full log message using a **dictionary** that maps IDs to format strings.

### Binary frame format

Each frame sent over RTT channel 0 has the following layout (little-endian):

```
+-------+----------+-------+--------+------------+-----------+
| Start | DataSize | Level |   ID   | Timestamp  |   Args    |
| 1B    | 1B       | 1B    | 3B     | 4B         | 0..N B    |
+-------+----------+-------+--------+------------+-----------+
```

| Field      | Size    | Description                                         |
|------------|---------|-----------------------------------------------------|
| Start      | 1 byte  | Sync byte, always `0x55`                            |
| DataSize   | 1 byte  | Number of bytes following (Level + ID + Timestamp + Args) |
| Level      | 1 byte  | Log level: 0=DEBUG, 1=INFO, 2=WARNING, 3=ERROR     |
| ID         | 3 bytes | Message ID (little-endian, matches dictionary key)  |
| Timestamp  | 4 bytes | Tick counter from the target (little-endian u32)    |
| Args       | 0..N    | Packed argument values (little-endian)              |

Supported argument types: `u8`, `i8`, `u16`, `i16`, `u32`, `i32`, `f32`.

### Dictionary format

The dictionary is a JSON file generated alongside the firmware. It maps each message ID to its format string, argument types, and source location:

```json
{
  "messages": {
    "331898": { "fmt": "System initialized",                    "args": "",     "file": "main.zig",  "line": 70 },
    "1016184": { "fmt": "Warm reset (count={d})",               "args": "u32",  "file": "reset.zig", "line": 12 },
    "1048476": { "fmt": "GPIO port {d} pin {d} initialized",   "args": "u8u8", "file": "gpio.zig",  "line": 88 }
  }
}
```

Format placeholders: `{d}` (decimal), `{x}` (hex lowercase), `{X}` (hex uppercase).

### Output

Log lines are printed with ANSI colors, aligned columns, and the source location:

```
     1000 [INFO ] main.zig:70  :System initialized
    10000 [DEBUG] gpio.zig:88  :GPIO port 2 pin 5 initialized
    15000 [WARN ] reset.zig:12 :Warm reset (count=3)
```

## Usage

```
zRttViewer [dictionary.json] [options]
```

### Options

| Option              | Description                                     |
|---------------------|-------------------------------------------------|
| `--file <path>`     | Read from a binary log file instead of live RTT |
| `--raw`             | Raw text mode: display RTT data as-is (no decoding) |
| `--help`            | Show help                                       |

### Examples

```bash
# Live mode: spawns JLinkRTTLogger and decodes the stream
zRttViewer log_dictionary.json

# Decode a previously captured binary log file
zRttViewer log_dictionary.json --file rtt.bin

# Reuse the last dictionary (saved in zrtt_viewer_cfg.ini)
zRttViewer

# Raw text mode (no decoding, useful for plain-text RTT output)
zRttViewer --raw
```

The dictionary path is remembered across runs in `zrtt_viewer_cfg.ini` next to the executable.

## Building

Requires [Zig](https://ziglang.org/) 0.15+.

```bash
zig build            # build
zig build run        # build and run
zig build test       # run tests
```

## Requirements

- **SEGGER J-Link** with `JLinkRTTLogger` available in `PATH` (for live mode)
- A firmware that sends deferred log frames over RTT channel 0
- A matching dictionary JSON file
