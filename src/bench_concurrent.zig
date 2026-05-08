//! Concurrent reader/writer harness for pyx.
//!
//! Phase A — read-only scaling.
//!   For R in {1, 2, 4, 8}: spawn R reader threads, each holding its own
//!   Snapshot captured at thread start. Frozen-snapshot semantics — no
//!   refresh during the run, so reads stay on the lock-free pread path.
//!   Workload mix: 75% random get-by-id, 25% indexed point query.
//!
//! Phase B — 1 writer + R readers.
//!   One writer thread doing batched inserts (BATCH per txn) plus R
//!   reader threads doing the same workload as phase A. Frozen
//!   snapshots; readers see the state at thread start, writer keeps
//!   appending.
//!
//! All threads run for SECS_PHASE wall-clock seconds and report
//! aggregate ops/sec. Run: `zig build bench-concurrent -Doptimize=ReleaseFast`.

const std = @import("std");
const Io = std.Io;
const pyx = @import("pyx");
const Builder = pyx.doc.Builder;
const Db = pyx.db.Db;

const PRELOAD_N: u64 = 100_000;
const SECS_PHASE: u64 = 3;
const WRITER_BATCH: u32 = 100;

fn nowNs(io: Io) u64 {
    const ts = Io.Clock.Timestamp.now(io, .awake);
    return @intCast(ts.raw.toNanoseconds());
}

fn opsPerSec(ops: u64, ns: u64) f64 {
    return @as(f64, @floatFromInt(ops)) * @as(f64, @floatFromInt(std.time.ns_per_s)) / @as(f64, @floatFromInt(ns));
}

const ReaderCtx = struct {
    db: *Db,
    deadline_ns: u64,
    rng_seed: u64,
    io: Io,
    out_ops: *u64,
};

fn readerLoop(ctx: *ReaderCtx) void {
    var prng = std.Random.DefaultPrng.init(ctx.rng_seed);
    const r = prng.random();
    const ally = std.heap.c_allocator;
    var snap = ctx.db.snapshot() catch |e| {
        std.debug.print("snapshot capture failed: {s}\n", .{@errorName(e)});
        return;
    };
    defer snap.deinit();
    const sc = snap.collection("docs");
    var ops: u64 = 0;
    while (true) {
        // Cheap deadline check — clock_gettime every 1024 ops is plenty.
        if (ops & 1023 == 0 and nowNs(ctx.io) >= ctx.deadline_ns) break;
        if (r.uintLessThan(u32, 4) == 0) {
            const target = r.uintLessThan(u64, PRELOAD_N);
            _ = sc.findOne("count", .{ .i64 = @intCast(target) }) catch null;
        } else {
            const id = r.uintLessThan(u64, PRELOAD_N) + 1;
            const got = sc.get(ally, id) catch null;
            if (got) |buf| ally.free(buf);
        }
        ops += 1;
    }
    ctx.out_ops.* = ops;
}

const WriterCtx = struct {
    db: *Db,
    deadline_ns: u64,
    io: Io,
    out_ops: *u64,
    out_txns: *u64,
};

fn writerLoop(ctx: *WriterCtx) void {
    const ally = std.heap.c_allocator;
    const c = ctx.db.collection("docs");
    var next: i64 = @intCast(PRELOAD_N);
    var ops: u64 = 0;
    var txns: u64 = 0;

    while (nowNs(ctx.io) < ctx.deadline_ns) {
        ctx.db.begin() catch |e| {
            std.debug.print("writer begin failed: {s}\n", .{@errorName(e)});
            return;
        };
        var i: u32 = 0;
        var name_buf: [32]u8 = undefined;
        while (i < WRITER_BATCH) : (i += 1) {
            var b = Builder.init(ally);
            defer b.deinit();
            b.beginDocument() catch return;
            const name = std.fmt.bufPrint(&name_buf, "w-{d}", .{next}) catch return;
            b.putString("name", name) catch return;
            b.putI64("count", next) catch return;
            b.endDocument() catch return;
            const bytes = b.finish() catch return;
            defer ally.free(bytes);
            _ = c.insert(bytes) catch return;
            next += 1;
            ops += 1;
        }
        ctx.db.commit() catch |e| {
            std.debug.print("writer commit failed: {s}\n", .{@errorName(e)});
            return;
        };
        txns += 1;
    }
    ctx.out_ops.* = ops;
    ctx.out_txns.* = txns;
}

fn runReaderSweep(out: *Io.Writer, db: *Db, io: Io, ally: std.mem.Allocator, label: []const u8, reader_counts: []const u32) !void {
    try out.print("[{s}] readers do 75% random get, 25% indexed findOne; each holds a frozen snapshot.\n", .{label});
    for (reader_counts) |R| {
        // Checkpoint between sweeps so dirty pages from a previous mixed
        // run don't pile up in the page cache and slow snapshot capture.
        try db.checkpoint();
        const deadline = nowNs(io) + SECS_PHASE * std.time.ns_per_s;
        const threads = try ally.alloc(std.Thread, R);
        defer ally.free(threads);
        const ops_per_thread = try ally.alloc(u64, R);
        defer ally.free(ops_per_thread);
        const ctxs = try ally.alloc(ReaderCtx, R);
        defer ally.free(ctxs);

        for (0..R) |i| {
            ops_per_thread[i] = 0;
            ctxs[i] = .{
                .db = db,
                .deadline_ns = deadline,
                .rng_seed = 0x1000 + i,
                .io = io,
                .out_ops = &ops_per_thread[i],
            };
            threads[i] = try std.Thread.spawn(.{}, readerLoop, .{&ctxs[i]});
        }
        for (threads) |t| t.join();

        var total: u64 = 0;
        for (ops_per_thread) |o| total += o;
        const elapsed_ns = SECS_PHASE * std.time.ns_per_s;
        try out.print("  {d:>2} readers: {d:>10} ops/s aggregate ({d:.0} ops/s/thread)\n", .{
            R,
            @as(u64, @intFromFloat(opsPerSec(total, elapsed_ns))),
            opsPerSec(total, elapsed_ns) / @as(f64, @floatFromInt(R)),
        });
    }
    try out.print("\n", .{});
}

fn runMixedSweep(out: *Io.Writer, db: *Db, io: Io, ally: std.mem.Allocator, reader_counts: []const u32) !void {
    try out.print("[1 writer + N readers] writer does {d}-doc batched inserts; readers as in phase A.\n", .{WRITER_BATCH});
    for (reader_counts) |R| {
        try db.checkpoint();
        const deadline = nowNs(io) + SECS_PHASE * std.time.ns_per_s;
        const threads = try ally.alloc(std.Thread, R + 1);
        defer ally.free(threads);
        const reader_ops = try ally.alloc(u64, R);
        defer ally.free(reader_ops);
        const rctxs = try ally.alloc(ReaderCtx, R);
        defer ally.free(rctxs);

        for (0..R) |i| {
            reader_ops[i] = 0;
            rctxs[i] = .{
                .db = db,
                .deadline_ns = deadline,
                .rng_seed = 0x2000 + i,
                .io = io,
                .out_ops = &reader_ops[i],
            };
            threads[i] = try std.Thread.spawn(.{}, readerLoop, .{&rctxs[i]});
        }
        var writer_ops: u64 = 0;
        var writer_txns: u64 = 0;
        var wctx: WriterCtx = .{
            .db = db,
            .deadline_ns = deadline,
            .io = io,
            .out_ops = &writer_ops,
            .out_txns = &writer_txns,
        };
        threads[R] = try std.Thread.spawn(.{}, writerLoop, .{&wctx});
        for (threads) |t| t.join();

        var read_total: u64 = 0;
        for (reader_ops) |o| read_total += o;
        const elapsed_ns = SECS_PHASE * std.time.ns_per_s;
        try out.print("  1w+{d}r: writer {d:>9} inserts/s ({d} commits), readers {d:>10} ops/s aggregate\n", .{
            R,
            @as(u64, @intFromFloat(opsPerSec(writer_ops, elapsed_ns))),
            writer_txns,
            @as(u64, @intFromFloat(opsPerSec(read_total, elapsed_ns))),
        });
    }
    try out.print("\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    const ally = std.heap.c_allocator;
    var tmp_dir = try Io.Dir.cwd().createDirPathOpen(io, ".bench-tmp", .{});
    defer tmp_dir.close(io);
    tmp_dir.deleteFile(io, "bench_concurrent.db") catch {};
    tmp_dir.deleteFile(io, "bench_concurrent.db.wal") catch {};

    var db = try Db.open(ally, io, tmp_dir, "bench_concurrent.db");
    defer db.close();
    db.setSyncMode(.normal);

    try out.print("pyx concurrent benchmark — preload={d}, secs/phase={d}\n", .{ PRELOAD_N, SECS_PHASE });
    try out.print("=========================================================\n", .{});

    // Warmup: preload N docs in one big txn, then create the index used
    // by indexed findOne. Doing the index after the bulk load lets the
    // pre-load run at append-cursor speed.
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

    const reader_counts = [_]u32{ 1, 2, 4, 8 };
    try runReaderSweep(out, &db, io, ally, "read-only", &reader_counts);
    try runMixedSweep(out, &db, io, ally, &reader_counts);

    try out.flush();
}
