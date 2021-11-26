const std = @import("std");

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 0xFF,

    fn hash(c: Color) u6 {
        return @truncate(u6, c.r ^ c.g ^ c.b ^ c.a);
    }

    pub fn eql(a: Color, b: Color) bool {
        return std.meta.eql(a, b);
    }
};

/// A QOI image with RGBA pixels.
pub const Image = struct {
    width: u16,
    height: u16,
    pixels: []Color,

    pub fn asConst(self: Image) ConstImage {
        return ConstImage{
            .width = self.width,
            .height = self.height,
            .pixels = self.pixels,
        };
    }

    pub fn deinit(self: *Image, allocator: *std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// A QOI image with RGBA pixels.
pub const ConstImage = struct {
    width: u16,
    height: u16,
    pixels: []const Color,
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
    var color_lut = std.mem.zeroes([64]Color);

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

            // std.debug.print("read hash lookup to {} at +{}\n", .{ color_index, reader.context.getPos() });
            new_color = color_lut[color_index];
        } else if (hasPrefix(byte, u3, 0b010)) { // QOI_RUN_8
            count = @as(usize, @truncate(u5, byte)) + 1;

            // std.debug.print("read run of {} pixels at +{}\n", .{ count, reader.context.getPos() });
        } else if (hasPrefix(byte, u3, 0b011)) { // QOI_RUN_16
            const head = @as(usize, @truncate(u5, byte));
            const tail = @as(usize, try reader.readByte());

            count = ((head << 8) | tail) + 33;

            // std.debug.print("read run of {} pixels at +{}\n", .{ count, reader.context.getPos() });
        } else if (hasPrefix(byte, u2, 0b10)) { // QOI_DIFF_8

            const diff_r = @as(i8, @truncate(u2, byte >> 4)) - 1;
            const diff_g = @as(i8, @truncate(u2, byte >> 2)) - 1;
            const diff_b = @as(i8, @truncate(u2, byte >> 0)) - 1;

            // std.debug.print("read delta8({},{},{}) at +{}\n", .{ diff_r, diff_g, diff_b, reader.context.getPos() });

            add8(&new_color.r, diff_r);
            add8(&new_color.g, diff_g);
            add8(&new_color.b, diff_b);
        } else if (hasPrefix(byte, u3, 0b110)) { // QOI_DIFF_16

            const second = try reader.readByte();

            const diff_r = @as(i8, @truncate(u5, byte)) - 15;
            const diff_g = @as(i8, @truncate(u4, second >> 4)) - 7;
            const diff_b = @as(i8, @truncate(u4, second >> 0)) - 7;

            // std.debug.print("read delta16({},{},{}) at +{}\n", .{ diff_r, diff_g, diff_b, reader.context.getPos() });

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

            // std.debug.print("read delta24({},{},{},{}) at +{}\n", .{ diff_r, diff_g, diff_b, diff_a, reader.context.getPos() });

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

            // std.debug.print("read color({},{},{},{}) at +{}\n", .{ new_color.r, new_color.g, new_color.b, new_color.a, reader.context.getPos() });
        } else {
            unreachable;
        }

        while (count > 0) {
            count -= 1;

            img.pixels[index] = new_color;
            index += 1;
        }

        color_lut[new_color.hash()] = new_color;
        current_color = new_color;
    }

    return img;
}

pub const EncodeError = error{ OutOfMemory, ImageTooLarge, EndOfStream };

/// Encodes a given `image` into a QOI file.
/// Requires allocation to save the stream, cannot use Writer interface as we need to be able
/// to seek to the start.
pub fn encodeBuffer(allocator: *std.mem.Allocator, image: ConstImage) EncodeError![]u8 {
    const padding_size = 4; // arbitrary 4 bytes at the end of the file

    const QOI_INDEX: u8 = 0x00; // 00xxxxxx
    const QOI_RUN_8: u8 = 0x40; // 010xxxxx
    const QOI_RUN_16: u8 = 0x60; // 011xxxxx
    const QOI_DIFF_8: u8 = 0x80; // 10xxxxxx
    const QOI_DIFF_16: u8 = 0xc0; // 110xxxxx
    const QOI_DIFF_24: u8 = 0xe0; // 1110xxxx
    const QOI_COLOR: u8 = 0xf0; // 1111xxxx

    var destination_buffer = std.ArrayList(u8).init(allocator);
    defer destination_buffer.deinit();

    var writer = destination_buffer.writer();

    var header = Header{
        .width = image.width,
        .height = image.height,
        .size = undefined,
    };
    try writer.writeAll(&header.encode());

    var color_lut = std.mem.zeroes([64]Color);

    var previous_pixel = Color{ .r = 0, .g = 0, .b = 0, .a = 0xFF };
    var run_length: usize = 0;

    for (image.pixels) |pixel, i| {
        defer previous_pixel = pixel;

        const same_pixel = pixel.eql(previous_pixel);

        if (same_pixel) {
            run_length += 1;
        }

        if (run_length > 0 and (run_length == 0x2020 or !same_pixel or (i == (image.pixels.len - 1)))) {
            // std.debug.print("write run of {} pixels at +{}\n", .{ run_length, destination_buffer.items.len });
            // flush the run
            if (run_length < 33) {
                run_length -= 1;
                try writer.writeByte(QOI_RUN_8 | @truncate(u6, run_length));
            } else {
                run_length -= 33;
                try writer.writeByte(QOI_RUN_16 | @truncate(u5, run_length >> 8));
                try writer.writeByte(@truncate(u8, run_length));
            }
            run_length = 0;
        }

        if (!same_pixel) {
            const hash = pixel.hash();
            if (color_lut[hash].eql(pixel)) {
                // std.debug.print("write hash lookup to {} at +{}\n", .{ hash, destination_buffer.items.len });
                try writer.writeByte(QOI_INDEX | hash);
            } else {
                color_lut[hash] = pixel;
                const dr = @as(i9, pixel.r) - @as(i9, previous_pixel.r);
                const dg = @as(i9, pixel.g) - @as(i9, previous_pixel.g);
                const db = @as(i9, pixel.b) - @as(i9, previous_pixel.b);
                const da = @as(i9, pixel.a) - @as(i9, previous_pixel.a);

                // use delta encoding
                if (da == 0 and inRange2(dr) and inRange2(dg) and inRange2(db)) {
                    // use delta encoding 8
                    // std.debug.print("write delta8({},{},{}) at +{}\n", .{ dr, dg, db, destination_buffer.items.len });

                    try writer.writeByte(QOI_DIFF_8 |
                        (mapRange2(dr) << 4) |
                        (mapRange2(dg) << 2) |
                        (mapRange2(db) << 0));
                } else if (da == 0 and inRange5(dr) and inRange4(dg) and inRange4(db)) {
                    // std.debug.print("write delta16({},{},{}) at +{}\n", .{ dr, dg, db, destination_buffer.items.len });
                    // use delta encoding 16
                    try writer.writeByte(QOI_DIFF_16 | mapRange5(dr));
                    try writer.writeByte((mapRange4(dg) << 4) | (mapRange4(db) << 0));
                } else if (inRange5(dr) and inRange5(dg) and inRange5(db) and inRange5(da)) {
                    // std.debug.print("write delta24({},{},{},{}) at +{}\n", .{ dr, dg, db, da, destination_buffer.items.len });
                    // use delta encoding 24
                    const value = (@as(u24, QOI_DIFF_24) << 16) |
                        (@as(u24, mapRange5(dr)) << 15) |
                        (@as(u24, mapRange5(dg)) << 10) |
                        (@as(u24, mapRange5(db)) << 5) |
                        (@as(u24, mapRange5(da)) << 0);
                    try writer.writeByte(@truncate(u8, value >> 16));
                    try writer.writeByte(@truncate(u8, value >> 8));
                    try writer.writeByte(@truncate(u8, value >> 0));
                } else {
                    // std.debug.print("write color({},{},{},{}) at +{}\n", .{ pixel.r, pixel.g, pixel.b, pixel.a, destination_buffer.items.len });
                    // use absolute encoding
                    const bitmask = QOI_COLOR |
                        (if (dr != 0) @as(u8, 0b1000) else 0) |
                        (if (dg != 0) @as(u8, 0b0100) else 0) |
                        (if (db != 0) @as(u8, 0b0010) else 0) |
                        (if (da != 0) @as(u8, 0b0001) else 0);

                    try writer.writeByte(bitmask);

                    if (dr != 0) {
                        try writer.writeByte(pixel.r);
                    }
                    if (dg != 0) {
                        try writer.writeByte(pixel.g);
                    }
                    if (db != 0) {
                        try writer.writeByte(pixel.b);
                    }
                    if (da != 0) {
                        try writer.writeByte(pixel.a);
                    }
                }
            }
        }
    }

    try writer.writeByteNTimes(0, padding_size);

    // re-encode the header, but now with the correct size
    header.size = std.math.cast(u32, destination_buffer.items.len - Header.size) catch return error.ImageTooLarge;
    std.mem.copy(u8, destination_buffer.items, &header.encode());

    return destination_buffer.toOwnedSlice();
}

fn mapRange2(val: i9) u8 {
    return @intCast(u2, val + 1);
}
fn mapRange4(val: i9) u8 {
    return @intCast(u4, val + 7);
}
fn mapRange5(val: i9) u8 {
    return @intCast(u5, val + 15);
}

fn inRange2(val: i9) bool {
    return (val >= -1) and (val <= 2);
}
fn inRange4(val: i9) bool {
    return (val >= -7) and (val <= 8);
}
fn inRange5(val: i9) bool {
    return (val >= -15) and (val <= 16);
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
        std.mem.writeIntBig(u32, result[8..12], header.size);
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

    const dst_data = @embedFile("../data/zero.raw");
    try std.testing.expectEqualSlices(u8, dst_data, std.mem.sliceAsBytes(image.pixels));
}

test "encode qoi" {
    const src_data = @embedFile("../data/zero.raw");

    var dst_data = try encodeBuffer(std.testing.allocator, ConstImage{
        .width = 512,
        .height = 512,
        .pixels = std.mem.bytesAsSlice(Color, src_data),
    });
    defer std.testing.allocator.free(dst_data);

    const ref_data = @embedFile("../data/zero.qoi");
    try std.testing.expectEqualSlices(u8, ref_data, dst_data);
}

test "random encode/decode" {
    var rng_engine = std.rand.DefaultPrng.init(0x1337);
    const rng = rng_engine.random();

    const width = 251;
    const height = 49;

    var rounds: usize = 64;
    while (rounds > 0) {
        rounds -= 1;
        var input_buffer: [width * height]Color = undefined;
        rng.bytes(std.mem.sliceAsBytes(&input_buffer));

        var encoded_data = try encodeBuffer(std.testing.allocator, ConstImage{
            .width = width,
            .height = height,
            .pixels = &input_buffer,
        });
        defer std.testing.allocator.free(encoded_data);

        var image = try decodeBuffer(std.testing.allocator, encoded_data);
        defer image.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(u16, width), image.width);
        try std.testing.expectEqual(@as(u16, height), image.height);
        try std.testing.expectEqualSlices(Color, &input_buffer, image.pixels);
    }
}

test "input fuzzer. plz do not crash" {
    var rng_engine = std.rand.DefaultPrng.init(0x1337);
    const rng = rng_engine.random();

    var rounds: usize = 512;
    while (rounds > 0) {
        rounds -= 1;
        var input_buffer: [1 << 20]u8 = undefined;
        rng.bytes(std.mem.sliceAsBytes(&input_buffer));

        if (decodeBuffer(std.testing.allocator, &input_buffer)) |*image| {
            defer image.deinit(std.testing.allocator);
        } else |err| {
            // error is also okay, just no crashes plz
            err catch {};
        }
    }
}
