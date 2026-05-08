//! Microbench: latency of Db.snapshot() in isolation. We populate a
//! growing page cache and time how long capture takes.

const std = @import("std");
const Io = std.Io;
const pyx = @import("pyx");
const Db = pyx.db.Db;
const Builder = pyx.doc.Builder;

fn nowNs(io: Io) u64 {
    const ts = Io.Clock.Timestamp.now(io, .awake);
    return @intCast(ts.raw.toNanoseconds());
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const ally = std.heap.c_allocator;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_w.interface;

    var tmp_dir = try Io.Dir.cwd().createDirPathOpen(io, ".bench-tmp", .{});
    defer tmp_dir.close(io);
    tmp_dir.deleteFile(io, "snap.db") catch {};
    tmp_dir.deleteFile(io, "snap.db.wal") catch {};

    var db = try Db.open(ally, io, tmp_dir, "snap.db");
    defer db.close();
    db.setSyncMode(.normal);

    // Seed K docs in one txn.
    const K: u64 = 10_000;
    {
        try db.begin();
        const c = db.collection("c");
        for (0..K) |i| {
            var b = Builder.init(ally);
            defer b.deinit();
            try b.beginDocument();
            try b.putI64("count", @intCast(i));
            try b.endDocument();
            const bytes = try b.finish();
            defer ally.free(bytes);
            _ = try c.insert(bytes);
        }
        try db.commit();
        try db.checkpoint();
    }

    // Scenario A — empty page_cache (just checkpointed).
    {
        const N: u32 = 1000;
        const t0 = nowNs(io);
        for (0..N) |_| {
            var snap = try db.snapshot();
            snap.deinit();
        }
        const t1 = nowNs(io);
        try out.print("A. snapshot() with empty page_cache: {d:.1} us/op ({d} ops in {d} ns)\n", .{
            @as(f64, @floatFromInt(t1 - t0)) / @as(f64, @floatFromInt(N)) / 1000.0,
            N,
            t1 - t0,
        });
    }

    // Scenario B — small page_cache (one auto-commit insert between
    // each snapshot, ~5 dirty pages).
    {
        const N: u32 = 1000;
        const t0 = nowNs(io);
        for (0..N) |i| {
            var b = Builder.init(ally);
            defer b.deinit();
            try b.beginDocument();
            try b.putI64("count", @intCast(K + i));
            try b.endDocument();
            const bytes = try b.finish();
            defer ally.free(bytes);
            _ = try db.collection("c").insert(bytes);

            var snap = try db.snapshot();
            snap.deinit();
        }
        const t1 = nowNs(io);
        try out.print("B. snapshot() with 1-commit page_cache (steady state): {d:.1} us/op ({d} ops in {d} ns)\n", .{
            @as(f64, @floatFromInt(t1 - t0)) / @as(f64, @floatFromInt(N)) / 1000.0,
            N,
            t1 - t0,
        });
    }

    // Scenario C — break the cost down for ONE large page_cache.
    // Insert M docs, then time a single snapshot.
    {
        const M: u32 = 1000;
        for (0..M) |i| {
            var b = Builder.init(ally);
            defer b.deinit();
            try b.beginDocument();
            try b.putI64("count", @intCast(K + 1000 + i));
            try b.endDocument();
            const bytes = try b.finish();
            defer ally.free(bytes);
            _ = try db.collection("c").insert(bytes);
        }
        const t0 = nowNs(io);
        var snap = try db.snapshot();
        const t1 = nowNs(io);
        snap.deinit();
        const t2 = nowNs(io);
        try out.print("C. snapshot() with {d}-commit page_cache: capture {d:.1} us, deinit {d:.1} us\n", .{
            M,
            @as(f64, @floatFromInt(t1 - t0)) / 1000.0,
            @as(f64, @floatFromInt(t2 - t1)) / 1000.0,
        });
    }

    try out.flush();
}
