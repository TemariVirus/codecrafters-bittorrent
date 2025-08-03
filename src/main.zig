const std = @import("std");
const assert = std.debug.assert;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

var stdout: *Writer = undefined;

pub fn main() !void {
    // Use empty buffer to always flush immediately
    var stdout_file = std.fs.File.stdout().writer(&.{});
    stdout = &stdout_file.interface;
    const allocator = std.heap.smp_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) @panic("Usage: your_program.sh <command> <args>");

    const command = args[1];

    if (std.mem.eql(u8, command, "decode")) {
        const encoded = args[2];
        const decoded = Bencode.decodeSlice(allocator, encoded) catch @panic("Invalid encoded value");
        defer decoded.deinit();
        switch (decoded.value) {
            .string => |s| try stdout.print("{f}\n", .{std.json.fmt(s, .{})}),
            .integer => |i| try stdout.print("{f}\n", .{std.json.fmt(i, .{})}),
            .list => |l| try stdout.print("{f}\n", .{std.json.fmt(l, .{})}),
        }
    }
}

const Bencode = union(enum) {
    string: []const u8,
    integer: i64,
    list: []const Bencode,

    pub const Decoded = struct {
        arena: std.heap.ArenaAllocator,
        value: Bencode,

        pub fn deinit(self: Decoded) void {
            self.arena.deinit();
        }
    };

    pub const DecodeOptions = struct {
        allocate_strings: bool = true,
    };

    pub const DecodeError = std.mem.Allocator.Error || Reader.Error || error{InvalidArgument};

    pub fn decode(allocator: std.mem.Allocator, encoded: *Reader, options: DecodeOptions) DecodeError!Decoded {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        return .{
            .arena = arena,
            .value = try decodeInner(arena.allocator(), encoded, options),
        };
    }

    fn decodeInner(allocator: std.mem.Allocator, encoded: *Reader, options: DecodeOptions) DecodeError!Bencode {
        return switch (try encoded.peekByte()) {
            '0'...'9' => try decodeString(if (options.allocate_strings) allocator else null, encoded),
            'i' => try decodeInteger(encoded),
            'l' => try decodeList(allocator, encoded, options),
            else => error.InvalidArgument,
        };
    }

    pub fn decodeSlice(allocator: std.mem.Allocator, encoded: []const u8) DecodeError!Decoded {
        var reader: Reader = .fixed(encoded);
        return decode(allocator, &reader, .{ .allocate_strings = false });
    }

    fn decodeString(allocator: ?std.mem.Allocator, encoded: *Reader) DecodeError!Bencode {
        const len = blk: {
            // On 128-bit systems (do those exist?) the largest usize has 39 digits
            var buf: [39]u8 = undefined;
            var writer = Writer.fixed(&buf);
            _ = encoded.streamDelimiter(&writer, ':') catch |err| switch (err) {
                // Too long
                error.WriteFailed,
                // No ':' found
                error.EndOfStream,
                => return error.InvalidArgument,
                else => |e| return e,
            };
            _ = encoded.takeByte() catch unreachable; // Discard the ':'
            break :blk std.fmt.parseInt(usize, writer.buffered(), 10) catch return error.InvalidArgument;
        };

        return .{
            .string = if (allocator) |alloc|
                try encoded.readAlloc(alloc, len)
            else
                try encoded.take(len),
        };
    }

    fn decodeInteger(encoded: *Reader) DecodeError!Bencode {
        assert(try encoded.takeByte() == 'i');

        // Largest i64 has 20 digits
        var buf: [20]u8 = undefined;
        var writer = Writer.fixed(&buf);
        _ = encoded.streamDelimiter(&writer, 'e') catch |err| switch (err) {
            // Too long
            error.WriteFailed,
            // No 'e' found
            error.EndOfStream,
            => return error.InvalidArgument,
            else => |e| return e,
        };
        _ = encoded.takeByte() catch unreachable; // Discard the 'e'

        const value = std.fmt.parseInt(i64, writer.buffered(), 10) catch return error.InvalidArgument;
        return .{ .integer = value };
    }

    fn decodeList(allocator: std.mem.Allocator, encoded: *Reader, options: DecodeOptions) DecodeError!Bencode {
        _ = allocator;
        _ = encoded;
        _ = options;
        @panic("TODO");
    }
};
