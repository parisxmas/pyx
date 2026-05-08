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
//!   bytes 64..4096 reserved
//!
//! Phase 2 will add a wal-index hash table after the header. Phase 3
//! adds a reader-mark slot array. The 4 KB header reservation gives
//! room for forward-compatible additions without bumping format
//! versions for benign growth.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;

pub const shm_size: usize = 4096;
pub const magic: [8]u8 = .{ 'P', 'Y', 'X', 'S', 'H', 'M', '0', '1' };
pub const version: u32 = 1;

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
    /// Pads the struct to 4096 bytes for forward compatibility.
    _reserved: [shm_size - 64]u8,
};

comptime {
    std.debug.assert(@sizeOf(Header) == shm_size);
    std.debug.assert(@offsetOf(Header, "next_doc_id") == 16);
    std.debug.assert(@offsetOf(Header, "num_pages") == 24);
    std.debug.assert(@offsetOf(Header, "next_lsn") == 32);
    std.debug.assert(@offsetOf(Header, "wal_end_offset") == 40);
    std.debug.assert(@offsetOf(Header, "writer_pid") == 48);
    std.debug.assert(@offsetOf(Header, "btree_root") == 56);
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

    /// Seed every atomic counter from the values the on-disk DB header
    /// has at open time. Called by the first opener — phase 1 always
    /// calls it (single-process); phase 1C will gate it on the
    /// RECOVERY fcntl lock so only one process re-seeds across a
    /// multi-opener run.
    pub fn seedFromHeader(
        self: *Shm,
        next_doc_id: u64,
        num_pages: u64,
        next_lsn: u64,
        btree_root: u64,
    ) void {
        self.nextDocId().store(next_doc_id, .release);
        self.numPages().store(num_pages, .release);
        self.nextLsn().store(next_lsn, .release);
        self.btreeRoot().store(btree_root, .release);
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
