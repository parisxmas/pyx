const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("pyx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "pyx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pyx", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Benchmark binary.
    const bench = b.addExecutable(.{
        .name = "pyx-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "pyx", .module = mod },
            },
        }),
    });
    b.installArtifact(bench);
    const bench_cmd = b.addRunArtifact(bench);
    bench_cmd.step.dependOn(b.getInstallStep());
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);

    // Static library — what an embedder ships when linking pyx into an
    // iOS app, an Android NDK lib, a Python C-extension, etc. The C ABI
    // surface lives in src/c_api.zig and is what forces the linker to
    // keep the whole engine alive.
    const c_api_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "pyx", .module = mod }},
    });
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "pyx",
        .root_module = c_api_mod,
    });
    b.installArtifact(lib);
    // Dynamic library for runtime loaders (ctypes, cffi, dlopen).
    const dylib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "pyx",
        .root_module = c_api_mod,
    });
    b.installArtifact(dylib);
    b.installFile("include/pyx.h", "include/pyx.h");

    // C-ABI tests.
    const c_api_tests = b.addTest(.{ .root_module = c_api_mod });
    const run_c_api_tests = b.addRunArtifact(c_api_tests);
    test_step.dependOn(&run_c_api_tests.step);

    // SQLite benchmark for comparison.
    const bench_sqlite = b.addExecutable(.{
        .name = "pyx-bench-sqlite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_sqlite.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench_sqlite.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/Cellar/sqlite/3.53.0/include" });
    bench_sqlite.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/Cellar/sqlite/3.53.0/lib" });
    bench_sqlite.root_module.linkSystemLibrary("sqlite3", .{});
    bench_sqlite.root_module.link_libc = true;
    b.installArtifact(bench_sqlite);
    const bench_sqlite_cmd = b.addRunArtifact(bench_sqlite);
    bench_sqlite_cmd.step.dependOn(b.getInstallStep());
    const bench_sqlite_step = b.step("bench-sqlite", "Run SQLite comparison benchmark");
    bench_sqlite_step.dependOn(&bench_sqlite_cmd.step);

    // Concurrent reader/writer harness for pyx.
    const bench_conc = b.addExecutable(.{
        .name = "pyx-bench-concurrent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_concurrent.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "pyx", .module = mod }},
        }),
    });
    b.installArtifact(bench_conc);
    const bench_conc_cmd = b.addRunArtifact(bench_conc);
    bench_conc_cmd.step.dependOn(b.getInstallStep());
    const bench_conc_step = b.step("bench-concurrent", "Run concurrent reader/writer benchmark");
    bench_conc_step.dependOn(&bench_conc_cmd.step);

    // Write-only profile target (for use with macOS sample(1) / Instruments).
    const bench_wp = b.addExecutable(.{
        .name = "pyx-bench-writer-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_writer_profile.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "pyx", .module = mod }},
        }),
    });
    b.installArtifact(bench_wp);
    const bench_wp_cmd = b.addRunArtifact(bench_wp);
    bench_wp_cmd.step.dependOn(b.getInstallStep());
    const bench_wp_step = b.step("bench-writer-profile", "Run write-only profile target");
    bench_wp_step.dependOn(&bench_wp_cmd.step);

    // Read-only profile target.
    const bench_rp = b.addExecutable(.{
        .name = "pyx-bench-reader-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_reader_profile.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "pyx", .module = mod }},
        }),
    });
    b.installArtifact(bench_rp);
    const bench_rp_cmd = b.addRunArtifact(bench_rp);
    bench_rp_cmd.step.dependOn(b.getInstallStep());
    const bench_rp_step = b.step("bench-reader-profile", "Run read-only profile target");
    bench_rp_step.dependOn(&bench_rp_cmd.step);

    // Concurrent reader/writer harness for SQLite (WAL + NORMAL).
    const bench_conc_sqlite = b.addExecutable(.{
        .name = "pyx-bench-concurrent-sqlite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_concurrent_sqlite.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench_conc_sqlite.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/Cellar/sqlite/3.53.0/include" });
    bench_conc_sqlite.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/Cellar/sqlite/3.53.0/lib" });
    bench_conc_sqlite.root_module.linkSystemLibrary("sqlite3", .{});
    bench_conc_sqlite.root_module.link_libc = true;
    b.installArtifact(bench_conc_sqlite);
    const bench_conc_sqlite_cmd = b.addRunArtifact(bench_conc_sqlite);
    bench_conc_sqlite_cmd.step.dependOn(b.getInstallStep());
    const bench_conc_sqlite_step = b.step("bench-concurrent-sqlite", "Run SQLite concurrent benchmark");
    bench_conc_sqlite_step.dependOn(&bench_conc_sqlite_cmd.step);
}
