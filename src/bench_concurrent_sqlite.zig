//! SQLite concurrent reader/writer harness mirroring bench_concurrent.zig.
//!
//! WAL+NORMAL — same sync semantics as the pyx run. Each thread opens
//! its own sqlite3 connection (the way SQLite WAL is meant to scale:
//! shared file, separate connections). All connections set
//! `synchronous=NORMAL`. Writer connection sets `journal_mode=WAL` once;
//! it sticks across reconnects.
//!
//! Workload mirrors bench_concurrent.zig: phase A read-only sweep,
//! phase B 1 writer + R readers; same 75/25 read mix; same batch size.

const std = @import("std");
const Io = std.Io;

const c = @cImport({
    @cInclude("sqlite3.h");
});

const SQLITE_TRANSIENT: c.sqlite3_destructor_type = null;

const PRELOAD_N: u64 = 100_000;
const SECS_PHASE: u64 = 3;
const WRITER_BATCH: u32 = 100;
const DB_PATH = ".bench-tmp/sqlite_concurrent.db";

fn nowNs(io: Io) u64 {
    const ts = Io.Clock.Timestamp.now(io, .awake);
    return @intCast(ts.raw.toNanoseconds());
}

fn opsPerSec(ops: u64, ns: u64) f64 {
    return @as(f64, @floatFromInt(ops)) * @as(f64, @floatFromInt(std.time.ns_per_s)) / @as(f64, @floatFromInt(ns));
}

fn check(rc: c_int, msg: []const u8) !void {
    if (rc != c.SQLITE_OK and rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) {
        std.debug.print("SQLite error: {s} (rc={d})\n", .{ msg, rc });
        return error.SqliteError;
    }
}

fn openConn() !*c.sqlite3 {
    var conn: ?*c.sqlite3 = null;
    try check(c.sqlite3_open(DB_PATH, &conn), "open");
    // 5 second busy-wait so a reader doesn't immediately fail if the
    // writer is briefly holding a lock.
    _ = c.sqlite3_busy_timeout(conn, 5000);
    try check(c.sqlite3_exec(conn, "PRAGMA synchronous=NORMAL;", null, null, null), "sync=normal");
    return conn.?;
}

const ReaderCtx = struct {
    deadline_ns: u64,
    rng_seed: u64,
    io: Io,
    out_ops: *u64,
};

fn readerLoop(ctx: *ReaderCtx) void {
    var prng = std.Random.DefaultPrng.init(ctx.rng_seed);
    const r = prng.random();

    const conn = openConn() catch return;
    defer _ = c.sqlite3_close(conn);

    var stmt_get: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(conn, "SELECT name, count FROM docs WHERE id = ?", -1, &stmt_get, null) != c.SQLITE_OK) return;
    defer _ = c.sqlite3_finalize(stmt_get);

    var stmt_idx: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(conn, "SELECT id FROM docs WHERE count = ? LIMIT 1", -1, &stmt_idx, null) != c.SQLITE_OK) return;
    defer _ = c.sqlite3_finalize(stmt_idx);

    var ops: u64 = 0;
    while (true) {
        if (ops & 1023 == 0 and nowNs(ctx.io) >= ctx.deadline_ns) break;
        if (r.uintLessThan(u32, 4) == 0) {
            const target = r.uintLessThan(u64, PRELOAD_N);
            _ = c.sqlite3_bind_int64(stmt_idx, 1, @intCast(target));
            while (c.sqlite3_step(stmt_idx) == c.SQLITE_ROW) {}
            _ = c.sqlite3_reset(stmt_idx);
        } else {
            const id: i64 = @intCast(r.uintLessThan(u64, PRELOAD_N) + 1);
            _ = c.sqlite3_bind_int64(stmt_get, 1, id);
            _ = c.sqlite3_step(stmt_get);
            _ = c.sqlite3_reset(stmt_get);
        }
        ops += 1;
    }
    ctx.out_ops.* = ops;
}

const WriterCtx = struct {
    deadline_ns: u64,
    io: Io,
    out_ops: *u64,
    out_txns: *u64,
};

fn writerLoop(ctx: *WriterCtx) void {
    const conn = openConn() catch return;
    defer _ = c.sqlite3_close(conn);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(conn, "INSERT INTO docs (name, count) VALUES (?, ?)", -1, &stmt, null) != c.SQLITE_OK) return;
    defer _ = c.sqlite3_finalize(stmt);

    var next: i64 = @intCast(PRELOAD_N);
    var ops: u64 = 0;
    var txns: u64 = 0;
    var name_buf: [32]u8 = undefined;

    while (nowNs(ctx.io) < ctx.deadline_ns) {
        if (c.sqlite3_exec(conn, "BEGIN IMMEDIATE", null, null, null) != c.SQLITE_OK) return;
        var i: u32 = 0;
        while (i < WRITER_BATCH) : (i += 1) {
            const name = std.fmt.bufPrint(&name_buf, "w-{d}", .{next}) catch return;
            _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), SQLITE_TRANSIENT);
            _ = c.sqlite3_bind_int64(stmt, 2, next);
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return;
            _ = c.sqlite3_reset(stmt);
            next += 1;
            ops += 1;
        }
        if (c.sqlite3_exec(conn, "COMMIT", null, null, null) != c.SQLITE_OK) return;
        txns += 1;
    }
    ctx.out_ops.* = ops;
    ctx.out_txns.* = txns;
}

fn runReaderSweep(out: *Io.Writer, io: Io, ally: std.mem.Allocator, reader_counts: []const u32) !void {
    try out.print("[read-only] readers do 75% random get, 25% indexed point query; one connection per thread.\n", .{});
    for (reader_counts) |R| {
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

fn runMixedSweep(out: *Io.Writer, io: Io, ally: std.mem.Allocator, reader_counts: []const u32) !void {
    try out.print("[1 writer + N readers] writer does {d}-doc batched inserts (BEGIN IMMEDIATE...COMMIT).\n", .{WRITER_BATCH});
    for (reader_counts) |R| {
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

    // Fresh DB file.
    Io.Dir.cwd().deleteFile(io, DB_PATH) catch {};
    Io.Dir.cwd().deleteFile(io, ".bench-tmp/sqlite_concurrent.db-journal") catch {};
    Io.Dir.cwd().deleteFile(io, ".bench-tmp/sqlite_concurrent.db-wal") catch {};
    Io.Dir.cwd().deleteFile(io, ".bench-tmp/sqlite_concurrent.db-shm") catch {};
    var tmp = try Io.Dir.cwd().createDirPathOpen(io, ".bench-tmp", .{});
    tmp.close(io);

    try out.print("SQLite concurrent benchmark — WAL + sync=NORMAL, preload={d}, secs/phase={d}\n", .{ PRELOAD_N, SECS_PHASE });
    try out.print("=================================================================\n", .{});

    // Warmup: open one connection, set WAL mode (file-level pragma; persists),
    // create schema, batch-insert PRELOAD_N rows, create index.
    {
        const conn = try openConn();
        defer _ = c.sqlite3_close(conn);
        try check(c.sqlite3_exec(conn, "PRAGMA journal_mode=WAL;", null, null, null), "wal");
        try check(c.sqlite3_exec(conn,
            "CREATE TABLE docs (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, count INTEGER);",
            null, null, null), "create");

        var stmt: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(conn, "INSERT INTO docs (name, count) VALUES (?, ?)", -1, &stmt, null), "prep");
        defer _ = c.sqlite3_finalize(stmt);
        try check(c.sqlite3_exec(conn, "BEGIN", null, null, null), "begin");
        var name_buf: [32]u8 = undefined;
        for (0..PRELOAD_N) |i| {
            const name = try std.fmt.bufPrint(&name_buf, "doc-{d}", .{i});
            _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), SQLITE_TRANSIENT);
            _ = c.sqlite3_bind_int64(stmt, 2, @intCast(i));
            try check(c.sqlite3_step(stmt), "step");
            _ = c.sqlite3_reset(stmt);
        }
        try check(c.sqlite3_exec(conn, "COMMIT", null, null, null), "commit");
        try check(c.sqlite3_exec(conn, "CREATE INDEX idx_count ON docs(count);", null, null, null), "idx");
        try check(c.sqlite3_exec(conn, "PRAGMA wal_checkpoint(TRUNCATE);", null, null, null), "ckpt");
    }

    const reader_counts = [_]u32{ 1, 2, 4, 8 };
    try runReaderSweep(out, io, ally, &reader_counts);
    try runMixedSweep(out, io, ally, &reader_counts);

    try out.flush();
}
