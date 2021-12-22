const std = @import("std");
const logger = std.log.scoped(.qoi);

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 0xFF,

    fn hash(c: Color) u6 {
        return @truncate(u6, c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
    }

    pub fn eql(a: Color, b: Color) bool {
        return std.meta.eql(a, b);
    }
};

/// A QOI image with RGBA pixels.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []Color,
    colorspace: Colorspace,

    pub fn asConst(self: Image) ConstImage {
        return ConstImage{
            .width = self.width,
            .height = self.height,
            .pixels = self.pixels,
            .colorspace = self.colorspace,
        };
    }

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// A QOI image with RGBA pixels.
pub const ConstImage = struct {
    width: u32,
    height: u32,
    pixels: []const Color,
    colorspace: Colorspace,
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
pub fn decodeBuffer(allocator: std.mem.Allocator, buffer: []const u8) DecodeError!Image {
    if (buffer.len < Header.size)
        return error.InvalidData;

    var stream = std.io.fixedBufferStream(buffer);
    return try decodeStream(allocator, stream.reader());
}

fn LimitedBufferedStream(comptime UnderlyingReader: type, comptime buffer_size: usize) type {
    return struct {
        const Self = @This();
        const Error = UnderlyingReader.Error || error{EndOfStream};
        const FifoType = std.fifo.LinearFifo(u8, std.fifo.LinearFifoBufferType{ .Static = buffer_size });

        unbuffered_reader: UnderlyingReader,
        limit: usize,
        fifo: FifoType = FifoType.init(),

        pub const Reader = std.io.Reader(*Self, Error, read);

        pub fn reader(self: *Self) Reader {
            return Reader{ .context = self };
        }

        pub fn read(self: *Self, dest: []u8) Error!usize {
            var dest_index: usize = 0;
            while (dest_index < dest.len) {
                const written = self.fifo.read(dest[dest_index..]);
                if (written == 0) {
                    // fifo empty, fill it
                    const writable = self.fifo.writableSlice(0);
                    std.debug.assert(writable.len > 0);

                    if (self.limit == 0)
                        return error.EndOfStream;

                    const max_data = std.math.min(self.limit, writable.len);
                    const n = try self.unbuffered_reader.read(writable[0..max_data]);
                    if (n == 0) {
                        // reading from the unbuffered stream returned nothing
                        // so we have nothing left to read.
                        return dest_index;
                    }
                    self.limit -= n;
                    self.fifo.update(n);
                }
                dest_index += written;
            }
            return dest.len;
        }
    };
}

const debug_decode_qoi_opcodes = false;

/// Decodes a QOI stream and returns the decoded image.
pub fn decodeStream(allocator: std.mem.Allocator, reader: anytype) (DecodeError || @TypeOf(reader).Error)!Image {
    var header_data: [Header.size]u8 = undefined;
    try reader.readNoEof(&header_data);
    const header = Header.decode(header_data) catch return error.InvalidData;

    const size_raw = @as(u64, header.width) * @as(u64, header.height);
    const size = std.math.cast(usize, size_raw) catch return error.OutOfMemory;

    var img = Image{
        .width = header.width,
        .height = header.height,
        .pixels = try allocator.alloc(Color, size),
        .colorspace = header.colorspace,
    };
    errdefer allocator.free(img.pixels);

    var current_color = Color{ .r = 0, .g = 0, .b = 0, .a = 0xFF };
    var color_lut = std.mem.zeroes([64]Color);

    var index: usize = 0;
    while (index < img.pixels.len) {
        var byte = try reader.readByte();

        var new_color = current_color;
        var count: usize = 1;

        if (byte == 0b11111110) { // QOI_OP_RGB
            new_color.r = try reader.readByte();
            new_color.g = try reader.readByte();
            new_color.b = try reader.readByte();

            if (debug_decode_qoi_opcodes) {
                new_color = Color{ .r = 0xFF, .g = 0x00, .b = 0x00 };
            }
        } else if (byte == 0b11111111) { // QOI_OP_RGBA
            new_color.r = try reader.readByte();
            new_color.g = try reader.readByte();
            new_color.b = try reader.readByte();
            new_color.a = try reader.readByte();

            if (debug_decode_qoi_opcodes) {
                new_color = Color{ .r = 0x00, .g = 0xFF, .b = 0x00 };
            }
        } else if (hasPrefix(byte, u2, 0b00)) { // QOI_OP_INDEX
            const color_index = @truncate(u6, byte);
            new_color = color_lut[color_index];

            if (debug_decode_qoi_opcodes) {
                new_color = Color{ .r = 0x00, .g = 0x00, .b = 0xFF };
            }
        } else if (hasPrefix(byte, u2, 0b01)) { // QOI_OP_DIFF
            const diff_r = unmapRange2(byte >> 4);
            const diff_g = unmapRange2(byte >> 2);
            const diff_b = unmapRange2(byte >> 0);

            add8(&new_color.r, diff_r);
            add8(&new_color.g, diff_g);
            add8(&new_color.b, diff_b);

            if (debug_decode_qoi_opcodes) {
                new_color = Color{ .r = 0xFF, .g = 0xFF, .b = 0x00 };
            }
        } else if (hasPrefix(byte, u2, 0b10)) { // QOI_OP_LUMA

            const diff_g = unmapRange6(byte);

            const diff_rg_rb = try reader.readByte();

            const diff_rg = unmapRange4(diff_rg_rb >> 4);
            const diff_rb = unmapRange4(diff_rg_rb >> 0);

            const diff_r = @as(i8, diff_g) + diff_rg;
            const diff_b = @as(i8, diff_g) + diff_rb;

            add8(&new_color.r, diff_r);
            add8(&new_color.g, diff_g);
            add8(&new_color.b, diff_b);

            if (debug_decode_qoi_opcodes) {
                new_color = Color{ .r = 0xFF, .g = 0x00, .b = 0xFF };
            }
        } else if (hasPrefix(byte, u2, 0b11)) { // QOI_OP_RUN
            count = @as(usize, @truncate(u6, byte)) + 1;
            std.debug.assert(count >= 1 and count <= 62);

            if (debug_decode_qoi_opcodes) {
                new_color = Color{ .r = 0x00, .g = 0xFF, .b = 0xFF };
            }
        } else {
            // we have covered all possibilities.
            unreachable;
        }

        // this will happen when a file has an invalid run length
        // and we would decode more pixels than there are in the image.
        if (index + count > img.pixels.len) {
            return error.InvalidData;
        }

        while (count > 0) {
            count -= 1;
            img.pixels[index] = new_color;
            index += 1;

            if (debug_decode_qoi_opcodes) {
                new_color = Color{ .r = 0x80, .g = 0x80, .b = 0x80 };
            }
        }

        color_lut[new_color.hash()] = new_color;
        current_color = new_color;
    }

    return img;
}

pub const EncodeError = error{};

/// Encodes a given `image` into a QOI buffer.
pub fn encodeBuffer(allocator: std.mem.Allocator, image: ConstImage) (std.mem.Allocator.Error || EncodeError)![]u8 {
    var destination_buffer = std.ArrayList(u8).init(allocator);
    defer destination_buffer.deinit();

    try encodeStream(image, destination_buffer.writer());

    return destination_buffer.toOwnedSlice();
}

/// Encodes a given `image` into a QOI buffer.
pub fn encodeStream(image: ConstImage, writer: anytype) (EncodeError || @TypeOf(writer).Error)!void {
    var format = for (image.pixels) |pix| {
        if (pix.a != 0xFF)
            break Format.rgba;
    } else Format.rgb;

    var header = Header{
        .width = image.width,
        .height = image.height,
        .format = format,
        .colorspace = .sRGB,
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

        if (run_length > 0 and (run_length == 62 or !same_pixel or (i == (image.pixels.len - 1)))) {
            // QOI_OP_RUN
            std.debug.assert(run_length >= 1 and run_length <= 62);
            try writer.writeByte(0b1100_0000 | @truncate(u8, run_length - 1));
            run_length = 0;
        }

        if (!same_pixel) {
            const hash = pixel.hash();
            if (color_lut[hash].eql(pixel)) {
                // QOI_OP_INDEX
                try writer.writeByte(0b0000_0000 | hash);
            } else {
                color_lut[hash] = pixel;

                const diff_r = @as(i16, pixel.r) - @as(i16, previous_pixel.r);
                const diff_g = @as(i16, pixel.g) - @as(i16, previous_pixel.g);
                const diff_b = @as(i16, pixel.b) - @as(i16, previous_pixel.b);
                const diff_a = @as(i16, pixel.a) - @as(i16, previous_pixel.a);

                const diff_rg = diff_r - diff_g;
                const diff_rb = diff_b - diff_g;

                if (diff_a == 0 and inRange2(diff_r) and inRange2(diff_g) and inRange2(diff_b)) {
                    // QOI_OP_DIFF
                    const byte = 0b0100_0000 |
                        (mapRange2(diff_r) << 4) |
                        (mapRange2(diff_g) << 2) |
                        (mapRange2(diff_b) << 0);
                    try writer.writeByte(byte);
                } else if (diff_a == 0 and inRange6(diff_g) and inRange4(diff_rg) and inRange4(diff_rb)) {
                    // QOI_OP_LUMA
                    try writer.writeAll(&[2]u8{
                        0b1000_0000 | mapRange6(diff_g),
                        (mapRange4(diff_rg) << 4) | (mapRange4(diff_rb) << 0),
                    });
                } else if (diff_a == 0) {
                    // QOI_OP_RGB
                    try writer.writeAll(&[4]u8{
                        0b1111_1110,
                        pixel.r,
                        pixel.g,
                        pixel.b,
                    });
                } else {
                    // QOI_OP_RGBA
                    try writer.writeAll(&[5]u8{
                        0b1111_1111,
                        pixel.r,
                        pixel.g,
                        pixel.b,
                        pixel.a,
                    });
                }
            }
        }
    }

    try writer.writeAll(&[8]u8{
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
    });
}

fn mapRange2(val: i16) u8 {
    return @intCast(u2, val + 2);
}
fn mapRange4(val: i16) u8 {
    return @intCast(u4, val + 8);
}
fn mapRange6(val: i16) u8 {
    return @intCast(u6, val + 32);
}

fn unmapRange2(val: u32) i2 {
    return @intCast(i2, @as(i8, @truncate(u2, val)) - 2);
}
fn unmapRange4(val: u32) i4 {
    return @intCast(i4, @as(i8, @truncate(u4, val)) - 8);
}
fn unmapRange6(val: u32) i6 {
    return @intCast(i6, @as(i8, @truncate(u6, val)) - 32);
}

fn inRange2(val: i16) bool {
    return (val >= -2) and (val <= 1);
}
fn inRange4(val: i16) bool {
    return (val >= -8) and (val <= 7);
}
fn inRange6(val: i16) bool {
    return (val >= -32) and (val <= 31);
}

fn add8(dst: *u8, diff: i8) void {
    dst.* +%= @bitCast(u8, diff);
}

fn hasPrefix(value: u8, comptime T: type, prefix: T) bool {
    return (@truncate(T, value >> (8 - @bitSizeOf(T))) == prefix);
}

pub const Header = struct {
    const size = 14;
    const correct_magic = [4]u8{ 'q', 'o', 'i', 'f' };

    width: u32,
    height: u32,
    format: Format,
    colorspace: Colorspace,

    fn decode(buffer: [size]u8) !Header {
        if (!std.mem.eql(u8, buffer[0..4], &correct_magic))
            return error.InvalidMagic;
        return Header{
            .width = std.mem.readIntBig(u32, buffer[4..8]),
            .height = std.mem.readIntBig(u32, buffer[8..12]),
            .format = try std.meta.intToEnum(Format, buffer[12]),
            .colorspace = try std.meta.intToEnum(Colorspace, buffer[13]),
        };
    }

    fn encode(header: Header) [size]u8 {
        var result: [size]u8 = undefined;
        std.mem.copy(u8, result[0..4], &correct_magic);
        std.mem.writeIntBig(u32, result[4..8], header.width);
        std.mem.writeIntBig(u32, result[8..12], header.height);
        result[12] = @enumToInt(header.format);
        result[13] = @enumToInt(header.colorspace);
        return result;
    }
};

pub const Colorspace = enum(u8) {
    /// sRGB color, linear alpha
    sRGB = 0,

    /// Every channel is linear
    linear = 1,
};

pub const Format = enum(u8) {
    rgb = 3,
    rgba = 4,
};

test "decode qoi" {
    const src_data = @embedFile("../data/zero.qoi");

    var image = try decodeBuffer(std.testing.allocator, src_data);
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 512), image.width);
    try std.testing.expectEqual(@as(u32, 512), image.height);
    try std.testing.expectEqual(@as(usize, 512 * 512), image.pixels.len);

    const dst_data = @embedFile("../data/zero.raw");
    try std.testing.expectEqualSlices(u8, dst_data, std.mem.sliceAsBytes(image.pixels));
}

test "decode qoi file" {
    var file = try std.fs.cwd().openFile("data/zero.qoi", .{});
    defer file.close();

    var image = try decodeStream(std.testing.allocator, file.reader());
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 512), image.width);
    try std.testing.expectEqual(@as(u32, 512), image.height);
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
        .colorspace = .sRGB,
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

    var rounds: usize = 512;
    while (rounds > 0) {
        rounds -= 1;
        var input_buffer: [width * height]Color = undefined;
        rng.bytes(std.mem.sliceAsBytes(&input_buffer));

        var encoded_data = try encodeBuffer(std.testing.allocator, ConstImage{
            .width = width,
            .height = height,
            .pixels = &input_buffer,
            .colorspace = if (rng.boolean()) Colorspace.sRGB else Colorspace.linear,
        });
        defer std.testing.allocator.free(encoded_data);

        var image = try decodeBuffer(std.testing.allocator, encoded_data);
        defer image.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(u32, width), image.width);
        try std.testing.expectEqual(@as(u32, height), image.height);
        try std.testing.expectEqualSlices(Color, &input_buffer, image.pixels);
    }
}

test "input fuzzer. plz do not crash" {
    var rng_engine = std.rand.DefaultPrng.init(0x1337);
    const rng = rng_engine.random();

    var rounds: usize = 32;
    while (rounds > 0) {
        rounds -= 1;
        var input_buffer: [1 << 20]u8 = undefined; // perform on a 1 MB buffer
        rng.bytes(&input_buffer);

        if ((rounds % 4) != 0) { // 25% is fully random 75% has a correct looking header
            std.mem.copy(u8, &input_buffer, &(Header{
                .width = rng.int(u16),
                .height = rng.int(u16),
                .format = rng.enumValue(Format),
                .colorspace = rng.enumValue(Colorspace),
            }).encode());
        }

        var stream = std.io.fixedBufferStream(&input_buffer);

        if (decodeStream(std.testing.allocator, stream.reader())) |*image| {
            defer image.deinit(std.testing.allocator);
        } else |err| {
            // error is also okay, just no crashes plz
            err catch {};
        }
    }
}
