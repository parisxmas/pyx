//! SQLite microbench mirroring `bench.zig` for apples-to-apples comparison.
//! Run with `zig build bench-sqlite -Doptimize=ReleaseFast`.

const std = @import("std");
const Io = std.Io;

const c = @cImport({
    @cInclude("sqlite3.h");
});

// `null` destructor = SQLITE_STATIC: SQLite reads the bound bytes during
// step() but doesn't retain them afterward, so reusing the bind buffer
// between iterations is safe in our tight loop.
const SQLITE_TRANSIENT: c.sqlite3_destructor_type = null;

fn nowNs(io: Io) u64 {
    const ts = Io.Clock.Timestamp.now(io, .awake);
    return @intCast(ts.raw.toNanoseconds());
}

fn opsPerSec(ops: u64, elapsed_ns: u64) f64 {
    return @as(f64, @floatFromInt(ops)) * @as(f64, @floatFromInt(std.time.ns_per_s)) / @as(f64, @floatFromInt(elapsed_ns));
}

fn check(rc: c_int, msg: []const u8) !void {
    if (rc != c.SQLITE_OK and rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) {
        std.debug.print("SQLite error: {s} (rc={d})\n", .{ msg, rc });
        return error.SqliteError;
    }
}

const SqliteMode = enum { default, wal_normal };

fn runWorkload(io: Io, label: []const u8, mode: SqliteMode, out: *Io.Writer) !void {
    const N: u64 = 10_000;

    // Fresh DB file each run.
    Io.Dir.cwd().deleteFile(io, ".bench-tmp/sqlite.db") catch {};
    Io.Dir.cwd().deleteFile(io, ".bench-tmp/sqlite.db-journal") catch {};
    Io.Dir.cwd().deleteFile(io, ".bench-tmp/sqlite.db-wal") catch {};
    Io.Dir.cwd().deleteFile(io, ".bench-tmp/sqlite.db-shm") catch {};

    var db: ?*c.sqlite3 = null;
    try check(c.sqlite3_open(".bench-tmp/sqlite.db", &db), "open");
    defer _ = c.sqlite3_close(db);

    switch (mode) {
        .default => {}, // rollback journal, synchronous=FULL — closest to our auto-commit semantics
        .wal_normal => {
            try check(c.sqlite3_exec(db, "PRAGMA journal_mode=WAL;", null, null, null), "wal");
            try check(c.sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", null, null, null), "sync");
        },
    }

    try check(c.sqlite3_exec(db,
        \\CREATE TABLE seq     (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, count INTEGER);
        \\CREATE TABLE batched (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, count INTEGER);
    , null, null, null), "create");

    try out.print("---- {s} ----\n", .{label});

    // 1. Sequential auto-commit inserts.
    {
        var stmt: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(db, "INSERT INTO seq (name, count) VALUES (?, ?)", -1, &stmt, null), "prep");
        defer _ = c.sqlite3_finalize(stmt);
        const start = nowNs(io);
        var name_buf: [32]u8 = undefined;
        for (0..N) |i| {
            const name = try std.fmt.bufPrint(&name_buf, "doc-{d}", .{i});
            _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), SQLITE_TRANSIENT);
            _ = c.sqlite3_bind_int64(stmt, 2, @intCast(i));
            try check(c.sqlite3_step(stmt), "step");
            _ = c.sqlite3_reset(stmt);
        }
        const ns = nowNs(io) - start;
        try out.print("insert auto-commit:   {d:>10} ns/op  ({d:.0} ops/s)\n", .{ ns / N, opsPerSec(N, ns) });
    }

    // 2. Batched inserts (one transaction).
    {
        var stmt: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(db, "INSERT INTO batched (name, count) VALUES (?, ?)", -1, &stmt, null), "prep");
        defer _ = c.sqlite3_finalize(stmt);
        const start = nowNs(io);
        try check(c.sqlite3_exec(db, "BEGIN", null, null, null), "begin");
        var name_buf: [32]u8 = undefined;
        for (0..N) |i| {
            const name = try std.fmt.bufPrint(&name_buf, "doc-{d}", .{i});
            _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), SQLITE_TRANSIENT);
            _ = c.sqlite3_bind_int64(stmt, 2, @intCast(i));
            try check(c.sqlite3_step(stmt), "step");
            _ = c.sqlite3_reset(stmt);
        }
        try check(c.sqlite3_exec(db, "COMMIT", null, null, null), "commit");
        const ns = nowNs(io) - start;
        try out.print("insert batched:       {d:>10} ns/op  ({d:.0} ops/s)\n", .{ ns / N, opsPerSec(N, ns) });
    }

    // 3. Random gets by primary key.
    {
        var prng = std.Random.DefaultPrng.init(0x42);
        const r = prng.random();
        const lookups: u64 = 1000;
        var ids: [1000]i64 = undefined;
        for (&ids) |*id| id.* = @intCast(r.uintLessThan(u64, N) + 1);

        var stmt: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(db, "SELECT name, count FROM batched WHERE id = ?", -1, &stmt, null), "prep");
        defer _ = c.sqlite3_finalize(stmt);
        const start = nowNs(io);
        for (ids) |id| {
            _ = c.sqlite3_bind_int64(stmt, 1, id);
            _ = c.sqlite3_step(stmt);
            _ = c.sqlite3_reset(stmt);
        }
        const ns = nowNs(io) - start;
        try out.print("random get:           {d:>10} ns/op  ({d:.0} ops/s)\n", .{ ns / lookups, opsPerSec(lookups, ns) });
    }

    // 4. Full table scan.
    {
        var stmt: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(db, "SELECT id, name, count FROM batched", -1, &stmt, null), "prep");
        defer _ = c.sqlite3_finalize(stmt);
        const start = nowNs(io);
        var seen: u64 = 0;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) seen += 1;
        const ns = nowNs(io) - start;
        try out.print("iterate ({d} docs): {d:>10} ns/doc ({d:.0} docs/s)\n", .{ seen, ns / seen, opsPerSec(seen, ns) });
    }

    // 5. Indexed equality lookup.
    {
        try check(c.sqlite3_exec(db, "CREATE INDEX idx_count ON batched(count);", null, null, null), "index");
        var prng = std.Random.DefaultPrng.init(0x99);
        const r = prng.random();
        const lookups: u64 = 1000;
        var stmt: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(db, "SELECT id FROM batched WHERE count = ? LIMIT 1", -1, &stmt, null), "prep");
        defer _ = c.sqlite3_finalize(stmt);
        const start = nowNs(io);
        var hits: u32 = 0;
        for (0..lookups) |_| {
            const target = r.uintLessThan(u64, N);
            _ = c.sqlite3_bind_int64(stmt, 1, @intCast(target));
            if (c.sqlite3_step(stmt) == c.SQLITE_ROW) hits += 1;
            _ = c.sqlite3_reset(stmt);
        }
        const ns = nowNs(io) - start;
        try out.print("indexed findOne:      {d:>10} ns/op  ({d:.0} ops/s, {d}/{d} hit)\n", .{ ns / lookups, opsPerSec(lookups, ns), hits, lookups });
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var tmp_dir = try Io.Dir.cwd().createDirPathOpen(io, ".bench-tmp", .{});
    tmp_dir.close(io);

    try out.print("SQLite microbenchmarks (10000 ops)\n", .{});
    try out.print("=========================================\n", .{});

    try runWorkload(io, "SQLite default (rollback journal, sync=FULL)", .default, out);
    try runWorkload(io, "SQLite WAL mode + sync=NORMAL", .wal_normal, out);

    try out.flush();
}
