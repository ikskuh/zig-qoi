const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const optimization = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    var converter = b.addExecutable(.{
        .name = "qoi-convert",
        .root_source_file = .{ .path = "src/convert.zig" },
        .target = target,
        .optimize = optimization,
    });

    converter.addAnonymousModule("args", .{ .source_file = .{ .path = "vendor/zig-args/args.zig" } });
    converter.addAnonymousModule("qoi", .{ .source_file = .{ .path = "src/qoi.zig" } });
    converter.addAnonymousModule("img", .{ .source_file = .{ .path = "vendor/zigimg/zigimg.zig" } });
    b.installArtifact(converter);

    var benchmark = b.addExecutable(.{
        .name = "qoi-bench",
        .root_source_file = .{ .path = "src/bench.zig" },
        .target = target,
        .optimize = optimization,
    });

    benchmark.addAnonymousModule("args", .{ .source_file = .{ .path = "vendor/zig-args/args.zig" } });
    benchmark.linkLibC();
    b.installArtifact(benchmark);

    var benchmark_files = b.addExecutable(.{
        .name = "qoi-bench-files",
        .root_source_file = .{ .path = "src/bench-files.zig" },
        .target = target,
        .optimize = optimization,
    });
    benchmark_files.addAnonymousModule("args", .{ .source_file = .{ .path = "vendor/zig-args/args.zig" } });
    benchmark_files.addAnonymousModule("qoi", .{ .source_file = .{ .path = "src/qoi.zig" } });
    benchmark_files.addAnonymousModule("img", .{ .source_file = .{ .path = "vendor/zigimg/zigimg.zig" } });
    benchmark_files.linkLibC();
    b.installArtifact(benchmark_files);

    const test_step = b.step("test", "Runs the test suite.");
    {
        const test_runner = b.addTest(.{
            .root_source_file = .{ .path = "src/qoi.zig" },
            .target = target,
            .optimize = optimization,
        });
        test_step.dependOn(&test_runner.step);
    }

    const benchmark_step = b.step("benchmark", "Runs the benchmark.");
    {
        const runner = b.addRunArtifact(benchmark);
        benchmark_step.dependOn(&runner.step);
    }
}
