const std = @import("std");
const allocator = std.heap.page_allocator;
const Writer = std.Io.Writer;

var stdout: *Writer = undefined;

pub fn main() !void {
    // Use empty buffer to always flush immediately
    var stdout_file = std.fs.File.stdout().writer(&.{});
    stdout = &stdout_file.interface;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) @panic("Usage: your_program.sh <command> <args>");

    const command = args[1];

    if (std.mem.eql(u8, command, "decode")) {
        const encoded = args[2];
        const decoded = Bencode.decode(encoded) catch @panic("Invalid encoded value");
        switch (decoded) {
            .string => |s| try stdout.print("{f}\n", .{std.json.fmt(s, .{})}),
            .integer => |i| try stdout.print("{f}\n", .{std.json.fmt(i, .{})}),
        }
    }
}

const Bencode = union(enum) {
    string: []const u8,
    integer: i64,

    pub const DecodeError = error{InvalidArgument};

    pub fn decode(encoded: []const u8) DecodeError!Bencode {
        if (encoded[0] >= '0' and encoded[0] <= '9') {
            return decodeString(encoded);
        } else if (encoded[0] == 'i') {
            return decodeInteger(encoded);
        } else @panic("Unsupported type");
    }

    fn decodeString(encoded: []const u8) DecodeError!Bencode {
        const firstColon = std.mem.indexOf(u8, encoded, ":");
        if (firstColon == null) {
            return error.InvalidArgument;
        }

        const len = std.fmt.parseInt(usize, encoded[0..firstColon.?], 10) catch return error.InvalidArgument;
        return .{ .string = encoded[firstColon.? + 1 ..][0..len] };
    }

    fn decodeInteger(encoded: []const u8) DecodeError!Bencode {
        const end = std.mem.indexOf(u8, encoded, "e");
        if (end == null) {
            return error.InvalidArgument;
        }

        const value = std.fmt.parseInt(i64, encoded[1..end.?], 10) catch return error.InvalidArgument;
        return .{ .integer = value };
    }
};
