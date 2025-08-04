const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const Bencode = @import("bencode.zig").Bencode;

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
        const metainfo = try readTorrent(allocator, args[2]);
        defer metainfo.deinit(allocator);

        try stdout.print("Tracker URL: {s}\n", .{metainfo.announce});
        try stdout.print("Length: {d}\n", .{metainfo.length});
        try stdout.print("Info Hash: {s}\n", .{std.fmt.bytesToHex(metainfo.hash, .lower)});
        try stdout.print("Piece Length: {d}\n", .{metainfo.piece_length});

        try stdout.print("Piece Hashes:\n", .{});
        for (metainfo.piece_hashes) |piece_hash| {
            try stdout.print("{s}\n", .{std.fmt.bytesToHex(piece_hash, .lower)});
        }
    } else if (std.mem.eql(u8, command, "peers")) {
        const metainfo = try readTorrent(allocator, args[2]);
        defer metainfo.deinit(allocator);

        const my_id = blk: {
            var buf: [20]u8 = undefined;
            std.crypto.random.bytes(&buf);
            break :blk buf;
        };

        const response = blk: {
            var client: std.http.Client = .{ .allocator = allocator };
            defer client.deinit();

            const query = try std.fmt.allocPrint(
                allocator,
                "info_hash={s}&peer_id={s}&port={d}&uploaded={d}&downloaded={d}&left={d}&compact=1",
                .{ metainfo.hash, my_id, 6881, 0, 0, metainfo.length },
            );
            defer allocator.free(query);

            var tracker: std.Uri = try .parse(metainfo.announce);
            tracker.query = .{ .raw = query };

            var server_header_buffer: [16 * 1024]u8 = undefined;
            var req = try client.open(.GET, tracker, .{ .server_header_buffer = &server_header_buffer });
            defer req.deinit();
            try req.send();
            try req.finish();
            try req.wait();

            // We don't care about the headers, so we can reuse the buffer
            var reader = req.reader().adaptToNewApi(&server_header_buffer);
            break :blk try Bencode.decode(allocator, &reader.new_interface, .{});
        };
        defer response.deinit();

        var peers = std.mem.window(u8, response.value.dict.get("peers").?.str, 6, 6);
        while (peers.next()) |peer_bytes| {
            try stdout.print("{d}.{d}.{d}.{d}:{d}\n", .{
                peer_bytes[0],
                peer_bytes[1],
                peer_bytes[2],
                peer_bytes[3],
                std.mem.readInt(u16, peer_bytes[4..6], .big),
            });
        }
    } else @panic("Unknown command");
}

const Metainfo = struct {
    announce: []const u8,
    length: u64,
    piece_length: u64,
    piece_hashes: []const Digest,
    hash: Digest,

    const Hash = std.crypto.hash.Sha1;
    pub const Digest = [Hash.digest_length]u8;

    pub fn parse(allocator: Allocator, reader: *Reader) !Metainfo {
        const decoded = try Bencode.decode(allocator, reader, .{});
        defer decoded.deinit();

        const metainfo = decoded.value.dict;
        const info = metainfo.get("info").?.dict;

        const announce = try allocator.dupe(u8, metainfo.get("announce").?.str);
        errdefer allocator.free(announce);

        const piece_hashes = try allocator.dupe(Digest, @ptrCast(info.get("pieces").?.str));
        errdefer allocator.free(piece_hashes);

        const hash = blk: {
            var writer = null_writer.hashed(Hash.init(.{}), &.{});
            try writer.writer.print("{f}", .{Bencode{ .dict = info }});
            break :blk writer.hasher.finalResult();
        };

        return .{
            .announce = announce,
            .length = @intCast(info.get("length").?.int),
            .piece_length = @intCast(info.get("piece length").?.int),
            .piece_hashes = piece_hashes,
            .hash = hash,
        };
    }

    pub fn deinit(self: Metainfo, allocator: Allocator) void {
        allocator.free(self.announce);
        allocator.free(self.piece_hashes);
    }
};

fn readTorrent(allocator: Allocator, path: []const u8) !Metainfo {
    var file_buf: [4096]u8 = undefined;
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    var reader = f.reader(&file_buf);
    return .parse(allocator, &reader.interface);
}
