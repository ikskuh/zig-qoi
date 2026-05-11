const std = @import("std");
const qoi = @import("qoi.zig");

const total_rounds = 4096;

pub fn main(init: std.process.Init) !void {
    const progress = std.Progress.start(init.io, .{});
    try perform(true, init.io, progress);
    try perform(false, init.io, progress);
}

fn perform(comptime test_encoder: bool, io: std.Io, progress: std.Progress.Node) !void {
    const allocator = std.heap.c_allocator;

    const source_data = @embedFile("data/zero.qoi");
    const ref_data = @embedFile("data/zero.raw");

    const benchmark = progress.start("Benchmark", total_rounds);

    var total_time: u64 = 0;

    var rounds: usize = total_rounds;
    while (rounds > 0) {
        rounds -= 1;

        var start_point: std.Io.Timestamp = undefined;
        var end_point: std.Io.Timestamp = undefined;

        if (test_encoder) {
            start_point = .now(io, .real);

            const memory = try qoi.encodeBuffer(allocator, qoi.ConstImage{
                .width = 512,
                .height = 512,
                .pixels = std.mem.bytesAsSlice(qoi.Color, ref_data),
                .colorspace = .sRGB,
            });
            defer allocator.free(memory);

            end_point = .now(io, .real);

            if (!std.mem.eql(u8, source_data, memory))
                return error.EncodingError;
        } else {
            start_point = .now(io, .real);

            var image = try qoi.decodeBuffer(allocator, source_data);
            defer image.deinit(allocator);

            end_point = .now(io, .real);

            if (image.width != 512 or image.height != 512)
                return error.DecodingError;

            if (!std.mem.eql(u8, ref_data, std.mem.sliceAsBytes(image.pixels)))
                return error.DecodingError;
        }

        total_time += @intCast(start_point.durationTo(end_point).toNanoseconds());

        benchmark.completeOne();
    }

    if (test_encoder) {
        std.debug.print("Encoding time for {} => {} bytes: {f}\n", .{
            ref_data.len,
            source_data.len,
            std.Io.Duration.fromNanoseconds(total_time / total_rounds),
        });
    } else {
        std.debug.print("Decoding time for {} => {} bytes: {f}\n", .{
            source_data.len,
            ref_data.len,
            std.Io.Duration.fromNanoseconds(total_time / total_rounds),
        });
    }
}
