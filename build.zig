const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimization = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const converter = b.addExecutable(.{
        .name = "qoi-convert",
        .root_source_file = b.path("src/convert.zig"),
        .target = target,
        .optimize = optimization,
    });

    const args = b.addModule("args", .{ .root_source_file = b.path("vendor/zig-args/args.zig") });
    const qoi = b.addModule("qoi", .{ .root_source_file = b.path("src/qoi.zig") });
    const img = b.addModule("img", .{ .root_source_file = b.path("vendor/zigimg/zigimg.zig") });
    converter.root_module.addImport("args", args);
    converter.root_module.addImport("qoi", qoi);
    converter.root_module.addImport("img", img);
    b.installArtifact(converter);

    var benchmark = b.addExecutable(.{
        .name = "qoi-bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimization,
    });

    const argsb = b.addModule("args", .{ .root_source_file = b.path("vendor/zig-args/args.zig") });
    benchmark.root_module.addImport("args", argsb);
    benchmark.linkLibC();
    b.installArtifact(benchmark);

    var benchmark_files = b.addExecutable(.{
        .name = "qoi-bench-files",
        .root_source_file = b.path("src/bench-files.zig"),
        .target = target,
        .optimize = optimization,
    });
    const bfargs = b.addModule("args", .{ .root_source_file = b.path("vendor/zig-args/args.zig") });
    const bfqoi = b.addModule("qoi", .{ .root_source_file = b.path("src/qoi.zig") });
    const bfimg = b.addModule("img", .{ .root_source_file = b.path("vendor/zigimg/zigimg.zig") });
    benchmark_files.root_module.addImport("args", bfargs);
    benchmark_files.root_module.addImport("qoi", bfqoi);
    benchmark_files.root_module.addImport("img", bfimg);
    benchmark_files.linkLibC();
    b.installArtifact(benchmark_files);

    const test_step = b.step("test", "Runs the test suite.");
    {
        const test_runner = b.addTest(.{
            .root_source_file = b.path("src/qoi.zig"),
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
