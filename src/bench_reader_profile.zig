//! Read-only profile target. Preloads N docs, creates an index on
//! `count`, captures one frozen Snapshot (lock-free pread path), then
//! runs the same 75% random-get + 25% indexed-findOne mix as
//! `bench_concurrent.zig` for `RUN_SECS` seconds. Phase-level timing
//! buckets give a coarse split; attach `sample(1)` to the running PID
//! for stack-level attribution.
//!
//! Usage:
//!   zig build bench-reader-profile -Doptimize=ReleaseFast
//!   ./zig-out/bin/pyx-bench-reader-profile &
//!   sample $! 5 -file /tmp/pyx-reader.sample
//!   wait
//!   less /tmp/pyx-reader.sample

const std = @import("std");
const Io = std.Io;
const pyx = @import("pyx");
const Builder = pyx.doc.Builder;
const Db = pyx.db.Db;

const PRELOAD_N: u64 = 100_000;
const RUN_SECS: u64 = 8;
const REPORT_EVERY: u64 = 1024;

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
    tmp_dir.deleteFile(io, "reader_profile.db") catch {};
    tmp_dir.deleteFile(io, "reader_profile.db.wal") catch {};

    var db = try Db.open(ally, io, tmp_dir, "reader_profile.db");
    defer db.close();
    db.setSyncMode(.normal);

    // Preload — one big batched txn, then index, then checkpoint so the
    // page cache is empty at sample time and snapshot reads go to disk.
    {
        try db.begin();
        const c = db.collection("docs");
        var name_buf: [32]u8 = undefined;
        for (0..PRELOAD_N) |i| {
            var b = Builder.init(ally);
            defer b.deinit();
            try b.beginDocument();
            try b.putString("name", try std.fmt.bufPrint(&name_buf, "doc-{d}", .{i}));
            try b.putI64("count", @intCast(i));
            try b.endDocument();
            const bytes = try b.finish();
            defer ally.free(bytes);
            _ = try c.insert(bytes);
        }
        try db.commit();
        try db.createIndex("docs", "count");
        try db.checkpoint();
    }

    try out.print("pid={d}  pyx reader profile target — {d} secs, preload={d}\n", .{
        std.posix.system.getpid(),
        RUN_SECS, PRELOAD_N,
    });
    try out.flush();

    var snap = try db.snapshot();
    defer snap.deinit();
    const sc = snap.collection("docs");

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const r = prng.random();
    const deadline = nowNs(io) + RUN_SECS * std.time.ns_per_s;

    var get_ops: u64 = 0;
    var get_hits: u64 = 0;
    var get_ns: u64 = 0;
    var find_ops: u64 = 0;
    var find_hits: u64 = 0;
    var find_ns: u64 = 0;
    var loop_iters: u64 = 0;

    while (true) {
        if (loop_iters & (REPORT_EVERY - 1) == 0 and nowNs(io) >= deadline) break;
        if (r.uintLessThan(u32, 4) == 0) {
            // 25% indexed findOne — exercises the secondary B+tree.
            const target = r.uintLessThan(u64, PRELOAD_N);
            const t0 = nowNs(io);
            const found = sc.findOne("count", .{ .i64 = @intCast(target) }) catch null;
            find_ns += nowNs(io) - t0;
            find_ops += 1;
            if (found) |_| find_hits += 1;
        } else {
            // 75% random get-by-id — exercises the primary B+tree only.
            const id = r.uintLessThan(u64, PRELOAD_N) + 1;
            const t0 = nowNs(io);
            const got = sc.get(ally, id) catch null;
            get_ns += nowNs(io) - t0;
            if (got) |buf| {
                get_hits += 1;
                ally.free(buf);
            }
            get_ops += 1;
        }
        loop_iters += 1;
    }

    const total_ns = get_ns + find_ns;
    try out.print("\n--- reader phase breakdown ---\n", .{});
    try out.print("get   ops: {d:>8}  hits: {d:>8}  ns total: {d:>14}  ns/op: {d:>8}  ({d:.0} ops/s)\n", .{
        get_ops, get_hits, get_ns,
        if (get_ops == 0) 0 else get_ns / get_ops,
        @as(f64, @floatFromInt(get_ops)) * 1e9 / @as(f64, @floatFromInt(@max(get_ns, 1))),
    });
    try out.print("find  ops: {d:>8}  hits: {d:>8}  ns total: {d:>14}  ns/op: {d:>8}  ({d:.0} ops/s)\n", .{
        find_ops, find_hits, find_ns,
        if (find_ops == 0) 0 else find_ns / find_ops,
        @as(f64, @floatFromInt(find_ops)) * 1e9 / @as(f64, @floatFromInt(@max(find_ns, 1))),
    });
    try out.print("aggregate: {d} ops in {d:.2}s ({d:.0} ops/s)\n", .{
        get_ops + find_ops,
        @as(f64, @floatFromInt(total_ns)) / 1e9,
        @as(f64, @floatFromInt(get_ops + find_ops)) * 1e9 / @as(f64, @floatFromInt(@max(total_ns, 1))),
    });
    try out.flush();
}
