//! C ABI for embedding pyx into other-language hosts. Mirrors `include/pyx.h`.
//!
//! Conventions:
//!   - All inputs are `(ptr, len)`; no null-terminated strings.
//!   - Output buffers are heap-allocated via the C allocator and must be
//!     released by the caller via `pyx_buf_free`.
//!   - Iterator handles borrow into pyx-owned memory between calls.
//!   - Errors map to `pyx_status` codes; per-thread error messages live in
//!     a thread-local buffer accessible via `pyx_last_error()`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const pyx = @import("pyx");
const doc_mod = pyx.doc;
const index_mod = pyx.index;

// ====================================================================
// Status codes — mirror the C enum exactly.
// ====================================================================

const Status = enum(c_int) {
    ok = 0,
    not_found = 1,
    end = 2,
    invalid_arg = -1,
    out_of_memory = -2,
    io_error = -3,
    corrupt_db = -4,
    txn_already_active = -5,
    no_active_txn = -6,
    key_too_large = -7,
    value_too_large = -8,
    collection_name_invalid = -9,
    no_such_index = -10,
    unsupported_field_type = -11,
    write_conflict = -12,
    retry_budget_exhausted = -13,
    /// Caller's output buffer is too small. `*out_buf_used` (or
    /// equivalent) is set to the required size; caller should retry
    /// with a buffer at least that large.
    buffer_too_small = -14,
    internal = -99,
};

fn statusFromError(err: anyerror) c_int {
    const s: Status = switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.NotADocDb,
        error.UnsupportedVersion,
        error.WrongPageSize,
        error.CorruptHeader,
        error.TruncatedFile,
        error.CorruptNode,
        error.BadTag,
        error.BadVarint,
        error.Truncated,
        => .corrupt_db,
        error.InvalidPageId,
        error.CannotFreeHeader,
        => .internal,
        error.TxnAlreadyActive => .txn_already_active,
        error.NoActiveTxn => .no_active_txn,
        error.KeyTooLarge => .key_too_large,
        error.ValueTooLarge => .value_too_large,
        error.CollectionNameInvalid => .collection_name_invalid,
        error.NoSuchIndex => .no_such_index,
        error.UnsupportedFieldType => .unsupported_field_type,
        error.WriteConflict => .write_conflict,
        error.RetryBudgetExhausted => .retry_budget_exhausted,
        else => blk: {
            setLastError("internal error: {t}", .{err});
            break :blk .internal;
        },
    };
    return @intFromEnum(s);
}

const status_ok: c_int = @intFromEnum(Status.ok);
const status_not_found: c_int = @intFromEnum(Status.not_found);
const status_end: c_int = @intFromEnum(Status.end);
const status_invalid_arg: c_int = @intFromEnum(Status.invalid_arg);
const status_oom: c_int = @intFromEnum(Status.out_of_memory);
const status_write_conflict: c_int = @intFromEnum(Status.write_conflict);
const status_buffer_too_small: c_int = @intFromEnum(Status.buffer_too_small);

// ====================================================================
// Per-thread last-error buffer.
// ====================================================================

threadlocal var last_error_buf: [512]u8 = .{0} ** 512;
threadlocal var last_error_set: bool = false;

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    if (std.fmt.bufPrintZ(last_error_buf[0..511], fmt, args)) |_| {
        last_error_set = true;
    } else |_| {
        @memcpy(last_error_buf[0..15], "error too long\x00");
        last_error_set = true;
    }
}

export fn pyx_last_error() [*:0]const u8 {
    if (!last_error_set) return "no error";
    return @ptrCast(&last_error_buf);
}

// ====================================================================
// Versioning
// ====================================================================

export fn pyx_version() u32 {
    return (0 << 16) | (2 << 8) | 0;
}

export fn pyx_version_string() [*:0]const u8 {
    return "0.2.0";
}

export fn pyx_format_version() u32 {
    // Matches `format_version` in pager.zig.
    return 1;
}

export fn pyx_status_string(status: c_int) [*:0]const u8 {
    return switch (status) {
        @intFromEnum(Status.ok) => "ok",
        @intFromEnum(Status.not_found) => "not found",
        @intFromEnum(Status.end) => "end of iterator",
        @intFromEnum(Status.invalid_arg) => "invalid argument",
        @intFromEnum(Status.out_of_memory) => "out of memory",
        @intFromEnum(Status.io_error) => "I/O error",
        @intFromEnum(Status.corrupt_db) => "corrupt database",
        @intFromEnum(Status.txn_already_active) => "transaction already active",
        @intFromEnum(Status.no_active_txn) => "no active transaction",
        @intFromEnum(Status.key_too_large) => "key too large",
        @intFromEnum(Status.value_too_large) => "value too large",
        @intFromEnum(Status.collection_name_invalid) => "collection name invalid",
        @intFromEnum(Status.no_such_index) => "no such index",
        @intFromEnum(Status.unsupported_field_type) => "unsupported field type",
        @intFromEnum(Status.write_conflict) => "OCC write conflict — retry",
        @intFromEnum(Status.retry_budget_exhausted) => "OCC retry budget exhausted",
        @intFromEnum(Status.internal) => "internal error",
        else => "unknown status",
    };
}

// ====================================================================
// Database state.
// ====================================================================

const State = struct {
    allocator: Allocator,
    threaded: Io.Threaded,
    db: pyx.Db,
};

const SnapshotState = struct {
    allocator: Allocator,
    snapshot: pyx.db.Snapshot,
    /// Borrowed: the State that owns the underlying pyx.Db. We keep a
    /// reference for two reasons: (1) so that internal lookups can reach
    /// the index manager, and (2) to ensure the file/io stay valid.
    state: *State,
};

const IteratorState = struct {
    allocator: Allocator,
    inner: pyx.db.Iterator,
};

const LookupState = struct {
    allocator: Allocator,
    impl: union(enum) {
        equality: index_mod.LookupIterator,
        range: index_mod.RangeIterator,
    },
};

const OptimisticTxnState = struct {
    allocator: Allocator,
    txn: pyx.db.OptimisticTxn,
    /// Borrowed; gives the OCC C entry points access to the underlying
    /// state if they ever need it (currently they only touch `txn`).
    state: *State,
};

// ====================================================================
// pyx_buf
// ====================================================================

const PyxBuf = extern struct {
    data: ?[*]u8,
    len: usize,
};

export fn pyx_buf_free(buf: ?*PyxBuf) void {
    const b = buf orelse return;
    if (b.data) |ptr| {
        if (b.len > 0) std.heap.c_allocator.free(ptr[0..b.len]);
    }
    b.data = null;
    b.len = 0;
}

// ====================================================================
// Database lifecycle
// ====================================================================

export fn pyx_open(path: ?[*:0]const u8, out_db: ?**State) c_int {
    const p = path orelse {
        setLastError("pyx_open: path is null", .{});
        return status_invalid_arg;
    };
    const out = out_db orelse {
        setLastError("pyx_open: out_db is null", .{});
        return status_invalid_arg;
    };

    const allocator = std.heap.c_allocator;
    const state = allocator.create(State) catch {
        setLastError("pyx_open: out of memory", .{});
        return status_oom;
    };
    state.allocator = allocator;
    state.threaded = Io.Threaded.init(allocator, .{});
    state.db = pyx.Db.open(allocator, state.threaded.io(), Io.Dir.cwd(), std.mem.span(p)) catch |err| {
        state.threaded.deinit();
        allocator.destroy(state);
        setLastError("pyx_open: {t}", .{err});
        return statusFromError(err);
    };
    out.* = state;
    return status_ok;
}

export fn pyx_close(db: ?*State) void {
    const s = db orelse return;
    s.db.close();
    s.threaded.deinit();
    s.allocator.destroy(s);
}

export fn pyx_set_sync_mode(db: ?*State, mode: c_int) void {
    const s = db orelse return;
    s.db.setSyncMode(if (mode == 0) .full else .normal);
}

export fn pyx_checkpoint(db: ?*State) c_int {
    const s = db orelse return status_invalid_arg;
    s.db.checkpoint() catch |err| {
        setLastError("pyx_checkpoint: {t}", .{err});
        return statusFromError(err);
    };
    return status_ok;
}

// ====================================================================
// Transactions
// ====================================================================

export fn pyx_begin(db: ?*State) c_int {
    const s = db orelse return status_invalid_arg;
    s.db.begin() catch |err| {
        setLastError("pyx_begin: {t}", .{err});
        return statusFromError(err);
    };
    return status_ok;
}

export fn pyx_commit(db: ?*State) c_int {
    const s = db orelse return status_invalid_arg;
    s.db.commit() catch |err| {
        setLastError("pyx_commit: {t}", .{err});
        return statusFromError(err);
    };
    return status_ok;
}

export fn pyx_abort(db: ?*State) void {
    const s = db orelse return;
    s.db.abort();
}

// ====================================================================
// Document operations
// ====================================================================

fn sliceFromCArg(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return &[_]u8{};
    if (ptr) |p| return p[0..len];
    return null;
}

fn nameSliceFromCArg(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return null;
    if (ptr) |p| return p[0..len];
    return null;
}

export fn pyx_insert(
    db: ?*State,
    coll: ?[*]const u8, coll_len: usize,
    doc: ?[*]const u8, doc_len: usize,
    out_doc_id: ?*u64,
) c_int {
    const s = db orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse {
        setLastError("pyx_insert: collection is null/empty", .{});
        return status_invalid_arg;
    };
    const d = sliceFromCArg(doc, doc_len) orelse {
        setLastError("pyx_insert: doc pointer null with non-zero length", .{});
        return status_invalid_arg;
    };
    const out = out_doc_id orelse {
        setLastError("pyx_insert: out_doc_id is null", .{});
        return status_invalid_arg;
    };
    const id = s.db.collection(c).insert(d) catch |err| {
        setLastError("pyx_insert: {t}", .{err});
        return statusFromError(err);
    };
    out.* = id;
    return status_ok;
}

export fn pyx_put(
    db: ?*State,
    coll: ?[*]const u8, coll_len: usize,
    doc_id: u64,
    doc: ?[*]const u8, doc_len: usize,
) c_int {
    const s = db orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const d = sliceFromCArg(doc, doc_len) orelse return status_invalid_arg;
    s.db.collection(c).put(doc_id, d) catch |err| {
        setLastError("pyx_put: {t}", .{err});
        return statusFromError(err);
    };
    return status_ok;
}

export fn pyx_get(
    db: ?*State,
    coll: ?[*]const u8, coll_len: usize,
    doc_id: u64,
    out_buf: ?*PyxBuf,
) c_int {
    const s = db orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const out = out_buf orelse return status_invalid_arg;
    out.data = null;
    out.len = 0;

    const result = s.db.collection(c).get(s.allocator, doc_id) catch |err| {
        setLastError("pyx_get: {t}", .{err});
        return statusFromError(err);
    };
    if (result) |bytes| {
        out.data = bytes.ptr;
        out.len = bytes.len;
        return status_ok;
    }
    return status_not_found;
}

/// Batched get (phase 4) — collapses N point reads into one C call so
/// Python callers don't pay the per-call ctypes overhead per id. Layout:
///
///   inputs:  ids[n_ids]               u64 doc ids (any order)
///   outputs: out_lens[n_ids]          u32 bytes-per-doc; 0 == not found
///            out_buf[out_buf_cap]     packed bytes for the values, in
///                                     ids[] order, no separators (use
///                                     out_lens[] to slice)
///            *out_buf_used            total bytes written (or required
///                                     if return is buffer_too_small)
///
/// On `buffer_too_small`, `*out_buf_used` is set to the total bytes
/// every found doc would need; caller should retry with a buffer of at
/// least that size. The retry path scans every id again (fast — the
/// pages are already warm in the kernel page cache).
export fn pyx_get_many(
    db: ?*State,
    coll: ?[*]const u8, coll_len: usize,
    ids: ?[*]const u64, n_ids: usize,
    out_lens: ?[*]u32,
    out_buf: ?[*]u8, out_buf_cap: usize,
    out_buf_used: ?*usize,
) c_int {
    const s = db orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    if (out_buf_used) |p| p.* = 0;
    if (n_ids == 0) return status_ok;
    const ids_ptr = ids orelse return status_invalid_arg;
    const lens_ptr = out_lens orelse return status_invalid_arg;
    const buf_ptr = out_buf orelse return status_invalid_arg;

    const collection = s.db.collection(c);
    var used: usize = 0;
    const ok = collection.getMany(
        s.allocator,
        ids_ptr[0..n_ids],
        lens_ptr[0..n_ids],
        buf_ptr[0..out_buf_cap],
        &used,
    ) catch |err| switch (err) {
        error.BufferTooSmall => {
            if (out_buf_used) |p| p.* = used;
            return status_buffer_too_small;
        },
        else => {
            setLastError("pyx_get_many: {t}", .{err});
            return statusFromError(err);
        },
    };
    _ = ok;
    if (out_buf_used) |p| p.* = used;
    return status_ok;
}

export fn pyx_delete(
    db: ?*State,
    coll: ?[*]const u8, coll_len: usize,
    doc_id: u64,
) c_int {
    const s = db orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const found = s.db.collection(c).delete(doc_id) catch |err| {
        setLastError("pyx_delete: {t}", .{err});
        return statusFromError(err);
    };
    return if (found) status_ok else status_not_found;
}

// ====================================================================
// Iteration
// ====================================================================

export fn pyx_iter_open(
    db: ?*State,
    coll: ?[*]const u8, coll_len: usize,
    out_iter: ?**IteratorState,
) c_int {
    const s = db orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const out = out_iter orelse return status_invalid_arg;

    const it_state = s.allocator.create(IteratorState) catch return status_oom;
    it_state.allocator = s.allocator;
    it_state.inner = s.db.collection(c).iterator(s.allocator) catch |err| {
        s.allocator.destroy(it_state);
        setLastError("pyx_iter_open: {t}", .{err});
        return statusFromError(err);
    };
    out.* = it_state;
    return status_ok;
}

export fn pyx_iter_next(
    iter: ?*IteratorState,
    out_doc_id: ?*u64,
    out_doc: ?*PyxBuf,
) c_int {
    const it = iter orelse return status_invalid_arg;
    const id_out = out_doc_id orelse return status_invalid_arg;
    const buf_out = out_doc orelse return status_invalid_arg;

    const entry = (it.inner.next() catch |err| {
        setLastError("pyx_iter_next: {t}", .{err});
        return statusFromError(err);
    }) orelse {
        buf_out.data = null;
        buf_out.len = 0;
        return status_end;
    };
    id_out.* = entry.id;
    // Borrowed slice — points into the underlying btree iterator's frame
    // page buffer. Caller must NOT free; valid until the next next/close.
    buf_out.data = @constCast(entry.doc.ptr);
    buf_out.len = entry.doc.len;
    return status_ok;
}

export fn pyx_iter_close(iter: ?*IteratorState) void {
    const it = iter orelse return;
    it.inner.deinit();
    it.allocator.destroy(it);
}

// ====================================================================
// Collections (sharding phase 2C)
// ====================================================================

/// Create a new collection backed by its own B+Tree. Idempotent —
/// re-calling with an existing name returns the same id without
/// allocating a new one. The id is written to `*out_id` (which may
/// be NULL if the caller doesn't need it; the registration still
/// happens). Returns a status code.
export fn pyx_create_collection(
    db: ?*State,
    name: ?[*]const u8, name_len: usize,
    out_id: ?*u32,
) c_int {
    const s = db orelse return status_invalid_arg;
    const n = nameSliceFromCArg(name, name_len) orelse return status_invalid_arg;
    const id = s.db.createCollection(n) catch |err| {
        setLastError("pyx_create_collection: {t}", .{err});
        return statusFromError(err);
    };
    if (out_id) |p| p.* = id;
    return status_ok;
}

// ====================================================================
// Indexes
// ====================================================================

export fn pyx_create_index(
    db: ?*State,
    coll: ?[*]const u8, coll_len: usize,
    field: ?[*]const u8, field_len: usize,
) c_int {
    const s = db orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const f = nameSliceFromCArg(field, field_len) orelse return status_invalid_arg;
    s.db.createIndex(c, f) catch |err| {
        setLastError("pyx_create_index: {t}", .{err});
        return statusFromError(err);
    };
    return status_ok;
}

export fn pyx_drop_index(
    db: ?*State,
    coll: ?[*]const u8, coll_len: usize,
    field: ?[*]const u8, field_len: usize,
) c_int {
    const s = db orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const f = nameSliceFromCArg(field, field_len) orelse return status_invalid_arg;
    s.db.dropIndex(c, f) catch |err| {
        setLastError("pyx_drop_index: {t}", .{err});
        return statusFromError(err);
    };
    return status_ok;
}

// ====================================================================
// pyx_value <-> doc.Value bridge
// ====================================================================

const PyxValueType = enum(c_int) {
    null = 0,
    bool = 1,
    i64 = 2,
    f64 = 3,
    string = 4,
    _,
};

const PyxString = extern struct { ptr: ?[*]const u8, len: usize };

const PyxValueAs = extern union {
    i64_v: i64,
    f64_v: f64,
    boolean: u8,
    string: PyxString,
};

const PyxValue = extern struct {
    type: PyxValueType,
    as: PyxValueAs,
};

const PyxBoundKind = enum(c_int) {
    none = 0,
    inclusive = 1,
    exclusive = 2,
    _,
};

const PyxBound = extern struct {
    kind: PyxBoundKind,
    value: PyxValue,
};

fn convertValue(v: *const PyxValue) !doc_mod.Value {
    return switch (v.type) {
        .null => .null,
        .bool => .{ .bool = v.as.boolean != 0 },
        .i64 => .{ .i64 = v.as.i64_v },
        .f64 => .{ .f64 = v.as.f64_v },
        .string => blk: {
            const ptr = v.as.string.ptr orelse return error.InvalidArg;
            break :blk .{ .string = ptr[0..v.as.string.len] };
        },
        _ => error.InvalidArg,
    };
}

fn convertBound(b: ?*const PyxBound) !index_mod.Bound {
    if (b) |bp| {
        return switch (bp.kind) {
            .none => .none,
            .inclusive => .{ .inclusive = try convertValue(&bp.value) },
            .exclusive => .{ .exclusive = try convertValue(&bp.value) },
            _ => error.InvalidArg,
        };
    }
    return .none;
}

export fn pyx_find_one(
    db: ?*State,
    coll: ?[*]const u8, coll_len: usize,
    field: ?[*]const u8, field_len: usize,
    value: ?*const PyxValue,
    out_doc_id: ?*u64,
) c_int {
    const s = db orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const f = nameSliceFromCArg(field, field_len) orelse return status_invalid_arg;
    const v = value orelse return status_invalid_arg;
    const out = out_doc_id orelse return status_invalid_arg;
    const dv = convertValue(v) catch return status_invalid_arg;
    const id = s.db.collection(c).findOne(f, dv) catch |err| {
        setLastError("pyx_find_one: {t}", .{err});
        return statusFromError(err);
    };
    if (id) |found| {
        out.* = found;
        return status_ok;
    }
    return status_not_found;
}

export fn pyx_find_range(
    db: ?*State,
    coll: ?[*]const u8, coll_len: usize,
    field: ?[*]const u8, field_len: usize,
    lo: ?*const PyxBound,
    hi: ?*const PyxBound,
    out_lookup: ?**LookupState,
) c_int {
    const s = db orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const f = nameSliceFromCArg(field, field_len) orelse return status_invalid_arg;
    const out = out_lookup orelse return status_invalid_arg;

    const lo_b = convertBound(lo) catch return status_invalid_arg;
    const hi_b = convertBound(hi) catch return status_invalid_arg;

    const ls = s.allocator.create(LookupState) catch return status_oom;
    ls.allocator = s.allocator;
    const range_iter = s.db.collection(c).findRange(s.allocator, f, lo_b, hi_b) catch |err| {
        s.allocator.destroy(ls);
        setLastError("pyx_find_range: {t}", .{err});
        return statusFromError(err);
    };
    ls.impl = .{ .range = range_iter };
    out.* = ls;
    return status_ok;
}

export fn pyx_lookup_next(lookup: ?*LookupState, out_doc_id: ?*u64) c_int {
    const ls = lookup orelse return status_invalid_arg;
    const out = out_doc_id orelse return status_invalid_arg;
    const id = switch (ls.impl) {
        .equality => |*it| it.next() catch |err| {
            setLastError("pyx_lookup_next: {t}", .{err});
            return statusFromError(err);
        },
        .range => |*it| it.next() catch |err| {
            setLastError("pyx_lookup_next: {t}", .{err});
            return statusFromError(err);
        },
    };
    if (id) |found| {
        out.* = found;
        return status_ok;
    }
    return status_end;
}

export fn pyx_lookup_close(lookup: ?*LookupState) void {
    const ls = lookup orelse return;
    switch (ls.impl) {
        .equality => |*it| it.deinit(),
        .range => |*it| it.deinit(),
    }
    ls.allocator.destroy(ls);
}

// ====================================================================
// Snapshots — lock-free reads
// ====================================================================

export fn pyx_snapshot_open(db: ?*State, out_snap: ?**SnapshotState) c_int {
    const s = db orelse return status_invalid_arg;
    const out = out_snap orelse return status_invalid_arg;
    const ss = s.allocator.create(SnapshotState) catch return status_oom;
    ss.allocator = s.allocator;
    ss.state = s;
    ss.snapshot = s.db.snapshot() catch |err| {
        s.allocator.destroy(ss);
        setLastError("pyx_snapshot_open: {t}", .{err});
        return statusFromError(err);
    };
    out.* = ss;
    return status_ok;
}

export fn pyx_snapshot_close(snap: ?*SnapshotState) void {
    const ss = snap orelse return;
    ss.snapshot.deinit();
    ss.allocator.destroy(ss);
}

export fn pyx_snapshot_get(
    snap: ?*SnapshotState,
    coll: ?[*]const u8, coll_len: usize,
    doc_id: u64,
    out_buf: ?*PyxBuf,
) c_int {
    const ss = snap orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const out = out_buf orelse return status_invalid_arg;
    out.data = null;
    out.len = 0;

    const result = ss.snapshot.collection(c).get(ss.allocator, doc_id) catch |err| {
        setLastError("pyx_snapshot_get: {t}", .{err});
        return statusFromError(err);
    };
    if (result) |bytes| {
        out.data = bytes.ptr;
        out.len = bytes.len;
        return status_ok;
    }
    return status_not_found;
}

export fn pyx_snapshot_iter_open(
    snap: ?*SnapshotState,
    coll: ?[*]const u8, coll_len: usize,
    out_iter: ?**IteratorState,
) c_int {
    const ss = snap orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const out = out_iter orelse return status_invalid_arg;

    const it_state = ss.allocator.create(IteratorState) catch return status_oom;
    it_state.allocator = ss.allocator;
    it_state.inner = ss.snapshot.collection(c).iterator(ss.allocator) catch |err| {
        ss.allocator.destroy(it_state);
        setLastError("pyx_snapshot_iter_open: {t}", .{err});
        return statusFromError(err);
    };
    out.* = it_state;
    return status_ok;
}

export fn pyx_snapshot_find_one(
    snap: ?*SnapshotState,
    coll: ?[*]const u8, coll_len: usize,
    field: ?[*]const u8, field_len: usize,
    value: ?*const PyxValue,
    out_doc_id: ?*u64,
) c_int {
    const ss = snap orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const f = nameSliceFromCArg(field, field_len) orelse return status_invalid_arg;
    const v = value orelse return status_invalid_arg;
    const out = out_doc_id orelse return status_invalid_arg;
    const dv = convertValue(v) catch return status_invalid_arg;
    const id = ss.snapshot.collection(c).findOne(f, dv) catch |err| {
        setLastError("pyx_snapshot_find_one: {t}", .{err});
        return statusFromError(err);
    };
    if (id) |found| {
        out.* = found;
        return status_ok;
    }
    return status_not_found;
}

export fn pyx_snapshot_find_range(
    snap: ?*SnapshotState,
    coll: ?[*]const u8, coll_len: usize,
    field: ?[*]const u8, field_len: usize,
    lo: ?*const PyxBound,
    hi: ?*const PyxBound,
    out_lookup: ?**LookupState,
) c_int {
    const ss = snap orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const f = nameSliceFromCArg(field, field_len) orelse return status_invalid_arg;
    const out = out_lookup orelse return status_invalid_arg;

    const lo_b = convertBound(lo) catch return status_invalid_arg;
    const hi_b = convertBound(hi) catch return status_invalid_arg;

    const ls = ss.allocator.create(LookupState) catch return status_oom;
    ls.allocator = ss.allocator;
    const range_iter = ss.snapshot.collection(c).findRange(ss.allocator, f, lo_b, hi_b) catch |err| {
        ss.allocator.destroy(ls);
        setLastError("pyx_snapshot_find_range: {t}", .{err});
        return statusFromError(err);
    };
    ls.impl = .{ .range = range_iter };
    out.* = ls;
    return status_ok;
}

// ====================================================================
// Compound indexes
// ====================================================================

/// Decode a `(field_ptrs, field_lens, n_fields)` triple from C into a
/// stack-bounded array of slices. Returns null on null pointers or
/// unsupported `n_fields`.
fn collectCompoundFields(
    fields_ptrs: ?[*]const ?[*]const u8,
    field_lens: ?[*]const usize,
    n_fields: usize,
    out: *[16][]const u8,
) ?[]const []const u8 {
    if (n_fields == 0 or n_fields > out.len) return null;
    const ptrs = fields_ptrs orelse return null;
    const lens = field_lens orelse return null;
    var i: usize = 0;
    while (i < n_fields) : (i += 1) {
        const p = ptrs[i] orelse return null;
        out[i] = p[0..lens[i]];
    }
    return out[0..n_fields];
}

export fn pyx_create_compound_index(
    db: ?*State,
    coll: ?[*]const u8, coll_len: usize,
    fields: ?[*]const ?[*]const u8,
    field_lens: ?[*]const usize,
    n_fields: usize,
) c_int {
    const s = db orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    var stack: [16][]const u8 = undefined;
    const fs = collectCompoundFields(fields, field_lens, n_fields, &stack) orelse return status_invalid_arg;
    s.db.createCompoundIndex(c, fs) catch |err| {
        setLastError("pyx_create_compound_index: {t}", .{err});
        return statusFromError(err);
    };
    return status_ok;
}

export fn pyx_drop_compound_index(
    db: ?*State,
    coll: ?[*]const u8, coll_len: usize,
    fields: ?[*]const ?[*]const u8,
    field_lens: ?[*]const usize,
    n_fields: usize,
) c_int {
    const s = db orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    var stack: [16][]const u8 = undefined;
    const fs = collectCompoundFields(fields, field_lens, n_fields, &stack) orelse return status_invalid_arg;
    s.db.dropCompoundIndex(c, fs) catch |err| {
        setLastError("pyx_drop_compound_index: {t}", .{err});
        return statusFromError(err);
    };
    return status_ok;
}

export fn pyx_compound_find_one(
    db: ?*State,
    coll: ?[*]const u8, coll_len: usize,
    fields: ?[*]const ?[*]const u8,
    field_lens: ?[*]const usize,
    n_fields: usize,
    values: ?[*]const PyxValue,
    out_doc_id: ?*u64,
) c_int {
    const s = db orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const out = out_doc_id orelse return status_invalid_arg;
    var fields_stack: [16][]const u8 = undefined;
    const fs = collectCompoundFields(fields, field_lens, n_fields, &fields_stack) orelse return status_invalid_arg;
    const vs_ptr = values orelse return status_invalid_arg;
    var values_stack: [16]doc_mod.Value = undefined;
    if (n_fields > values_stack.len) return status_invalid_arg;
    var i: usize = 0;
    while (i < n_fields) : (i += 1) {
        values_stack[i] = convertValue(&vs_ptr[i]) catch return status_invalid_arg;
    }
    const id = s.db.collection(c).findOneCompound(fs, values_stack[0..n_fields]) catch |err| {
        setLastError("pyx_compound_find_one: {t}", .{err});
        return statusFromError(err);
    };
    if (id) |found| {
        out.* = found;
        return status_ok;
    }
    return status_not_found;
}

// ====================================================================
// Optimistic concurrency
// ====================================================================

export fn pyx_begin_optimistic(db: ?*State, out_txn: ?**OptimisticTxnState) c_int {
    const s = db orelse return status_invalid_arg;
    const out = out_txn orelse return status_invalid_arg;
    const ts = s.allocator.create(OptimisticTxnState) catch {
        setLastError("pyx_begin_optimistic: out of memory", .{});
        return status_oom;
    };
    ts.allocator = s.allocator;
    ts.state = s;
    ts.txn = s.db.beginOptimistic() catch |err| {
        s.allocator.destroy(ts);
        setLastError("pyx_begin_optimistic: {t}", .{err});
        return statusFromError(err);
    };
    out.* = ts;
    return status_ok;
}

export fn pyx_optimistic_commit(txn: ?*OptimisticTxnState) c_int {
    const t = txn orelse return status_invalid_arg;
    defer t.allocator.destroy(t);
    t.txn.commit() catch |err| {
        // pyx.db.OptimisticTxn.commit deinits its own state on every
        // path, so we don't call abort here on error.
        if (err != error.WriteConflict) setLastError("pyx_optimistic_commit: {t}", .{err});
        return statusFromError(err);
    };
    return status_ok;
}

export fn pyx_optimistic_abort(txn: ?*OptimisticTxnState) void {
    const t = txn orelse return;
    t.txn.abort();
    t.allocator.destroy(t);
}

export fn pyx_optimistic_insert(
    txn: ?*OptimisticTxnState,
    coll: ?[*]const u8, coll_len: usize,
    doc: ?[*]const u8, doc_len: usize,
    out_doc_id: ?*u64,
) c_int {
    const t = txn orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const d = sliceFromCArg(doc, doc_len) orelse return status_invalid_arg;
    const out = out_doc_id orelse return status_invalid_arg;
    const id = t.txn.collection(c).insert(d) catch |err| {
        setLastError("pyx_optimistic_insert: {t}", .{err});
        return statusFromError(err);
    };
    out.* = id;
    return status_ok;
}

export fn pyx_optimistic_put(
    txn: ?*OptimisticTxnState,
    coll: ?[*]const u8, coll_len: usize,
    doc_id: u64,
    doc: ?[*]const u8, doc_len: usize,
) c_int {
    const t = txn orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const d = sliceFromCArg(doc, doc_len) orelse return status_invalid_arg;
    t.txn.collection(c).put(doc_id, d) catch |err| {
        setLastError("pyx_optimistic_put: {t}", .{err});
        return statusFromError(err);
    };
    return status_ok;
}

export fn pyx_optimistic_delete(
    txn: ?*OptimisticTxnState,
    coll: ?[*]const u8, coll_len: usize,
    doc_id: u64,
) c_int {
    const t = txn orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    _ = t.txn.collection(c).delete(doc_id) catch |err| {
        setLastError("pyx_optimistic_delete: {t}", .{err});
        return statusFromError(err);
    };
    return status_ok;
}

export fn pyx_optimistic_get(
    txn: ?*OptimisticTxnState,
    coll: ?[*]const u8, coll_len: usize,
    doc_id: u64,
    out: ?*PyxBuf,
) c_int {
    const t = txn orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const buf = out orelse return status_invalid_arg;
    const result = t.txn.collection(c).get(std.heap.c_allocator, doc_id) catch |err| {
        setLastError("pyx_optimistic_get: {t}", .{err});
        return statusFromError(err);
    };
    if (result) |bytes| {
        buf.data = bytes.ptr;
        buf.len = bytes.len;
        return status_ok;
    }
    buf.data = null;
    buf.len = 0;
    return status_not_found;
}

export fn pyx_optimistic_find_one(
    txn: ?*OptimisticTxnState,
    coll: ?[*]const u8, coll_len: usize,
    field: ?[*]const u8, field_len: usize,
    value: ?*const PyxValue,
    out_doc_id: ?*u64,
) c_int {
    const t = txn orelse return status_invalid_arg;
    const c = nameSliceFromCArg(coll, coll_len) orelse return status_invalid_arg;
    const f = nameSliceFromCArg(field, field_len) orelse return status_invalid_arg;
    const v = value orelse return status_invalid_arg;
    const out = out_doc_id orelse return status_invalid_arg;
    const dv = convertValue(v) catch return status_invalid_arg;
    const id = t.txn.collection(c).findOne(f, dv) catch |err| {
        setLastError("pyx_optimistic_find_one: {t}", .{err});
        return statusFromError(err);
    };
    if (id) |found| {
        out.* = found;
        return status_ok;
    }
    return status_not_found;
}

// ====================================================================
// Round-trip self-test (calls our own exports through Zig).
// ====================================================================

const testing = std.testing;

// Helper: prepare a fresh DB path under a known scratch dir. The C ABI
// uses `Io.Dir.cwd()` internally, so paths are relative to cwd.
fn cabiPath(comptime name: []const u8) [:0]const u8 {
    var tmp_dir = Io.Dir.cwd().createDirPathOpen(testing.io, ".cabi-test", .{}) catch unreachable;
    defer tmp_dir.close(testing.io);
    tmp_dir.deleteFile(testing.io, name) catch {};
    tmp_dir.deleteFile(testing.io, name ++ ".wal") catch {};
    return ".cabi-test/" ++ name;
}

test "C ABI: open / insert / get / delete via exports" {
    const path = cabiPath("c-abi.db");

    var db: *State = undefined;
    try testing.expectEqual(status_ok, pyx_open(path.ptr, &db));
    defer pyx_close(db);

    pyx_set_sync_mode(db, 1); // normal

    const coll = "users";
    var doc1 = "{\"name\": \"alice\"}".*;
    var id1: u64 = 0;
    try testing.expectEqual(status_ok, pyx_insert(db, coll.ptr, coll.len, &doc1, doc1.len, &id1));
    try testing.expect(id1 > 0);

    var got: PyxBuf = .{ .data = null, .len = 0 };
    try testing.expectEqual(status_ok, pyx_get(db, coll.ptr, coll.len, id1, &got));
    try testing.expectEqualSlices(u8, &doc1, got.data.?[0..got.len]);
    pyx_buf_free(&got);
    try testing.expectEqual(@as(?[*]u8, null), got.data);

    try testing.expectEqual(status_ok, pyx_delete(db, coll.ptr, coll.len, id1));
    try testing.expectEqual(status_not_found, pyx_get(db, coll.ptr, coll.len, id1, &got));
}

test "C ABI: iterator borrows valid bytes" {
    const path = cabiPath("c-iter.db");

    var db: *State = undefined;
    try testing.expectEqual(status_ok, pyx_open(path.ptr, &db));
    defer pyx_close(db);

    const coll = "c";
    var d1 = "{\"i\": 1}".*;
    var d2 = "{\"i\": 2}".*;
    var id: u64 = 0;
    try testing.expectEqual(status_ok, pyx_insert(db, coll.ptr, coll.len, &d1, d1.len, &id));
    try testing.expectEqual(status_ok, pyx_insert(db, coll.ptr, coll.len, &d2, d2.len, &id));

    var iter: *IteratorState = undefined;
    try testing.expectEqual(status_ok, pyx_iter_open(db, coll.ptr, coll.len, &iter));
    defer pyx_iter_close(iter);

    var seen: u32 = 0;
    var doc_id: u64 = 0;
    var buf: PyxBuf = .{ .data = null, .len = 0 };
    while (true) {
        const rc = pyx_iter_next(iter, &doc_id, &buf);
        if (rc == status_end) break;
        try testing.expectEqual(status_ok, rc);
        try testing.expect(buf.len > 0);
        seen += 1;
    }
    try testing.expectEqual(@as(u32, 2), seen);
}

test "C ABI: indexed find_one and find_range" {
    const path = cabiPath("c-idx.db");

    var db: *State = undefined;
    try testing.expectEqual(status_ok, pyx_open(path.ptr, &db));
    defer pyx_close(db);

    const coll = "c";
    const field = "count";

    // Build proper binary docs via pyx's JSON helper (so the index can
    // extract `count` from each doc).
    var i: i64 = 0;
    while (i < 10) : (i += 1) {
        var json_buf: [64]u8 = undefined;
        const json_str = try std.fmt.bufPrint(&json_buf, "{{\"count\": {d}}}", .{i});
        const doc_bytes = try pyx.json.fromJson(std.heap.c_allocator, json_str);
        defer std.heap.c_allocator.free(doc_bytes);
        var id: u64 = 0;
        try testing.expectEqual(status_ok, pyx_insert(db, coll.ptr, coll.len, doc_bytes.ptr, doc_bytes.len, &id));
    }

    try testing.expectEqual(status_ok, pyx_create_index(db, coll.ptr, coll.len, field.ptr, field.len));

    // Equality lookup hits.
    var v: PyxValue = .{ .type = .i64, .as = .{ .i64_v = 5 } };
    var doc_id: u64 = 0;
    try testing.expectEqual(status_ok, pyx_find_one(db, coll.ptr, coll.len, field.ptr, field.len, &v, &doc_id));
    try testing.expect(doc_id != 0);

    // Range scan over [3, 7] inclusive — should yield 5 doc ids.
    const lo: PyxBound = .{ .kind = .inclusive, .value = .{ .type = .i64, .as = .{ .i64_v = 3 } } };
    const hi: PyxBound = .{ .kind = .inclusive, .value = .{ .type = .i64, .as = .{ .i64_v = 7 } } };
    var lookup: *LookupState = undefined;
    try testing.expectEqual(status_ok, pyx_find_range(db, coll.ptr, coll.len, field.ptr, field.len, &lo, &hi, &lookup));
    defer pyx_lookup_close(lookup);
    var seen: u32 = 0;
    while (pyx_lookup_next(lookup, &doc_id) == status_ok) seen += 1;
    try testing.expectEqual(@as(u32, 5), seen);
}

test "C ABI: snapshot reads survive concurrent writes (single-thread sanity)" {
    const path = cabiPath("c-snap.db");

    var db: *State = undefined;
    try testing.expectEqual(status_ok, pyx_open(path.ptr, &db));
    defer pyx_close(db);

    const coll = "c";
    var doc = "{}".*;
    var id: u64 = 0;
    try testing.expectEqual(status_ok, pyx_insert(db, coll.ptr, coll.len, &doc, doc.len, &id));

    var snap: *SnapshotState = undefined;
    try testing.expectEqual(status_ok, pyx_snapshot_open(db, &snap));
    defer pyx_snapshot_close(snap);

    var post_doc = "{\"after\":true}".*;
    var post_id: u64 = 0;
    try testing.expectEqual(status_ok, pyx_insert(db, coll.ptr, coll.len, &post_doc, post_doc.len, &post_id));

    // Snapshot still finds the original doc.
    var got: PyxBuf = .{ .data = null, .len = 0 };
    try testing.expectEqual(status_ok, pyx_snapshot_get(snap, coll.ptr, coll.len, id, &got));
    pyx_buf_free(&got);

    // Snapshot does NOT find the post-snapshot doc.
    try testing.expectEqual(status_not_found, pyx_snapshot_get(snap, coll.ptr, coll.len, post_id, &got));
}

test "C ABI: null inputs return invalid_arg, not crash" {
    try testing.expectEqual(status_invalid_arg, pyx_open(null, null));
    pyx_close(null); // no-op
    pyx_buf_free(null); // no-op
    try testing.expectEqual(status_invalid_arg, pyx_checkpoint(null));
}

test "C ABI: OCC begin/insert/get/commit roundtrip" {
    const path = cabiPath("c-abi-occ.db");
    var db: *State = undefined;
    try testing.expectEqual(status_ok, pyx_open(path.ptr, &db));
    defer pyx_close(db);
    pyx_set_sync_mode(db, 1);

    var txn: *OptimisticTxnState = undefined;
    try testing.expectEqual(status_ok, pyx_begin_optimistic(db, &txn));

    const coll = "users";
    var doc1 = "{\"name\": \"alice\"}".*;
    var id1: u64 = 0;
    try testing.expectEqual(status_ok, pyx_optimistic_insert(txn, coll.ptr, coll.len, &doc1, doc1.len, &id1));
    try testing.expect(id1 > 0);

    // Read-your-own-writes via the OCC get path.
    var got: PyxBuf = .{ .data = null, .len = 0 };
    try testing.expectEqual(status_ok, pyx_optimistic_get(txn, coll.ptr, coll.len, id1, &got));
    try testing.expectEqualSlices(u8, &doc1, got.data.?[0..got.len]);
    pyx_buf_free(&got);

    try testing.expectEqual(status_ok, pyx_optimistic_commit(txn));

    // After commit, the doc must be visible via the regular get.
    try testing.expectEqual(status_ok, pyx_get(db, coll.ptr, coll.len, id1, &got));
    try testing.expectEqualSlices(u8, &doc1, got.data.?[0..got.len]);
    pyx_buf_free(&got);
}

test "C ABI: OCC abort discards writes" {
    const path = cabiPath("c-abi-occ-abort.db");
    var db: *State = undefined;
    try testing.expectEqual(status_ok, pyx_open(path.ptr, &db));
    defer pyx_close(db);
    pyx_set_sync_mode(db, 1);

    var txn: *OptimisticTxnState = undefined;
    try testing.expectEqual(status_ok, pyx_begin_optimistic(db, &txn));
    const coll = "c";
    var doc1 = "{\"x\": 1}".*;
    var id1: u64 = 0;
    try testing.expectEqual(status_ok, pyx_optimistic_insert(txn, coll.ptr, coll.len, &doc1, doc1.len, &id1));
    pyx_optimistic_abort(txn);

    var got: PyxBuf = .{ .data = null, .len = 0 };
    try testing.expectEqual(status_not_found, pyx_get(db, coll.ptr, coll.len, id1, &got));
}

test "C ABI: OCC commit returns write_conflict on observed-value change" {
    const path = cabiPath("c-abi-occ-conflict.db");
    var db: *State = undefined;
    try testing.expectEqual(status_ok, pyx_open(path.ptr, &db));
    defer pyx_close(db);
    pyx_set_sync_mode(db, 1);

    const coll = "c";
    var v0 = "{\"v\": 0}".*;
    var v1 = "{\"v\": 1}".*;
    var v2 = "{\"v\": 2}".*;
    var id: u64 = 0;
    try testing.expectEqual(status_ok, pyx_insert(db, coll.ptr, coll.len, &v0, v0.len, &id));
    try testing.expectEqual(status_ok, pyx_checkpoint(db));

    // Begin an OCC txn and read the doc.
    var txn: *OptimisticTxnState = undefined;
    try testing.expectEqual(status_ok, pyx_begin_optimistic(db, &txn));
    var got: PyxBuf = .{ .data = null, .len = 0 };
    try testing.expectEqual(status_ok, pyx_optimistic_get(txn, coll.ptr, coll.len, id, &got));
    pyx_buf_free(&got);

    // External committer overwrites it.
    try testing.expectEqual(status_ok, pyx_put(db, coll.ptr, coll.len, id, &v1, v1.len));

    // OCC stages its own write and tries to commit → conflict.
    try testing.expectEqual(status_ok, pyx_optimistic_put(txn, coll.ptr, coll.len, id, &v2, v2.len));
    try testing.expectEqual(status_write_conflict, pyx_optimistic_commit(txn));
}

test "C ABI: compound index create + find + drop" {
    const path = cabiPath("c-abi-compound.db");
    var db: *State = undefined;
    try testing.expectEqual(status_ok, pyx_open(path.ptr, &db));
    defer pyx_close(db);
    pyx_set_sync_mode(db, 1);

    // Insert two docs with last/first via the binary doc Builder.
    const coll = "u";
    const Builder = pyx.doc.Builder;
    const ally = std.testing.allocator;

    var bytes_a: []u8 = undefined;
    {
        var b = Builder.init(ally);
        defer b.deinit();
        try b.beginDocument();
        try b.putString("last", "smith");
        try b.putString("first", "alice");
        try b.endDocument();
        bytes_a = try b.finish();
    }
    defer ally.free(bytes_a);
    var bytes_b: []u8 = undefined;
    {
        var b = Builder.init(ally);
        defer b.deinit();
        try b.beginDocument();
        try b.putString("last", "smith");
        try b.putString("first", "bob");
        try b.endDocument();
        bytes_b = try b.finish();
    }
    defer ally.free(bytes_b);

    var id_a: u64 = 0;
    var id_b: u64 = 0;
    try testing.expectEqual(status_ok, pyx_insert(db, coll.ptr, coll.len, bytes_a.ptr, bytes_a.len, &id_a));
    try testing.expectEqual(status_ok, pyx_insert(db, coll.ptr, coll.len, bytes_b.ptr, bytes_b.len, &id_b));

    // Build the field-pointer arrays.
    const last = "last";
    const first = "first";
    const field_ptrs = [2]?[*]const u8{ last.ptr, first.ptr };
    const field_lens = [2]usize{ last.len, first.len };

    try testing.expectEqual(status_ok, pyx_create_compound_index(
        db, coll.ptr, coll.len, &field_ptrs, &field_lens, 2,
    ));

    // Lookup (smith, alice) → id_a.
    const v_smith = PyxValue{ .type = .string, .as = .{ .string = .{ .ptr = "smith".ptr, .len = 5 } } };
    const v_alice = PyxValue{ .type = .string, .as = .{ .string = .{ .ptr = "alice".ptr, .len = 5 } } };
    const values = [2]PyxValue{ v_smith, v_alice };
    var got: u64 = 0;
    try testing.expectEqual(status_ok, pyx_compound_find_one(
        db, coll.ptr, coll.len, &field_ptrs, &field_lens, 2, &values, &got,
    ));
    try testing.expectEqual(id_a, got);

    // Drop → subsequent find raises no_such_index.
    try testing.expectEqual(status_ok, pyx_drop_compound_index(
        db, coll.ptr, coll.len, &field_ptrs, &field_lens, 2,
    ));
    const drop_status = pyx_compound_find_one(
        db, coll.ptr, coll.len, &field_ptrs, &field_lens, 2, &values, &got,
    );
    try testing.expectEqual(@intFromEnum(Status.no_such_index), drop_status);
}
