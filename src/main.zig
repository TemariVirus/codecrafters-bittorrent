const std = @import("std");
const Allocator = std.mem.Allocator;
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
        try stdout.print("{f}\n", .{std.json.fmt(decoded.value, .{})});
    }
}

const Bencode = union(enum) {
    str: []const u8,
    int: i64,
    list: []const Bencode,
    dict: std.StringHashMapUnmanaged(Bencode),

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

    pub const DecodeError = Allocator.Error || Reader.Error || error{InvalidArgument};

    pub fn decode(allocator: Allocator, encoded: *Reader, options: DecodeOptions) DecodeError!Decoded {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        return .{
            .arena = arena,
            .value = try decodeInner(arena.allocator(), encoded, options),
        };
    }

    fn decodeInner(allocator: Allocator, encoded: *Reader, options: DecodeOptions) DecodeError!Bencode {
        return switch (try encoded.peekByte()) {
            '0'...'9' => .{ .str = try decodeStr(if (options.allocate_strings) allocator else null, encoded) },
            'i' => .{ .int = try decodeInt(encoded) },
            'l' => .{ .list = try decodeList(allocator, encoded, options) },
            'd' => .{ .dict = try decodeDict(allocator, encoded, options) },
            else => error.InvalidArgument,
        };
    }

    pub fn decodeSlice(allocator: Allocator, encoded: []const u8) DecodeError!Decoded {
        var reader: Reader = .fixed(encoded);
        return decode(allocator, &reader, .{ .allocate_strings = false });
    }

    fn decodeStr(allocator: ?Allocator, encoded: *Reader) DecodeError![]const u8 {
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

        return if (allocator) |alloc|
            try encoded.readAlloc(alloc, len)
        else
            try encoded.take(len);
    }

    fn decodeInt(encoded: *Reader) DecodeError!i64 {
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

        return std.fmt.parseInt(i64, writer.buffered(), 10) catch return error.InvalidArgument;
    }

    fn decodeList(
        allocator: Allocator,
        encoded: *Reader,
        options: DecodeOptions,
    ) DecodeError![]const Bencode {
        assert(try encoded.takeByte() == 'l');

        // No need to perform cleanup as `allocator` is an arena
        var list: std.ArrayList(Bencode) = .init(allocator);
        while (true) {
            if (try encoded.peekByte() == 'e') {
                _ = encoded.takeByte() catch unreachable; // Discard the 'e'
                return try list.toOwnedSlice();
            }
            try list.append(try decodeInner(allocator, encoded, options));
        }
    }

    fn decodeDict(
        allocator: Allocator,
        encoded: *Reader,
        options: DecodeOptions,
    ) DecodeError!std.StringHashMapUnmanaged(Bencode) {
        assert(try encoded.takeByte() == 'd');

        // No need to perform cleanup as `allocator` is an arena
        var dict: std.StringHashMap(Bencode) = .init(allocator);
        while (true) {
            if (try encoded.peekByte() == 'e') {
                _ = encoded.takeByte() catch unreachable; // Discard the 'e'
                return dict.unmanaged;
            }
            const key = try decodeStr(if (options.allocate_strings) allocator else null, encoded);
            const value = try decodeInner(allocator, encoded, options);
            try dict.put(key, value);
        }
    }

    pub fn jsonStringify(self: Bencode, json: *std.json.Stringify) std.json.Stringify.Error!void {
        switch (self) {
            .str => |s| try json.write(s),
            .int => |i| try json.write(i),
            .list => |l| {
                try json.beginArray();
                for (l) |item| {
                    try json.write(item);
                }
                try json.endArray();
            },
            .dict => |d| {
                try json.beginObject();
                var it = d.iterator();
                while (it.next()) |entry| {
                    try json.objectField(entry.key_ptr.*);
                    try json.write(entry.value_ptr.*);
                }
                try json.endObject();
            },
        }
    }
};
