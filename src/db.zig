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
    /// set. Caller is expected to retry. Phase 1 reserves the error in
    /// the API surface but cannot yet produce it (txns still serialise
    /// on the data lock).
    WriteConflict,
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
    /// captures the current B+Tree root as its snapshot, accumulates
    /// writes into a private buffer, and validates them against the live
    /// tree at `commit()`.
    ///
    /// Phase 1: still serialises on `db.mu` (so behaviour matches
    /// `begin()`/`commit()` exactly — the read_set/write_set are
    /// recorded but unused). Phase 2 will release `db.mu` during the
    /// read+work phase and validate at commit, returning
    /// `error.WriteConflict` when validation fails.
    pub fn beginOptimistic(self: *Db) !OptimisticTxn {
        try self.begin();
        errdefer self.abort();
        return .{
            .db = self,
            .start_root = self.pager.bTreeRoot(),
            .arena = std.heap.ArenaAllocator.init(self.allocator),
            .read_set = .empty,
            .write_set = .empty,
        };
    }

    pub fn collection(self: *Db, name: []const u8) Collection {
        return .{ .db = self, .name = name };
    }

    /// Capture a consistent point-in-time view of the database. The
    /// returned `Snapshot` is **lock-free for reads** — readers from any
    /// thread can issue `get`/`iterator` calls concurrently with writers
    /// on the main thread, with no mutex acquisition on the read path.
    ///
    /// Implementation: we acquire the mutex briefly, force a `checkpoint`
    /// so every page reachable from the captured root is durable on disk,
    /// then release the mutex. Subsequent reads bypass the page cache and
    /// pager state entirely — they go straight to the file via `pread`,
    /// which POSIX guarantees is thread-safe per file descriptor.
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
        try self.pager.checkpoint();
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
/// Each txn captures `start_root` at begin time. Reads of documents are
/// recorded in `read_set` (with the doc's value hash); writes are
/// recorded in `write_set` and applied to the live B+Tree.
///
/// Phase 1 caveats:
///   - `db.mu` is held across the whole txn (still serialised).
///   - Reads via `findOne`/`findAll`/`findRange`/`iterator` are NOT yet
///     tracked in the read set — they're phantom-prone and need
///     range-tracking support that lands later.
///   - `read_set` / `write_set` are populated for plumbing, not yet
///     consulted at commit. Phase 2 wires up validation.
pub const OptimisticTxn = struct {
    db: *Db,
    start_root: pager_mod.PageId,
    arena: std.heap.ArenaAllocator,
    read_set: ArrayList(ReadSetEntry),
    write_set: ArrayList(WriteSetEntry),

    pub const WriteKind = enum { insert, put, delete };

    pub const ReadSetEntry = struct {
        coll: []const u8, // owned by `arena`
        doc_id: u64,
        /// Wyhash of the doc bytes at read time, or 0 sentinel when the
        /// read returned null. Validation in phase 2 re-reads and
        /// compares.
        value_hash: u64,
    };

    pub const WriteSetEntry = struct {
        coll: []const u8, // owned by `arena`
        doc_id: u64,
        kind: WriteKind,
    };

    pub fn collection(self: *OptimisticTxn, name: []const u8) TxnCollection {
        return .{ .txn = self, .name = name };
    }

    pub fn commit(self: *OptimisticTxn) !void {
        defer self.deinitBuffers();
        try self.db.commit();
    }

    pub fn abort(self: *OptimisticTxn) void {
        defer self.deinitBuffers();
        self.db.abort();
    }

    fn deinitBuffers(self: *OptimisticTxn) void {
        self.read_set.deinit(self.db.allocator);
        self.write_set.deinit(self.db.allocator);
        self.arena.deinit();
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

    fn recordWrite(self: *OptimisticTxn, coll: []const u8, doc_id: u64, kind: WriteKind) !void {
        const owned = try self.arena.allocator().dupe(u8, coll);
        try self.write_set.append(self.db.allocator, .{
            .coll = owned,
            .doc_id = doc_id,
            .kind = kind,
        });
    }
};

/// Collection handle bound to an `OptimisticTxn`. Mirrors `Collection`'s
/// API; the difference is each call updates the txn's read/write sets.
pub const TxnCollection = struct {
    txn: *OptimisticTxn,
    name: []const u8,

    fn underlying(self: TxnCollection) Collection {
        return self.txn.db.collection(self.name);
    }

    pub fn insert(self: TxnCollection, doc_bytes: []const u8) !u64 {
        const id = try self.underlying().insert(doc_bytes);
        try self.txn.recordWrite(self.name, id, .insert);
        return id;
    }

    pub fn put(self: TxnCollection, doc_id: u64, doc_bytes: []const u8) !void {
        try self.underlying().put(doc_id, doc_bytes);
        try self.txn.recordWrite(self.name, doc_id, .put);
    }

    pub fn delete(self: TxnCollection, doc_id: u64) !bool {
        const found = try self.underlying().delete(doc_id);
        try self.txn.recordWrite(self.name, doc_id, .delete);
        return found;
    }

    pub fn get(self: TxnCollection, allocator: Allocator, doc_id: u64) !?[]u8 {
        const result = try self.underlying().get(allocator, doc_id);
        try self.txn.recordRead(self.name, doc_id, result);
        return result;
    }

    pub fn iterator(self: TxnCollection, allocator: Allocator) !Iterator {
        return self.underlying().iterator(allocator);
    }

    pub fn count(self: TxnCollection, allocator: Allocator) !u64 {
        return self.underlying().count(allocator);
    }

    pub fn findOne(
        self: TxnCollection,
        field_path: []const u8,
        value: doc_mod.Value,
    ) !?u64 {
        return self.underlying().findOne(field_path, value);
    }

    pub fn findAll(
        self: TxnCollection,
        allocator: Allocator,
        field_path: []const u8,
        value: doc_mod.Value,
    ) !index_mod.LookupIterator {
        return self.underlying().findAll(allocator, field_path, value);
    }

    pub fn findRange(
        self: TxnCollection,
        allocator: Allocator,
        field_path: []const u8,
        lo: index_mod.Bound,
        hi: index_mod.Bound,
    ) !index_mod.RangeIterator {
        return self.underlying().findRange(allocator, field_path, lo, hi);
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


test "OptimisticTxn: insert + get + commit roundtrip, read/write sets populated" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    var db = try Db.open(ally, testing.io, tmp.dir, "occ.db");
    defer db.close();

    const alice = try buildDoc("alice", 30);
    defer ally.free(alice);

    var saved_id: u64 = undefined;
    var saw_writes: usize = 0;
    var saw_reads: usize = 0;

    {
        var txn = try db.beginOptimistic();
        errdefer txn.abort();
        const users = txn.collection("users");
        saved_id = try users.insert(alice);

        const got = (try users.get(ally, saved_id)).?;
        defer ally.free(got);
        try testing.expectEqualSlices(u8, alice, got);

        // The txn captured the snapshot at begin time, before our insert.
        // start_root is the empty B+tree root from a fresh DB.
        try testing.expectEqual(@as(usize, 1), txn.write_set.items.len);
        try testing.expectEqual(@as(usize, 1), txn.read_set.items.len);
        saw_writes = txn.write_set.items.len;
        saw_reads = txn.read_set.items.len;
        try testing.expectEqual(OptimisticTxn.WriteKind.insert, txn.write_set.items[0].kind);
        try testing.expectEqual(saved_id, txn.write_set.items[0].doc_id);
        try testing.expectEqualStrings("users", txn.write_set.items[0].coll);

        try txn.commit();
    }

    // Doc must be visible after commit via the regular API.
    const after = (try db.collection("users").get(ally, saved_id)).?;
    defer ally.free(after);
    try testing.expectEqualSlices(u8, alice, after);
    try testing.expectEqual(@as(usize, 1), saw_writes);
    try testing.expectEqual(@as(usize, 1), saw_reads);
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

