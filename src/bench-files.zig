const std = @import("std");
const args_parser = @import("args");
const zigimg = @import("img");
const qoi = @import("qoi.zig");

const total_rounds = 8;

pub fn main() !u8 {
    const allocator = std.heap.c_allocator; // for perf

    var cli = args_parser.parseForCurrentProcess(struct {}, allocator, .print) catch return 1;
    defer cli.deinit();

    var total_raw_size: u64 = 0;
    var total_png_size: u64 = 0;
    var total_qoi_size: u64 = 0;

    var total_decode_time: u64 = 0;
    var total_encode_time: u64 = 0;

    std.debug.print(
        "File Name\tWidth\tHeight\tTotal Raw Bytes\tTotal PNG Bytes\tPNG Compression\tTotal QOI Bytes\tQOI Compression\tQOI to PNG\tDecode Time (ns)\tEncode Time (ns)\n",
        .{},
    );

    for (cli.positionals) |folder_name| {
        var folder = try std.fs.cwd().openIterableDir(folder_name, .{ .access_sub_paths = true });
        defer folder.close();

        var iterator = folder.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) {
                continue;
            }

            const ext = std.fs.path.extension(entry.name);
            if (!std.mem.eql(u8, ext, ".png"))
                continue;

            var file = try folder.dir.openFile(entry.name, .{});
            defer file.close();

            const png_size = (try file.stat()).size;

            var raw_image = try zigimg.Image.fromFile(allocator, &file);
            defer raw_image.deinit();

            var image = qoi.Image{
                .width = std.math.cast(u32, raw_image.width) orelse return error.Overflow,
                .height = std.math.cast(u32, raw_image.height) orelse return error.Overflow,
                .colorspace = .sRGB,
                .pixels = try allocator.alloc(qoi.Color, raw_image.width * raw_image.height),
            };
            defer image.deinit(allocator);
            {
                var index: usize = 0;
                var pixels = raw_image.iterator();
                while (pixels.next()) |pix| {
                    const rgba8 = pix.toRgba32();
                    image.pixels[index] = .{
                        .r = rgba8.r,
                        .g = rgba8.g,
                        .b = rgba8.b,
                        .a = rgba8.a,
                    };
                    index += 1;
                }
                std.debug.assert(image.pixels.len == index);
            }

            const reference_qoi = try qoi.encodeBuffer(allocator, image.asConst());
            defer allocator.free(reference_qoi);

            const decode_time = try performBenchmark(false, reference_qoi, image.asConst());
            const encode_time = try performBenchmark(true, reference_qoi, image.asConst());

            const raw_size = @sizeOf(qoi.Color) * image.pixels.len;
            const qoi_size = reference_qoi.len;

            total_raw_size += raw_size;
            total_qoi_size += qoi_size;
            total_png_size += png_size;

            total_decode_time += decode_time;
            total_encode_time += encode_time;

            const png_rel_size = @as(f32, @floatFromInt(png_size)) / @as(f32, @floatFromInt(raw_size));
            const qoi_rel_size = @as(f32, @floatFromInt(qoi_size)) / @as(f32, @floatFromInt(raw_size));

            const png_to_qoi_diff = qoi_rel_size / png_rel_size;

            std.debug.print("{s}/{s}\t{}\t{}\t{}\t{}\t{d:3.2}\t{}\t{d:3.2}\t{d}\t{}\t{}\n", .{
                folder_name,
                entry.name,
                image.width,
                image.height,
                raw_size,
                png_size,
                png_rel_size,
                qoi_size,
                qoi_rel_size,
                png_to_qoi_diff,
                decode_time,
                encode_time,
            });
        }
    }

    std.debug.print("total sum\t0\t0\t{}\t{}\t{d:3.2}\t{}\t{d:3.2}\t{d}\t{}\t{}\n", .{
        total_raw_size,
        total_png_size,
        @as(f32, @floatFromInt(total_png_size)) / @as(f32, @floatFromInt(total_raw_size)),
        total_qoi_size,
        @as(f32, @floatFromInt(total_qoi_size)) / @as(f32, @floatFromInt(total_raw_size)),
        @as(f32, @floatFromInt(total_qoi_size)) / @as(f32, @floatFromInt(total_png_size)),
        total_decode_time,
        total_encode_time,
    });

    return 0;
}

fn performBenchmark(comptime test_encoder: bool, qoi_data: []const u8, reference_image: qoi.ConstImage) !u64 {
    const allocator = std.heap.c_allocator;

    var total_time: u64 = 0;

    var rounds: usize = total_rounds;
    while (rounds > 0) {
        rounds -= 1;

        var start_point: i128 = undefined;
        var end_point: i128 = undefined;

        if (test_encoder) {
            start_point = std.time.nanoTimestamp();

            const memory = try qoi.encodeBuffer(allocator, reference_image);
            defer allocator.free(memory);

            end_point = std.time.nanoTimestamp();

            if (!std.mem.eql(u8, qoi_data, memory))
                return error.EncodingError;
        } else {
            start_point = std.time.nanoTimestamp();

            var image = try qoi.decodeBuffer(allocator, qoi_data);
            defer image.deinit(allocator);

            end_point = std.time.nanoTimestamp();

            if (image.width != reference_image.width or image.height != reference_image.height)
                return error.DecodingError;

            if (!std.mem.eql(u8, std.mem.sliceAsBytes(reference_image.pixels), std.mem.sliceAsBytes(image.pixels)))
                return error.DecodingError;
        }

        total_time += @as(u64, @intCast(end_point - start_point));
    }

    return total_time / total_rounds;
}
