const std = @import("std");
const qoi = @import("qoi.zig");

const total_rounds = 4096;

pub fn main() !void {
    try perform(true);
    try perform(false);
}

fn perform(comptime test_encoder: bool) !void {
    const allocator = std.heap.c_allocator;

    const source_data = @embedFile("../data/zero.qoi");
    const ref_data = @embedFile("../data/zero.raw");

    var progress = std.Progress{};

    const benchmark = try progress.start("Benchmark", total_rounds);

    var total_time: u64 = 0;

    var rounds: usize = total_rounds;
    while (rounds > 0) {
        rounds -= 1;

        var start_point: i128 = undefined;
        var end_point: i128 = undefined;

        if (test_encoder) {
            start_point = std.time.nanoTimestamp();

            const memory = try qoi.encodeBuffer(allocator, qoi.ConstImage{
                .width = 512,
                .height = 512,
                .pixels = std.mem.bytesAsSlice(qoi.Color, ref_data),
                .colorspace = .sRGB,
            });
            defer allocator.free(memory);

            end_point = std.time.nanoTimestamp();

            if (!std.mem.eql(u8, source_data, memory))
                return error.EncodingError;
        } else {
            start_point = std.time.nanoTimestamp();

            var image = try qoi.decodeBuffer(allocator, source_data);
            defer image.deinit(allocator);

            end_point = std.time.nanoTimestamp();

            if (image.width != 512 or image.height != 512)
                return error.DecodingError;

            if (!std.mem.eql(u8, ref_data, std.mem.sliceAsBytes(image.pixels)))
                return error.DecodingError;
        }

        total_time += @intCast(u64, end_point - start_point);

        benchmark.completeOne();
    }

    if (test_encoder) {
        std.debug.print("Encoding time for {} => {} bytes: {}\n", .{
            ref_data.len,
            source_data.len,
            std.fmt.fmtDuration(total_time / total_rounds),
        });
    } else {
        std.debug.print("Decoding time for {} => {} bytes: {}\n", .{
            source_data.len,
            ref_data.len,
            std.fmt.fmtDuration(total_time / total_rounds),
        });
    }
}
