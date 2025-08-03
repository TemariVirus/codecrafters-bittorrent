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

    if (args.len < 3) {
        try stdout.print("Usage: your_program.sh <command> <args>\n", .{});
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "decode")) {
        const encodedStr = args[2];
        const decodedStr = decodeBencode(encodedStr) catch {
            stdout.print("Invalid encoded value\n", .{}) catch {};
            std.process.exit(1);
        };
        try stdout.print("{f}\n", .{std.json.fmt(decodedStr, .{})});
    }
}

fn decodeBencode(encodedValue: []const u8) error{InvalidArgument}![]const u8 {
    if (encodedValue[0] >= '0' and encodedValue[0] <= '9') {
        const firstColon = std.mem.indexOf(u8, encodedValue, ":");
        if (firstColon == null) {
            return error.InvalidArgument;
        }
        return encodedValue[firstColon.? + 1 ..];
    } else {
        stdout.print("Only strings are supported at the moment\n", .{}) catch {};
        std.process.exit(1);
    }
}
