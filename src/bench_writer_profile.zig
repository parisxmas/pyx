//! Write-only profile target. Runs for `--secs` seconds doing back-to-back
//! batched inserts (each batch = WRITER_BATCH docs in one txn). No
//! readers, no warmup. Designed to be sampled by macOS `sample(1)` or
//! Instruments to attribute writer cost to specific code paths.
//!
//! Usage:
//!   zig build bench-writer-profile -Doptimize=ReleaseFast
//!   ./zig-out/bin/pyx-bench-writer-profile &
//!   sample $! 5 -file /tmp/pyx-writer.sample
//!   wait
//!   less /tmp/pyx-writer.sample

const std = @import("std");
const Io = std.Io;
const pyx = @import("pyx");
const Builder = pyx.doc.Builder;
const Db = pyx.db.Db;

const WRITER_BATCH: u32 = 100;
const RUN_SECS: u64 = 8;

fn nowNs(io: Io) u64 {
    const ts = Io.Clock.Timestamp.now(io, .awake);
    return @intCast(ts.raw.toNanoseconds());
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    const ally = std.heap.c_allocator;

    var tmp_dir = try Io.Dir.cwd().createDirPathOpen(io, ".bench-tmp", .{});
    defer tmp_dir.close(io);
    tmp_dir.deleteFile(io, "writer_profile.db") catch {};
    tmp_dir.deleteFile(io, "writer_profile.db.wal") catch {};

    var db = try Db.open(ally, io, tmp_dir, "writer_profile.db");
    defer db.close();
    db.setSyncMode(.normal);

    const c = db.collection("docs");
    const deadline = nowNs(io) + RUN_SECS * std.time.ns_per_s;

    // Per-phase counters. Lightweight enough that ReleaseFast inlining
    // shouldn't completely warp the result; we only call nowNs around
    // coarse phase boundaries (whole txn, not per-insert).
    var ns_begin: u64 = 0;
    var ns_build: u64 = 0;
    var ns_insert: u64 = 0;
    var ns_commit: u64 = 0;
    var inserts: u64 = 0;
    var commits: u64 = 0;

    try out.print("pid={d}  pyx writer profile target — {d} secs, batch={d}\n", .{
        std.posix.system.getpid(),
        RUN_SECS, WRITER_BATCH,
    });
    try out.flush();

    while (nowNs(io) < deadline) {
        const t0 = nowNs(io);
        try db.begin();
        const t1 = nowNs(io);

        var i: u32 = 0;
        var name_buf: [32]u8 = undefined;

        // Build phase: encode the doc bytes.
        var build_acc: u64 = 0;
        var insert_acc: u64 = 0;

        while (i < WRITER_BATCH) : (i += 1) {
            const tb0 = nowNs(io);
            var b = Builder.init(ally);
            defer b.deinit();
            try b.beginDocument();
            try b.putString("name", try std.fmt.bufPrint(&name_buf, "w-{d}", .{inserts + i}));
            try b.putI64("count", @intCast(inserts + i));
            try b.endDocument();
            const bytes = try b.finish();
            const tb1 = nowNs(io);
            build_acc += tb1 - tb0;

            const ti0 = nowNs(io);
            _ = try c.insert(bytes);
            ally.free(bytes);
            const ti1 = nowNs(io);
            insert_acc += ti1 - ti0;
        }

        const t2 = nowNs(io);
        try db.commit();
        const t3 = nowNs(io);

        ns_begin += t1 - t0;
        ns_build += build_acc;
        ns_insert += insert_acc;
        ns_commit += t3 - t2;
        inserts += WRITER_BATCH;
        commits += 1;
    }

    const total_ns = ns_begin + ns_build + ns_insert + ns_commit;
    try out.print("\n--- writer phase breakdown ---\n", .{});
    try out.print("inserts: {d}  commits: {d}  total accounted: {d:.2}s\n", .{
        inserts, commits, @as(f64, @floatFromInt(total_ns)) / 1e9,
    });
    try out.print("{s:<14} {s:>14} {s:>14} {s:>10}\n", .{ "phase", "total ns", "ns/op", "% of total" });
    const phases = [_]struct { name: []const u8, ns: u64, per: u64 }{
        .{ .name = "begin",  .ns = ns_begin,  .per = commits },
        .{ .name = "build",  .ns = ns_build,  .per = inserts },
        .{ .name = "insert", .ns = ns_insert, .per = inserts },
        .{ .name = "commit", .ns = ns_commit, .per = commits },
    };
    for (phases) |p| {
        const per = if (p.per == 0) 0 else p.ns / p.per;
        const pct = if (total_ns == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(p.ns)) / @as(f64, @floatFromInt(total_ns));
        try out.print("{s:<14} {d:>14} {d:>14} {d:>9.1}%\n", .{ p.name, p.ns, per, pct });
    }
    try out.print("aggregate: {d:.0} inserts/s\n", .{
        @as(f64, @floatFromInt(inserts)) * 1e9 / @as(f64, @floatFromInt(total_ns)),
    });
    try out.flush();
}
