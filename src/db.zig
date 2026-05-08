//! High-level document database API.
//!
//! Storage layout (single global B+Tree, namespace byte disambiguates):
//!   \x00 + varint(coll_len) + coll + u64_BE(doc_id)         — primary entry
//!   \x01 + ... + field + type_tag + value + u64_BE(doc_id)  — index entry
//!   \x02 + varint(coll_len) + coll + varint(field_len) + field — index registry
//!
//! Snapshot isolation falls out of the CoW B+Tree. Indexes are persistent
//! and auto-maintained on insert/put/delete.
//!
//! Threading (v0):
//!   - All public Db/Collection/SnapshotCollection methods take a Mutex,
//!     so concurrent auto-commit operations across threads are serialized.
//!   - Iterators are NOT thread-safe — don't use one while another thread
//!     writes through the same Db.
//!   - Multi-op explicit transactions (begin/commit/abort) are intended
//!     for single-threaded use; mixing with concurrent auto-commit ops on
//!     other threads is undefined.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const Mutex = Io.Mutex;

const pager_mod = @import("pager.zig");
const btree_mod = @import("btree.zig");
const doc_mod = @import("doc.zig");
const index_mod = @import("index.zig");
const wal_mod = @import("wal.zig");
const PageId = pager_mod.PageId;
const ArrayList = std.ArrayList;

pub const max_collection_name: usize = 200;

pub const Error = error{
    CollectionNameInvalid,
    NoSuchIndex,
    /// Returned by `OptimisticTxn.commit()` when validation detects that
    /// another committed transaction modified a key in this txn's read
    /// set since it began. Caller should retry — typically via
    /// `Db.runOptimistic`.
    WriteConflict,
    /// Returned by `Db.runOptimistic` when the retry budget is
    /// exhausted without a successful commit.
    RetryBudgetExhausted,
};

const max_prefix_size: usize = 1 + 10 + max_collection_name; // namespace + varint + name
const max_full_key_size: usize = max_prefix_size + 8;

fn encodeCollectionPrefix(buf: []u8, name: []const u8) usize {
    var pos: usize = 0;
    buf[pos] = index_mod.ns_primary;
    pos += 1;
    pos += doc_mod.writeVarint(buf[pos..], name.len);
    @memcpy(buf[pos .. pos + name.len], name);
    pos += name.len;
    return pos;
}

fn encodeKey(buf: []u8, name: []const u8, doc_id: u64) usize {
    var pos = encodeCollectionPrefix(buf, name);
    mem.writeInt(u64, buf[pos..][0..8], doc_id, .big);
    pos += 8;
    return pos;
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_collection_name) return Error.CollectionNameInvalid;
}

const ReplayOp = union(enum) {
    put: struct { key: []u8, value: []u8 },
    delete: []u8,

    fn deinit(self: ReplayOp, allocator: Allocator) void {
        switch (self) {
            .put => |p| {
                allocator.free(p.key);
                allocator.free(p.value);
            },
            .delete => |k| allocator.free(k),
        }
    }
};

const ReplayCtx = struct {
    allocator: Allocator,
    pager: *pager_mod.Pager,
    pending: ArrayList(ReplayOp),

    fn handle(self: *ReplayCtx, rec: wal_mod.Record, lsn: u64) anyerror!void {
        _ = lsn;
        switch (rec) {
            .put => |p| try self.pending.append(self.allocator, .{
                .put = .{
                    .key = try self.allocator.dupe(u8, p.key),
                    .value = try self.allocator.dupe(u8, p.value),
                },
            }),
            .delete => |k| try self.pending.append(self.allocator, .{ .delete = try self.allocator.dupe(u8, k) }),
            .commit => |c| {
                const bt = btree_mod.BTree.init(self.allocator, self.pager);
                for (self.pending.items) |op| {
                    switch (op) {
                        .put => |p| try bt.put(p.key, p.value),
                        .delete => |k| _ = try bt.delete(k),
                    }
                }
                self.pager.restoreNextDocId(c.next_doc_id);
                for (self.pending.items) |op| op.deinit(self.allocator);
                self.pending.clearRetainingCapacity();
            },
        }
    }
};

fn replayWal(allocator: Allocator, pager: *pager_mod.Pager) !void {
    if (pager.wal.end_offset <= wal_mod.wal_header_size) return;

    pager.in_recovery = true;
    defer pager.in_recovery = false;

    var ctx = ReplayCtx{
        .allocator = allocator,
        .pager = pager,
        .pending = .empty,
    };
    defer {
        for (ctx.pending.items) |op| op.deinit(allocator);
        ctx.pending.deinit(allocator);
    }

    const max_lsn = try pager.wal.replay(allocator, &ctx, ReplayCtx.handle);
    pager.next_lsn = max_lsn + 1;

    try pager.flushHeader();
    try pager.checkpoint();
}


pub const Db = struct {
    allocator: Allocator,
    pager: pager_mod.Pager,
    indexes: index_mod.Manager,
    mu: Mutex,
    /// Thread that currently holds an explicit (begin/commit) transaction.
    /// 0 = no holder. Lets the same thread re-enter via auto-commit ops
    /// without trying to relock the (non-reentrant) Mutex.
    txn_owner: std.atomic.Value(std.Thread.Id),

    pub fn open(allocator: Allocator, io: Io, dir: Dir, sub_path: []const u8) !Db {
        var pager = try pager_mod.Pager.open(allocator, io, dir, sub_path);
        errdefer pager.close();
        try replayWal(allocator, &pager);
        var indexes = index_mod.Manager.init(allocator);
        errdefer indexes.deinit();
        try indexes.loadFromPager(&pager);
        return .{
            .allocator = allocator,
            .pager = pager,
            .indexes = indexes,
            .mu = Mutex.init,
            .txn_owner = .init(0),
        };
    }

    fn ownsTxn(self: *const Db) bool {
        return self.txn_owner.load(.acquire) == std.Thread.getCurrentId();
    }

    pub fn close(self: *Db) void {
        self.indexes.deinit();
        self.pager.close();
    }

    pub fn checkpoint(self: *Db) !void {
        if (self.ownsTxn()) return; // checkpoint inside a txn is a no-op
        self.mu.lockUncancelable(self.pager.io);
        defer self.mu.unlock(self.pager.io);
        try self.pager.checkpoint();
    }

    /// Trade per-commit fsync for higher write throughput. With `.normal`,
    /// the WAL is fsynced at `checkpoint()` instead of on every commit —
    /// the same trade-off as SQLite's `synchronous=NORMAL` in WAL mode.
    /// Crash safety is preserved (the WAL is CRC-validated on replay);
    /// only durability of the most recent commits is relaxed.
    pub fn setSyncMode(self: *Db, mode: pager_mod.SyncMode) void {
        self.pager.setSyncMode(mode);
    }

    // Multi-op transaction control. The caller's thread holds the Db lock
    // until commit/abort releases it; auto-commit ops on the same thread
    // re-enter without relocking.
    pub fn begin(self: *Db) !void {
        self.mu.lockUncancelable(self.pager.io);
        errdefer self.mu.unlock(self.pager.io);
        try self.pager.begin();
        self.txn_owner.store(std.Thread.getCurrentId(), .release);
    }
    pub fn commit(self: *Db) !void {
        self.txn_owner.store(0, .release);
        const commit_lsn = blk: {
            defer self.mu.unlock(self.pager.io);
            const lsn = try self.pager.commitAppend();
            try self.pager.applyAndFinalize();
            break :blk lsn;
        };
        try self.pager.syncTo(commit_lsn);
    }
    pub fn abort(self: *Db) void {
        self.txn_owner.store(0, .release);
        defer self.mu.unlock(self.pager.io);
        self.pager.abort();
    }

    /// Begin an optimistic-concurrency transaction. The returned `Txn`
    /// captures a `Snapshot` of the current B+Tree, accumulates writes
    /// into a private buffer, and validates them against the live tree
    /// at `commit()`.
    ///
    /// Reads against the txn (`TxnCollection.get`) are lock-free —
    /// they go through the snapshot's mmap view of the data file.
    /// Writes are buffered in the txn's `write_set` and only touch the
    /// live tree at commit time, after validation. Many txns can run
    /// concurrently from different threads; only the brief commit
    /// validate+apply step takes `db.mu`.
    ///
    /// On commit, validation re-reads each `read_set` entry against
    /// the current live tree and verifies the value's hash matches
    /// what was observed at begin time. Any divergence yields
    /// `error.WriteConflict` and the caller should retry. Caveat:
    /// blind writes (put/delete without a prior get of the same key)
    /// are not protected from lost-update — read before writing if
    /// you care.
    pub fn beginOptimistic(self: *Db) !OptimisticTxn {
        // Snapshot capture briefly takes db.mu inside `snapshot()` to
        // checkpoint, then releases it. The returned Snapshot owns an
        // mmap of the data file at the captured root, so subsequent
        // reads from concurrent OCC txns are fully lock-free.
        var snap = try self.snapshot();
        errdefer snap.deinit();
        return .{
            .db = self,
            .snapshot = snap,
            .start_root = snap.btree_root,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .read_set = .empty,
            .write_set = .empty,
            .range_set = .empty,
        };
    }

    /// Run an OCC transaction with automatic retry on
    /// `error.WriteConflict`. The caller's `func` receives the active
    /// txn handle; on success the helper commits, on `WriteConflict`
    /// it abandons the txn, sleeps with exponential backoff + full
    /// jitter, and starts a fresh one. Other user errors
    /// short-circuit and are returned to the caller.
    ///
    /// Backoff schedule: cap doubles on each conflict from 100 µs up
    /// to 10 ms; the actual sleep is uniformly drawn from `[0, cap)`
    /// (AWS "full jitter" — avoids synchronised retry storms when
    /// many threads conflict on the same key).
    ///
    /// Returns `error.RetryBudgetExhausted` if `max_attempts` is
    /// reached without a successful commit.
    pub fn runOptimistic(
        self: *Db,
        max_attempts: u32,
        context: anytype,
        comptime func: fn (@TypeOf(context), *OptimisticTxn) anyerror!void,
    ) !void {
        const initial_backoff_ns: u64 = 100 * std.time.ns_per_us; // 100 µs
        const max_backoff_ns: u64 = 10 * std.time.ns_per_ms; //     10 ms
        var backoff_cap_ns: u64 = initial_backoff_ns;
        var prng_seeded = false;
        var prng: std.Random.DefaultPrng = undefined;

        var attempts: u32 = 0;
        while (attempts < max_attempts) : (attempts += 1) {
            var txn = try self.beginOptimistic();
            // No errdefer needed — every exit path either calls
            // commit (which deinits) or abort (also deinits), and
            // OptimisticTxn.deinitAll is idempotent.
            func(context, &txn) catch |e| {
                txn.abort();
                return e;
            };
            txn.commit() catch |e| switch (e) {
                error.WriteConflict => {
                    if (!prng_seeded) {
                        const ts = Io.Clock.Timestamp.now(self.pager.io, .awake);
                        const seed: u64 = @as(u64, @truncate(@as(u128, @intCast(ts.raw.toNanoseconds())))) ^
                            @as(u64, @intCast(std.Thread.getCurrentId()));
                        prng = std.Random.DefaultPrng.init(seed);
                        prng_seeded = true;
                    }
                    if (backoff_cap_ns > 0) {
                        const sleep_ns = prng.random().uintLessThan(u64, backoff_cap_ns);
                        if (sleep_ns > 0) {
                            const dur = Io.Duration.fromNanoseconds(@intCast(sleep_ns));
                            self.pager.io.sleep(dur, .awake) catch {};
                        }
                    }
                    backoff_cap_ns = @min(backoff_cap_ns *| 2, max_backoff_ns);
                    continue;
                },
                else => return e,
            };
            return;
        }
        return Error.RetryBudgetExhausted;
    }

    pub fn collection(self: *Db, name: []const u8) Collection {
        return .{ .db = self, .name = name };
    }

    /// Capture a consistent point-in-time view of the database. The
    /// returned `Snapshot` is **lock-free for reads** — readers from any
    /// thread can issue `get`/`iterator` calls concurrently with writers
    /// on the main thread, with no mutex acquisition on the read path.
    ///
    /// Implementation: acquire the mutex briefly, soft-flush the page
    /// cache so every page reachable from the captured root is at
    /// least in the kernel's page cache (mmap reads share that), then
    /// release the mutex. We do NOT fsync — the WAL covers durability,
    /// and mmap doesn't need on-disk durability to read back the
    /// just-pwritten bytes. Subsequent reads bypass the userspace page
    /// cache and pager state entirely; they go straight to the mmap
    /// (or pread) which POSIX guarantees thread-safe per fd.
    ///
    /// Inside an explicit transaction (`ownsTxn` true), the snapshot
    /// keeps the pager-mediated read path because the cache may still
    /// hold uncommitted pages. That path is mutex-protected; concurrency
    /// is preserved only for snapshots taken outside any txn.
    pub fn snapshot(self: *Db) !Snapshot {
        if (self.ownsTxn()) {
            return .{
                .db = self,
                .btree_root = self.pager.bTreeRoot(),
                .file = self.pager.file,
                .io = self.pager.io,
                .lock_free = false,
                .mmap = null,
            };
        }
        self.mu.lockUncancelable(self.pager.io);
        defer self.mu.unlock(self.pager.io);
        try self.pager.flushForSnapshot();
        const file_len = try self.pager.file.length(self.pager.io);
        // mmap a read-only view of the data file at its current size.
        // CoW means subsequent writers append new pages past `file_len`;
        // those pages are not reachable from the captured B+tree root,
        // so the mapping never needs to grow during the snapshot's life.
        // If the mapping fails (e.g. zero-length file, oddball fs), fall
        // back to plain pread for this snapshot.
        const mm: ?std.Io.File.MemoryMap = if (file_len == 0) null else std.Io.File.MemoryMap.create(
            self.pager.io,
            self.pager.file,
            .{
                .len = @intCast(file_len),
                .protection = .{ .read = true, .write = false },
                .undefined_contents = false,
                .populate = false,
            },
        ) catch null;
        return .{
            .db = self,
            .btree_root = self.pager.bTreeRoot(),
            .file = self.pager.file,
            .io = self.pager.io,
            .lock_free = true,
            .mmap = mm,
        };
    }

    pub fn createIndex(self: *Db, coll: []const u8, field_path: []const u8) !void {
        try validateName(coll);
        if (self.ownsTxn()) {
            try self.indexes.createIndex(&self.pager, coll, field_path);
            return;
        }
        const commit_lsn = blk: {
            self.mu.lockUncancelable(self.pager.io);
            defer self.mu.unlock(self.pager.io);
            try self.pager.begin();
            errdefer self.pager.abort();
            try self.indexes.createIndex(&self.pager, coll, field_path);
            const lsn = try self.pager.commitAppend();
            try self.pager.applyAndFinalize();
            break :blk lsn;
        };
        try self.pager.syncTo(commit_lsn);
    }

    pub fn dropIndex(self: *Db, coll: []const u8, field_path: []const u8) !void {
        try validateName(coll);
        if (self.ownsTxn()) {
            try self.indexes.dropIndex(&self.pager, coll, field_path);
            return;
        }
        const commit_lsn = blk: {
            self.mu.lockUncancelable(self.pager.io);
            defer self.mu.unlock(self.pager.io);
            try self.pager.begin();
            errdefer self.pager.abort();
            try self.indexes.dropIndex(&self.pager, coll, field_path);
            const lsn = try self.pager.commitAppend();
            try self.pager.applyAndFinalize();
            break :blk lsn;
        };
        try self.pager.syncTo(commit_lsn);
    }

    /// Create a compound (multi-field) index. The field order matters —
    /// `(last, first)` is a different index from `(first, last)` and
    /// only the former answers `last="X" AND first="Y"` lookups.
    pub fn createCompoundIndex(self: *Db, coll: []const u8, fields: []const []const u8) !void {
        try validateName(coll);
        if (self.ownsTxn()) {
            try self.indexes.createCompoundIndex(&self.pager, coll, fields);
            return;
        }
        const commit_lsn = blk: {
            self.mu.lockUncancelable(self.pager.io);
            defer self.mu.unlock(self.pager.io);
            try self.pager.begin();
            errdefer self.pager.abort();
            try self.indexes.createCompoundIndex(&self.pager, coll, fields);
            const lsn = try self.pager.commitAppend();
            try self.pager.applyAndFinalize();
            break :blk lsn;
        };
        try self.pager.syncTo(commit_lsn);
    }

    pub fn dropCompoundIndex(self: *Db, coll: []const u8, fields: []const []const u8) !void {
        try validateName(coll);
        if (self.ownsTxn()) {
            try self.indexes.dropCompoundIndex(&self.pager, coll, fields);
            return;
        }
        const commit_lsn = blk: {
            self.mu.lockUncancelable(self.pager.io);
            defer self.mu.unlock(self.pager.io);
            try self.pager.begin();
            errdefer self.pager.abort();
            try self.indexes.dropCompoundIndex(&self.pager, coll, fields);
            const lsn = try self.pager.commitAppend();
            try self.pager.applyAndFinalize();
            break :blk lsn;
        };
        try self.pager.syncTo(commit_lsn);
    }
};

pub const Collection = struct {
    db: *Db,
    name: []const u8,

    fn btree(self: Collection) btree_mod.BTree {
        return btree_mod.BTree.init(self.db.allocator, &self.db.pager);
    }

    pub fn insert(self: Collection, doc_bytes: []const u8) !u64 {
        try validateName(self.name);
        if (self.db.ownsTxn()) return self.insertLocked(doc_bytes);
        var commit_lsn: u64 = 0;
        const id = blk: {
            self.db.mu.lockUncancelable(self.db.pager.io);
            defer self.db.mu.unlock(self.db.pager.io);
            try self.db.pager.begin();
            errdefer self.db.pager.abort();
            const inserted_id = try self.insertLocked(doc_bytes);
            commit_lsn = try self.db.pager.commitAppend();
            try self.db.pager.applyAndFinalize();
            break :blk inserted_id;
        };
        try self.db.pager.syncTo(commit_lsn);
        return id;
    }

    fn insertLocked(self: Collection, doc_bytes: []const u8) !u64 {
        const doc_id = try self.db.pager.nextDocId();
        var key_buf: [max_full_key_size]u8 = undefined;
        const key_len = encodeKey(&key_buf, self.name, doc_id);
        try self.btree().put(key_buf[0..key_len], doc_bytes);
        try self.db.indexes.afterInsert(&self.db.pager, self.name, doc_id, doc_bytes);
        return doc_id;
    }

    pub fn put(self: Collection, doc_id: u64, doc_bytes: []const u8) !void {
        try validateName(self.name);
        if (self.db.ownsTxn()) return self.putLocked(doc_id, doc_bytes);
        const commit_lsn = blk: {
            self.db.mu.lockUncancelable(self.db.pager.io);
            defer self.db.mu.unlock(self.db.pager.io);
            try self.db.pager.begin();
            errdefer self.db.pager.abort();
            try self.putLocked(doc_id, doc_bytes);
            const lsn = try self.db.pager.commitAppend();
            try self.db.pager.applyAndFinalize();
            break :blk lsn;
        };
        try self.db.pager.syncTo(commit_lsn);
    }

    fn putLocked(self: Collection, doc_id: u64, doc_bytes: []const u8) !void {
        var key_buf: [max_full_key_size]u8 = undefined;
        const key_len = encodeKey(&key_buf, self.name, doc_id);

        // For index maintenance we need the old doc (if any) to remove its
        // index entries before adding new ones.
        const bt = self.btree();
        const old = try bt.get(self.db.allocator, key_buf[0..key_len]);
        defer if (old) |o| self.db.allocator.free(o);
        if (old) |o| try self.db.indexes.beforeDelete(&self.db.pager, self.name, doc_id, o);

        try bt.put(key_buf[0..key_len], doc_bytes);
        try self.db.indexes.afterInsert(&self.db.pager, self.name, doc_id, doc_bytes);
    }

    pub fn get(self: Collection, allocator: Allocator, doc_id: u64) !?[]u8 {
        try validateName(self.name);
        const locked = !self.db.ownsTxn();
        if (locked) self.db.mu.lockUncancelable(self.db.pager.io);
        defer if (locked) self.db.mu.unlock(self.db.pager.io);
        var key_buf: [max_full_key_size]u8 = undefined;
        const key_len = encodeKey(&key_buf, self.name, doc_id);
        return self.btree().get(allocator, key_buf[0..key_len]);
    }

    pub fn delete(self: Collection, doc_id: u64) !bool {
        try validateName(self.name);
        if (self.db.ownsTxn()) return self.deleteLocked(doc_id);
        var commit_lsn: u64 = 0;
        const found = blk: {
            self.db.mu.lockUncancelable(self.db.pager.io);
            defer self.db.mu.unlock(self.db.pager.io);
            try self.db.pager.begin();
            errdefer self.db.pager.abort();
            const f = try self.deleteLocked(doc_id);
            commit_lsn = try self.db.pager.commitAppend();
            try self.db.pager.applyAndFinalize();
            break :blk f;
        };
        try self.db.pager.syncTo(commit_lsn);
        return found;
    }

    fn deleteLocked(self: Collection, doc_id: u64) !bool {
        var key_buf: [max_full_key_size]u8 = undefined;
        const key_len = encodeKey(&key_buf, self.name, doc_id);
        const bt = self.btree();
        const old = try bt.get(self.db.allocator, key_buf[0..key_len]);
        defer if (old) |o| self.db.allocator.free(o);
        if (old == null) return false;
        try self.db.indexes.beforeDelete(&self.db.pager, self.name, doc_id, old.?);
        return bt.delete(key_buf[0..key_len]);
    }

    pub fn iterator(self: Collection, allocator: Allocator) !Iterator {
        try validateName(self.name);
        const locked = !self.db.ownsTxn();
        if (locked) self.db.mu.lockUncancelable(self.db.pager.io);
        defer if (locked) self.db.mu.unlock(self.db.pager.io);
        return Iterator.openWithRoot(allocator, &self.db.pager, self.db.pager.bTreeRoot(), self.name);
    }

    pub fn count(self: Collection, allocator: Allocator) !u64 {
        var it = try self.iterator(allocator);
        defer it.deinit();
        var n: u64 = 0;
        while (try it.next()) |_| n += 1;
        return n;
    }

    /// Indexed equality lookup. Returns the matching doc id, or null. The
    /// underlying index must exist (created via `Db.createIndex`).
    pub fn findOne(
        self: Collection,
        field_path: []const u8,
        value: doc_mod.Value,
    ) !?u64 {
        try validateName(self.name);
        const locked = !self.db.ownsTxn();
        if (locked) self.db.mu.lockUncancelable(self.db.pager.io);
        defer if (locked) self.db.mu.unlock(self.db.pager.io);
        return self.db.indexes.findOne(&self.db.pager, self.name, field_path, value) catch |err| switch (err) {
            error.NoSuchIndex => Error.NoSuchIndex,
            else => err,
        };
    }

    /// Compound-index equality lookup. `fields` and `values` must align
    /// in order with the index's registered field list — `(last, first)`
    /// is a different index from `(first, last)`.
    pub fn findOneCompound(
        self: Collection,
        fields: []const []const u8,
        values: []const doc_mod.Value,
    ) !?u64 {
        try validateName(self.name);
        const locked = !self.db.ownsTxn();
        if (locked) self.db.mu.lockUncancelable(self.db.pager.io);
        defer if (locked) self.db.mu.unlock(self.db.pager.io);
        return self.db.indexes.findOneCompound(&self.db.pager, self.name, fields, values) catch |err| switch (err) {
            error.NoSuchIndex => Error.NoSuchIndex,
            else => err,
        };
    }

    /// Indexed range scan. `lo`/`hi` are `Bound`s (`.none`, `.inclusive`,
    /// `.exclusive`). Returned iterator yields doc ids in ascending value
    /// order. Caller must `deinit`.
    pub fn findRange(
        self: Collection,
        allocator: Allocator,
        field_path: []const u8,
        lo: index_mod.Bound,
        hi: index_mod.Bound,
    ) !index_mod.RangeIterator {
        try validateName(self.name);
        const locked = !self.db.ownsTxn();
        if (locked) self.db.mu.lockUncancelable(self.db.pager.io);
        defer if (locked) self.db.mu.unlock(self.db.pager.io);
        return self.db.indexes.findRange(allocator, &self.db.pager, self.name, field_path, lo, hi) catch |err| switch (err) {
            error.NoSuchIndex => Error.NoSuchIndex,
            else => err,
        };
    }

    /// Indexed equality scan. Yields all matching doc ids in ascending order.
    pub fn findAll(
        self: Collection,
        allocator: Allocator,
        field_path: []const u8,
        value: doc_mod.Value,
    ) !index_mod.LookupIterator {
        try validateName(self.name);
        const locked = !self.db.ownsTxn();
        if (locked) self.db.mu.lockUncancelable(self.db.pager.io);
        defer if (locked) self.db.mu.unlock(self.db.pager.io);
        return self.db.indexes.findAll(allocator, &self.db.pager, self.name, field_path, value) catch |err| switch (err) {
            error.NoSuchIndex => Error.NoSuchIndex,
            else => err,
        };
    }

    /// Predicate filter — full collection scan. The predicate function
    /// receives the raw encoded doc bytes; pair with `doc.parse` to inspect.
    pub fn find(self: Collection, allocator: Allocator, predicate: *const fn ([]const u8) bool) !FindIterator {
        const inner = try self.iterator(allocator);
        return .{ .inner = inner, .predicate = predicate };
    }
};

pub const Snapshot = struct {
    db: *Db,
    btree_root: PageId,
    file: std.Io.File,
    io: std.Io,
    /// True for snapshots captured outside any txn — reads go straight to
    /// disk without locking. False for in-txn snapshots, which have to
    /// consult the page cache through the pager (and hold the mutex).
    lock_free: bool,
    /// Read-only mmap of the data file at snapshot creation. Reads
    /// `memcpy` from the mapped region; only pages added by writers
    /// after this snapshot's capture (which the captured B+tree root
    /// can never reach) are absent from the map. Thread-safe; can be
    /// shared across reader threads without coordination.
    mmap: ?std.Io.File.MemoryMap,

    pub fn collection(self: Snapshot, name: []const u8) SnapshotCollection {
        return .{ .snapshot = self, .name = name };
    }

    pub fn deinit(self: *Snapshot) void {
        if (self.mmap) |*m| {
            m.destroy(self.io);
            self.mmap = null;
        }
    }
};

pub const SnapshotCollection = struct {
    snapshot: Snapshot,
    name: []const u8,

    fn view(self: SnapshotCollection) btree_mod.View {
        return .{
            .pager = if (self.snapshot.lock_free) null else &self.snapshot.db.pager,
            .file = self.snapshot.file,
            .io = self.snapshot.io,
            .root = self.snapshot.btree_root,
            .mmap = if (self.snapshot.mmap) |m| m.memory else null,
        };
    }

    pub fn get(self: SnapshotCollection, allocator: Allocator, doc_id: u64) !?[]u8 {
        try validateName(self.name);
        // Lock-free path: no mutex; reads go straight to disk via pread.
        if (self.snapshot.lock_free) {
            var key_buf: [max_full_key_size]u8 = undefined;
            const key_len = encodeKey(&key_buf, self.name, doc_id);
            return self.view().get(allocator, key_buf[0..key_len]);
        }
        // In-txn path: cache-aware reads, requires the lock.
        const locked = !self.snapshot.db.ownsTxn();
        if (locked) self.snapshot.db.mu.lockUncancelable(self.snapshot.db.pager.io);
        defer if (locked) self.snapshot.db.mu.unlock(self.snapshot.db.pager.io);
        var key_buf: [max_full_key_size]u8 = undefined;
        const key_len = encodeKey(&key_buf, self.name, doc_id);
        return self.view().get(allocator, key_buf[0..key_len]);
    }

    pub fn iterator(self: SnapshotCollection, allocator: Allocator) !Iterator {
        try validateName(self.name);
        if (self.snapshot.lock_free) {
            return Iterator.openWithSnapshot(allocator, self.snapshot, self.name);
        }
        const locked = !self.snapshot.db.ownsTxn();
        if (locked) self.snapshot.db.mu.lockUncancelable(self.snapshot.db.pager.io);
        defer if (locked) self.snapshot.db.mu.unlock(self.snapshot.db.pager.io);
        return Iterator.openWithRoot(allocator, &self.snapshot.db.pager, self.snapshot.btree_root, self.name);
    }

    pub fn count(self: SnapshotCollection, allocator: Allocator) !u64 {
        var it = try self.iterator(allocator);
        defer it.deinit();
        var n: u64 = 0;
        while (try it.next()) |_| n += 1;
        return n;
    }

    /// Indexed equality lookup, lock-free when this snapshot was captured
    /// outside any transaction. The index lookup walks the B+Tree through
    /// the snapshot's view (direct disk reads) — no mutex acquired.
    ///
    /// Caveat: this still reads `db.indexes.indexes` (the in-memory index
    /// registry) without synchronization. Don't `createIndex`/`dropIndex`
    /// while concurrent snapshot readers are running indexed lookups.
    pub fn findOne(
        self: SnapshotCollection,
        field_path: []const u8,
        value: doc_mod.Value,
    ) !?u64 {
        try validateName(self.name);
        if (self.snapshot.lock_free) {
            return self.snapshot.db.indexes.findOneInView(
                self.view(),
                self.name,
                field_path,
                value,
            ) catch |err| switch (err) {
                error.NoSuchIndex => Error.NoSuchIndex,
                else => err,
            };
        }
        const locked = !self.snapshot.db.ownsTxn();
        if (locked) self.snapshot.db.mu.lockUncancelable(self.snapshot.db.pager.io);
        defer if (locked) self.snapshot.db.mu.unlock(self.snapshot.db.pager.io);
        return self.snapshot.db.indexes.findOneInView(self.view(), self.name, field_path, value) catch |err| switch (err) {
            error.NoSuchIndex => Error.NoSuchIndex,
            else => err,
        };
    }

    /// Lock-free indexed range scan against the snapshot.
    pub fn findRange(
        self: SnapshotCollection,
        allocator: Allocator,
        field_path: []const u8,
        lo: index_mod.Bound,
        hi: index_mod.Bound,
    ) !index_mod.RangeIterator {
        try validateName(self.name);
        if (self.snapshot.lock_free) {
            return self.snapshot.db.indexes.findRangeInView(
                allocator,
                self.view(),
                self.name,
                field_path,
                lo,
                hi,
            ) catch |err| switch (err) {
                error.NoSuchIndex => Error.NoSuchIndex,
                else => err,
            };
        }
        const locked = !self.snapshot.db.ownsTxn();
        if (locked) self.snapshot.db.mu.lockUncancelable(self.snapshot.db.pager.io);
        defer if (locked) self.snapshot.db.mu.unlock(self.snapshot.db.pager.io);
        return self.snapshot.db.indexes.findRangeInView(allocator, self.view(), self.name, field_path, lo, hi) catch |err| switch (err) {
            error.NoSuchIndex => Error.NoSuchIndex,
            else => err,
        };
    }

    /// Lock-free indexed equality scan against the snapshot.
    pub fn findAll(
        self: SnapshotCollection,
        allocator: Allocator,
        field_path: []const u8,
        value: doc_mod.Value,
    ) !index_mod.LookupIterator {
        try validateName(self.name);
        if (self.snapshot.lock_free) {
            return self.snapshot.db.indexes.findAllInView(
                allocator,
                self.view(),
                self.name,
                field_path,
                value,
            ) catch |err| switch (err) {
                error.NoSuchIndex => Error.NoSuchIndex,
                else => err,
            };
        }
        const locked = !self.snapshot.db.ownsTxn();
        if (locked) self.snapshot.db.mu.lockUncancelable(self.snapshot.db.pager.io);
        defer if (locked) self.snapshot.db.mu.unlock(self.snapshot.db.pager.io);
        return self.snapshot.db.indexes.findAllInView(allocator, self.view(), self.name, field_path, value) catch |err| switch (err) {
            error.NoSuchIndex => Error.NoSuchIndex,
            else => err,
        };
    }
};

pub const Iterator = struct {
    btree_iter: btree_mod.Iterator,
    prefix_buf: [max_prefix_size]u8,
    prefix_len: usize,

    pub const Entry = struct { id: u64, doc: []const u8 };

    fn openWithRoot(
        allocator: Allocator,
        pager: *pager_mod.Pager,
        root: PageId,
        name: []const u8,
    ) !Iterator {
        var prefix_buf: [max_prefix_size]u8 = undefined;
        const prefix_len = encodeCollectionPrefix(&prefix_buf, name);
        const view = btree_mod.View{ .pager = pager, .file = pager.file, .io = pager.io, .root = root };
        const inner = try view.iteratorFrom(allocator, prefix_buf[0..prefix_len]);
        var it = Iterator{
            .btree_iter = inner,
            .prefix_buf = undefined,
            .prefix_len = prefix_len,
        };
        @memcpy(it.prefix_buf[0..prefix_len], prefix_buf[0..prefix_len]);
        return it;
    }

    fn openWithSnapshot(
        allocator: Allocator,
        snapshot: Snapshot,
        name: []const u8,
    ) !Iterator {
        var prefix_buf: [max_prefix_size]u8 = undefined;
        const prefix_len = encodeCollectionPrefix(&prefix_buf, name);
        const view = btree_mod.View{
            .pager = null, // lock-free direct-disk path
            .file = snapshot.file,
            .io = snapshot.io,
            .root = snapshot.btree_root,
        };
        const inner = try view.iteratorFrom(allocator, prefix_buf[0..prefix_len]);
        var it = Iterator{
            .btree_iter = inner,
            .prefix_buf = undefined,
            .prefix_len = prefix_len,
        };
        @memcpy(it.prefix_buf[0..prefix_len], prefix_buf[0..prefix_len]);
        return it;
    }

    pub fn deinit(self: *Iterator) void {
        self.btree_iter.deinit();
    }

    pub fn next(self: *Iterator) !?Entry {
        const e = (try self.btree_iter.next()) orelse return null;
        const prefix = self.prefix_buf[0..self.prefix_len];
        if (e.key.len != self.prefix_len + 8) return null;
        if (!mem.startsWith(u8, e.key, prefix)) return null;
        const id = mem.readInt(u64, e.key[self.prefix_len..][0..8], .big);
        return .{ .id = id, .doc = e.value };
    }
};

pub const FindIterator = struct {
    inner: Iterator,
    predicate: *const fn ([]const u8) bool,

    pub fn deinit(self: *FindIterator) void {
        self.inner.deinit();
    }

    pub fn next(self: *FindIterator) !?Iterator.Entry {
        while (try self.inner.next()) |entry| {
            if (self.predicate(entry.doc)) return entry;
        }
        return null;
    }
};

/// An optimistic-concurrency transaction. Use `Db.beginOptimistic`.
///
/// Reads of documents are recorded in `read_set` (with the doc's value
/// hash) for commit-time validation. Writes are buffered in
/// `write_set` and applied to the live B+Tree only at commit, after
/// validation succeeds.
///
/// Read tracking covers point reads (via `read_set`) and indexed
/// equality / range reads (via `range_set`). `Collection.iterator`
/// (full-collection scans) is not yet tracked — phantoms there are
/// O(collection) to validate, so they're left as a documented gap.
pub const OptimisticTxn = struct {
    db: *Db,
    snapshot: Snapshot,
    start_root: pager_mod.PageId,
    arena: std.heap.ArenaAllocator,
    read_set: ArrayList(ReadSetEntry),
    write_set: ArrayList(WriteSetEntry),
    range_set: ArrayList(RangeReadEntry),
    done: bool = false,

    pub const WriteKind = enum { insert, put, delete };

    pub const ReadSetEntry = struct {
        coll: []const u8, // owned by `arena`
        doc_id: u64,
        /// Wyhash of the doc bytes at read time, or 0 sentinel when the
        /// read returned null.
        value_hash: u64,
    };

    /// Indexed read predicate captured at read time. At commit, the
    /// validator re-runs the same predicate against the live tree and
    /// compares the result to what was observed; any difference =
    /// phantom = `WriteConflict`.
    pub const RangeReadEntry = union(enum) {
        find_one: FindOneEntry,
        find_all: FindAllEntry,
        find_range: FindRangeEntry,
        iterator: IteratorEntry,
    };

    pub const FindOneEntry = struct {
        coll: []const u8,           // owned by `arena`
        field: []const u8,          // owned by `arena`
        value: doc_mod.Value,       // string/bytes payloads owned by `arena`
        first_match: ?u64,          // result observed at snapshot time
    };

    pub const FindAllEntry = struct {
        coll: []const u8,           // owned by `arena`
        field: []const u8,          // owned by `arena`
        value: doc_mod.Value,       // string/bytes payloads owned by `arena`
        /// All doc_ids matching `field == value` at snapshot time, in
        /// ascending index order. Owned by `arena`.
        matches: []const u64,
    };

    pub const FindRangeEntry = struct {
        coll: []const u8,           // owned by `arena`
        field: []const u8,          // owned by `arena`
        lo: index_mod.Bound,        // string/bytes payloads owned by `arena`
        hi: index_mod.Bound,
        /// All doc_ids in [lo, hi] at snapshot time, in ascending index
        /// order. Owned by `arena`.
        matches: []const u64,
    };

    pub const IteratorEntry = struct {
        coll: []const u8,                    // owned by `arena`
        /// Doc_ids yielded so far, in the order the snapshot iterator
        /// produced them. Grows lazily as the user iterates; partial if
        /// they break early. Owned by the txn's main allocator (not the
        /// arena) since we need `.append`.
        matches: ArrayList(u64),
        /// Set when the user iterated past the last entry — i.e. their
        /// view "saw the end of the collection." Validation extends to
        /// "no doc was appended after the observed tail."
        exhausted: bool,
    };

    pub const WriteSetEntry = struct {
        coll: []const u8, // owned by `arena`
        doc_id: u64,
        kind: WriteKind,
        /// New doc bytes for `insert`/`put`; empty slice for `delete`.
        /// Owned by `arena`.
        value: []const u8,
    };

    pub fn collection(self: *OptimisticTxn, name: []const u8) TxnCollection {
        return .{ .txn = self, .name = name };
    }

    /// Validate the read set against the live tree, then apply the
    /// write set under db.mu. Returns `error.WriteConflict` if any
    /// observed value has changed since this txn began.
    pub fn commit(self: *OptimisticTxn) !void {
        defer self.deinitAll();

        // Open a pessimistic txn for the validate+apply phase. Auto-
        // commit ops on this thread re-enter through ownsTxn() and
        // share the lock without relocking.
        try self.db.begin();

        self.validateAndApply() catch |err| {
            self.db.abort();
            return err;
        };

        // Db.commit reliably releases db.mu whether it returns ok or
        // an error, so we do not call abort on its failure path.
        try self.db.commit();
    }

    fn validateAndApply(self: *OptimisticTxn) !void {
        for (self.read_set.items) |entry| {
            const coll = self.db.collection(entry.coll);
            const live = try coll.get(self.db.allocator, entry.doc_id);
            defer if (live) |v| self.db.allocator.free(v);
            const live_hash: u64 = if (live) |v| std.hash.Wyhash.hash(0, v) else 0;
            if (live_hash != entry.value_hash) return Error.WriteConflict;
        }

        for (self.range_set.items) |entry| {
            switch (entry) {
                .find_one => |fo| {
                    const live_first = try self.db.collection(fo.coll).findOne(fo.field, fo.value);
                    if (live_first != fo.first_match) return Error.WriteConflict;
                },
                .find_all => |fa| {
                    var it = try self.db.collection(fa.coll).findAll(self.db.allocator, fa.field, fa.value);
                    defer it.deinit();
                    if (!try liveMatchesEqual(&it, fa.matches)) return Error.WriteConflict;
                },
                .find_range => |fr| {
                    var it = try self.db.collection(fr.coll).findRange(self.db.allocator, fr.field, fr.lo, fr.hi);
                    defer it.deinit();
                    if (!try liveMatchesEqual(&it, fr.matches)) return Error.WriteConflict;
                },
                .iterator => |ie| {
                    var live = try self.db.collection(ie.coll).iterator(self.db.allocator);
                    defer live.deinit();
                    for (ie.matches.items) |expected_id| {
                        const got = (try live.next()) orelse return Error.WriteConflict;
                        if (got.id != expected_id) return Error.WriteConflict;
                    }
                    if (ie.exhausted) {
                        if ((try live.next()) != null) return Error.WriteConflict;
                    }
                },
            }
        }

        for (self.write_set.items) |entry| {
            const coll = self.db.collection(entry.coll);
            switch (entry.kind) {
                .insert, .put => try coll.put(entry.doc_id, entry.value),
                .delete => _ = try coll.delete(entry.doc_id),
            }
        }
    }

    pub fn abort(self: *OptimisticTxn) void {
        self.deinitAll();
    }

    /// Idempotent — safe to call from both `commit`'s defer and a
    /// caller's errdefer-style `abort`. Subsequent calls are no-ops.
    fn deinitAll(self: *OptimisticTxn) void {
        if (self.done) return;
        self.done = true;
        // Iterator entries hold non-arena ArrayLists; free them before
        // the arena tears down the rest.
        for (self.range_set.items) |*entry| {
            switch (entry.*) {
                .iterator => |*it| it.matches.deinit(self.db.allocator),
                else => {},
            }
        }
        self.read_set.deinit(self.db.allocator);
        self.write_set.deinit(self.db.allocator);
        self.range_set.deinit(self.db.allocator);
        self.arena.deinit();
        self.snapshot.deinit();
    }

    /// Search backwards through the write_set for the most recent op
    /// on `(coll, doc_id)`. Used by reads-your-own-writes.
    fn lookupOwnWrite(self: *OptimisticTxn, coll: []const u8, doc_id: u64) ?WriteSetEntry {
        var i = self.write_set.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.write_set.items[i];
            if (e.doc_id == doc_id and std.mem.eql(u8, e.coll, coll)) return e;
        }
        return null;
    }

    /// Whether `(coll, doc_id)` is already represented in the read set.
    /// Used to avoid duplicating a recordRead when a key is touched
    /// multiple times in the same txn (e.g. blind put followed by a
    /// later get, or the implicit-read-on-write path).
    fn hasReadSetEntry(self: *OptimisticTxn, coll: []const u8, doc_id: u64) bool {
        for (self.read_set.items) |e| {
            if (e.doc_id == doc_id and std.mem.eql(u8, e.coll, coll)) return true;
        }
        return false;
    }

    fn recordRead(self: *OptimisticTxn, coll: []const u8, doc_id: u64, value: ?[]const u8) !void {
        const owned = try self.arena.allocator().dupe(u8, coll);
        const hash: u64 = if (value) |v| std.hash.Wyhash.hash(0, v) else 0;
        try self.read_set.append(self.db.allocator, .{
            .coll = owned,
            .doc_id = doc_id,
            .value_hash = hash,
        });
    }

    fn recordWrite(
        self: *OptimisticTxn,
        coll: []const u8,
        doc_id: u64,
        kind: WriteKind,
        value: []const u8,
    ) !void {
        const arena_allocator = self.arena.allocator();
        const owned_coll = try arena_allocator.dupe(u8, coll);
        const owned_value = if (value.len == 0) "" else try arena_allocator.dupe(u8, value);
        try self.write_set.append(self.db.allocator, .{
            .coll = owned_coll,
            .doc_id = doc_id,
            .kind = kind,
            .value = owned_value,
        });
    }

    fn recordFindOne(
        self: *OptimisticTxn,
        coll: []const u8,
        field: []const u8,
        value: doc_mod.Value,
        first_match: ?u64,
    ) !void {
        const arena_allocator = self.arena.allocator();
        try self.range_set.append(self.db.allocator, .{
            .find_one = .{
                .coll = try arena_allocator.dupe(u8, coll),
                .field = try arena_allocator.dupe(u8, field),
                .value = try dupeValue(arena_allocator, value),
                .first_match = first_match,
            },
        });
    }

    fn recordFindAll(
        self: *OptimisticTxn,
        coll: []const u8,
        field: []const u8,
        value: doc_mod.Value,
        matches: []const u64,
    ) !void {
        const arena_allocator = self.arena.allocator();
        try self.range_set.append(self.db.allocator, .{
            .find_all = .{
                .coll = try arena_allocator.dupe(u8, coll),
                .field = try arena_allocator.dupe(u8, field),
                .value = try dupeValue(arena_allocator, value),
                .matches = try arena_allocator.dupe(u64, matches),
            },
        });
    }

    fn recordFindRange(
        self: *OptimisticTxn,
        coll: []const u8,
        field: []const u8,
        lo: index_mod.Bound,
        hi: index_mod.Bound,
        matches: []const u64,
    ) !void {
        const arena_allocator = self.arena.allocator();
        try self.range_set.append(self.db.allocator, .{
            .find_range = .{
                .coll = try arena_allocator.dupe(u8, coll),
                .field = try arena_allocator.dupe(u8, field),
                .lo = try dupeBound(arena_allocator, lo),
                .hi = try dupeBound(arena_allocator, hi),
                .matches = try arena_allocator.dupe(u64, matches),
            },
        });
    }
};

/// Tracking iterator for `TxnCollection.iterator`. Wraps the
/// snapshot's `Iterator` and appends each yielded doc_id to the
/// txn's range_set so commit-time validation can detect phantoms.
/// Calling `next()` past the last entry sets `exhausted = true` on
/// the recorded entry, which extends validation to "no doc appended
/// past the observed tail." If the caller breaks early, only the
/// observed prefix is recorded — phantom inserts past the break
/// point won't conflict (the user didn't depend on that range).
pub const TxnIterator = struct {
    inner: Iterator,
    txn: *OptimisticTxn,
    /// Index into `txn.range_set` of our `iterator` entry. Stable
    /// across resizes — we re-index `range_set.items` on every call.
    range_idx: usize,

    pub fn deinit(self: *TxnIterator) void {
        self.inner.deinit();
    }

    pub fn next(self: *TxnIterator) !?Iterator.Entry {
        const e = (try self.inner.next()) orelse {
            self.txn.range_set.items[self.range_idx].iterator.exhausted = true;
            return null;
        };
        try self.txn.range_set.items[self.range_idx].iterator.matches.append(
            self.txn.db.allocator,
            e.id,
        );
        return e;
    }
};

/// Iterator over the captured match list of an OCC `findAll` or
/// `findRange`. yields doc_ids in the same ascending order the live
/// index would. `deinit` is a no-op — matches are owned by the
/// surrounding `OptimisticTxn`'s arena.
pub const TxnMatchIterator = struct {
    matches: []const u64,
    pos: usize = 0,

    pub fn deinit(self: *TxnMatchIterator) void {
        _ = self;
    }

    pub fn next(self: *TxnMatchIterator) !?u64 {
        if (self.pos >= self.matches.len) return null;
        const id = self.matches[self.pos];
        self.pos += 1;
        return id;
    }
};

/// Deep-copy a doc_mod.Value into the given allocator. The variants
/// that carry slice payloads (`string`, `bytes`) are duped; inline
/// variants pass through. Array/object values aren't yet allowed in
/// indexed lookups, so they're treated as pass-through too.
fn dupeValue(arena: Allocator, v: doc_mod.Value) !doc_mod.Value {
    return switch (v) {
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .bytes => |b| .{ .bytes = try arena.dupe(u8, b) },
        else => v,
    };
}

fn dupeBound(arena: Allocator, b: index_mod.Bound) !index_mod.Bound {
    return switch (b) {
        .none => .none,
        .inclusive => |v| .{ .inclusive = try dupeValue(arena, v) },
        .exclusive => |v| .{ .exclusive = try dupeValue(arena, v) },
    };
}

/// Walk a live-tree iterator (`RangeIterator` or `LookupIterator`) and
/// confirm it yields exactly the same doc_ids in the same order as
/// `expected`. Used by the OCC commit to catch phantoms in `findAll`
/// and `findRange`.
fn liveMatchesEqual(it: anytype, expected: []const u64) !bool {
    var i: usize = 0;
    while (try it.next()) |id| {
        if (i >= expected.len) return false; // live has more matches
        if (id != expected[i]) return false; // diverged
        i += 1;
    }
    return i == expected.len; // live had fewer matches if i < expected.len
}

/// Collection handle bound to an `OptimisticTxn`. Reads go through the
/// txn's snapshot (lock-free); writes are buffered in the txn until
/// commit. Reads that find a matching staged write return that
/// write's value (read-your-own-writes) without recording a read-set
/// entry — what we'd validate is what we just wrote.
pub const TxnCollection = struct {
    txn: *OptimisticTxn,
    name: []const u8,

    pub fn insert(self: TxnCollection, doc_bytes: []const u8) !u64 {
        try validateName(self.name);
        // No implicit read: pager.reserveDocId hands back a fresh id
        // from the atomic counter, so by construction no other writer
        // can be touching it. There's nothing to compare-against.
        const id = self.txn.db.pager.reserveDocId();
        try self.txn.recordWrite(self.name, id, .insert, doc_bytes);
        return id;
    }

    pub fn put(self: TxnCollection, doc_id: u64, doc_bytes: []const u8) !void {
        try validateName(self.name);
        try self.recordImplicitReadIfNew(doc_id);
        try self.txn.recordWrite(self.name, doc_id, .put, doc_bytes);
    }

    pub fn delete(self: TxnCollection, doc_id: u64) !bool {
        try validateName(self.name);
        try self.recordImplicitReadIfNew(doc_id);
        // We can't tell from the buffered state alone whether this
        // doc_id exists in the live tree. Buffer the delete; the
        // committed apply phase will short-circuit if it's missing.
        try self.txn.recordWrite(self.name, doc_id, .delete, "");
        return true;
    }

    /// Implicit snapshot read on the write path. Without this, blind
    /// `put`/`delete` (no preceding `get` of the same key) would not
    /// add an entry to the read_set, and a concurrent committer who
    /// modified the same key between begin and commit would go
    /// undetected — classic lost-update.
    ///
    /// Skipped when:
    ///   - The key is already in our own write_set: an earlier op in
    ///     this same txn established the precondition, no need to
    ///     duplicate.
    ///   - The key is already in our read_set: we recorded its
    ///     start_root state via an earlier explicit get; a second
    ///     entry would just be redundant work at validation time.
    fn recordImplicitReadIfNew(self: TxnCollection, doc_id: u64) !void {
        if (self.txn.lookupOwnWrite(self.name, doc_id)) |_| return;
        if (self.txn.hasReadSetEntry(self.name, doc_id)) return;
        const ally = self.txn.db.allocator;
        const start_value = try self.txn.snapshot.collection(self.name).get(ally, doc_id);
        defer if (start_value) |v| ally.free(v);
        try self.txn.recordRead(self.name, doc_id, start_value);
    }

    pub fn get(self: TxnCollection, allocator: Allocator, doc_id: u64) !?[]u8 {
        try validateName(self.name);
        // 1. Read-your-own-writes: latest staged op wins.
        if (self.txn.lookupOwnWrite(self.name, doc_id)) |w| {
            switch (w.kind) {
                .delete => return null,
                .insert, .put => return try allocator.dupe(u8, w.value),
            }
        }
        // 2. Snapshot read against start_root. Lock-free.
        const snap_coll = self.txn.snapshot.collection(self.name);
        const value = try snap_coll.get(allocator, doc_id);
        try self.txn.recordRead(self.name, doc_id, value);
        return value;
    }

    // Range / indexed reads are phantom-prone in this version — they
    // pass through to the snapshot with no read-set tracking. A future
    // version will add range tracking.
    pub fn iterator(self: TxnCollection, allocator: Allocator) !TxnIterator {
        try validateName(self.name);
        const inner = try self.txn.snapshot.collection(self.name).iterator(allocator);
        const arena_alloc = self.txn.arena.allocator();
        try self.txn.range_set.append(self.txn.db.allocator, .{
            .iterator = .{
                .coll = try arena_alloc.dupe(u8, self.name),
                .matches = .empty,
                .exhausted = false,
            },
        });
        return .{
            .inner = inner,
            .txn = self.txn,
            .range_idx = self.txn.range_set.items.len - 1,
        };
    }

    pub fn count(self: TxnCollection, allocator: Allocator) !u64 {
        var it = try self.iterator(allocator);
        defer it.deinit();
        var n: u64 = 0;
        while (try it.next()) |_| n += 1;
        return n;
    }

    pub fn findOne(
        self: TxnCollection,
        field_path: []const u8,
        value: doc_mod.Value,
    ) !?u64 {
        try validateName(self.name);
        const first = try self.txn.snapshot.collection(self.name).findOne(field_path, value);
        try self.txn.recordFindOne(self.name, field_path, value, first);
        return first;
    }

    pub fn findAll(
        self: TxnCollection,
        allocator: Allocator,
        field_path: []const u8,
        value: doc_mod.Value,
    ) !TxnMatchIterator {
        try validateName(self.name);
        var inner = try self.txn.snapshot.collection(self.name).findAll(allocator, field_path, value);
        defer inner.deinit();
        var list: ArrayList(u64) = .empty;
        defer list.deinit(allocator);
        while (try inner.next()) |id| try list.append(allocator, id);
        try self.txn.recordFindAll(self.name, field_path, value, list.items);
        // Hand back an iterator over the arena-owned copy so the caller
        // can deinit `list` without leaking the txn's record.
        const last = self.txn.range_set.items[self.txn.range_set.items.len - 1];
        return .{ .matches = last.find_all.matches };
    }

    pub fn findRange(
        self: TxnCollection,
        allocator: Allocator,
        field_path: []const u8,
        lo: index_mod.Bound,
        hi: index_mod.Bound,
    ) !TxnMatchIterator {
        try validateName(self.name);
        var inner = try self.txn.snapshot.collection(self.name).findRange(allocator, field_path, lo, hi);
        defer inner.deinit();
        var list: ArrayList(u64) = .empty;
        defer list.deinit(allocator);
        while (try inner.next()) |id| try list.append(allocator, id);
        try self.txn.recordFindRange(self.name, field_path, lo, hi, list.items);
        const last = self.txn.range_set.items[self.txn.range_set.items.len - 1];
        return .{ .matches = last.find_range.matches };
    }
};

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;
const Builder = doc_mod.Builder;

fn buildDoc(s: []const u8, n: i64) ![]u8 {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.beginDocument();
    try b.putString("name", s);
    try b.putI64("count", n);
    try b.endDocument();
    return try b.finish();
}

test "open, insert, get, delete on a single collection" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, testing.io, tmp.dir, "demo.db");
    defer db.close();

    const users = db.collection("users");

    const alice = try buildDoc("alice", 1);
    defer testing.allocator.free(alice);
    const bob = try buildDoc("bob", 2);
    defer testing.allocator.free(bob);

    const id_a = try users.insert(alice);
    const id_b = try users.insert(bob);
    try testing.expect(id_a != id_b);

    const got_a = (try users.get(testing.allocator, id_a)).?;
    defer testing.allocator.free(got_a);
    try testing.expectEqualSlices(u8, alice, got_a);

    try testing.expect(try users.delete(id_a));
    try testing.expect(!try users.delete(id_a));
    try testing.expect(try users.get(testing.allocator, id_a) == null);
}

test "multiple collections do not interfere" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, testing.io, tmp.dir, "multi.db");
    defer db.close();

    const users = db.collection("users");
    const products = db.collection("products");

    const ua = try buildDoc("alice", 1);
    defer testing.allocator.free(ua);
    const ub = try buildDoc("bob", 2);
    defer testing.allocator.free(ub);
    const pa = try buildDoc("widget", 10);
    defer testing.allocator.free(pa);
    const pb = try buildDoc("gadget", 20);
    defer testing.allocator.free(pb);

    _ = try users.insert(ua);
    _ = try products.insert(pa);
    _ = try users.insert(ub);
    _ = try products.insert(pb);

    try testing.expectEqual(@as(u64, 2), try users.count(testing.allocator));
    try testing.expectEqual(@as(u64, 2), try products.count(testing.allocator));
}

test "data persists across reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    const io = testing.io;

    var saved_id: u64 = undefined;
    {
        var db = try Db.open(ally, io, tmp.dir, "persist.db");
        defer db.close();
        const c = db.collection("things");
        const d = try buildDoc("hello", 42);
        defer ally.free(d);
        saved_id = try c.insert(d);
        try db.checkpoint();
    }
    {
        var db = try Db.open(ally, io, tmp.dir, "persist.db");
        defer db.close();
        const c = db.collection("things");
        const got = (try c.get(ally, saved_id)).?;
        defer ally.free(got);
        const v = try doc_mod.parse(got);
        try testing.expectEqualStrings("hello", (try v.object.get("name")).?.string);
    }
}

test "snapshot preserves view through subsequent writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "snap.db");
    defer db.close();

    const users = db.collection("users");
    const orig = try buildDoc("alice", 1);
    defer ally.free(orig);
    const id = try users.insert(orig);

    var snap = try db.snapshot();
    defer snap.deinit();
    const snap_users = snap.collection("users");

    const updated = try buildDoc("alice-v2", 2);
    defer ally.free(updated);
    try users.put(id, updated);

    const new_v = try buildDoc("bob", 1);
    defer ally.free(new_v);
    _ = try users.insert(new_v);

    try testing.expectEqual(@as(u64, 2), try users.count(ally));

    try testing.expectEqual(@as(u64, 1), try snap_users.count(ally));
    const snap_doc = (try snap_users.get(ally, id)).?;
    defer ally.free(snap_doc);
    const snap_parsed = try doc_mod.parse(snap_doc);
    try testing.expectEqualStrings("alice", (try snap_parsed.object.get("name")).?.string);
}

test "rejects empty or oversized collection name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, testing.io, tmp.dir, "names.db");
    defer db.close();

    const empty = db.collection("");
    try testing.expectError(Error.CollectionNameInvalid, empty.insert("anything"));

    var big_name: [max_collection_name + 1]u8 = @splat('x');
    const big = db.collection(&big_name);
    try testing.expectError(Error.CollectionNameInvalid, big.insert("anything"));
}

test "secondary index: create, find, drop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "idx.db");
    defer db.close();

    const users = db.collection("users");

    const a = try buildDoc("alice", 1);
    defer ally.free(a);
    const b = try buildDoc("bob", 2);
    defer ally.free(b);
    const c = try buildDoc("alice", 3); // duplicate name
    defer ally.free(c);

    const id_a = try users.insert(a);
    const id_b = try users.insert(b);
    const id_c = try users.insert(c);

    try db.createIndex("users", "name");

    // findOne returns the lowest doc id matching.
    const got_alice = try users.findOne("name", .{ .string = "alice" });
    try testing.expectEqual(@as(?u64, id_a), got_alice);

    const got_bob = try users.findOne("name", .{ .string = "bob" });
    try testing.expectEqual(@as(?u64, id_b), got_bob);

    const not_found = try users.findOne("name", .{ .string = "carol" });
    try testing.expect(not_found == null);

    // findAll yields both alices in ascending id order.
    var it = try users.findAll(ally, "name", .{ .string = "alice" });
    defer it.deinit();
    try testing.expectEqual(@as(?u64, id_a), try it.next());
    try testing.expectEqual(@as(?u64, id_c), try it.next());
    try testing.expect((try it.next()) == null);

    // After dropping the index, findOne errors.
    try db.dropIndex("users", "name");
    try testing.expectError(Error.NoSuchIndex, users.findOne("name", .{ .string = "alice" }));
}

test "index auto-maintained on insert / put / delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "auto.db");
    defer db.close();

    try db.createIndex("users", "count");

    const users = db.collection("users");
    const a = try buildDoc("alice", 5);
    defer ally.free(a);
    const id_a = try users.insert(a);
    try testing.expectEqual(@as(?u64, id_a), try users.findOne("count", .{ .i64 = 5 }));

    // put: old index entry (count=5) goes away, new (count=99) shows up.
    const a2 = try buildDoc("alice", 99);
    defer ally.free(a2);
    try users.put(id_a, a2);
    try testing.expect((try users.findOne("count", .{ .i64 = 5 })) == null);
    try testing.expectEqual(@as(?u64, id_a), try users.findOne("count", .{ .i64 = 99 }));

    // delete: entry goes away.
    _ = try users.delete(id_a);
    try testing.expect((try users.findOne("count", .{ .i64 = 99 })) == null);
}

test "indexes restored on reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    const io = testing.io;

    var saved_id: u64 = undefined;
    {
        var db = try Db.open(ally, io, tmp.dir, "idx-restore.db");
        defer db.close();
        try db.createIndex("users", "name");
        const a = try buildDoc("alice", 1);
        defer ally.free(a);
        saved_id = try db.collection("users").insert(a);
        try db.checkpoint();
    }
    {
        var db = try Db.open(ally, io, tmp.dir, "idx-restore.db");
        defer db.close();
        const users = db.collection("users");
        // Index was loaded from registry.
        try testing.expectEqual(@as(?u64, saved_id), try users.findOne("name", .{ .string = "alice" }));
    }
}

test "Collection.find with a predicate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "find.db");
    defer db.close();

    const c = db.collection("c");
    for (0..20) |i| {
        const d = try buildDoc("x", @intCast(i));
        defer ally.free(d);
        _ = try c.insert(d);
    }

    const Pred = struct {
        fn match(doc_bytes: []const u8) bool {
            const v = doc_mod.parse(doc_bytes) catch return false;
            const cnt = (v.object.get("count") catch return false) orelse return false;
            return cnt.i64 > 15;
        }
    };

    var it = try c.find(ally, Pred.match);
    defer it.deinit();
    var matches: u32 = 0;
    while (try it.next()) |_| matches += 1;
    try testing.expectEqual(@as(u32, 4), matches); // i in {16, 17, 18, 19}
}

test "createIndex on a large batched collection finds every doc" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "idx-large.db");
    defer db.close();

    const c = db.collection("c");
    const n: usize = 500;
    try db.begin();
    var name_buf: [16]u8 = undefined;
    for (0..n) |i| {
        var b = Builder.init(ally);
        defer b.deinit();
        try b.beginDocument();
        try b.putString("name", try std.fmt.bufPrint(&name_buf, "n{d}", .{i}));
        try b.putI64("count", @intCast(i));
        try b.endDocument();
        const bytes = try b.finish();
        defer ally.free(bytes);
        _ = try c.insert(bytes);
    }
    try db.commit();

    try db.createIndex("c", "count");

    // Every count value 0..n-1 should be findable.
    for (0..n) |i| {
        const got = try c.findOne("count", .{ .i64 = @intCast(i) });
        if (got == null) {
            std.debug.print("MISSING count={d}\n", .{i});
            return error.IndexEntryMissing;
        }
    }
}

test "lock-free snapshot reads from many threads while main writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "lockfree.db");
    defer db.close();

    const c = db.collection("c");
    const n: usize = 200;
    try db.begin();
    for (0..n) |i| {
        const d = try buildDoc("snapdoc", @intCast(i));
        defer ally.free(d);
        _ = try c.insert(d);
    }
    try db.commit();

    // Capture a snapshot. From here on, any number of threads can read
    // through it without acquiring any mutex.
    var snap = try db.snapshot();
    defer snap.deinit();
    try testing.expect(snap.lock_free);

    const ReaderArgs = struct { snap: Snapshot, total: u64 = 0 };
    const Reader = struct {
        fn run(args: *ReaderArgs) !void {
            const sc = args.snap.collection("c");
            // Each thread fully iterates the snapshot via the lock-free path.
            for (0..5) |_| {
                var it = try sc.iterator(testing.allocator);
                defer it.deinit();
                while (try it.next()) |_| args.total += 1;
            }
        }
    };

    const num_threads = 4;
    var args: [num_threads]ReaderArgs = .{ .{ .snap = snap }, .{ .snap = snap }, .{ .snap = snap }, .{ .snap = snap } };
    var threads: [num_threads]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Reader.run, .{&args[i]});
    }

    // Concurrently with the readers, push more writes through the
    // primary collection. The lock-free snapshot must NOT see them.
    for (0..50) |i| {
        const d = try buildDoc("after-snap", @intCast(i));
        defer ally.free(d);
        _ = try c.insert(d);
    }

    for (threads) |t| t.join();

    // Each reader iterated 5 full passes of the 200-doc snapshot.
    for (args) |a| try testing.expectEqual(@as(u64, n * 5), a.total);

    // The live collection sees both pre- and post-snapshot inserts.
    try testing.expectEqual(@as(u64, n + 50), try c.count(ally));
}

test "indexed range scan: inclusive, exclusive, half-open" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "range.db");
    defer db.close();

    const c = db.collection("c");
    try db.begin();
    var i: i64 = 0;
    while (i < 20) : (i += 1) {
        const d = try buildDoc("d", i);
        defer ally.free(d);
        _ = try c.insert(d);
    }
    try db.commit();
    try db.createIndex("c", "count");

    const collect = struct {
        fn collect(coll: Collection, lo: index_mod.Bound, hi: index_mod.Bound, out: *std.ArrayList(u64), allocator: std.mem.Allocator) !void {
            var it = try coll.findRange(allocator, "count", lo, hi);
            defer it.deinit();
            while (try it.next()) |id| try out.append(allocator, id);
        }
    }.collect;

    // Inclusive [5, 10]
    {
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(ally);
        try collect(c, .{ .inclusive = .{ .i64 = 5 } }, .{ .inclusive = .{ .i64 = 10 } }, &ids, ally);
        try testing.expectEqual(@as(usize, 6), ids.items.len); // 5,6,7,8,9,10
    }

    // Exclusive (5, 10)
    {
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(ally);
        try collect(c, .{ .exclusive = .{ .i64 = 5 } }, .{ .exclusive = .{ .i64 = 10 } }, &ids, ally);
        try testing.expectEqual(@as(usize, 4), ids.items.len); // 6,7,8,9
    }

    // Half-open [, 3]
    {
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(ally);
        try collect(c, .none, .{ .inclusive = .{ .i64 = 3 } }, &ids, ally);
        try testing.expectEqual(@as(usize, 4), ids.items.len); // 0..3
    }

    // Half-open (15,
    {
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(ally);
        try collect(c, .{ .exclusive = .{ .i64 = 15 } }, .none, &ids, ally);
        try testing.expectEqual(@as(usize, 4), ids.items.len); // 16..19
    }

    // Empty range (4, 4)
    {
        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(ally);
        try collect(c, .{ .exclusive = .{ .i64 = 4 } }, .{ .exclusive = .{ .i64 = 4 } }, &ids, ally);
        try testing.expectEqual(@as(usize, 0), ids.items.len);
    }
}

test "indexed range scan: negative i64 values sort correctly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "range-neg.db");
    defer db.close();

    const c = db.collection("c");
    const values = [_]i64{ -100, -10, -1, 0, 1, 10, 100 };
    for (values) |v| {
        const d = try buildDoc("d", v);
        defer ally.free(d);
        _ = try c.insert(d);
    }
    try db.createIndex("c", "count");

    // Range [-10, 1] should include -10, -1, 0, 1.
    var it = try c.findRange(ally, "count", .{ .inclusive = .{ .i64 = -10 } }, .{ .inclusive = .{ .i64 = 1 } });
    defer it.deinit();
    var count: u32 = 0;
    while (try it.next()) |_| count += 1;
    try testing.expectEqual(@as(u32, 4), count);
}

test "indexed range scan: string values" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "range-str.db");
    defer db.close();

    const c = db.collection("c");
    const names = [_][]const u8{ "alice", "bob", "carol", "dave", "eve" };
    for (names) |n| {
        const d = try buildDoc(n, 0);
        defer ally.free(d);
        _ = try c.insert(d);
    }
    try db.createIndex("c", "name");

    // ["bob", "dave"] inclusive — should match bob, carol, dave.
    var it = try c.findRange(ally, "name", .{ .inclusive = .{ .string = "bob" } }, .{ .inclusive = .{ .string = "dave" } });
    defer it.deinit();
    var count: u32 = 0;
    while (try it.next()) |_| count += 1;
    try testing.expectEqual(@as(u32, 3), count);
}

test "lock-free range scan from snapshot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "range-snap.db");
    defer db.close();

    const c = db.collection("c");
    var i: i64 = 0;
    while (i < 50) : (i += 1) {
        const d = try buildDoc("d", i);
        defer ally.free(d);
        _ = try c.insert(d);
    }
    try db.createIndex("c", "count");

    var snap = try db.snapshot();
    defer snap.deinit();
    try testing.expect(snap.lock_free);

    // Insert more after snapshot — shouldn't appear in the range scan.
    while (i < 100) : (i += 1) {
        const d = try buildDoc("d", i);
        defer ally.free(d);
        _ = try c.insert(d);
    }

    var it = try snap.collection("c").findRange(
        ally,
        "count",
        .{ .inclusive = .{ .i64 = 10 } },
        .{ .inclusive = .{ .i64 = 1000 } },
    );
    defer it.deinit();
    var count: u32 = 0;
    while (try it.next()) |_| count += 1;
    // Snapshot has values 0..49; range [10, 1000] selects 10..49 = 40 values.
    try testing.expectEqual(@as(u32, 40), count);
}

test "lock-free indexed findOne from many threads while main writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "lockfree-idx.db");
    defer db.close();

    const c = db.collection("c");
    const n: i64 = 200;
    try db.begin();
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const d = try buildDoc("d", i);
        defer ally.free(d);
        _ = try c.insert(d);
    }
    try db.commit();
    try db.createIndex("c", "count");

    var snap = try db.snapshot();
    defer snap.deinit();
    try testing.expect(snap.lock_free);

    const ReaderArgs = struct { snap: Snapshot, hits: u32 = 0 };
    const Reader = struct {
        fn run(args: *ReaderArgs) !void {
            const sc = args.snap.collection("c");
            // Each thread does 200 indexed lookups, no mutex acquired.
            var k: i64 = 0;
            while (k < 200) : (k += 1) {
                if (try sc.findOne("count", .{ .i64 = k })) |_| args.hits += 1;
            }
        }
    };

    const num_threads = 4;
    var args: [num_threads]ReaderArgs = .{ .{ .snap = snap }, .{ .snap = snap }, .{ .snap = snap }, .{ .snap = snap } };
    var threads: [num_threads]std.Thread = undefined;
    for (&threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, Reader.run, .{&args[idx]});
    }

    // Push writes through the live collection while readers run their
    // indexed lookups against the snapshot. Snapshot must be unaffected.
    var k: i64 = n;
    while (k < n + 50) : (k += 1) {
        const d = try buildDoc("late", k);
        defer ally.free(d);
        _ = try c.insert(d);
    }

    for (threads) |t| t.join();

    // Every thread saw all 200 pre-snapshot count values.
    for (args) |a| try testing.expectEqual(@as(u32, 200), a.hits);
}

test "concurrent inserts from multiple threads" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "concur.db");
    defer db.close();

    const Args = struct { db: *Db, count: u32, base: u32 };
    const Worker = struct {
        fn run(args: Args) !void {
            var name_buf: [32]u8 = undefined;
            for (0..args.count) |i| {
                var b = Builder.init(testing.allocator);
                defer b.deinit();
                try b.beginDocument();
                const name = try std.fmt.bufPrint(&name_buf, "w{d}-{d}", .{ args.base, i });
                try b.putString("name", name);
                try b.putI64("idx", @intCast(args.base * args.count + i));
                try b.endDocument();
                const bytes = try b.finish();
                defer testing.allocator.free(bytes);
                _ = try args.db.collection("c").insert(bytes);
            }
        }
    };

    const num_threads = 4;
    const per_thread = 50;
    var threads: [num_threads]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        const args: Args = .{ .db = &db, .count = per_thread, .base = @intCast(i) };
        t.* = try std.Thread.spawn(.{}, Worker.run, .{args});
    }
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u64, num_threads * per_thread), try db.collection("c").count(ally));
}


test "OptimisticTxn: insert + get + commit roundtrip; reads-your-own-writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ.db");
    defer db.close();

    const alice = try buildDoc("alice", 30);
    defer ally.free(alice);

    var saved_id: u64 = undefined;
    {
        var txn = try db.beginOptimistic();
        errdefer txn.abort();
        const users = txn.collection("users");
        saved_id = try users.insert(alice);

        // get() finds the staged write — read_set should NOT have an
        // entry for this, because we'd be validating a value we just
        // wrote ourselves.
        const got = (try users.get(ally, saved_id)).?;
        defer ally.free(got);
        try testing.expectEqualSlices(u8, alice, got);

        try testing.expectEqual(@as(usize, 1), txn.write_set.items.len);
        try testing.expectEqual(@as(usize, 0), txn.read_set.items.len);
        try testing.expectEqual(OptimisticTxn.WriteKind.insert, txn.write_set.items[0].kind);
        try testing.expectEqual(saved_id, txn.write_set.items[0].doc_id);
        try testing.expectEqualStrings("users", txn.write_set.items[0].coll);
        try testing.expectEqualSlices(u8, alice, txn.write_set.items[0].value);

        try txn.commit();
    }

    // Doc must be visible after commit via the regular API.
    const after = (try db.collection("users").get(ally, saved_id)).?;
    defer ally.free(after);
    try testing.expectEqualSlices(u8, alice, after);
}

test "OptimisticTxn: get of unstaged doc records a read_set entry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-read.db");
    defer db.close();

    // Pre-seed a doc, checkpoint so it's reachable from snapshot.
    const seed = try buildDoc("seed", 7);
    defer ally.free(seed);
    const seed_id = try db.collection("c").insert(seed);
    try db.checkpoint();

    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    const c = txn.collection("c");

    const got = (try c.get(ally, seed_id)).?;
    defer ally.free(got);
    try testing.expectEqualSlices(u8, seed, got);

    // This was a snapshot read, not own-write.
    try testing.expectEqual(@as(usize, 0), txn.write_set.items.len);
    try testing.expectEqual(@as(usize, 1), txn.read_set.items.len);
    try testing.expectEqual(seed_id, txn.read_set.items[0].doc_id);
    try testing.expect(txn.read_set.items[0].value_hash != 0);

    txn.abort();
}

test "OptimisticTxn: WriteConflict when read value changes between begin and commit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-conflict.db");
    defer db.close();

    const v1 = try buildDoc("v1", 1);
    defer ally.free(v1);
    const v2 = try buildDoc("v2", 2);
    defer ally.free(v2);

    const seed_id = try db.collection("c").insert(v1);
    try db.checkpoint();

    // Txn A starts, reads v1 from snapshot.
    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    const c = txn.collection("c");
    const got = (try c.get(ally, seed_id)).?;
    defer ally.free(got);
    try testing.expectEqualSlices(u8, v1, got);

    // While A is mid-work, another writer overwrites the doc.
    try db.collection("c").put(seed_id, v2);

    // Txn A queues a write of its own and tries to commit. Validation
    // sees that seed_id no longer holds v1 → conflict.
    try c.put(seed_id, v2);
    try testing.expectError(Error.WriteConflict, txn.commit());
}

test "OptimisticTxn: two concurrent txns inserting disjoint docs both succeed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-disjoint.db");
    defer db.close();

    const a = try buildDoc("a", 1);
    defer ally.free(a);
    const b = try buildDoc("b", 2);
    defer ally.free(b);

    var ta = try db.beginOptimistic();
    errdefer ta.abort();
    const ca = ta.collection("c");
    const id_a = try ca.insert(a);

    var tb = try db.beginOptimistic();
    errdefer tb.abort();
    const cb = tb.collection("c");
    const id_b = try cb.insert(b);

    // Disjoint doc_ids (each came from the atomic counter).
    try testing.expect(id_a != id_b);

    try ta.commit();
    try tb.commit();

    try testing.expectEqual(@as(u64, 2), try db.collection("c").count(ally));
}

test "OptimisticTxn: delete of staged doc returns null on subsequent get" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-del.db");
    defer db.close();

    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    const c = txn.collection("c");
    const d = try buildDoc("x", 1);
    defer ally.free(d);
    const id = try c.insert(d);

    _ = try c.delete(id);

    // After staged delete, get should see nothing.
    try testing.expect((try c.get(ally, id)) == null);
    txn.abort();
}

test "OptimisticTxn: abort discards writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-abort.db");
    defer db.close();

    var saved_id: u64 = undefined;
    {
        var txn = try db.beginOptimistic();
        const c = txn.collection("c");
        const d = try buildDoc("a", 1);
        defer ally.free(d);
        saved_id = try c.insert(d);
        txn.abort();
    }

    try testing.expect((try db.collection("c").get(ally, saved_id)) == null);
}

test "OptimisticTxn: start_root captured at begin reflects snapshot version" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-root.db");
    defer db.close();

    // Seed one doc, checkpoint so the live root is non-zero.
    const seed = try buildDoc("seed", 0);
    defer ally.free(seed);
    _ = try db.collection("c").insert(seed);
    try db.checkpoint();

    const root_before = db.pager.bTreeRoot();
    var txn = try db.beginOptimistic();
    try testing.expectEqual(root_before, txn.start_root);
    txn.abort();
}


test "OptimisticTxn: 4 threads, disjoint inserts, all commit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-concurrent.db");
    defer db.close();

    const Args = struct { db: *Db, base: u32, n: u32 };
    const Worker = struct {
        fn run(args: Args) !void {
            var name_buf: [32]u8 = undefined;
            var i: u32 = 0;
            while (i < args.n) : (i += 1) {
                var txn = try args.db.beginOptimistic();
                errdefer txn.abort();
                const c = txn.collection("c");
                var b = Builder.init(testing.allocator);
                defer b.deinit();
                try b.beginDocument();
                const name = try std.fmt.bufPrint(&name_buf, "w{d}-{d}", .{ args.base, i });
                try b.putString("name", name);
                try b.putI64("idx", @intCast(args.base * args.n + i));
                try b.endDocument();
                const bytes = try b.finish();
                defer testing.allocator.free(bytes);
                _ = try c.insert(bytes);
                try txn.commit();
            }
        }
    };

    const num_threads = 4;
    const per_thread = 25;
    var threads: [num_threads]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        const args: Args = .{ .db = &db, .base = @intCast(i), .n = per_thread };
        t.* = try std.Thread.spawn(.{}, Worker.run, .{args});
    }
    for (threads) |t| t.join();

    try testing.expectEqual(
        @as(u64, num_threads * per_thread),
        try db.collection("c").count(ally),
    );
}

test "Db.runOptimistic: success path commits without retry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-runopt.db");
    defer db.close();

    const Ctx = struct {
        doc: []const u8,
        out_id: *u64,
        fn run(self: *@This(), txn: *OptimisticTxn) !void {
            const c = txn.collection("c");
            self.out_id.* = try c.insert(self.doc);
        }
    };

    const d = try buildDoc("hello", 1);
    defer ally.free(d);
    var id: u64 = 0;
    var ctx = Ctx{ .doc = d, .out_id = &id };
    try db.runOptimistic(8, &ctx, Ctx.run);

    const got = (try db.collection("c").get(ally, id)).?;
    defer ally.free(got);
    try testing.expectEqualSlices(u8, d, got);
}

test "Db.runOptimistic: user-thrown error short-circuits, no retry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-runopt-err.db");
    defer db.close();

    const E = error{Boom};
    const Ctx = struct {
        attempts: *u32,
        fn run(self: *@This(), txn: *OptimisticTxn) !void {
            _ = txn;
            self.attempts.* += 1;
            return E.Boom;
        }
    };

    var attempts: u32 = 0;
    var ctx = Ctx{ .attempts = &attempts };
    try testing.expectError(E.Boom, db.runOptimistic(8, &ctx, Ctx.run));
    try testing.expectEqual(@as(u32, 1), attempts);
}

test "OptimisticTxn: blind put detects lost-update via implicit read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-blind-put.db");
    defer db.close();

    const v0 = try buildDoc("v0", 0);
    defer ally.free(v0);
    const v1 = try buildDoc("v1", 1);
    defer ally.free(v1);
    const v2 = try buildDoc("v2", 2);
    defer ally.free(v2);

    // Seed the doc.
    const id = try db.collection("c").insert(v0);
    try db.checkpoint();

    // Txn A starts. It does NOT call get — just a blind put.
    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    const c = txn.collection("c");
    try c.put(id, v1);

    // The implicit-read-on-write should have populated read_set with
    // the doc's value at start_root (= v0).
    try testing.expectEqual(@as(usize, 1), txn.read_set.items.len);
    try testing.expectEqual(@as(usize, 1), txn.write_set.items.len);
    const v0_hash = std.hash.Wyhash.hash(0, v0);
    try testing.expectEqual(v0_hash, txn.read_set.items[0].value_hash);

    // Concurrent committer changes the doc.
    try db.collection("c").put(id, v2);

    // A's commit should now see the read_set mismatch and conflict.
    try testing.expectError(Error.WriteConflict, txn.commit());
}

test "OptimisticTxn: same-key put twice records read_set only once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-dup-put.db");
    defer db.close();

    const seed = try buildDoc("seed", 0);
    defer ally.free(seed);
    const a = try buildDoc("a", 1);
    defer ally.free(a);
    const b = try buildDoc("b", 2);
    defer ally.free(b);

    const id = try db.collection("c").insert(seed);
    try db.checkpoint();

    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    const c = txn.collection("c");

    try c.put(id, a);
    try c.put(id, b);

    // First put established the read_set entry; second put saw an
    // existing own-write and skipped recordRead.
    try testing.expectEqual(@as(usize, 1), txn.read_set.items.len);
    try testing.expectEqual(@as(usize, 2), txn.write_set.items.len);

    // Final live state after commit should be `b`.
    try txn.commit();
    const got = (try db.collection("c").get(ally, id)).?;
    defer ally.free(got);
    try testing.expectEqualSlices(u8, b, got);
}

test "OptimisticTxn: insert does not populate read_set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-insert-noread.db");
    defer db.close();

    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    const c = txn.collection("c");
    const d = try buildDoc("x", 1);
    defer ally.free(d);
    _ = try c.insert(d);

    try testing.expectEqual(@as(usize, 0), txn.read_set.items.len);
    try testing.expectEqual(@as(usize, 1), txn.write_set.items.len);

    try txn.commit();
}

test "OptimisticTxn: concurrent disjoint blind puts both succeed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-disjoint-put.db");
    defer db.close();

    const seed = try buildDoc("seed", 0);
    defer ally.free(seed);
    const v_a = try buildDoc("a", 1);
    defer ally.free(v_a);
    const v_b = try buildDoc("b", 2);
    defer ally.free(v_b);

    const id_a = try db.collection("c").insert(seed);
    const id_b = try db.collection("c").insert(seed);
    try db.checkpoint();

    var ta = try db.beginOptimistic();
    errdefer ta.abort();
    var tb = try db.beginOptimistic();
    errdefer tb.abort();

    try ta.collection("c").put(id_a, v_a);
    try tb.collection("c").put(id_b, v_b);

    try ta.commit();
    try tb.commit();

    const got_a = (try db.collection("c").get(ally, id_a)).?;
    defer ally.free(got_a);
    const got_b = (try db.collection("c").get(ally, id_b)).?;
    defer ally.free(got_b);
    try testing.expectEqualSlices(u8, v_a, got_a);
    try testing.expectEqualSlices(u8, v_b, got_b);
}

test "OptimisticTxn: findOne phantom — concurrent insert with smaller doc_id triggers conflict" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-fo-phantom.db");
    defer db.close();

    // Seed two existing alices, then drop the lower-id one so the
    // index has a gap below the surviving match.
    const alice_a = try buildDoc("alice", 100);
    defer ally.free(alice_a);
    const alice_b = try buildDoc("alice", 200);
    defer ally.free(alice_b);

    const id_low = try db.collection("u").insert(alice_a);
    const id_high = try db.collection("u").insert(alice_b);
    _ = try db.collection("u").delete(id_low);
    try db.createIndex("u", "name");
    try db.checkpoint();

    // Txn A reads "alice" and sees id_high as the first match.
    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    const got = try txn.collection("u").findOne("name", .{ .string = "alice" });
    try testing.expectEqual(@as(?u64, id_high), got);

    // Concurrent committer inserts a new "alice" — it gets a fresh
    // doc_id from the atomic counter, which is now ABOVE id_high; so
    // findOne's first match is unchanged. NO conflict expected.
    const alice_c = try buildDoc("alice", 300);
    defer ally.free(alice_c);
    const id_higher = try db.collection("u").insert(alice_c);
    try testing.expect(id_higher > id_high);
    try txn.commit();

    // Now reverse: a phantom that DOES change first_match. Re-seed.
    const bob = try buildDoc("bob", 1);
    defer ally.free(bob);
    const id_first_bob = try db.collection("u").insert(bob);
    try db.checkpoint();

    var txn2 = try db.beginOptimistic();
    errdefer txn2.abort();
    const got2 = try txn2.collection("u").findOne("name", .{ .string = "bob" });
    try testing.expectEqual(@as(?u64, id_first_bob), got2);

    // External committer deletes the only match — first_match becomes null.
    _ = try db.collection("u").delete(id_first_bob);
    try testing.expectError(Error.WriteConflict, txn2.commit());
}

test "OptimisticTxn: findOne(null result) detects phantom insert into the predicate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-fo-empty.db");
    defer db.close();

    try db.createIndex("u", "name");

    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    // Predicate has zero matches at start_root.
    const got = try txn.collection("u").findOne("name", .{ .string = "carol" });
    try testing.expectEqual(@as(?u64, null), got);

    // Concurrent inserter creates a "carol" — predicate now has a match.
    const carol = try buildDoc("carol", 1);
    defer ally.free(carol);
    _ = try db.collection("u").insert(carol);

    // Validation re-runs findOne, sees a match where there was none → conflict.
    try testing.expectError(Error.WriteConflict, txn.commit());
}

test "OptimisticTxn: range_set entry recorded for each findOne call" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-fo-record.db");
    defer db.close();

    try db.createIndex("u", "name");

    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    _ = try txn.collection("u").findOne("name", .{ .string = "alice" });
    _ = try txn.collection("u").findOne("name", .{ .string = "bob" });

    try testing.expectEqual(@as(usize, 2), txn.range_set.items.len);
    try testing.expectEqualStrings("alice", txn.range_set.items[0].find_one.value.string);
    try testing.expectEqualStrings("bob", txn.range_set.items[1].find_one.value.string);
    txn.abort();
}

test "OptimisticTxn: findRange phantom — concurrent insert into observed range conflicts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-fr-phantom.db");
    defer db.close();

    // Seed three docs with counts 10, 20, 30. Index on count.
    const a = try buildDoc("a", 10);
    defer ally.free(a);
    const b = try buildDoc("b", 20);
    defer ally.free(b);
    const c = try buildDoc("c", 30);
    defer ally.free(c);
    _ = try db.collection("u").insert(a);
    _ = try db.collection("u").insert(b);
    _ = try db.collection("u").insert(c);
    try db.createIndex("u", "count");
    try db.checkpoint();

    // Txn reads the [15, 25] range — sees only b.
    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    var it = try txn.collection("u").findRange(
        ally,
        "count",
        .{ .inclusive = .{ .i64 = 15 } },
        .{ .inclusive = .{ .i64 = 25 } },
    );
    defer it.deinit();
    var n: u32 = 0;
    while (try it.next()) |_| n += 1;
    try testing.expectEqual(@as(u32, 1), n);

    // Concurrent committer drops a doc with count=20 (clone of b) into
    // the observed range.
    const d = try buildDoc("d", 20);
    defer ally.free(d);
    _ = try db.collection("u").insert(d);

    try testing.expectError(Error.WriteConflict, txn.commit());
}

test "OptimisticTxn: findRange — disjoint range query is unaffected by writes outside it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-fr-disjoint.db");
    defer db.close();

    const a = try buildDoc("a", 10);
    defer ally.free(a);
    const b = try buildDoc("b", 20);
    defer ally.free(b);
    _ = try db.collection("u").insert(a);
    _ = try db.collection("u").insert(b);
    try db.createIndex("u", "count");
    try db.checkpoint();

    // Txn reads [15, 25] — sees b.
    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    var it = try txn.collection("u").findRange(
        ally,
        "count",
        .{ .inclusive = .{ .i64 = 15 } },
        .{ .inclusive = .{ .i64 = 25 } },
    );
    defer it.deinit();
    while (try it.next()) |_| {}

    // Concurrent insert with count=100 — out of range, no conflict.
    const c = try buildDoc("c", 100);
    defer ally.free(c);
    _ = try db.collection("u").insert(c);

    try txn.commit();
}

test "OptimisticTxn: findAll phantom — concurrent insert with same value conflicts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-fa-phantom.db");
    defer db.close();

    const alice = try buildDoc("alice", 1);
    defer ally.free(alice);
    _ = try db.collection("u").insert(alice);
    try db.createIndex("u", "name");
    try db.checkpoint();

    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    var it = try txn.collection("u").findAll(ally, "name", .{ .string = "alice" });
    defer it.deinit();
    var seen: u32 = 0;
    while (try it.next()) |_| seen += 1;
    try testing.expectEqual(@as(u32, 1), seen);

    // Concurrent committer adds another alice.
    const a2 = try buildDoc("alice", 2);
    defer ally.free(a2);
    _ = try db.collection("u").insert(a2);

    try testing.expectError(Error.WriteConflict, txn.commit());
}

test "Db.runOptimistic: retries N times on conflict, succeeds when contention stops" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-retry.db");
    defer db.close();

    const seed_doc = try buildDoc("seed", 0);
    defer ally.free(seed_doc);
    const id = try db.collection("c").insert(seed_doc);
    try db.checkpoint();

    // The user-supplied func reads the doc (records read_set), then —
    // on the *first* `target_conflicts` invocations — bumps the live
    // doc through the regular API to force a WriteConflict at commit.
    // After enough conflicts it stops bumping and the retry succeeds.
    const Ctx = struct {
        db: *Db,
        id: u64,
        conflicts_to_force: u32,
        attempts: *u32,

        fn run(self: *@This(), txn: *OptimisticTxn) !void {
            self.attempts.* += 1;
            const c = txn.collection("c");
            const v = try c.get(testing.allocator, self.id);
            defer if (v) |vv| testing.allocator.free(vv);
            if (self.attempts.* <= self.conflicts_to_force) {
                // Step the live doc out from under us. This commit
                // happens on the same thread but uses the pessimistic
                // path, so it doesn't touch txn's snapshot — when txn
                // commits, validation will see the change and conflict.
                var b = Builder.init(testing.allocator);
                defer b.deinit();
                try b.beginDocument();
                try b.putI64("count", @intCast(self.attempts.*));
                try b.endDocument();
                const bytes = try b.finish();
                defer testing.allocator.free(bytes);
                try self.db.collection("c").put(self.id, bytes);
            }
            // Always do at least one OCC write so the apply phase has
            // something to do.
            const new_v = try buildDoc("after-retry", 999);
            defer testing.allocator.free(new_v);
            try c.put(self.id, new_v);
        }
    };

    var attempts: u32 = 0;
    var ctx = Ctx{ .db = &db, .id = id, .conflicts_to_force = 3, .attempts = &attempts };
    try db.runOptimistic(8, &ctx, Ctx.run);
    // Expected: 3 forced conflicts + 1 successful = 4 attempts.
    try testing.expectEqual(@as(u32, 4), attempts);

    const final = (try db.collection("c").get(ally, id)).?;
    defer ally.free(final);
    const parsed = try doc_mod.parse(final);
    const name = (try parsed.object.get("name")).?.string;
    try testing.expectEqualStrings("after-retry", name);
}

test "Db.runOptimistic: returns RetryBudgetExhausted when conflicts persist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-budget.db");
    defer db.close();

    const seed_doc = try buildDoc("seed", 0);
    defer ally.free(seed_doc);
    const id = try db.collection("c").insert(seed_doc);
    try db.checkpoint();

    // Always force a conflict — every attempt bumps the live doc.
    const Ctx = struct {
        db: *Db,
        id: u64,
        attempts: *u32,
        fn run(self: *@This(), txn: *OptimisticTxn) !void {
            self.attempts.* += 1;
            const c = txn.collection("c");
            const v = try c.get(testing.allocator, self.id);
            defer if (v) |vv| testing.allocator.free(vv);
            var b = Builder.init(testing.allocator);
            defer b.deinit();
            try b.beginDocument();
            try b.putI64("count", @intCast(self.attempts.*));
            try b.endDocument();
            const bytes = try b.finish();
            defer testing.allocator.free(bytes);
            try self.db.collection("c").put(self.id, bytes);
            // Stage an OCC put as well so the txn has work to do.
            const new_v = try buildDoc("nope", 0);
            defer testing.allocator.free(new_v);
            try c.put(self.id, new_v);
        }
    };

    var attempts: u32 = 0;
    var ctx = Ctx{ .db = &db, .id = id, .attempts = &attempts };
    // Cap at 3 so the test stays fast (backoff caps at 10ms × 3 attempts).
    try testing.expectError(Error.RetryBudgetExhausted, db.runOptimistic(3, &ctx, Ctx.run));
    try testing.expectEqual(@as(u32, 3), attempts);
}

test "OptimisticTxn: iterator exhausted, concurrent insert appends → conflict" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-it-append.db");
    defer db.close();

    const a = try buildDoc("a", 1);
    defer ally.free(a);
    const b = try buildDoc("b", 2);
    defer ally.free(b);
    _ = try db.collection("c").insert(a);
    _ = try db.collection("c").insert(b);
    try db.checkpoint();

    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    var it = try txn.collection("c").iterator(ally);
    defer it.deinit();
    var n: u32 = 0;
    while (try it.next()) |_| n += 1;
    try testing.expectEqual(@as(u32, 2), n);

    // Concurrent committer appends a third doc.
    const c = try buildDoc("c", 3);
    defer ally.free(c);
    _ = try db.collection("c").insert(c);

    try testing.expectError(Error.WriteConflict, txn.commit());
}

test "OptimisticTxn: iterator early break — concurrent insert past break point does not conflict" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-it-break.db");
    defer db.close();

    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        const d = try buildDoc("d", i);
        defer ally.free(d);
        _ = try db.collection("c").insert(d);
    }
    try db.checkpoint();

    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    var it = try txn.collection("c").iterator(ally);
    defer it.deinit();
    // Read only the first two — break early.
    _ = try it.next();
    _ = try it.next();

    // Concurrent committer appends a sixth doc — past our observed
    // prefix, so the txn doesn't depend on it.
    const x = try buildDoc("x", 99);
    defer ally.free(x);
    _ = try db.collection("c").insert(x);

    try txn.commit();
}

test "OptimisticTxn: iterator + concurrent delete in observed prefix → conflict" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ-it-del.db");
    defer db.close();

    const a = try buildDoc("a", 1);
    defer ally.free(a);
    const b = try buildDoc("b", 2);
    defer ally.free(b);
    const c = try buildDoc("c", 3);
    defer ally.free(c);
    const id_a = try db.collection("c").insert(a);
    _ = try db.collection("c").insert(b);
    _ = try db.collection("c").insert(c);
    try db.checkpoint();

    var txn = try db.beginOptimistic();
    errdefer txn.abort();
    var it = try txn.collection("c").iterator(ally);
    defer it.deinit();
    while (try it.next()) |_| {}

    // Concurrent committer deletes the first observed doc.
    _ = try db.collection("c").delete(id_a);

    try testing.expectError(Error.WriteConflict, txn.commit());
}

test "compound index: create + insert + findOne + drop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "compound.db");
    defer db.close();

    // Build a doc with both `last` and `first`.
    const alice_smith = blk: {
        var b = Builder.init(ally);
        defer b.deinit();
        try b.beginDocument();
        try b.putString("last", "smith");
        try b.putString("first", "alice");
        try b.endDocument();
        break :blk try b.finish();
    };
    defer ally.free(alice_smith);
    const bob_smith = blk: {
        var b = Builder.init(ally);
        defer b.deinit();
        try b.beginDocument();
        try b.putString("last", "smith");
        try b.putString("first", "bob");
        try b.endDocument();
        break :blk try b.finish();
    };
    defer ally.free(bob_smith);

    const users = db.collection("users");
    const id_a = try users.insert(alice_smith);
    const id_b = try users.insert(bob_smith);

    try db.createCompoundIndex("users", &.{ "last", "first" });

    const got_a = try users.findOneCompound(
        &.{ "last", "first" },
        &.{ .{ .string = "smith" }, .{ .string = "alice" } },
    );
    try testing.expectEqual(@as(?u64, id_a), got_a);

    const got_b = try users.findOneCompound(
        &.{ "last", "first" },
        &.{ .{ .string = "smith" }, .{ .string = "bob" } },
    );
    try testing.expectEqual(@as(?u64, id_b), got_b);

    // Wrong field order is a different (unregistered) index.
    try testing.expectError(Error.NoSuchIndex, users.findOneCompound(
        &.{ "first", "last" },
        &.{ .{ .string = "alice" }, .{ .string = "smith" } },
    ));

    // No-such-tuple lookup returns null (still uses the same index).
    const nope = try users.findOneCompound(
        &.{ "last", "first" },
        &.{ .{ .string = "smith" }, .{ .string = "carol" } },
    );
    try testing.expect(nope == null);

    try db.dropCompoundIndex("users", &.{ "last", "first" });
    try testing.expectError(Error.NoSuchIndex, users.findOneCompound(
        &.{ "last", "first" },
        &.{ .{ .string = "smith" }, .{ .string = "alice" } },
    ));
}

test "compound index: auto-maintained on insert / put / delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "compound-auto.db");
    defer db.close();

    try db.createCompoundIndex("c", &.{ "last", "first" });

    const make = struct {
        fn make(allocator: std.mem.Allocator, last: []const u8, first: []const u8) ![]u8 {
            var b = Builder.init(allocator);
            defer b.deinit();
            try b.beginDocument();
            try b.putString("last", last);
            try b.putString("first", first);
            try b.endDocument();
            return try b.finish();
        }
    }.make;

    const c = db.collection("c");
    const a1 = try make(ally, "smith", "alice");
    defer ally.free(a1);
    const id = try c.insert(a1);

    const fields = &[_][]const u8{ "last", "first" };
    try testing.expectEqual(@as(?u64, id), try c.findOneCompound(
        fields,
        &.{ .{ .string = "smith" }, .{ .string = "alice" } },
    ));

    // put → old (smith, alice) entry removed; new (jones, alicia) added.
    const a2 = try make(ally, "jones", "alicia");
    defer ally.free(a2);
    try c.put(id, a2);
    try testing.expect((try c.findOneCompound(
        fields,
        &.{ .{ .string = "smith" }, .{ .string = "alice" } },
    )) == null);
    try testing.expectEqual(@as(?u64, id), try c.findOneCompound(
        fields,
        &.{ .{ .string = "jones" }, .{ .string = "alicia" } },
    ));

    // delete → entry gone.
    _ = try c.delete(id);
    try testing.expect((try c.findOneCompound(
        fields,
        &.{ .{ .string = "jones" }, .{ .string = "alicia" } },
    )) == null);
}

test "compound index: reopen restores definition and entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    const io = testing.io;

    var saved_id: u64 = undefined;
    {
        var db = try Db.open(ally, io, tmp.dir, "compound-reopen.db");
        defer db.close();
        try db.createCompoundIndex("c", &.{ "last", "first" });

        var b = Builder.init(ally);
        defer b.deinit();
        try b.beginDocument();
        try b.putString("last", "smith");
        try b.putString("first", "alice");
        try b.endDocument();
        const bytes = try b.finish();
        defer ally.free(bytes);
        saved_id = try db.collection("c").insert(bytes);
        try db.checkpoint();
    }
    {
        var db = try Db.open(ally, io, tmp.dir, "compound-reopen.db");
        defer db.close();
        const got = try db.collection("c").findOneCompound(
            &.{ "last", "first" },
            &.{ .{ .string = "smith" }, .{ .string = "alice" } },
        );
        try testing.expectEqual(@as(?u64, saved_id), got);
    }
}

test "compound index: build-while-scan picks up pre-existing docs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "compound-build.db");
    defer db.close();

    const make = struct {
        fn make(allocator: std.mem.Allocator, last: []const u8, first: []const u8) ![]u8 {
            var b = Builder.init(allocator);
            defer b.deinit();
            try b.beginDocument();
            try b.putString("last", last);
            try b.putString("first", first);
            try b.endDocument();
            return try b.finish();
        }
    }.make;

    const c = db.collection("c");
    var ids: [3]u64 = undefined;
    {
        const x = try make(ally, "smith", "a");
        defer ally.free(x);
        ids[0] = try c.insert(x);
    }
    {
        const x = try make(ally, "smith", "b");
        defer ally.free(x);
        ids[1] = try c.insert(x);
    }
    {
        const x = try make(ally, "jones", "c");
        defer ally.free(x);
        ids[2] = try c.insert(x);
    }

    try db.createCompoundIndex("c", &.{ "last", "first" });

    try testing.expectEqual(@as(?u64, ids[0]), try c.findOneCompound(
        &.{ "last", "first" },
        &.{ .{ .string = "smith" }, .{ .string = "a" } },
    ));
    try testing.expectEqual(@as(?u64, ids[1]), try c.findOneCompound(
        &.{ "last", "first" },
        &.{ .{ .string = "smith" }, .{ .string = "b" } },
    ));
    try testing.expectEqual(@as(?u64, ids[2]), try c.findOneCompound(
        &.{ "last", "first" },
        &.{ .{ .string = "jones" }, .{ .string = "c" } },
    ));
}
