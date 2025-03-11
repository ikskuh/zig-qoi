const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimization = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const qoi = b.addModule("qoi", .{
        .root_source_file = b.path("src/qoi.zig"),
        .target = target,
        .optimize = optimization,
    });
    const args = b.dependency("args", .{}).module("args");
    const img = b.dependency("img", .{}).module("zigimg");

    const test_step = b.step("test", "Run the test suite");
    const unit_tests = b.addTest(.{ .root_module = qoi });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const converter = b.addExecutable(.{
        .name = "qoi-convert",
        .root_source_file = b.path("src/convert.zig"),
        .target = target,
        .optimize = optimization,
    });

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
    benchmark.root_module.addImport("args", args);
    benchmark.linkLibC();

    var benchmark_files = b.addExecutable(.{
        .name = "qoi-bench-files",
        .root_source_file = b.path("src/bench-files.zig"),
        .target = target,
        .optimize = optimization,
    });
    benchmark_files.root_module.addImport("args", args);
    benchmark_files.root_module.addImport("qoi", qoi);
    benchmark_files.root_module.addImport("img", img);
    benchmark_files.linkLibC();

    const benchmark_step = b.step("benchmark", "Copy benchmark artifacts to prefix path");
    benchmark_step.dependOn(&b.addInstallArtifact(benchmark, .{}).step);
    benchmark_step.dependOn(&b.addInstallArtifact(benchmark_files, .{}).step);
    const run_benchmark_step = b.step("run-benchmark", "Run the benchmark");
    run_benchmark_step.dependOn(&b.addRunArtifact(benchmark).step);
}
