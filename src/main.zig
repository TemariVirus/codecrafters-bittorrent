const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

var null_writer: Writer = .{
    .buffer = &.{},
    .vtable = &.{
        .drain = (struct {
            fn drain(_: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
                var written: usize = data[data.len - 1].len * splat;
                for (data[0 .. data.len - 1]) |bytes| {
                    written += bytes.len;
                }
                return written;
            }
        }).drain,
    },
};

pub fn main() !void {
    // Use empty buffer to always flush immediately
    var stdout_file = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_file.interface;
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
    } else if (std.mem.eql(u8, command, "info")) {
        const metainfo_file = args[2];
        var file_buf: [4096]u8 = undefined;
        const f = try std.fs.cwd().openFile(metainfo_file, .{});
        defer f.close();
        var reader = f.reader(&file_buf);

        const decoded = Bencode.decode(allocator, &reader.interface, .{}) catch @panic("Invalid encoded value");
        defer decoded.deinit();

        const metainfo = decoded.value.dict;
        const info = metainfo.get("info").?.dict;
        try stdout.print("Tracker URL: {s}\n", .{metainfo.get("announce").?.str});
        try stdout.print("Length: {d}\n", .{info.get("length").?.int});

        const Hash = std.crypto.hash.Sha1;
        const hash = blk: {
            var writer = null_writer.hashed(Hash.init(.{}), &.{});
            try writer.writer.print("{f}", .{Bencode{ .dict = info }});
            break :blk writer.hasher.finalResult();
        };
        try stdout.print("Info Hash: {s}\n", .{std.fmt.bytesToHex(hash, .lower)});

        const piece_len = info.get("piece length").?.int;
        try stdout.print("Piece Length: {d}\n", .{piece_len});

        try stdout.print("Piece Hashes:\n", .{});
        var piece_hashes = std.mem.window(
            u8,
            info.get("pieces").?.str,
            Hash.digest_length,
            Hash.digest_length,
        );
        while (piece_hashes.next()) |piece_hash| {
            try stdout.print("{s}\n", .{
                std.fmt.bytesToHex(piece_hash[0..Hash.digest_length].*, .lower),
            });
        }
    } else @panic("Unknown command");
}

const Bencode = union(enum) {
    str: []const u8,
    int: i64,
    list: []const Bencode,
    dict: Dict,

    pub const Dict = struct {
        /// Stored in ascending order by `key`
        entires: []const Entry,

        pub const Entry = struct {
            key: []const u8,
            value: Bencode,
        };

        pub fn fromSlice(entries: []Entry) Dict {
            std.sort.pdq(Entry, entries, {}, (struct {
                fn lt(_: void, lhs: Entry, rhs: Entry) bool {
                    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
                }
            }).lt);
            return .{ .entires = entries };
        }

        pub fn get(self: Dict, key: []const u8) ?Bencode {
            var left: usize = 0;
            var right: usize = self.entires.len - 1;
            while (left <= right) {
                const mid = left + (right - left) / 2;
                switch (std.mem.order(u8, self.entires[mid].key, key)) {
                    .lt => left = mid + 1,
                    .eq => return self.entires[mid].value,
                    .gt => right = mid - 1,
                }
            }
            return null;
        }
    };

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
    ) DecodeError!Dict {
        assert(try encoded.takeByte() == 'd');

        // No need to perform cleanup as `allocator` is an arena
        var entries: std.ArrayList(Dict.Entry) = .init(allocator);
        while (true) {
            if (try encoded.peekByte() == 'e') {
                _ = encoded.takeByte() catch unreachable; // Discard the 'e'
                return .fromSlice(try entries.toOwnedSlice());
            }
            const key = try decodeStr(if (options.allocate_strings) allocator else null, encoded);
            const value = try decodeInner(allocator, encoded, options);
            try entries.append(.{ .key = key, .value = value });
        }
    }

    pub fn encode(self: Bencode, writer: *Writer) Writer.Error!void {
        switch (self) {
            .str => |s| try writer.print("{d}:{s}", .{ s.len, s }),
            .int => |i| try writer.print("i{d}e", .{i}),
            .list => |l| {
                try writer.writeByte('l');
                for (l) |item| {
                    try item.encode(writer);
                }
                try writer.writeByte('e');
            },
            .dict => |d| {
                try writer.writeByte('d');
                for (d.entires) |entry| {
                    try writer.print("{d}:{s}", .{ entry.key.len, entry.key });
                    try entry.value.encode(writer);
                }
                try writer.writeByte('e');
            },
        }
    }

    pub fn format(self: Bencode, writer: *Writer) Writer.Error!void {
        return self.encode(writer);
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
                for (d.entires) |entry| {
                    try json.objectField(entry.key);
                    try json.write(entry.value);
                }
                try json.endObject();
            },
        }
    }
};
