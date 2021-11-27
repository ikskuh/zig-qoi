const std = @import("std");
const args_parser = @import("args");
const img = @import("img");
const qoi = @import("qoi");

const Cli = struct {
    help: bool = false,
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;

    var cli = args_parser.parseForCurrentProcess(Cli, allocator, .print) catch return 1;
    defer cli.deinit();

    if (cli.positionals.len != 2) {
        return 1;
    }

    const in_path = cli.positionals[0];
    const out_path = cli.positionals[1];

    const in_ext = std.fs.path.extension(in_path);
    const out_ext = std.fs.path.extension(out_path);

    var image = if (std.mem.eql(u8, in_ext, ".qoi")) blk: {
        var file = try std.fs.cwd().openFile(in_path, .{});
        defer file.close();

        var buffered_stream = std.io.bufferedReader(file.reader());

        break :blk try qoi.decodeStream(allocator, buffered_stream.reader());
    } else blk: {
        var file = try img.Image.fromFilePath(allocator, in_path);
        defer file.deinit();

        var image = qoi.Image{
            .width = try std.math.cast(u32, file.width),
            .height = try std.math.cast(u32, file.height),
            .colorspace = .sRGB,
            .pixels = try allocator.alloc(qoi.Color, file.width * file.height),
        };
        errdefer image.deinit(allocator);

        var iter = file.iterator();
        var index: usize = 0;
        while (iter.next()) |color| : (index += 1) {
            const src_pix = color.toIntegerColor8();
            image.pixels[index] = .{
                .r = src_pix.R,
                .g = src_pix.G,
                .b = src_pix.B,
                .a = src_pix.A,
            };
        }

        break :blk image;
    };
    defer image.deinit(allocator);

    var file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();

    if (std.mem.eql(u8, out_ext, ".qoi")) {
        const buffer = try qoi.encodeBuffer(allocator, image.asConst());
        defer allocator.free(buffer);

        try file.writeAll(buffer);
    } else if (std.mem.eql(u8, out_ext, ".ppm")) { // portable pixmap
        // https://en.wikipedia.org/wiki/Netpbm#PPM_example
        try file.writer().print("P6 {} {} 255\n", .{ image.width, image.height });
        for (image.pixels) |pix| {
            try file.writeAll(&[_]u8{
                pix.r, pix.g, pix.b,
            });
        }
    } else if (std.mem.eql(u8, out_ext, ".pam")) { // portable anymap
        // https://en.wikipedia.org/wiki/Netpbm#PAM_graphics_format
        try file.writer().print(
            \\P7
            \\WIDTH {}
            \\HEIGHT {}
            \\DEPTH 4
            \\MAXVAL 255
            \\TUPLTYPE RGB_ALPHA
            \\ENDHDR
            \\
        , .{ image.width, image.height });

        try file.writeAll(std.mem.sliceAsBytes(image.pixels));
    } else { // fallback impl
        var zigimg = img.Image{
            .allocator = undefined,
            .width = image.width,
            .height = image.height,
            .pixels = img.color.ColorStorage{
                .Rgba32 = @ptrCast([*]img.color.Rgba32, image.pixels.ptr)[0..image.pixels.len],
            },
        };

        const fmt = if (std.ascii.eqlIgnoreCase(out_ext, ".bmp"))
            img.ImageFormat.Bmp
        else if (std.ascii.eqlIgnoreCase(out_ext, ".pbm"))
            img.ImageFormat.Pbm
        else if (std.ascii.eqlIgnoreCase(out_ext, ".pcx"))
            img.ImageFormat.Pcx
        else if (std.ascii.eqlIgnoreCase(out_ext, ".pgm"))
            img.ImageFormat.Pgm
        else if (std.ascii.eqlIgnoreCase(out_ext, ".png"))
            img.ImageFormat.Png
        else if (std.ascii.eqlIgnoreCase(out_ext, ".ppm"))
            img.ImageFormat.Ppm
        else if (std.ascii.eqlIgnoreCase(out_ext, ".raw"))
            img.ImageFormat.Raw
        else if (std.ascii.eqlIgnoreCase(out_ext, ".tga"))
            img.ImageFormat.Tga
        else
            return error.UnknownFormat;

        try zigimg.writeToFile(&file, fmt, img.AllFormats.ImageEncoderOptions.None);
    }

    return 0;
}
