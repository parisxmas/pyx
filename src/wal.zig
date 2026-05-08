//! Write-ahead log — logical (operation-level) records.
//!
//! Each record describes a B+Tree operation, not a page image. Replay
//! re-executes the operations against the live tree; CoW guarantees that
//! re-execution produces a consistent post-state regardless of how much of
//! the original commit's page-apply step made it to disk before a crash.
//!
//! File layout:
//!     [0..16)  WAL file header
//!     [16..)   sequence of records
//!
//! Record on-disk format:
//!     u8   type
//!     u64  lsn
//!     u32  body_len
//!     [body_len]u8 body
//!     u32  crc32 (over type..body)
//!
//! Bodies:
//!   PUT    (1):  varint key_len | key | varint value_len | value
//!   DELETE (2):  varint key_len | key
//!   COMMIT (3):  u64  next_doc_id   (state to restore after replaying the txn)
//!
//! A transaction is one or more PUT/DELETE records followed by one COMMIT.
//! Records past the last good COMMIT are discarded on replay (truncated).

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const mem = std.mem;
const Allocator = mem.Allocator;
const Crc32 = std.hash.Crc32;
const ArrayList = std.ArrayList;

const doc_mod = @import("doc.zig");

const wal_magic: [8]u8 = .{ 'P', 'Y', 'X', 'W', 'A', 'L', 0, 2 };
const wal_version: u32 = 2;
pub const wal_header_size: u32 = 16;

const record_header_size: usize = 1 + 8 + 4; // type + lsn + body_len

pub const RecordType = enum(u8) {
    put = 1,
    delete = 2,
    commit = 3,
    _,
};

pub const Error = error{
    NotAWal,
    UnsupportedWal,
    WrongPageSize,
    TruncatedWal,
};

pub const Record = union(enum) {
    put: struct { key: []const u8, value: []const u8 },
    delete: []const u8,
    commit: struct { next_doc_id: u64 },
};

pub const Wal = struct {
    allocator: Allocator,
    io: Io,
    file: File,
    end_offset: u64,
    /// Staging buffer for the current commit cycle. `appendPut/Delete/Commit`
    /// serialize each record into this buffer; `flush` writes the whole
    /// thing in one `pwritev`. This collapses what used to be O(records)
    /// syscalls + per-record alloc/free into a single write per commit.
    pending: ArrayList(u8),

    pub fn open(allocator: Allocator, io: Io, dir: Dir, sub_path: []const u8) !Wal {
        const file = try dir.createFile(io, sub_path, .{
            .read = true,
            .truncate = false,
        });
        errdefer file.close(io);

        const len = try file.length(io);
        if (len == 0) {
            var hdr: [wal_header_size]u8 = @splat(0);
            @memcpy(hdr[0..8], &wal_magic);
            mem.writeInt(u32, hdr[8..12], wal_version, .little);
            mem.writeInt(u32, hdr[12..16], 4096, .little);
            try file.writePositionalAll(io, &hdr, 0);
            try file.sync(io);
            return .{ .allocator = allocator, .io = io, .file = file, .end_offset = wal_header_size, .pending = .empty };
        }
        if (len < wal_header_size) return Error.TruncatedWal;
        var hdr: [wal_header_size]u8 = undefined;
        const n = try file.readPositionalAll(io, &hdr, 0);
        if (n < wal_header_size) return Error.TruncatedWal;
        if (!mem.eql(u8, hdr[0..8], &wal_magic)) return Error.NotAWal;
        if (mem.readInt(u32, hdr[8..12], .little) != wal_version) return Error.UnsupportedWal;
        return .{ .allocator = allocator, .io = io, .file = file, .end_offset = len, .pending = .empty };
    }

    pub fn close(self: *Wal) void {
        self.pending.deinit(self.allocator);
        self.file.close(self.io);
        self.* = undefined;
    }

    /// Append one record into the in-memory staging buffer. Nothing
    /// reaches disk until `flush()` is called.
    fn stage(
        self: *Wal,
        rtype: RecordType,
        lsn: u64,
        body: []const u8,
    ) !void {
        const total = record_header_size + body.len + 4;
        try self.pending.ensureUnusedCapacity(self.allocator, total);
        const start = self.pending.items.len;
        // Grow by `total` bytes; we'll fill them in below.
        self.pending.items.len += total;
        const slot = self.pending.items[start..][0..total];
        slot[0] = @intFromEnum(rtype);
        mem.writeInt(u64, slot[1..9], lsn, .little);
        mem.writeInt(u32, slot[9..13], @intCast(body.len), .little);
        @memcpy(slot[record_header_size .. record_header_size + body.len], body);
        const csum = Crc32.hash(slot[0 .. record_header_size + body.len]);
        mem.writeInt(u32, slot[record_header_size + body.len ..][0..4], csum, .little);
    }

    pub fn appendPut(
        self: *Wal,
        lsn: u64,
        key: []const u8,
        value: []const u8,
    ) !void {
        const klen_size = doc_mod.varintSize(key.len);
        const vlen_size = doc_mod.varintSize(value.len);
        const body_len = klen_size + key.len + vlen_size + value.len;
        const total = record_header_size + body_len + 4;
        try self.pending.ensureUnusedCapacity(self.allocator, total);
        const start = self.pending.items.len;
        self.pending.items.len += total;
        const slot = self.pending.items[start..][0..total];
        slot[0] = @intFromEnum(RecordType.put);
        mem.writeInt(u64, slot[1..9], lsn, .little);
        mem.writeInt(u32, slot[9..13], @intCast(body_len), .little);
        var p: usize = record_header_size;
        p += doc_mod.writeVarint(slot[p..], key.len);
        @memcpy(slot[p .. p + key.len], key);
        p += key.len;
        p += doc_mod.writeVarint(slot[p..], value.len);
        @memcpy(slot[p .. p + value.len], value);
        const csum = Crc32.hash(slot[0 .. record_header_size + body_len]);
        mem.writeInt(u32, slot[record_header_size + body_len ..][0..4], csum, .little);
    }

    pub fn appendDelete(self: *Wal, lsn: u64, key: []const u8) !void {
        const klen_size = doc_mod.varintSize(key.len);
        const body_len = klen_size + key.len;
        var body_buf: [16]u8 = undefined;
        const stack_ok = body_len <= body_buf.len;
        const body = if (stack_ok) body_buf[0..body_len] else try self.allocator.alloc(u8, body_len);
        defer if (!stack_ok) self.allocator.free(body);
        var p: usize = 0;
        p += doc_mod.writeVarint(body[p..], key.len);
        @memcpy(body[p .. p + key.len], key);
        try self.stage(.delete, lsn, body);
    }

    pub fn appendCommit(self: *Wal, lsn: u64, next_doc_id: u64) !void {
        var body: [8]u8 = undefined;
        mem.writeInt(u64, &body, next_doc_id, .little);
        try self.stage(.commit, lsn, &body);
    }

    /// Push the staged records to disk in a single `pwritev`. Does not
    /// fsync — call `sync()` for that. Cheap to call when the buffer is
    /// empty (no-op).
    pub fn flush(self: *Wal) !void {
        if (self.pending.items.len == 0) return;
        try self.file.writePositionalAll(self.io, self.pending.items, self.end_offset);
        self.end_offset += self.pending.items.len;
        self.pending.clearRetainingCapacity();
    }

    /// Drop staged records without writing them. Used on the error path
    /// of a commit attempt that didn't reach `flush()`.
    pub fn discardPending(self: *Wal) void {
        self.pending.clearRetainingCapacity();
    }

    pub fn sync(self: *Wal) !void {
        try self.flush();
        try self.file.sync(self.io);
    }

    pub fn reset(self: *Wal) !void {
        self.pending.clearRetainingCapacity();
        try self.file.setLength(self.io, wal_header_size);
        try self.file.sync(self.io);
        self.end_offset = wal_header_size;
    }

    /// Two-pass replay: pass 1 finds the offset of the last good COMMIT
    /// (and truncates anything beyond), pass 2 dispatches every record up
    /// to that offset through `handle`. So `handle` only ever sees records
    /// that belong to a committed transaction.
    pub fn replay(
        self: *Wal,
        allocator: Allocator,
        ctx: anytype,
        comptime handle: fn (@TypeOf(ctx), Record, u64) anyerror!void,
    ) !u64 {
        var offset: u64 = wal_header_size;
        var last_commit_end: u64 = wal_header_size;
        var max_lsn: u64 = 0;
        while (offset + record_header_size <= self.end_offset) {
            const total = parseRecordTotalLen(self.file, self.io, offset, self.end_offset) catch break orelse break;
            const validated = validateRecord(self.file, self.io, allocator, offset, total) catch break;
            if (validated == null) break;
            const v = validated.?;
            if (v.type == .commit) {
                last_commit_end = offset + total;
                if (v.lsn > max_lsn) max_lsn = v.lsn;
            }
            offset += total;
        }
        if (last_commit_end < self.end_offset) {
            try self.file.setLength(self.io, last_commit_end);
            self.end_offset = last_commit_end;
        }

        offset = wal_header_size;
        while (offset < self.end_offset) {
            const total = (parseRecordTotalLen(self.file, self.io, offset, self.end_offset) catch return max_lsn) orelse return max_lsn;
            const buf = try allocator.alloc(u8, @intCast(total));
            defer allocator.free(buf);
            _ = self.file.readPositionalAll(self.io, buf, offset) catch return max_lsn;
            const t_raw = buf[0];
            const lsn = mem.readInt(u64, buf[1..9], .little);
            const body_len = mem.readInt(u32, buf[9..13], .little);
            const body = buf[record_header_size .. record_header_size + body_len];
            const t: RecordType = @enumFromInt(t_raw);
            const rec: Record = switch (t) {
                .put => blk: {
                    const k = try readVarint(body);
                    const key = body[k.len .. k.len + k.value];
                    const after_key = body[k.len + k.value ..];
                    const vlen = try readVarint(after_key);
                    const value = after_key[vlen.len .. vlen.len + vlen.value];
                    break :blk .{ .put = .{ .key = key, .value = value } };
                },
                .delete => blk: {
                    const k = try readVarint(body);
                    break :blk .{ .delete = body[k.len .. k.len + k.value] };
                },
                .commit => .{ .commit = .{ .next_doc_id = mem.readInt(u64, body[0..8], .little) } },
                _ => return max_lsn,
            };
            try handle(ctx, rec, lsn);
            offset += total;
        }
        return max_lsn;
    }
};

fn parseRecordTotalLen(file: File, io: Io, offset: u64, end: u64) !?u64 {
    var hdr_buf: [record_header_size]u8 = undefined;
    const n = try file.readPositionalAll(io, &hdr_buf, offset);
    if (n < record_header_size) return null;
    const body_len = mem.readInt(u32, hdr_buf[9..13], .little);
    const total: u64 = record_header_size + @as(u64, body_len) + 4;
    if (offset + total > end) return null;
    return total;
}

const ValidatedRecord = struct { type: RecordType, lsn: u64 };

fn validateRecord(file: File, io: Io, allocator: Allocator, offset: u64, total: u64) !?ValidatedRecord {
    const buf = try allocator.alloc(u8, @intCast(total));
    defer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, offset);
    if (n < total) return null;
    const stored = mem.readInt(u32, buf[buf.len - 4 ..][0..4], .little);
    const computed = Crc32.hash(buf[0 .. buf.len - 4]);
    if (stored != computed) return null;
    return .{
        .type = @enumFromInt(buf[0]),
        .lsn = mem.readInt(u64, buf[1..9], .little),
    };
}

const ReadVarintResult = struct { value: u64, len: usize };

fn readVarint(buf: []const u8) !ReadVarintResult {
    var v: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < buf.len) {
        const b = buf[i];
        i += 1;
        v |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return .{ .value = v, .len = i };
        if (shift >= 64 - 7) return error.BadVarint;
        shift += 7;
    }
    return error.TruncatedVarint;
}

const testing = std.testing;

test "logical wal append + replay applies committed records only" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const ally = testing.allocator;

    var w = try Wal.open(ally, io, tmp.dir, "wal");
    defer w.close();

    try w.appendPut(1, "alpha", "A");
    try w.appendPut(2, "beta", "B");
    try w.appendCommit(3, 42);
    try w.appendPut(4, "gamma", "G");
    try w.sync();

    const Captured = struct {
        puts: std.StringHashMap([]const u8),
        commits: u32,
        last_next_doc_id: u64,

        fn handle(self: *@This(), rec: Record, lsn: u64) anyerror!void {
            _ = lsn;
            switch (rec) {
                .put => |p| {
                    const k = try testing.allocator.dupe(u8, p.key);
                    const v = try testing.allocator.dupe(u8, p.value);
                    try self.puts.put(k, v);
                },
                .delete => {},
                .commit => |c| {
                    self.commits += 1;
                    self.last_next_doc_id = c.next_doc_id;
                },
            }
        }
    };
    var captured = Captured{ .puts = .init(ally), .commits = 0, .last_next_doc_id = 0 };
    defer {
        var it = captured.puts.iterator();
        while (it.next()) |e| {
            ally.free(e.key_ptr.*);
            ally.free(e.value_ptr.*);
        }
        captured.puts.deinit();
    }

    const max_lsn = try w.replay(ally, &captured, Captured.handle);

    try testing.expectEqual(@as(u64, 3), max_lsn);
    try testing.expectEqual(@as(u32, 1), captured.commits);
    try testing.expectEqual(@as(u64, 42), captured.last_next_doc_id);
    try testing.expect(captured.puts.contains("alpha"));
    try testing.expect(captured.puts.contains("beta"));
    try testing.expect(!captured.puts.contains("gamma"));
}

test "wal reset truncates back to header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const ally = testing.allocator;

    var w = try Wal.open(ally, io, tmp.dir, "wal");
    defer w.close();

    try w.appendPut(1, "k", "v");
    try w.appendCommit(2, 1);
    try w.reset();
    try testing.expectEqual(@as(u64, wal_header_size), w.end_offset);
}
