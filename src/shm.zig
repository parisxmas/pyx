//! Shared-memory file for cross-process coordination.
//!
//! Path is the DB path with a `-shm` suffix (sibling to `.pyx-wal`).
//! Every process that opens the DB also opens this file and mmap's its
//! first 4 KB as MAP_SHARED, so writes from one process are immediately
//! visible to others on the same machine.
//!
//! Layout:
//!   bytes 0..8     magic "PYXSHM01"
//!   bytes 8..12    layout version (currently 1)
//!   bytes 16..24   next_doc_id      (atomic u64)
//!   bytes 24..32   num_pages        (atomic u64)
//!   bytes 32..40   next_lsn         (atomic u64)
//!   bytes 40..48   wal_end_offset   (atomic u64)
//!   bytes 48..56   writer_pid       (debug; 0 when no writer holds the
//!                                    fcntl WRITER lock — added in phase 1C)
//!   bytes 56..64   btree_root       (atomic u64, phase 2A; the live
//!                                    root of the B+Tree, shared across
//!                                    processes. Stored as u64 here for
//!                                    layout regularity even though
//!                                    PageId is u32; reads narrow.)
//!   bytes 64..72   free_head        (atomic u64, phase 5; the head of
//!                                    the free-page list, shared across
//!                                    processes so freed pages are
//!                                    visible to everyone)
//!   bytes 72..328  collections[16]  (sharding phase 2A; per-collection
//!                                    state. Each slot is 16 bytes:
//!                                    btree_root u32 | free_head u32 |
//!                                    in_use u8 | _pad[7]. Slot 0 is
//!                                    always in_use and mirrors the
//!                                    top-level btree_root/free_head
//!                                    fields above; phase 2B will start
//!                                    actually routing per-id reads
//!                                    through these slots.)
//!   bytes 328..4096 reserved

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;

pub const shm_size: usize = 4096;
pub const magic: [8]u8 = .{ 'P', 'Y', 'X', 'S', 'H', 'M', '0', '1' };
pub const version: u32 = 1;

/// Number of collection slots reserved in the shm header. Mirrors
/// `pager.max_collections` (kept as a private constant here to avoid
/// a circular module import).
pub const max_collections: usize = 16;

/// Per-collection state in shm. 16 bytes; the array of 16 fits in
/// 256 bytes after the existing header fields.
pub const CollectionSlot = extern struct {
    /// Live B+Tree root for this collection. 0 means empty tree.
    btree_root: u32 align(4),
    /// Head of this collection's free-page list. 0 means empty.
    free_head: u32 align(4),
    /// Non-zero when the slot describes a real collection.
    in_use: u8,
    _pad: [7]u8,
};

comptime {
    std.debug.assert(@sizeOf(CollectionSlot) == 16);
}

pub const Error = error{
    NotAShm,
    UnsupportedShm,
    TruncatedShm,
};

/// Layout of the first page of the -shm file. All u64 fields are
/// accessed via `std.atomic.Value` ops, so loads/stores are well-
/// defined across processes that mmap the same file.
pub const Header = extern struct {
    magic: [8]u8,
    version: u32,
    _pad0: u32,
    next_doc_id: u64 align(8),
    num_pages: u64 align(8),
    next_lsn: u64 align(8),
    wal_end_offset: u64 align(8),
    writer_pid: u64 align(8),
    btree_root: u64 align(8),
    free_head: u64 align(8),
    collections: [max_collections]CollectionSlot align(8),
    /// Pads the struct to 4096 bytes for forward compatibility.
    _reserved: [shm_size - 72 - max_collections * 16]u8,
};

comptime {
    std.debug.assert(@sizeOf(Header) == shm_size);
    std.debug.assert(@offsetOf(Header, "next_doc_id") == 16);
    std.debug.assert(@offsetOf(Header, "num_pages") == 24);
    std.debug.assert(@offsetOf(Header, "next_lsn") == 32);
    std.debug.assert(@offsetOf(Header, "wal_end_offset") == 40);
    std.debug.assert(@offsetOf(Header, "writer_pid") == 48);
    std.debug.assert(@offsetOf(Header, "btree_root") == 56);
    std.debug.assert(@offsetOf(Header, "free_head") == 64);
    std.debug.assert(@offsetOf(Header, "collections") == 72);
}

pub const Shm = struct {
    file: File,
    io: Io,
    mmap: File.MemoryMap,
    /// True if this process initialised a fresh `-shm` file. The first
    /// opener uses this to know it should seed the shm atomics from
    /// the on-disk DB header rather than trust whatever's there.
    fresh: bool,

    pub fn open(io: Io, dir: Dir, sub_path: []const u8) !Shm {
        const file = try dir.createFile(io, sub_path, .{
            .read = true,
            .truncate = false,
        });
        errdefer file.close(io);

        const len = try file.length(io);
        var fresh = false;
        if (len == 0) {
            fresh = true;
            var hdr_buf: [shm_size]u8 = @splat(0);
            const hdr: *Header = @ptrCast(@alignCast(&hdr_buf));
            hdr.magic = magic;
            hdr.version = version;
            try file.writePositionalAll(io, &hdr_buf, 0);
            try file.sync(io);
        } else if (len < shm_size) {
            return Error.TruncatedShm;
        } else {
            var hdr_buf: [shm_size]u8 = undefined;
            const n = try file.readPositionalAll(io, &hdr_buf, 0);
            if (n < shm_size) return Error.TruncatedShm;
            const hdr: *const Header = @ptrCast(@alignCast(&hdr_buf));
            if (!std.mem.eql(u8, &hdr.magic, &magic)) return Error.NotAShm;
            if (hdr.version != version) return Error.UnsupportedShm;
        }

        const mmap = try File.MemoryMap.create(io, file, .{
            .len = shm_size,
            .protection = .{ .read = true, .write = true },
            .undefined_contents = false,
            .populate = false,
        });

        return .{
            .file = file,
            .io = io,
            .mmap = mmap,
            .fresh = fresh,
        };
    }

    pub fn close(self: *Shm) void {
        self.mmap.destroy(self.io);
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn header(self: *Shm) *Header {
        return @ptrCast(@alignCast(self.mmap.memory.ptr));
    }

    pub fn nextDocId(self: *Shm) *std.atomic.Value(u64) {
        return @ptrCast(@alignCast(&self.header().next_doc_id));
    }

    pub fn numPages(self: *Shm) *std.atomic.Value(u64) {
        return @ptrCast(@alignCast(&self.header().num_pages));
    }

    pub fn nextLsn(self: *Shm) *std.atomic.Value(u64) {
        return @ptrCast(@alignCast(&self.header().next_lsn));
    }

    pub fn walEndOffset(self: *Shm) *std.atomic.Value(u64) {
        return @ptrCast(@alignCast(&self.header().wal_end_offset));
    }

    pub fn btreeRoot(self: *Shm) *std.atomic.Value(u64) {
        return @ptrCast(@alignCast(&self.header().btree_root));
    }

    pub fn freeHead(self: *Shm) *std.atomic.Value(u64) {
        return @ptrCast(@alignCast(&self.header().free_head));
    }

    /// Per-collection live B+Tree root (sharding phase 2).
    pub fn collectionRoot(self: *Shm, id: usize) *std.atomic.Value(u32) {
        std.debug.assert(id < max_collections);
        return @ptrCast(@alignCast(&self.header().collections[id].btree_root));
    }

    /// Per-collection free-list head (sharding phase 2).
    pub fn collectionFreeHead(self: *Shm, id: usize) *std.atomic.Value(u32) {
        std.debug.assert(id < max_collections);
        return @ptrCast(@alignCast(&self.header().collections[id].free_head));
    }

    /// Whether slot `id` describes a real collection. Slot 0 is always
    /// true once the shm is initialised (it backs the default tree).
    pub fn collectionInUse(self: *Shm, id: usize) bool {
        std.debug.assert(id < max_collections);
        return @atomicLoad(u8, &self.header().collections[id].in_use, .acquire) != 0;
    }

    pub fn setCollectionInUse(self: *Shm, id: usize, value: bool) void {
        std.debug.assert(id < max_collections);
        @atomicStore(u8, &self.header().collections[id].in_use, if (value) 1 else 0, .release);
    }

    /// Seed every atomic counter from the values the on-disk DB header
    /// has at open time. Called by the first opener — phase 1 always
    /// calls it (single-process); phase 1C gates it on the
    /// WRITER fcntl lock so only one process re-seeds across a
    /// multi-opener run.
    ///
    /// Phase 2B: every collection slot is seeded from the on-disk
    /// header's `collection_roots[]` array. Slots that the header
    /// reports as 0 stay zero (no tree yet); slot 0 is also marked
    /// in-use so the default tree always has a valid slot.
    pub fn seedFromHeader(
        self: *Shm,
        next_doc_id: u64,
        num_pages: u64,
        next_lsn: u64,
        btree_root: u64,
        free_head: u64,
        collection_roots: []const u32,
    ) void {
        std.debug.assert(collection_roots.len == max_collections);
        self.nextDocId().store(next_doc_id, .release);
        self.numPages().store(num_pages, .release);
        self.nextLsn().store(next_lsn, .release);
        self.btreeRoot().store(btree_root, .release);
        self.freeHead().store(free_head, .release);
        var i: usize = 0;
        while (i < max_collections) : (i += 1) {
            self.collectionRoot(i).store(collection_roots[i], .release);
        }
        // Slot 0 also mirrors the top-level free_head; non-default
        // slots' free lists are reserved for phase 3+.
        self.collectionFreeHead(0).store(@intCast(free_head), .release);
        self.setCollectionInUse(0, true);
        // Mark every other slot in_use if its root is non-zero —
        // the on-disk header is the source of truth for which
        // collections actually exist after a crash that lost shm.
        i = 1;
        while (i < max_collections) : (i += 1) {
            if (collection_roots[i] != 0) self.setCollectionInUse(i, true);
        }
        // wal_end_offset is owned by Wal — set when the WAL is opened.
    }
};

const testing = std.testing;

test "shm: open creates fresh header; reopen validates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    {
        var shm = try Shm.open(io, tmp.dir, "test.shm");
        defer shm.close();
        try testing.expect(shm.fresh);
        shm.nextDocId().store(42, .release);
        shm.numPages().store(7, .release);
    }
    {
        var shm = try Shm.open(io, tmp.dir, "test.shm");
        defer shm.close();
        try testing.expect(!shm.fresh);
        try testing.expectEqual(@as(u64, 42), shm.nextDocId().load(.acquire));
        try testing.expectEqual(@as(u64, 7), shm.numPages().load(.acquire));
    }
}

test "shm: seedFromHeader fans collection_roots out across every slot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var shm = try Shm.open(io, tmp.dir, "slots.shm");
    defer shm.close();

    try testing.expect(!shm.collectionInUse(0));
    try testing.expect(!shm.collectionInUse(7));

    var roots = [_]u32{0} ** max_collections;
    roots[0] = 0xABC;
    roots[5] = 0x500;
    shm.seedFromHeader(1, 1, 1, 0xABC, 0xDEF, &roots);

    try testing.expect(shm.collectionInUse(0));
    try testing.expect(shm.collectionInUse(5)); // populated by header → in_use
    try testing.expect(!shm.collectionInUse(1)); // empty → still unused
    try testing.expectEqual(@as(u32, 0xABC), shm.collectionRoot(0).load(.acquire));
    try testing.expectEqual(@as(u32, 0x500), shm.collectionRoot(5).load(.acquire));
    try testing.expectEqual(@as(u32, 0xDEF), shm.collectionFreeHead(0).load(.acquire));
}

test "shm: rejects file with bad magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var f = try tmp.dir.createFile(io, "junk.shm", .{});
    var bogus: [shm_size]u8 = @splat(0);
    @memcpy(bogus[0..8], "WRONGMAG");
    try f.writePositionalAll(io, &bogus, 0);
    f.close(io);

    try testing.expectError(Error.NotAShm, Shm.open(io, tmp.dir, "junk.shm"));
}
