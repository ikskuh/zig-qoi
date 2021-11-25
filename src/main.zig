const std = @import("std");

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 0xFF,

    fn hash(c: Color) u8 {
        return c.r ^ c.g ^ c.b ^ c.a;
    }
};

/// A QOI image with RGBA pixels.
pub const Image = struct {
    width: u16,
    height: u16,
    pixels: []Color,

    pub fn deinit(self: *Image, allocator: *std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// Returns true if `bytes` appear to contain a valid QOI image.
pub fn isQOI(bytes: []const u8) bool {
    if (bytes.len < Header.size)
        return false;
    const header = Header.decode(bytes[0..Header.size].*) catch return false;
    return (bytes.len >= Header.size + header.size);
}

pub const DecodeError = error{ OutOfMemory, InvalidData, EndOfStream };

/// Decodes a buffer containing a QOI image and returns the decoded image.
pub fn decodeBuffer(allocator: *std.mem.Allocator, buffer: []const u8) DecodeError!Image {
    if (buffer.len < Header.size)
        return error.InvalidData;

    const header = Header.decode(buffer[0..12].*) catch return error.InvalidData;
    if (buffer.len != Header.size + header.size)
        return error.InvalidData;

    var stream = std.io.fixedBufferStream(buffer);
    return try decodeStream(allocator, stream.reader());
}

/// Decodes a QOI stream and returns the decoded image.
pub fn decodeStream(allocator: *std.mem.Allocator, reader: anytype) (DecodeError || @TypeOf(reader).Error)!Image {
    var header_data: [Header.size]u8 = undefined;
    try reader.readNoEof(&header_data);
    const header = Header.decode(header_data) catch return error.InvalidData;

    const size = @as(u32, header.width) * @as(u32, header.height);

    var img = Image{
        .width = header.width,
        .height = header.height,
        .pixels = try allocator.alloc(Color, size),
    };
    errdefer allocator.free(img.pixels);

    var current_color = Color{ .r = 0, .g = 0, .b = 0, .a = 0xFF };
    var previous_colors = std.mem.zeroes([64]Color);

    var index: usize = 0;
    while (index < img.pixels.len) {
        var byte = reader.readByte() catch |err| {
            std.log.err("failed to read byte from qoi stream at ({},{}): {s}", .{
                index % img.width,
                index / img.width,
                @errorName(err),
            });
            break;
            // return err;
        };

        var new_color = current_color;
        var count: usize = 1;

        if (hasPrefix(byte, u2, 0b00)) { // QOI_INDEX
            const color_index = @truncate(u6, byte);
            new_color = previous_colors[color_index];
        } else if (hasPrefix(byte, u3, 0b010)) { // QOI_RUN_8
            count = @as(usize, @truncate(u5, byte)) + 1;
        } else if (hasPrefix(byte, u3, 0b011)) { // QOI_RUN_16
            const head = @as(usize, @truncate(u5, byte));
            const tail = @as(usize, try reader.readByte());

            count = ((head << 8) | tail) + 33;
        } else if (hasPrefix(byte, u2, 0b10)) { // QOI_DIFF_8

            const diff_r = @as(i8, @truncate(u2, byte >> 4)) - 1;
            const diff_g = @as(i8, @truncate(u2, byte >> 2)) - 1;
            const diff_b = @as(i8, @truncate(u2, byte >> 0)) - 1;

            add8(&new_color.r, diff_r);
            add8(&new_color.g, diff_g);
            add8(&new_color.b, diff_b);
        } else if (hasPrefix(byte, u3, 0b110)) { // QOI_DIFF_16

            const second = try reader.readByte();

            const diff_r = @as(i8, @truncate(u5, byte)) - 15;
            const diff_g = @as(i8, @truncate(u4, second >> 4)) - 7;
            const diff_b = @as(i8, @truncate(u4, second >> 0)) - 7;

            add8(&new_color.r, diff_r);
            add8(&new_color.g, diff_g);
            add8(&new_color.b, diff_b);
        } else if (hasPrefix(byte, u4, 0b1110)) { // QOI_DIFF_24
            const second = try reader.readByte();
            const third = try reader.readByte();

            const all = (@as(u24, byte) << 16) | (@as(u24, second) << 8) | (@as(u24, third) << 0);

            const diff_r = @as(i8, @truncate(u5, all >> 15)) - 15;
            const diff_g = @as(i8, @truncate(u5, all >> 10)) - 15;
            const diff_b = @as(i8, @truncate(u5, all >> 5)) - 15;
            const diff_a = @as(i8, @truncate(u5, all >> 0)) - 15;

            add8(&new_color.r, diff_r);
            add8(&new_color.g, diff_g);
            add8(&new_color.b, diff_b);
            add8(&new_color.a, diff_a);
        } else if (hasPrefix(byte, u4, 0b1111)) { // QOI_COLOR
            const has_r = (byte & 0b1000) != 0;
            const has_g = (byte & 0b0100) != 0;
            const has_b = (byte & 0b0010) != 0;
            const has_a = (byte & 0b0001) != 0;

            if (has_r) {
                new_color.r = try reader.readByte();
            }
            if (has_g) {
                new_color.g = try reader.readByte();
            }
            if (has_b) {
                new_color.b = try reader.readByte();
            }
            if (has_a) {
                new_color.a = try reader.readByte();
            }
        } else {
            unreachable;
        }

        while (count > 0) {
            count -= 1;

            img.pixels[index] = new_color;
            index += 1;
        }

        previous_colors[new_color.hash() % 64] = new_color;
        current_color = new_color;
    }

    return img;
}

fn add8(dst: *u8, diff: i8) void {
    dst.* +%= @bitCast(u8, diff);
}

fn hasPrefix(value: u8, comptime T: type, prefix: T) bool {
    return (@truncate(T, value >> (8 - @bitSizeOf(T))) == prefix);
}

pub const Header = struct {
    const size = 12;
    const correct_magic = [4]u8{ 'q', 'o', 'i', 'f' };

    width: u16, // big endian
    height: u16, // big endian
    size: u32, // big endian

    fn decode(buffer: [size]u8) !Header {
        if (!std.mem.eql(u8, buffer[0..4], &correct_magic))
            return error.InvalidMagic;
        return Header{
            .width = std.mem.readIntBig(u16, buffer[4..6]),
            .height = std.mem.readIntBig(u16, buffer[6..8]),
            .size = std.mem.readIntBig(u32, buffer[8..12]),
        };
    }

    fn encode(header: Header) [size]u8 {
        var result: [size]u8 = undefined;
        std.mem.copy(u8, result[0..4], &correct_magic);
        std.mem.writeIntBig(u16, result[4..6], header.width);
        std.mem.writeIntBig(u16, result[6..8], header.height);
        std.mem.writeIntBig(u16, result[8..12], header.size);
        return result;
    }
};

test "decode zero.qoi" {
    const src_data = @embedFile("../data/zero.qoi");

    var image = try decodeBuffer(std.testing.allocator, src_data);
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 512), image.width);
    try std.testing.expectEqual(@as(u16, 512), image.height);
    try std.testing.expectEqual(@as(usize, 512 * 512), image.pixels.len);

    var out = try std.fs.cwd().createFile("debug.pam", .{});

    defer out.close();

    try out.writer().print(
        \\P7
        \\WIDTH {}
        \\HEIGHT {}
        \\DEPTH 4
        \\MAXVAL 255
        \\TUPLTYPE RGB_ALPHA
        \\ENDHDR
        \\
    , .{ image.width, image.height });
    try out.writeAll(std.mem.sliceAsBytes(image.pixels));
}
