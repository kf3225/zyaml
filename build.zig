const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("zyaml_lib", lib_mod);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zyaml",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);

    const c_api_optimize = std.builtin.OptimizeMode.ReleaseSafe;

    const c_api_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = c_api_optimize,
    });

    c_api_mod.addImport("root.zig", lib_mod);

    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zyaml",
        .root_module = c_api_mod,
    });
    shared_lib.linkLibC();

    b.installArtifact(shared_lib);

    const c_api_static_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = c_api_optimize,
    });

    c_api_static_mod.addImport("root.zig", lib_mod);

    const static_c_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zyaml_c",
        .root_module = c_api_static_mod,
    });
    static_c_lib.linkLibC();

    b.installArtifact(static_c_lib);

    const exe = b.addExecutable(.{
        .name = "zyaml",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);

    const yaml_spec_test_files = [_][]const u8{
        "src/test/yaml_spec/schemas.zig",
        "src/test/yaml_spec/edge_cases.zig",
        "src/test/yaml_spec/errors.zig",
    };

    inline for (yaml_spec_test_files) |test_file| {
        const spec_test_mod = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        spec_test_mod.addImport("zyaml", lib_mod);

        const spec_test = b.addTest(.{
            .root_module = spec_test_mod,
        });
        test_step.dependOn(&b.addRunArtifact(spec_test).step);
    }

    const fixture_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test/fixtures_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fixture_test_mod.addImport("zyaml", lib_mod);

    const fixture_test = b.addTest(.{
        .root_module = fixture_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(fixture_test).step);

    const suite_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test/yaml_test_suite.zig"),
        .target = target,
        .optimize = optimize,
    });
    suite_test_mod.addImport("zyaml", lib_mod);

    const suite_test = b.addTest(.{
        .root_module = suite_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(suite_test).step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("zyaml", lib_mod);

    const bench_exe = b.addExecutable(.{
        .name = "zyaml-bench",
        .root_module = bench_mod,
    });

    const bench_step = b.step("bench", "Run benchmarks");
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.step.dependOn(b.getInstallStep());
    bench_step.dependOn(&bench_run.step);
}
