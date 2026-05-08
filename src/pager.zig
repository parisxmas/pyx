//! Page-level storage with logical-WAL transactions.
//!
//! Layout of the DB file:
//!   page 0      — header (magic, version, free-list head, next doc id, …)
//!   page 1..N   — data pages or free pages (free pages link via first 4 bytes)
//!
//! Transactions:
//!   `begin()` / `commit()` / `abort()` group writes; mutating ops without
//!   an explicit transaction auto-commit. Higher layers (B+Tree) call
//!   `recordPut`/`recordDelete` to log operations into the txn-local
//!   record buffer. On commit, those records are written to the WAL,
//!   fsynced, then the dirty pages are applied to the DB file.
//!
//! Crash safety:
//!   - WAL records are logical, so replay can re-execute operations
//!     against whatever state the DB ended up in.
//!   - During apply, all non-header pages are written before page 0
//!     (the header). A crash between WAL fsync and the header write
//!     leaves the live tree pointing at the pre-commit root, so the
//!     state is consistent and replay can run.
//!   - Replay is driven by the layer above (typically `db.zig`), which
//!     re-executes B+Tree puts/deletes using the same operations that
//!     were logged.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const mem = std.mem;
const Allocator = mem.Allocator;
const Crc32 = std.hash.Crc32;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;
const ArrayList = std.ArrayList;

const wal_mod = @import("wal.zig");

pub const page_size: u32 = 4096;
pub const PageId = u32;

const magic: [8]u8 = .{ 'P', 'Y', 'X', 'D', 'B', '0', '0', '1' };
const format_version: u32 = 1;

pub const Header = struct {
    version: u32 = format_version,
    page_size: u32 = page_size,
    num_pages: u64 = 1,
    free_head: PageId = 0,
    next_doc_id: u64 = 1,
    btree_root: PageId = 0,
};

pub const Error = error{
    NotADocDb,
    UnsupportedVersion,
    WrongPageSize,
    CorruptHeader,
    TruncatedFile,
    InvalidPageId,
    CannotFreeHeader,
    TxnAlreadyActive,
    NoActiveTxn,
};

fn serializeHeader(h: Header, buf: *[page_size]u8) void {
    @memset(buf, 0);
    @memcpy(buf[0..8], &magic);
    var i: usize = 8;
    mem.writeInt(u32, buf[i..][0..4], h.version, .little);
    i += 4;
    mem.writeInt(u32, buf[i..][0..4], h.page_size, .little);
    i += 4;
    mem.writeInt(u64, buf[i..][0..8], h.num_pages, .little);
    i += 8;
    mem.writeInt(u32, buf[i..][0..4], h.free_head, .little);
    i += 4;
    mem.writeInt(u64, buf[i..][0..8], h.next_doc_id, .little);
    i += 8;
    mem.writeInt(u32, buf[i..][0..4], h.btree_root, .little);
    i += 4;
    const csum = Crc32.hash(buf[0..i]);
    mem.writeInt(u32, buf[i..][0..4], csum, .little);
}

fn deserializeHeader(buf: *const [page_size]u8) Error!Header {
    if (!mem.eql(u8, buf[0..8], &magic)) return Error.NotADocDb;
    var i: usize = 8;
    const version = mem.readInt(u32, buf[i..][0..4], .little);
    i += 4;
    if (version != format_version) return Error.UnsupportedVersion;
    const ps = mem.readInt(u32, buf[i..][0..4], .little);
    i += 4;
    if (ps != page_size) return Error.WrongPageSize;
    const num_pages = mem.readInt(u64, buf[i..][0..8], .little);
    i += 8;
    const free_head = mem.readInt(u32, buf[i..][0..4], .little);
    i += 4;
    const next_doc_id = mem.readInt(u64, buf[i..][0..8], .little);
    i += 8;
    const btree_root = mem.readInt(u32, buf[i..][0..4], .little);
    i += 4;
    const stored = mem.readInt(u32, buf[i..][0..4], .little);
    if (stored != Crc32.hash(buf[0..i])) return Error.CorruptHeader;
    return .{
        .version = version,
        .page_size = ps,
        .num_pages = num_pages,
        .free_head = free_head,
        .next_doc_id = next_doc_id,
        .btree_root = btree_root,
    };
}

pub const SyncMode = enum {
    /// fsync the WAL on every commit. Strongest durability — every
    /// committed transaction survives a power loss.
    full,
    /// Skip fsync at commit time; only fsync at `checkpoint()` (or close).
    /// Equivalent to SQLite's `synchronous=NORMAL` in WAL mode: the most
    /// recent commits may be lost on power loss, but the DB is never
    /// corrupted (the WAL still has CRC-validated records up to the last
    /// good COMMIT).
    normal,
};

/// Per-record key/value bytes are allocated from the pager's per-txn arena;
/// they're freed in bulk by `txn_arena.reset(.retain_capacity)` at commit
/// or abort, so this union has no `deinit`.
pub const PendingRecord = union(enum) {
    put: struct { key: []const u8, value: []const u8 },
    delete: []const u8,
};

pub const Pager = struct {
    allocator: Allocator,
    io: Io,
    file: File,
    wal: wal_mod.Wal,
    header: Header,
    header_dirty: bool,
    in_txn: bool,
    in_recovery: bool,
    txn_header_snapshot: Header,
    /// Per-txn buffer; cleared on commit (pages moved to `page_cache`) or
    /// on abort (pages destroyed).
    dirty: AutoHashMapUnmanaged(PageId, *[page_size]u8),
    /// Pages that have been committed but not yet checkpointed to the DB
    /// file. Reads consult this before going to disk. Flushed to disk by
    /// `checkpoint()`.
    page_cache: AutoHashMapUnmanaged(PageId, *[page_size]u8),
    pending: ArrayList(PendingRecord),
    /// Backs the bytes (keys, values) for every PendingRecord in the
    /// current transaction. Bump-allocated at recordPut/recordDelete time;
    /// reset in bulk on commit/abort.
    txn_arena: std.heap.ArenaAllocator,
    /// Per-txn append cursor: when the B+Tree successfully inserts at the
    /// rightmost slot of a leaf, it stores that leaf id here. The next
    /// `put` call checks this hint first and, if the new key is greater
    /// than the cached leaf's last key (and fits), skips the entire
    /// root-to-leaf descent. Cleared on commit/abort, on splits, and on
    /// any modification that invalidates the cursor (e.g. deletes).
    txn_append_hint: ?PageId,
    next_lsn: u64,
    sync_mode: SyncMode,
    /// Lock-free doc-id allocator used by OCC writers that don't hold the
    /// data lock. Initialised from `header.next_doc_id` at open and
    /// after WAL replay; the on-disk header is brought back into sync at
    /// the start of every `commitAppend` so the COMMIT record reflects
    /// every reservation made before the commit.
    next_doc_id_atomic: std.atomic.Value(u64),

    pub fn open(allocator: Allocator, io: Io, dir: Dir, sub_path: []const u8) !Pager {
        const file = try dir.createFile(io, sub_path, .{
            .read = true,
            .truncate = false,
        });
        errdefer file.close(io);

        const file_len = try file.length(io);
        const fresh = file_len == 0;

        const wal_path = try mem.concat(allocator, u8, &.{ sub_path, ".wal" });
        defer allocator.free(wal_path);

        if (fresh) {
            var hbuf: [page_size]u8 = undefined;
            serializeHeader(.{}, &hbuf);
            try file.writePositionalAll(io, &hbuf, 0);
            try file.sync(io);
            dir.deleteFile(io, wal_path) catch {};
        } else if (file_len < page_size) {
            return Error.TruncatedFile;
        }

        var wal = try wal_mod.Wal.open(allocator, io, dir, wal_path);
        errdefer wal.close();

        var hdr_buf: [page_size]u8 = undefined;
        const n = try file.readPositionalAll(io, &hdr_buf, 0);
        if (n < page_size) return Error.TruncatedFile;
        const header = try deserializeHeader(&hdr_buf);

        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .wal = wal,
            .header = header,
            .header_dirty = false,
            .in_txn = false,
            .in_recovery = false,
            .txn_header_snapshot = header,
            .dirty = .empty,
            .page_cache = .empty,
            .pending = .empty,
            .txn_arena = std.heap.ArenaAllocator.init(allocator),
            .txn_append_hint = null,
            .next_lsn = 1,
            .sync_mode = .full,
            .next_doc_id_atomic = .init(header.next_doc_id),
        };
    }

    pub fn setSyncMode(self: *Pager, mode: SyncMode) void {
        self.sync_mode = mode;
    }

    pub fn close(self: *Pager) void {
        if (self.in_txn) self.abort();
        // Best-effort flush of the page cache before closing. Failure is
        // recoverable on reopen via WAL replay (the WAL has every
        // committed record up to this point), so we don't surface errors.
        self.checkpoint() catch {};
        self.clearDirty();
        self.dirty.deinit(self.allocator);
        self.clearCache();
        self.page_cache.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.txn_arena.deinit();
        self.wal.close();
        self.file.close(self.io);
        self.* = undefined;
    }

    fn clearCache(self: *Pager) void {
        var it = self.page_cache.iterator();
        while (it.next()) |e| self.allocator.destroy(e.value_ptr.*);
        self.page_cache.clearRetainingCapacity();
    }

    /// Flush all cached pages to the DB file, fsync, and truncate the WAL.
    /// This is the only path that writes the on-disk DB file; commits leave
    /// modifications in `page_cache` for batched application here.
    pub fn checkpoint(self: *Pager) !void {
        if (self.in_txn) return Error.TxnAlreadyActive;

        // Apply non-header pages first; header page 0 last, so a crash
        // mid-flush leaves the live tree pointing at the previous root.
        var it = self.page_cache.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.* == 0) continue;
            try self.file.writePositionalAll(self.io, e.value_ptr.*, pageOffset(e.key_ptr.*));
        }
        if (self.page_cache.get(0)) |hbuf| {
            try self.file.writePositionalAll(self.io, hbuf, 0);
        }

        try self.file.sync(self.io);
        try self.wal.reset();

        self.clearCache();
    }

    /// Materialize the in-memory header into the page cache (so the next
    /// `checkpoint` writes it to disk). Used at the end of WAL replay,
    /// where the trailing COMMIT record's `next_doc_id` may not have been
    /// captured by any auto-commit's serialized cache[0] entry.
    pub fn flushHeader(self: *Pager) !void {
        if (self.in_txn) return Error.TxnAlreadyActive;
        const gop = try self.page_cache.getOrPut(self.allocator, 0);
        if (!gop.found_existing) {
            gop.value_ptr.* = try self.allocator.create([page_size]u8);
        }
        serializeHeader(self.header, gop.value_ptr.*);
        self.header_dirty = false;
    }

    pub fn begin(self: *Pager) !void {
        if (self.in_txn) return Error.TxnAlreadyActive;
        self.txn_header_snapshot = self.header;
        self.in_txn = true;
    }

    /// Commit pipeline, split into three phases so a future group-commit
    /// implementation can release the data lock before fsync.
    ///
    ///   1. `commitAppend` — stage WAL records, single pwritev, no fsync.
    ///      Returns the LSN of the COMMIT record (0 when called during
    ///      recovery, where no WAL records are written).
    ///   2. `syncTo(lsn)`  — fsync the WAL up to and including `lsn`.
    ///      No-op in `.normal` mode and during recovery.
    ///   3. `applyAndFinalize` — move dirty pages into the page cache,
    ///      reset the per-txn state, drop `in_txn`.
    ///
    /// The unified `commit()` calls all three in order, preserving
    /// pre-split behavior exactly (append → flush → fsync → cache-move).
    /// Group commit (phase 3) will keep `commitAppend` and `applyAndFinalize`
    /// under the data lock and call `syncTo` after the lock is released,
    /// allowing fsyncs to coalesce across writers.
    pub fn commit(self: *Pager) !void {
        const commit_lsn = try self.commitAppend();
        try self.syncTo(commit_lsn);
        try self.applyAndFinalize();
    }

    /// Phase-1 helper. Stages records into the WAL buffer, writes one
    /// `pwritev` for the whole batch, and returns the COMMIT-record LSN.
    /// Does NOT fsync; does NOT move dirty pages into the cache. Caller
    /// must follow with `syncTo` and `applyAndFinalize` (or use the
    /// unified `commit`).
    pub fn commitAppend(self: *Pager) !u64 {
        if (!self.in_txn) return Error.NoActiveTxn;

        // Bring the in-memory header up to whatever doc-id reservations
        // happened concurrently via `reserveDocId` (used by lock-free OCC
        // writers). This is a load-and-bump on the atomic; no contention.
        const reserved = self.next_doc_id_atomic.load(.monotonic);
        if (reserved > self.header.next_doc_id) {
            self.header.next_doc_id = reserved;
            self.header_dirty = true;
        }

        if (self.header_dirty) {
            const gop = try self.dirty.getOrPut(self.allocator, 0);
            if (!gop.found_existing) {
                gop.value_ptr.* = try self.allocator.create([page_size]u8);
            }
            serializeHeader(self.header, gop.value_ptr.*);
        }

        if (self.in_recovery) return 0;

        // Stage all records into the WAL's in-memory buffer first; if any
        // append fails we drop the partial batch and bail before touching
        // disk.
        errdefer self.wal.discardPending();
        for (self.pending.items) |rec| {
            switch (rec) {
                .put => |p| try self.wal.appendPut(self.next_lsn, p.key, p.value),
                .delete => |k| try self.wal.appendDelete(self.next_lsn, k),
            }
            self.next_lsn += 1;
        }
        const commit_lsn = self.next_lsn;
        try self.wal.appendCommit(commit_lsn, self.header.next_doc_id);
        self.next_lsn += 1;
        // One pwritev for the whole batch (PUTs + COMMIT). Records reach
        // the kernel page cache here; durability is the next phase's job.
        try self.wal.flush();
        // Publish the new high-water mark to the fsync queue. Any leader
        // that takes its snapshot after this `store` is guaranteed to
        // see (and fsync) our records.
        self.wal.last_flushed_lsn.store(commit_lsn, .release);
        return commit_lsn;
    }

    /// Make every commit up to `lsn` durable on disk. No-op in `.normal`
    /// mode (fsync is deferred to `checkpoint`) and during recovery
    /// (records being replayed are already on disk).
    ///
    /// Lock-free with respect to the data lock: callers may release
    /// `db.mu` before invoking this. Concurrent fsync requests coalesce
    /// inside `wal.syncToLsn` via a leader/follower queue — N writers
    /// hitting `.full`-mode commit at once typically pay one fsync, not
    /// N. Followers whose `lsn` was already covered by an earlier
    /// leader's fsync return without issuing any syscall.
    pub fn syncTo(self: *Pager, lsn: u64) !void {
        if (self.in_recovery) return;
        if (self.sync_mode != .full) return;
        try self.wal.syncToLsn(lsn);
    }

    /// Phase-1 helper. Move dirty pages into the page cache and reset the
    /// per-txn state. The cache is flushed to disk by `checkpoint()`,
    /// which is where the actual data-file pwrites happen, batched.
    /// Ownership of each 4 KB buffer transfers from `dirty` to
    /// `page_cache`; if the same page is already in the cache (overridden
    /// by this txn), the old cached buffer is freed.
    pub fn applyAndFinalize(self: *Pager) !void {
        var it = self.dirty.iterator();
        while (it.next()) |e| {
            const gop = try self.page_cache.getOrPut(self.allocator, e.key_ptr.*);
            if (gop.found_existing) self.allocator.destroy(gop.value_ptr.*);
            gop.value_ptr.* = e.value_ptr.*;
        }
        self.dirty.clearRetainingCapacity(); // ownership moved; do NOT destroy values
        self.pending.clearRetainingCapacity();
        _ = self.txn_arena.reset(.retain_capacity);
        self.txn_append_hint = null;
        self.header_dirty = false;
        self.in_txn = false;
    }

    pub fn abort(self: *Pager) void {
        if (!self.in_txn) return;
        self.clearDirty();
        self.pending.clearRetainingCapacity();
        _ = self.txn_arena.reset(.retain_capacity);
        self.txn_append_hint = null;
        self.header = self.txn_header_snapshot;
        self.header_dirty = false;
        self.in_txn = false;
    }

    pub fn recordPut(self: *Pager, key: []const u8, value: []const u8) !void {
        if (self.in_recovery or !self.in_txn) return;
        const arena = self.txn_arena.allocator();
        try self.pending.append(self.allocator, .{
            .put = .{
                .key = try arena.dupe(u8, key),
                .value = try arena.dupe(u8, value),
            },
        });
    }

    pub fn recordDelete(self: *Pager, key: []const u8) !void {
        if (self.in_recovery or !self.in_txn) return;
        const arena = self.txn_arena.allocator();
        try self.pending.append(self.allocator, .{ .delete = try arena.dupe(u8, key) });
    }

    fn clearDirty(self: *Pager) void {
        var it = self.dirty.iterator();
        while (it.next()) |e| {
            self.allocator.destroy(e.value_ptr.*);
        }
        self.dirty.clearRetainingCapacity();
    }

    fn pageOffset(id: PageId) u64 {
        return @as(u64, id) * page_size;
    }

    fn putDirty(self: *Pager, id: PageId, src: *const [page_size]u8) !void {
        const gop = try self.dirty.getOrPut(self.allocator, id);
        if (!gop.found_existing) {
            gop.value_ptr.* = try self.allocator.create([page_size]u8);
        }
        @memcpy(gop.value_ptr.*, src);
    }

    fn writePageInternal(self: *Pager, id: PageId, buf: *const [page_size]u8) !void {
        if (self.in_txn) {
            try self.putDirty(id, buf);
        } else {
            try self.file.writePositionalAll(self.io, buf, pageOffset(id));
        }
    }

    fn readPageInternal(self: *Pager, id: PageId, buf: *[page_size]u8) !void {
        // Read order: in-flight txn dirty buffer, then committed-but-
        // unflushed page cache, then disk. This is the standard
        // overlay: the user always sees the most recent committed state
        // (plus their own writes within an active txn).
        if (self.in_txn) {
            if (self.dirty.get(id)) |p| {
                buf.* = p.*;
                return;
            }
        }
        if (self.page_cache.get(id)) |p| {
            buf.* = p.*;
            return;
        }
        const n = try self.file.readPositionalAll(self.io, buf, pageOffset(id));
        if (n < page_size) return Error.TruncatedFile;
    }

    pub fn allocPage(self: *Pager) !PageId {
        if (self.in_txn) return self.allocPageInner();
        try self.begin();
        errdefer self.abort();
        const id = try self.allocPageInner();
        try self.commit();
        return id;
    }

    fn allocPageInner(self: *Pager) !PageId {
        if (self.header.free_head != 0) {
            const id = self.header.free_head;
            var page: [page_size]u8 = undefined;
            try self.readPageInternal(id, &page);
            self.header.free_head = mem.readInt(u32, page[0..4], .little);
            self.header_dirty = true;
            return id;
        }
        const id: PageId = @intCast(self.header.num_pages);
        self.header.num_pages += 1;
        self.header_dirty = true;
        const zero: [page_size]u8 = @splat(0);
        try self.writePageInternal(id, &zero);
        return id;
    }

    pub fn freePage(self: *Pager, id: PageId) !void {
        if (self.in_txn) return self.freePageInner(id);
        try self.begin();
        errdefer self.abort();
        try self.freePageInner(id);
        try self.commit();
    }

    fn freePageInner(self: *Pager, id: PageId) !void {
        if (id == 0) return Error.CannotFreeHeader;
        if (id >= self.header.num_pages) return Error.InvalidPageId;
        var page: [page_size]u8 = @splat(0);
        mem.writeInt(u32, page[0..4], self.header.free_head, .little);
        try self.writePageInternal(id, &page);
        self.header.free_head = id;
        self.header_dirty = true;
    }

    pub fn read(self: *Pager, id: PageId, buf: *[page_size]u8) !void {
        if (id == 0 or id >= self.header.num_pages) return Error.InvalidPageId;
        try self.readPageInternal(id, buf);
    }

    pub fn write(self: *Pager, id: PageId, buf: *const [page_size]u8) !void {
        if (id == 0 or id >= self.header.num_pages) return Error.InvalidPageId;
        if (self.in_txn) {
            try self.writePageInternal(id, buf);
            return;
        }
        try self.begin();
        errdefer self.abort();
        try self.writePageInternal(id, buf);
        try self.commit();
    }

    pub fn nextDocId(self: *Pager) !u64 {
        const id = self.next_doc_id_atomic.fetchAdd(1, .monotonic);
        if (self.in_txn) {
            // Header sync is handled by commitAppend — leaving the
            // header field stale here is fine and avoids redundant
            // writes when the same txn allocates many ids.
            return id;
        }
        try self.begin();
        errdefer self.abort();
        try self.commit();
        return id;
    }

    /// Lock-free doc-id reservation for OCC writers that don't hold the
    /// data lock. The id is reflected in the on-disk header on the next
    /// pessimistic commit (which includes the apply phase of an OCC
    /// commit), so a crash before that commit drops the reservation —
    /// acceptable, since the OCC txn would also have lost its
    /// uncommitted writes.
    pub fn reserveDocId(self: *Pager) u64 {
        return self.next_doc_id_atomic.fetchAdd(1, .monotonic);
    }

    pub fn restoreNextDocId(self: *Pager, value: u64) void {
        if (value > self.header.next_doc_id) {
            self.header.next_doc_id = value;
            self.header_dirty = true;
        }
        // Keep the atomic counter in sync with replayed state so any
        // post-replay reservation outranks the recovered value.
        while (true) {
            const cur = self.next_doc_id_atomic.load(.monotonic);
            if (cur >= value) break;
            if (self.next_doc_id_atomic.cmpxchgWeak(
                cur,
                value,
                .monotonic,
                .monotonic,
            ) == null) break;
        }
    }

    pub fn setBTreeRoot(self: *Pager, id: PageId) !void {
        if (self.header.btree_root == id) return; // no-op if unchanged
        if (self.in_txn) {
            self.header.btree_root = id;
            self.header_dirty = true;
            return;
        }
        try self.begin();
        errdefer self.abort();
        self.header.btree_root = id;
        self.header_dirty = true;
        try self.commit();
    }

    pub fn bTreeRoot(self: *const Pager) PageId {
        return self.header.btree_root;
    }

    /// Whether `id` was allocated/modified earlier in the current
    /// transaction. Such pages are not yet visible to any snapshot
    /// (their fresh ids exist only in `dirty`), so the B+Tree can
    /// safely modify them in place rather than CoW'ing again.
    pub fn isDirty(self: *const Pager, id: PageId) bool {
        return self.dirty.contains(id);
    }

    /// Mutable pointer into the in-memory dirty buffer for a page. Returns
    /// null if the page isn't currently dirty (i.e., it'd need to be CoW'd
    /// or read from disk first). Callers using this must respect the same
    /// safety rule as `isDirty`: only mutate pages that aren't reachable
    /// from any captured snapshot's root.
    pub fn dirtyPtr(self: *const Pager, id: PageId) ?*[page_size]u8 {
        if (!self.in_txn) return null;
        return self.dirty.get(id);
    }
};

const testing = std.testing;

test "create new db, alloc/write/read pages, close, reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    const io = testing.io;

    {
        var p = try Pager.open(ally, io, tmp.dir, "test.db");
        defer p.close();
        try testing.expectEqual(@as(u64, 1), p.header.num_pages);
        try testing.expectEqual(@as(PageId, 0), p.header.free_head);

        const a = try p.allocPage();
        const b = try p.allocPage();
        try testing.expectEqual(@as(PageId, 1), a);
        try testing.expectEqual(@as(PageId, 2), b);

        const page_a: [page_size]u8 = @splat(0xAA);
        const page_b: [page_size]u8 = @splat(0xBB);
        try p.write(a, &page_a);
        try p.write(b, &page_b);
        try p.checkpoint();
    }
    {
        var p = try Pager.open(ally, io, tmp.dir, "test.db");
        defer p.close();
        try testing.expectEqual(@as(u64, 3), p.header.num_pages);
        var got_a: [page_size]u8 = undefined;
        var got_b: [page_size]u8 = undefined;
        try p.read(1, &got_a);
        try p.read(2, &got_b);
        try testing.expect(mem.allEqual(u8, &got_a, 0xAA));
        try testing.expect(mem.allEqual(u8, &got_b, 0xBB));
    }
}

test "free list reuses freed pages LIFO" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var p = try Pager.open(testing.allocator, testing.io, tmp.dir, "freelist.db");
    defer p.close();

    const a = try p.allocPage();
    const b = try p.allocPage();
    const c = try p.allocPage();
    try testing.expectEqual(@as(PageId, 1), a);
    try testing.expectEqual(@as(PageId, 2), b);
    try testing.expectEqual(@as(PageId, 3), c);

    try p.freePage(b);
    try p.freePage(a);

    const r1 = try p.allocPage();
    const r2 = try p.allocPage();
    const r3 = try p.allocPage();
    try testing.expectEqual(a, r1);
    try testing.expectEqual(b, r2);
    try testing.expectEqual(@as(PageId, 4), r3);
}

test "rejects file with wrong magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    const io = testing.io;

    var f = try tmp.dir.createFile(io, "junk.db", .{});
    var bogus: [page_size]u8 = @splat(0);
    @memcpy(bogus[0..8], "WRONGMAG");
    try f.writePositionalAll(io, &bogus, 0);
    f.close(io);

    try testing.expectError(Error.NotADocDb, Pager.open(ally, io, tmp.dir, "junk.db"));
}

test "explicit txn commit applies all writes atomically" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var p = try Pager.open(testing.allocator, testing.io, tmp.dir, "tx.db");
    defer p.close();

    try p.begin();
    const a = try p.allocPage();
    const b = try p.allocPage();
    const img_a: [page_size]u8 = @splat(0x11);
    const img_b: [page_size]u8 = @splat(0x22);
    try p.write(a, &img_a);
    try p.write(b, &img_b);
    try p.commit();

    var got_a: [page_size]u8 = undefined;
    var got_b: [page_size]u8 = undefined;
    try p.read(a, &got_a);
    try p.read(b, &got_b);
    try testing.expect(mem.allEqual(u8, &got_a, 0x11));
    try testing.expect(mem.allEqual(u8, &got_b, 0x22));
}

test "abort restores pre-txn state" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var p = try Pager.open(testing.allocator, testing.io, tmp.dir, "abort.db");
    defer p.close();

    const id = try p.allocPage();
    const original: [page_size]u8 = @splat(0x55);
    try p.write(id, &original);
    const num_pages_before = p.header.num_pages;

    try p.begin();
    const tentative: [page_size]u8 = @splat(0x99);
    try p.write(id, &tentative);
    _ = try p.allocPage();
    p.abort();

    try testing.expectEqual(num_pages_before, p.header.num_pages);
    var after: [page_size]u8 = undefined;
    try p.read(id, &after);
    try testing.expect(mem.allEqual(u8, &after, 0x55));
}
