//! Microbenchmarks. Run with `zig build bench -Doptimize=ReleaseFast`.

const std = @import("std");
const Io = std.Io;
const pyx = @import("pyx");

const Db = pyx.db.Db;
const Builder = pyx.doc.Builder;

fn nowNs(io: Io) u64 {
    const ts = Io.Clock.Timestamp.now(io, .awake);
    return @intCast(ts.raw.toNanoseconds());
}

fn opsPerSec(ops: u64, elapsed_ns: u64) f64 {
    return @as(f64, @floatFromInt(ops)) * @as(f64, @floatFromInt(std.time.ns_per_s)) / @as(f64, @floatFromInt(elapsed_ns));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    // Use the C allocator for an apples-to-apples comparison with SQLite,
    // which uses libc malloc internally. DebugAllocator tracks every
    // allocation with metadata and is meant for safety, not speed.
    const ally = std.heap.c_allocator;

    var tmp_dir = try Io.Dir.cwd().createDirPathOpen(io, ".bench-tmp", .{});
    defer tmp_dir.close(io);
    tmp_dir.deleteFile(io, "bench.db") catch {};
    tmp_dir.deleteFile(io, "bench.db.wal") catch {};

    var db = try Db.open(ally, io, tmp_dir, "bench.db");
    defer db.close();

    const N: u64 = 10_000;

    try out.print("pyx microbenchmarks ({d} ops)\n", .{N});
    try out.print("=========================================\n", .{});

    // Match the comparison's sync semantics: SQLite WAL+NORMAL skips
    // per-commit fsync; we do the same here. Strict-durability users keep
    // the default `.full`.
    db.setSyncMode(.normal);

    // 1. Sequential auto-commit inserts (worst case — fsync per op).
    {
        const c = db.collection("seq");
        const start = nowNs(io);
        var name_buf: [32]u8 = undefined;
        for (0..N) |i| {
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
        const ns = nowNs(io) - start;
        try out.print("insert auto-commit:   {d:>10} ns/op  ({d:.0} ops/s)\n", .{ ns / N, opsPerSec(N, ns) });
    }

    // 2. Batched inserts (one txn, single fsync at the end).
    {
        const c = db.collection("batch");
        const start = nowNs(io);
        try db.begin();
        var name_buf: [32]u8 = undefined;
        for (0..N) |i| {
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
        const ns = nowNs(io) - start;
        try out.print("insert batched:       {d:>10} ns/op  ({d:.0} ops/s)\n", .{ ns / N, opsPerSec(N, ns) });
    }

    // 3. Random gets by doc id.
    {
        var prng = std.Random.DefaultPrng.init(0x42);
        const r = prng.random();
        const lookups: u64 = 1000;
        var ids: [1000]u64 = undefined;
        for (&ids) |*id| id.* = r.uintLessThan(u64, N) + 1;
        const c = db.collection("batch");
        const start = nowNs(io);
        for (ids) |id| {
            const got = (try c.get(ally, id)) orelse continue;
            ally.free(got);
        }
        const ns = nowNs(io) - start;
        try out.print("random get:           {d:>10} ns/op  ({d:.0} ops/s)\n", .{ ns / lookups, opsPerSec(lookups, ns) });
    }

    // 4. Full collection iteration.
    {
        const c = db.collection("batch");
        const start = nowNs(io);
        var it = try c.iterator(ally);
        defer it.deinit();
        var seen: u64 = 0;
        while (try it.next()) |_| seen += 1;
        const ns = nowNs(io) - start;
        try out.print("iterate ({d} docs): {d:>10} ns/doc ({d:.0} docs/s)\n", .{ seen, ns / seen, opsPerSec(seen, ns) });
    }

    // 5. Indexed equality lookup.
    {
        try db.createIndex("batch", "count");
        const c = db.collection("batch");
        var prng = std.Random.DefaultPrng.init(0x99);
        const r = prng.random();
        const lookups: u64 = 1000;
        const start = nowNs(io);
        var hits: u32 = 0;
        for (0..lookups) |_| {
            const target = r.uintLessThan(u64, N);
            if (try c.findOne("count", .{ .i64 = @intCast(target) })) |_| hits += 1;
        }
        const ns = nowNs(io) - start;
        try out.print("indexed findOne:      {d:>10} ns/op  ({d:.0} ops/s, {d}/{d} hit)\n", .{ ns / lookups, opsPerSec(lookups, ns), hits, lookups });
    }

    try out.flush();
}
