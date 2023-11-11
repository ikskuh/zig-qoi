const std = @import("std");
const logger = std.log.scoped(.qoi);

pub const EncodeError = error{};
pub const DecodeError = error{ OutOfMemory, InvalidData, EndOfStream };

/// Returns a raw qoi stream decoder that will fetch color runs from the qoi stream.
pub fn decoder(reader: anytype) Decoder(@TypeOf(reader)) {
    return .{ .reader = reader };
}

/// Returns a raw qoi stream encoder that will receive pixel colors and write out bytes to a writer. This stream does not create a qoi header!
pub fn encoder(writer: anytype) Encoder(@TypeOf(writer)) {
    return .{ .writer = writer };
}

/// A run of several pixels of the same color.
pub const ColorRun = struct {
    color: Color,
    /// Is always greater than 0.
    length: usize,
};

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 0xFF,

    fn hash(c: Color) u6 {
        return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
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

/// Returns true if `bytes` appear to contain a valid QOI image from the header. This does not a in-depth analysis.
pub fn isQOI(bytes: []const u8) bool {
    if (bytes.len < Header.size)
        return false;
    const header = Header.decode(bytes[0..Header.size].*) catch return false;
    return (bytes.len >= Header.size + header.size);
}

/// Decodes a buffer containing a QOI image and returns the decoded image.
pub fn decodeBuffer(allocator: std.mem.Allocator, buffer: []const u8) DecodeError!Image {
    if (buffer.len < Header.size)
        return error.InvalidData;

    var stream = std.io.fixedBufferStream(buffer);
    return try decodeStream(allocator, stream.reader());
}

/// Decodes a QOI stream and returns the decoded image.
pub fn decodeStream(allocator: std.mem.Allocator, reader: anytype) (DecodeError || @TypeOf(reader).Error)!Image {
    var header_data: [Header.size]u8 = undefined;
    try reader.readNoEof(&header_data);
    const header = Header.decode(header_data) catch return error.InvalidData;

    const size_raw = @as(u64, header.width) * @as(u64, header.height);
    const size = std.math.cast(usize, size_raw) orelse return error.OutOfMemory;

    var img = Image{
        .width = header.width,
        .height = header.height,
        .pixels = try allocator.alloc(Color, size),
        .colorspace = header.colorspace,
    };
    errdefer allocator.free(img.pixels);

    var dec = decoder(reader);

    var index: usize = 0;
    while (index < img.pixels.len) {
        var run = try dec.fetch();

        // this will happen when a file has an invalid run length
        // and we would decode more pixels than there are in the image.
        if (index + run.length > img.pixels.len) {
            return error.InvalidData;
        }

        while (run.length > 0) {
            run.length -= 1;
            img.pixels[index] = run.color;
            index += 1;
        }
    }

    return img;
}

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

    var enc = encoder(writer);
    for (image.pixels) |pixel| {
        try enc.push(pixel);
    }
    try enc.flush();

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

/// Returns a raw qoi stream encoder that will receive pixel colors and write out bytes to a writer. This stream does not create a qoi header!
/// - `Writer` is the type of that writer
pub fn Encoder(comptime Writer: type) type {
    return struct {
        const Self = @This();

        pub const Error = Writer.Error || EncodeError;

        // Set this to your writer:
        writer: Writer,

        // privates:
        color_lut: [64]Color = std.mem.zeroes([64]Color),
        previous_pixel: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0xFF },
        run_length: usize = 0,

        fn flushRun(self: *Self) !void { // QOI_OP_RUN
            std.debug.assert(self.run_length >= 1 and self.run_length <= 62);
            try self.writer.writeByte(0b1100_0000 | @as(u8, @truncate(self.run_length - 1)));
            self.run_length = 0;
        }

        /// Resets the stream so it will start encoding from a clean slate.
        pub fn reset(self: *Self) void {
            var writer = self.writer;
            self.* = Self{ .writer = writer };
        }

        /// Flushes any left runs to the stream and will leave the stream in a "clean" state where a stream is terminated.
        /// Does not reset the stream for a clean slate.
        pub fn flush(self: *Self) (EncodeError || Writer.Error)!void {
            if (self.run_length > 0) {
                try self.flushRun();
            }
            std.debug.assert(self.run_length == 0);
        }

        /// Pushes a pixel into the stream. Might not write data if the pixel can be encoded as a run.
        /// Call `flush` after encoding all pixels to make sure the stream is terminated properly.
        pub fn push(self: *Self, pixel: Color) (EncodeError || Writer.Error)!void {
            defer self.previous_pixel = pixel;
            const previous_pixel = self.previous_pixel;

            const same_pixel = pixel.eql(self.previous_pixel);

            if (same_pixel) {
                self.run_length += 1;
            }

            if (self.run_length > 0 and (self.run_length == 62 or !same_pixel)) {
                try self.flushRun();
            }

            if (same_pixel) {
                return;
            }

            const hash = pixel.hash();
            if (self.color_lut[hash].eql(pixel)) {
                // QOI_OP_INDEX
                try self.writer.writeByte(0b0000_0000 | hash);
            } else {
                self.color_lut[hash] = pixel;

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
                    try self.writer.writeByte(byte);
                } else if (diff_a == 0 and inRange6(diff_g) and inRange4(diff_rg) and inRange4(diff_rb)) {
                    // QOI_OP_LUMA
                    try self.writer.writeAll(&[2]u8{
                        0b1000_0000 | mapRange6(diff_g),
                        (mapRange4(diff_rg) << 4) | (mapRange4(diff_rb) << 0),
                    });
                } else if (diff_a == 0) {
                    // QOI_OP_RGB
                    try self.writer.writeAll(&[4]u8{
                        0b1111_1110,
                        pixel.r,
                        pixel.g,
                        pixel.b,
                    });
                } else {
                    // QOI_OP_RGBA
                    try self.writer.writeAll(&[5]u8{
                        0b1111_1111,
                        pixel.r,
                        pixel.g,
                        pixel.b,
                        pixel.a,
                    });
                }
            }
        }
    };
}

/// A raw stream decoder for Qoi data streams. Will not decode file headers.
pub fn Decoder(comptime Reader: type) type {
    return struct {
        const Self = @This();

        reader: Reader,

        // private api:
        current_color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0xFF },
        color_lut: [64]Color = std.mem.zeroes([64]Color),

        /// Decodes the next `ColorRun` from the stream. For non-run commands, will return a run with length 1.
        pub fn fetch(self: *Self) (Reader.Error || error{EndOfStream})!ColorRun {
            var byte = try self.reader.readByte();

            var new_color = self.current_color;
            var count: usize = 1;

            if (byte == 0b11111110) { // QOI_OP_RGB
                new_color.r = try self.reader.readByte();
                new_color.g = try self.reader.readByte();
                new_color.b = try self.reader.readByte();
            } else if (byte == 0b11111111) { // QOI_OP_RGBA
                new_color.r = try self.reader.readByte();
                new_color.g = try self.reader.readByte();
                new_color.b = try self.reader.readByte();
                new_color.a = try self.reader.readByte();
            } else if (hasPrefix(byte, u2, 0b00)) { // QOI_OP_INDEX
                const color_index = @as(u6, @truncate(byte));
                new_color = self.color_lut[color_index];
            } else if (hasPrefix(byte, u2, 0b01)) { // QOI_OP_DIFF
                const diff_r = unmapRange2(byte >> 4);
                const diff_g = unmapRange2(byte >> 2);
                const diff_b = unmapRange2(byte >> 0);

                add8(&new_color.r, diff_r);
                add8(&new_color.g, diff_g);
                add8(&new_color.b, diff_b);
            } else if (hasPrefix(byte, u2, 0b10)) { // QOI_OP_LUMA

                const diff_rg_rb = try self.reader.readByte();
                const diff_rg = unmapRange4(diff_rg_rb >> 4);
                const diff_rb = unmapRange4(diff_rg_rb >> 0);

                const diff_g = unmapRange6(byte);
                const diff_r = @as(i8, diff_g) + diff_rg;
                const diff_b = @as(i8, diff_g) + diff_rb;

                add8(&new_color.r, diff_r);
                add8(&new_color.g, diff_g);
                add8(&new_color.b, diff_b);
            } else if (hasPrefix(byte, u2, 0b11)) { // QOI_OP_RUN
                count = @as(usize, @as(u6, @truncate(byte))) + 1;
                std.debug.assert(count >= 1 and count <= 62);
            } else {
                // we have covered all possibilities.
                unreachable;
            }

            self.color_lut[new_color.hash()] = new_color;
            self.current_color = new_color;

            return ColorRun{ .color = new_color, .length = count };
        }
    };
}

fn mapRange2(val: i16) u8 {
    return @as(u2, @truncate(@as(u16, @intCast(val + 2))));
}
fn mapRange4(val: i16) u8 {
    return @as(u4, @truncate(@as(u16, @intCast(val + 8))));
}
fn mapRange6(val: i16) u8 {
    return @as(u6, @truncate(@as(u16, @intCast(val + 32))));
}

fn unmapRange2(val: u32) i2 {
    return @as(i2, @intCast(@as(i8, @as(u2, @truncate(val))) - 2));
}
fn unmapRange4(val: u32) i4 {
    return @as(i4, @intCast(@as(i8, @as(u4, @truncate(val))) - 8));
}
fn unmapRange6(val: u32) i6 {
    return @as(i6, @intCast(@as(i8, @as(u6, @truncate(val))) - 32));
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
    dst.* +%= @bitCast(diff);
}

fn hasPrefix(value: u8, comptime T: type, prefix: T) bool {
    return @as(T, @truncate(value >> (8 - @bitSizeOf(T)))) == prefix;
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
            .width = std.mem.readInt(u32, buffer[4..8], .big),
            .height = std.mem.readInt(u32, buffer[8..12], .big),
            .format = try std.meta.intToEnum(Format, buffer[12]),
            .colorspace = try std.meta.intToEnum(Colorspace, buffer[13]),
        };
    }

    fn encode(header: Header) [size]u8 {
        var result: [size]u8 = undefined;
        std.mem.copy(u8, result[0..4], &correct_magic);
        std.mem.writeInt(u32, result[4..8], header.width, .big);
        std.mem.writeInt(u32, result[8..12], header.height, .big);
        result[12] = @intFromEnum(header.format);
        result[13] = @intFromEnum(header.colorspace);
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
    const src_data = @embedFile("data/zero.qoi");

    var image = try decodeBuffer(std.testing.allocator, src_data);
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 512), image.width);
    try std.testing.expectEqual(@as(u32, 512), image.height);
    try std.testing.expectEqual(@as(usize, 512 * 512), image.pixels.len);

    const dst_data = @embedFile("data/zero.raw");
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

    const dst_data = @embedFile("data/zero.raw");
    try std.testing.expectEqualSlices(u8, dst_data, std.mem.sliceAsBytes(image.pixels));
}

test "encode qoi" {
    const src_data = @embedFile("data/zero.raw");

    var dst_data = try encodeBuffer(std.testing.allocator, ConstImage{
        .width = 512,
        .height = 512,
        .pixels = std.mem.bytesAsSlice(Color, src_data),
        .colorspace = .sRGB,
    });
    defer std.testing.allocator.free(dst_data);

    const ref_data = @embedFile("data/zero.qoi");
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

        var image_or_err = decodeStream(std.testing.allocator, stream.reader());
        if (image_or_err) |*image| {
            defer image.deinit(std.testing.allocator);
        } else |err| {
            // error is also okay, just no crashes plz
            err catch {};
        }
    }
}
