const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const converter = b.addExecutable("qoi-convert", "src/convert.zig");
    converter.setBuildMode(mode);
    converter.setTarget(target);
    converter.addPackage(.{
        .name = "args",
        .path = .{ .path = "vendor/zig-args/args.zig" },
    });
    converter.addPackage(.{
        .name = "qoi",
        .path = .{ .path = "src/qoi.zig" },
    });
    converter.addPackage(.{
        .name = "img",
        .path = .{ .path = "vendor/zigimg/zigimg.zig" },
    });
    converter.install();

    const benchmark = b.addExecutable("qoi-bench", "src/bench.zig");
    benchmark.setBuildMode(mode);
    benchmark.setTarget(target);
    benchmark.addPackage(.{
        .name = "args",
        .path = .{ .path = "vendor/zig-args/args.zig" },
    });
    benchmark.addPackage(.{
        .name = "qoi",
        .path = .{ .path = "src/qoi.zig" },
    });
    benchmark.addPackage(.{
        .name = "img",
        .path = .{ .path = "vendor/zigimg/zigimg.zig" },
    });
    benchmark.linkLibC();
    benchmark.install();

    const test_step = b.step("test", "Runs the test suite.");
    {
        const test_runner = b.addTest("src/qoi.zig");
        test_runner.setBuildMode(mode);
        test_step.dependOn(&test_runner.step);
    }

    const benchmark_step = b.step("benchmark", "Runs the benchmark.");
    {
        const runner = benchmark.run();

        benchmark_step.dependOn(&runner.step);
    }
}
