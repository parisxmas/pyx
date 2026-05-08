//! Copy-on-write B+Tree over the pager.
//!
//! Every mutation allocates fresh pages and propagates new page ids up to
//! the root. The previous root remains valid on disk and reachable from any
//! snapshot that captured it before the mutation — that's how snapshot
//! isolation falls out of the design. v0 leaks superseded pages; real GC
//! needs reader-set tracking.
//!
//! Page format (one node per page):
//!   [0..16)  NodeHeader
//!   [16..)   Slot directory: u16 offsets, one per key
//!   ...      Free space
//!   [..end)  Entries, packed from page end backward
//!
//! Leaf entries:     u16 key_len | u16 val_len | key | value
//! Internal entries: u16 key_len | u32 child_id | key
//!
//! Note: `next_leaf` is preserved in the page format for forward-compat,
//! but iteration is via tree traversal rather than the leaf chain (the
//! chain can't be maintained cheaply under CoW).

const std = @import("std");
const mem = std.mem;
const Order = std.math.Order;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const File = Io.File;

const pager_mod = @import("pager.zig");
pub const page_size = pager_mod.page_size;
pub const PageId = pager_mod.PageId;
const Pager = pager_mod.Pager;

pub const Error = error{
    KeyTooLarge,
    ValueTooLarge,
    CorruptNode,
};

const NodeType = enum(u8) { leaf = 1, internal = 2 };
const node_header_size: u16 = 16;
const slot_size: u16 = 2;

pub const max_key_size: u16 = 256;
pub const max_value_size: u16 = 1024;

const NodeHeader = struct {
    type: NodeType,
    num_keys: u16,
    entry_start: u16,
    next_leaf: PageId,
    leftmost_child: PageId,
};

fn readHeader(page: *const [page_size]u8) NodeHeader {
    return .{
        .type = @enumFromInt(page[0]),
        .num_keys = mem.readInt(u16, page[2..4], .little),
        .entry_start = mem.readInt(u16, page[4..6], .little),
        .next_leaf = mem.readInt(u32, page[8..12], .little),
        .leftmost_child = mem.readInt(u32, page[12..16], .little),
    };
}

fn writeHeader(page: *[page_size]u8, h: NodeHeader) void {
    page[0] = @intFromEnum(h.type);
    page[1] = 0;
    mem.writeInt(u16, page[2..4], h.num_keys, .little);
    mem.writeInt(u16, page[4..6], h.entry_start, .little);
    page[6] = 0;
    page[7] = 0;
    mem.writeInt(u32, page[8..12], h.next_leaf, .little);
    mem.writeInt(u32, page[12..16], h.leftmost_child, .little);
}

fn slotOffset(page: *const [page_size]u8, idx: u16) u16 {
    const off: usize = @as(usize, node_header_size) + @as(usize, idx) * slot_size;
    return mem.readInt(u16, page[off..][0..2], .little);
}

fn leafEntrySize(key_len: usize, val_len: usize) usize {
    return 4 + key_len + val_len;
}

fn internalEntrySize(key_len: usize) usize {
    return 6 + key_len;
}

pub const LeafEntry = struct { key: []const u8, value: []const u8 };

fn readLeafEntry(page: *const [page_size]u8, offset: u16) LeafEntry {
    const key_len = mem.readInt(u16, page[offset..][0..2], .little);
    const val_len = mem.readInt(u16, page[offset + 2 ..][0..2], .little);
    const k_start: usize = @as(usize, offset) + 4;
    const v_start: usize = k_start + key_len;
    return .{
        .key = page[k_start .. k_start + key_len],
        .value = page[v_start .. v_start + val_len],
    };
}

const InternalEntry = struct { key: []const u8, child: PageId };

fn readInternalEntry(page: *const [page_size]u8, offset: u16) InternalEntry {
    const key_len = mem.readInt(u16, page[offset..][0..2], .little);
    const child = mem.readInt(u32, page[offset + 2 ..][0..4], .little);
    const k_start: usize = @as(usize, offset) + 6;
    return .{
        .key = page[k_start .. k_start + key_len],
        .child = child,
    };
}

fn parseLeafEntries(allocator: Allocator, page: *const [page_size]u8) !ArrayList(LeafEntry) {
    var list: ArrayList(LeafEntry) = .empty;
    errdefer list.deinit(allocator);
    const hdr = readHeader(page);
    if (hdr.type != .leaf) return Error.CorruptNode;
    var i: u16 = 0;
    while (i < hdr.num_keys) : (i += 1) {
        try list.append(allocator, readLeafEntry(page, slotOffset(page, i)));
    }
    return list;
}

fn parseInternalEntries(allocator: Allocator, page: *const [page_size]u8) !ArrayList(InternalEntry) {
    var list: ArrayList(InternalEntry) = .empty;
    errdefer list.deinit(allocator);
    const hdr = readHeader(page);
    if (hdr.type != .internal) return Error.CorruptNode;
    var i: u16 = 0;
    while (i < hdr.num_keys) : (i += 1) {
        try list.append(allocator, readInternalEntry(page, slotOffset(page, i)));
    }
    return list;
}

fn buildLeaf(out: *[page_size]u8, entries: []const LeafEntry, next_leaf: PageId) !void {
    var data_size: usize = 0;
    for (entries) |e| data_size += leafEntrySize(e.key.len, e.value.len);
    const slots_size: usize = entries.len * slot_size;
    if (node_header_size + slots_size + data_size > page_size) return Error.ValueTooLarge;

    @memset(out, 0);
    var entry_start: usize = page_size;
    for (entries, 0..) |e, idx| {
        const sz = leafEntrySize(e.key.len, e.value.len);
        entry_start -= sz;
        const off: u16 = @intCast(entry_start);
        mem.writeInt(u16, out[off..][0..2], @intCast(e.key.len), .little);
        mem.writeInt(u16, out[off + 2 ..][0..2], @intCast(e.value.len), .little);
        @memcpy(out[off + 4 ..][0..e.key.len], e.key);
        @memcpy(out[off + 4 + e.key.len ..][0..e.value.len], e.value);
        const slot_pos: usize = @as(usize, node_header_size) + idx * slot_size;
        mem.writeInt(u16, out[slot_pos..][0..2], off, .little);
    }
    writeHeader(out, .{
        .type = .leaf,
        .num_keys = @intCast(entries.len),
        .entry_start = @intCast(entry_start),
        .next_leaf = next_leaf,
        .leftmost_child = 0,
    });
}

fn buildInternal(
    out: *[page_size]u8,
    entries: []const InternalEntry,
    leftmost_child: PageId,
) !void {
    var data_size: usize = 0;
    for (entries) |e| data_size += internalEntrySize(e.key.len);
    const slots_size: usize = entries.len * slot_size;
    if (node_header_size + slots_size + data_size > page_size) return Error.KeyTooLarge;

    @memset(out, 0);
    var entry_start: usize = page_size;
    for (entries, 0..) |e, idx| {
        const sz = internalEntrySize(e.key.len);
        entry_start -= sz;
        const off: u16 = @intCast(entry_start);
        mem.writeInt(u16, out[off..][0..2], @intCast(e.key.len), .little);
        mem.writeInt(u32, out[off + 2 ..][0..4], e.child, .little);
        @memcpy(out[off + 6 ..][0..e.key.len], e.key);
        const slot_pos: usize = @as(usize, node_header_size) + idx * slot_size;
        mem.writeInt(u16, out[slot_pos..][0..2], off, .little);
    }
    writeHeader(out, .{
        .type = .internal,
        .num_keys = @intCast(entries.len),
        .entry_start = @intCast(entry_start),
        .next_leaf = 0,
        .leftmost_child = leftmost_child,
    });
}

fn balancedLeafSplit(entries: []const LeafEntry) usize {
    var total: usize = 0;
    for (entries) |e| total += leafEntrySize(e.key.len, e.value.len);
    var running: usize = 0;
    for (entries, 0..) |e, i| {
        running += leafEntrySize(e.key.len, e.value.len);
        if (running > total / 2) return i + 1;
    }
    return entries.len;
}

fn balancedInternalSplit(entries: []const InternalEntry) usize {
    var total: usize = 0;
    for (entries) |e| total += internalEntrySize(e.key.len);
    var running: usize = 0;
    for (entries, 0..) |e, i| {
        running += internalEntrySize(e.key.len);
        if (running > total / 2) return i + 1;
    }
    return entries.len;
}

const Split = struct {
    promoted_key: []u8,
    new_right_id: PageId,
};

const CowResult = struct {
    new_id: PageId,
    split: ?Split,
};

// =========================================================================
// View — read-only access to the tree at a specific root.
// Used for snapshot reads; the BTree's read methods construct one of these
// internally pointing at the current root.
// =========================================================================

pub const View = struct {
    /// When non-null, reads go through the pager (consults dirty buffer +
    /// page cache + disk; requires the Db's mutex to be held by the caller).
    /// When null, reads go straight to disk via `file` — used by lock-free
    /// snapshot readers, which can run on any thread because POSIX `pread`
    /// is thread-safe per file descriptor.
    pager: ?*Pager,
    file: File,
    io: Io,
    root: PageId,
    /// Optional read-only mmap of the data file at snapshot creation.
    /// When set, lock-free reads `memcpy` from the mapped region and
    /// skip the `preadv` syscall entirely. mmap is inherently
    /// thread-safe (kernel manages it), so unlike a user-space cache
    /// this is safe to share across reader threads.
    mmap: ?[]const u8 = null,

    /// Returns a pointer to a 4 KB page. When the snapshot has an mmap,
    /// the pointer aliases the mapped region directly — no copy. For
    /// the writer / in-txn / pread paths, the page is read into the
    /// caller's `scratch` buffer and the returned pointer aliases that.
    fn readPage(self: View, id: PageId, scratch: *[page_size]u8) !*const [page_size]u8 {
        if (self.pager) |p| {
            try p.read(id, scratch);
            return scratch;
        }
        const off = @as(u64, id) * page_size;
        if (self.mmap) |m| {
            if (off + page_size <= m.len) {
                return m[off..][0..page_size];
            }
        }
        const n = try self.file.readPositionalAll(self.io, scratch, off);
        if (n < page_size) return Error.CorruptNode;
        return scratch;
    }

    pub fn get(self: View, allocator: Allocator, key: []const u8) !?[]u8 {
        if (self.root == 0) return null;
        var current = self.root;
        var scratch: [page_size]u8 = undefined;
        while (true) {
            const page = try self.readPage(current, &scratch);
            const hdr = readHeader(page);
            if (hdr.type == .leaf) {
                var i: u16 = 0;
                while (i < hdr.num_keys) : (i += 1) {
                    const e = readLeafEntry(page, slotOffset(page, i));
                    switch (mem.order(u8, key, e.key)) {
                        .lt => return null,
                        .eq => return try allocator.dupe(u8, e.value),
                        .gt => {},
                    }
                }
                return null;
            }
            if (hdr.type != .internal) return Error.CorruptNode;
            var child: PageId = hdr.leftmost_child;
            var i: u16 = 0;
            while (i < hdr.num_keys) : (i += 1) {
                const e = readInternalEntry(page, slotOffset(page, i));
                if (mem.order(u8, key, e.key) == .lt) break;
                child = e.child;
            }
            current = child;
        }
    }

    pub fn iterator(self: View, allocator: Allocator) !Iterator {
        return self.iteratorFromOpt(allocator, null);
    }

    pub fn iteratorFrom(self: View, allocator: Allocator, seek_key: []const u8) !Iterator {
        return self.iteratorFromOpt(allocator, seek_key);
    }

    /// Find the first entry whose key starts with `prefix`. Copies that
    /// key into `key_buf` and returns its length; returns `null` if no
    /// such entry exists. Pure stack-based traversal — no heap allocs —
    /// so it's the fast path for index point lookups (`findOneInView`).
    /// Walks the parent chain to follow into the next leaf when the
    /// prefix-range straddles a leaf boundary.
    pub fn findFirstByPrefix(self: View, prefix: []const u8, key_buf: []u8) !?usize {
        if (self.root == 0) return null;

        const StackFrame = struct { node_id: PageId, child_idx: u16 };
        var stack: [16]StackFrame = undefined;
        var depth: usize = 0;

        var scratch: [page_size]u8 = undefined;
        var current = self.root;
        var page: *const [page_size]u8 = undefined;

        while (true) {
            page = try self.readPage(current, &scratch);
            const hdr = readHeader(page);
            if (hdr.type == .leaf) break;
            if (hdr.type != .internal) return Error.CorruptNode;

            var child: PageId = hdr.leftmost_child;
            var taken_idx: u16 = 0;
            var i: u16 = 0;
            while (i < hdr.num_keys) : (i += 1) {
                const e = readInternalEntry(page, slotOffset(page, i));
                if (mem.order(u8, prefix, e.key) == .lt) break;
                child = e.child;
                taken_idx = i + 1;
            }
            if (depth >= stack.len) return Error.CorruptNode;
            stack[depth] = .{ .node_id = current, .child_idx = taken_idx };
            depth += 1;
            current = child;
        }

        var leaves_visited: u32 = 0;
        while (true) {
            leaves_visited += 1;
            const hdr = readHeader(page);
            var i: u16 = 0;
            while (i < hdr.num_keys) : (i += 1) {
                const e = readLeafEntry(page, slotOffset(page, i));
                if (mem.order(u8, e.key, prefix) == .lt) continue;
                if (e.key.len < prefix.len or !mem.eql(u8, e.key[0..prefix.len], prefix)) {
                    return null;
                }
                if (e.key.len > key_buf.len) return Error.CorruptNode;
                @memcpy(key_buf[0..e.key.len], e.key);
                return e.key.len;
            }
            var advanced = false;
            while (depth > 0) {
                depth -= 1;
                const frame = stack[depth];
                page = try self.readPage(frame.node_id, &scratch);
                const phdr = readHeader(page);
                if (frame.child_idx < phdr.num_keys) {
                    const next_child = readInternalEntry(page, slotOffset(page, frame.child_idx)).child;
                    stack[depth] = .{ .node_id = frame.node_id, .child_idx = frame.child_idx + 1 };
                    depth += 1;
                    var c2 = next_child;
                    while (true) {
                        page = try self.readPage(c2, &scratch);
                        const hdr2 = readHeader(page);
                        if (hdr2.type == .leaf) break;
                        if (hdr2.type != .internal) return Error.CorruptNode;
                        if (depth >= stack.len) return Error.CorruptNode;
                        stack[depth] = .{ .node_id = c2, .child_idx = 0 };
                        depth += 1;
                        c2 = hdr2.leftmost_child;
                    }
                    advanced = true;
                    break;
                }
            }
            if (!advanced) return null;
            if (leaves_visited > 64) return null;
        }
    }

    fn iteratorFromOpt(self: View, allocator: Allocator, seek_key: ?[]const u8) !Iterator {
        var it = Iterator{
            .pager = self.pager,
            .file = self.file,
            .io = self.io,
            .allocator = allocator,
            .stack = .empty,
        };
        errdefer it.deinit();
        if (self.root == 0) return it;
        try it.descendTo(self.root, seek_key);
        return it;
    }
};

// =========================================================================
// Iterator — tree-traversal (stack-based), works over any root.
// Mirrors `View`'s pager-or-file dispatch so snapshot iterators don't
// touch any shared mutable state during walks.
// =========================================================================

pub const Iterator = struct {
    pager: ?*Pager,
    file: File,
    io: Io,
    allocator: Allocator,
    stack: ArrayList(Frame),

    const Frame = struct {
        page: [page_size]u8,
        node_id: PageId,
        is_leaf: bool,
        slot_idx: u16,
    };

    pub fn deinit(self: *Iterator) void {
        self.stack.deinit(self.allocator);
        self.* = undefined;
    }

    fn readPage(self: *const Iterator, id: PageId, buf: *[page_size]u8) !void {
        if (self.pager) |p| {
            try p.read(id, buf);
        } else {
            const n = try self.file.readPositionalAll(self.io, buf, @as(u64, id) * page_size);
            if (n < page_size) return Error.CorruptNode;
        }
    }

    fn descendTo(self: *Iterator, start_node: PageId, seek_key: ?[]const u8) !void {
        var current = start_node;
        while (true) {
            const frame = try self.stack.addOne(self.allocator);
            frame.node_id = current;
            frame.slot_idx = 0;
            try self.readPage(current, &frame.page);
            const hdr = readHeader(&frame.page);
            frame.is_leaf = (hdr.type == .leaf);
            if (hdr.type == .leaf) {
                if (seek_key) |k| {
                    var i: u16 = 0;
                    while (i < hdr.num_keys) : (i += 1) {
                        const e = readLeafEntry(&frame.page, slotOffset(&frame.page, i));
                        if (mem.order(u8, e.key, k) != .lt) break;
                    }
                    frame.slot_idx = i;
                }
                return;
            }
            // Internal: descend to appropriate child.
            var child: PageId = hdr.leftmost_child;
            var visited_child_idx: u16 = 0; // 0 = leftmost, otherwise entry[idx-1].child
            if (seek_key) |k| {
                var i: u16 = 0;
                while (i < hdr.num_keys) : (i += 1) {
                    const e = readInternalEntry(&frame.page, slotOffset(&frame.page, i));
                    if (mem.order(u8, k, e.key) == .lt) break;
                    child = e.child;
                    visited_child_idx = i + 1;
                }
            }
            // Mark the parent as having "consumed" up to and including this child;
            // when we pop back up, we'll resume from visited_child_idx + 1.
            frame.slot_idx = visited_child_idx + 1;
            current = child;
        }
    }

    pub fn next(self: *Iterator) !?LeafEntry {
        while (self.stack.items.len > 0) {
            var top = &self.stack.items[self.stack.items.len - 1];
            if (top.is_leaf) {
                const hdr = readHeader(&top.page);
                if (top.slot_idx < hdr.num_keys) {
                    const e = readLeafEntry(&top.page, slotOffset(&top.page, top.slot_idx));
                    top.slot_idx += 1;
                    return e;
                }
                _ = self.stack.pop();
                continue;
            }
            // Internal: descend into the next unvisited child, if any.
            const hdr = readHeader(&top.page);
            const num_children: u16 = hdr.num_keys + 1;
            if (top.slot_idx >= num_children) {
                _ = self.stack.pop();
                continue;
            }
            const child_id: PageId = if (top.slot_idx == 0)
                hdr.leftmost_child
            else
                readInternalEntry(&top.page, slotOffset(&top.page, top.slot_idx - 1)).child;
            top.slot_idx += 1;
            try self.descendToLeftmost(child_id);
        }
        return null;
    }

    fn descendToLeftmost(self: *Iterator, start_node: PageId) !void {
        var current = start_node;
        while (true) {
            const frame = try self.stack.addOne(self.allocator);
            frame.node_id = current;
            frame.slot_idx = 0;
            try self.readPage(current, &frame.page);
            const hdr = readHeader(&frame.page);
            frame.is_leaf = (hdr.type == .leaf);
            if (hdr.type == .leaf) return;
            frame.slot_idx = 1; // we're descending into leftmost_child; next time, visit entry[0].child
            current = hdr.leftmost_child;
        }
    }
};

// =========================================================================
// BTree — read+write handle. CoW for mutations, View for reads.
// =========================================================================

pub const BTree = struct {
    allocator: Allocator,
    pager: *Pager,
    /// Identifies which tree-root in the pager this handle reads/writes
    /// through. Phase 1 of keyspace sharding: only `default_collection_id`
    /// is supported, but the field is plumbed everywhere so phase 2 can
    /// flip on N independent roots without touching call sites.
    collection_id: pager_mod.CollectionId,

    pub fn init(allocator: Allocator, pager: *Pager, collection_id: pager_mod.CollectionId) BTree {
        return .{
            .allocator = allocator,
            .pager = pager,
            .collection_id = collection_id,
        };
    }

    pub fn view(self: BTree) View {
        return .{
            .pager = self.pager,
            .file = self.pager.file,
            .io = self.pager.io,
            .root = self.pager.bTreeRoot(self.collection_id),
        };
    }

    // ---- read shortcuts (delegate to View at current root) ----

    pub fn get(self: BTree, allocator: Allocator, key: []const u8) !?[]u8 {
        return self.view().get(allocator, key);
    }

    pub fn iterator(self: BTree, allocator: Allocator) !Iterator {
        return self.view().iterator(allocator);
    }

    pub fn iteratorFrom(self: BTree, allocator: Allocator, seek_key: []const u8) !Iterator {
        return self.view().iteratorFrom(allocator, seek_key);
    }

    // ---- mutating (CoW) ----

    pub fn put(self: BTree, key: []const u8, value: []const u8) !void {
        if (key.len == 0 or key.len > max_key_size) return Error.KeyTooLarge;
        if (value.len > max_value_size) return Error.ValueTooLarge;
        if (self.pager.in_txn) {
            try self.pager.recordPut(self.collection_id, key, value);
            return self.putTxn(key, value);
        }
        try self.pager.begin(self.collection_id);
        errdefer self.pager.abort();
        try self.pager.recordPut(self.collection_id, key, value);
        try self.putTxn(key, value);
        try self.pager.commit();
    }

    fn putTxn(self: BTree, key: []const u8, value: []const u8) !void {
        const old_root = self.pager.bTreeRoot(self.collection_id);
        if (old_root == 0) {
            const new_root = try self.pager.allocPage();
            var page: [page_size]u8 = undefined;
            try buildLeaf(&page, &.{.{ .key = key, .value = value }}, 0);
            try self.pager.write(new_root, &page);
            try self.pager.setBTreeRoot(self.collection_id, new_root);
            self.pager.txn_append_hint = new_root;
            return;
        }

        // Append-cursor fast path: if the prior insert in this txn landed
        // on a leaf and the new key is strictly greater than that leaf's
        // last key, we can write directly into that leaf without
        // re-descending the tree. Cuts ~1.5 µs of tree-walk overhead per
        // append-style insert; this is what closes the gap to SQLite's
        // batched-insert path.
        if (self.pager.txn_append_hint) |hint_leaf| {
            if (self.pager.dirtyPtr(hint_leaf)) |leaf_page| {
                const leaf_type: u8 = leaf_page[0];
                const num_keys = mem.readInt(u16, leaf_page[2..4], .little);
                if (leaf_type == @intFromEnum(NodeType.leaf) and num_keys > 0) {
                    const last_off = slotOffset(leaf_page, num_keys - 1);
                    const last_key_len = mem.readInt(u16, leaf_page[last_off..][0..2], .little);
                    const last_key_start: usize = @as(usize, last_off) + 4;
                    const last_key = leaf_page[last_key_start .. last_key_start + last_key_len];
                    if (mem.order(u8, key, last_key) == .gt) {
                        if (try self.tryInsertLeafInPlace(leaf_page, key, value)) {
                            return; // ✨ no descent at all
                        }
                        // Doesn't fit (leaf full): clear hint, fall through.
                        self.pager.txn_append_hint = null;
                    }
                }
            } else {
                self.pager.txn_append_hint = null; // hint stale (page no longer dirty)
            }
        }

        const result = try self.insertRec(old_root, key, value);
        if (result.split) |sp| {
            const new_root = try self.pager.allocPage();
            var page: [page_size]u8 = undefined;
            try buildInternal(
                &page,
                &.{.{ .key = sp.promoted_key, .child = sp.new_right_id }},
                result.new_id,
            );
            try self.pager.write(new_root, &page);
            self.allocator.free(sp.promoted_key);
            try self.pager.setBTreeRoot(self.collection_id, new_root);
            // Hint invalidated by split. Next insert will re-descend and
            // set a fresh hint when it reaches a leaf.
            self.pager.txn_append_hint = null;
        } else if (result.new_id != old_root) {
            try self.pager.setBTreeRoot(self.collection_id, result.new_id);
        }
    }

    fn insertRec(self: BTree, node_id: PageId, key: []const u8, value: []const u8) !CowResult {
        // FAST PATH: page is already in this txn's dirty buffer, so we can
        // navigate / mutate it directly without copying it onto the stack
        // or rebuilding it from a parsed entry list.
        if (self.pager.dirtyPtr(node_id)) |p| {
            const hdr = readHeader(p);
            if (hdr.type == .leaf) {
                if (try self.tryInsertLeafInPlace(p, key, value)) {
                    self.pager.txn_append_hint = node_id;
                    return .{ .new_id = node_id, .split = null };
                }
                // Replace or doesn't-fit: fall through to slow path.
                return self.insertIntoLeafCow(p, hdr, node_id, key, value);
            }
            // Internal: descend through the dirty page directly.
            var child: PageId = hdr.leftmost_child;
            var follow_idx: u16 = 0;
            var i: u16 = 0;
            while (i < hdr.num_keys) : (i += 1) {
                const e = readInternalEntry(p, slotOffset(p, i));
                if (mem.order(u8, key, e.key) == .lt) break;
                child = e.child;
                follow_idx = i + 1;
            }
            const old_child = child;
            const child_result = try self.insertRec(child, key, value);
            if (child_result.new_id == old_child and child_result.split == null) {
                return .{ .new_id = node_id, .split = null };
            }
            // No split, just a child-pointer update — patch in place.
            if (child_result.split == null) {
                if (follow_idx == 0) {
                    mem.writeInt(u32, p[12..16], child_result.new_id, .little);
                } else {
                    const off = slotOffset(p, follow_idx - 1);
                    mem.writeInt(u32, p[off + 2 ..][0..4], child_result.new_id, .little);
                }
                return .{ .new_id = node_id, .split = null };
            }
            return self.insertIntoInternalCow(p, hdr, node_id, follow_idx, child_result);
        }

        // SLOW PATH: page on disk, full CoW.
        var page: [page_size]u8 = undefined;
        try self.pager.read(node_id, &page);
        const hdr = readHeader(&page);
        if (hdr.type == .leaf) {
            return self.insertIntoLeafCow(&page, hdr, node_id, key, value);
        }
        var child: PageId = hdr.leftmost_child;
        var follow_idx: u16 = 0;
        var i: u16 = 0;
        while (i < hdr.num_keys) : (i += 1) {
            const e = readInternalEntry(&page, slotOffset(&page, i));
            if (mem.order(u8, key, e.key) == .lt) break;
            child = e.child;
            follow_idx = i + 1;
        }
        const old_child = child;
        const child_result = try self.insertRec(child, key, value);
        if (child_result.new_id == old_child and child_result.split == null) {
            return .{ .new_id = node_id, .split = null };
        }
        return self.insertIntoInternalCow(&page, hdr, node_id, follow_idx, child_result);
    }

    /// Direct mutation of a leaf page already present in the dirty buffer.
    /// Returns true on success; false if the key already exists (replace
    /// path is more complex — caller falls back to the slow path) or if
    /// the page is full (caller falls back to split via the slow path).
    fn tryInsertLeafInPlace(
        self: BTree,
        page: *[page_size]u8,
        key: []const u8,
        value: []const u8,
    ) !bool {
        _ = self;
        const num_keys = mem.readInt(u16, page[2..4], .little);
        const entry_start = mem.readInt(u16, page[4..6], .little);

        // Append fast path: when the new key is greater than the leaf's
        // last key, slot = num_keys with no shift needed. This is the hot
        // case for sequential-id inserts (the bench, plus most insert
        // workloads with monotonic doc ids).
        var slot: u16 = num_keys;
        if (num_keys > 0) {
            const last_off = slotOffset(page, num_keys - 1);
            const last_key_len = mem.readInt(u16, page[last_off..][0..2], .little);
            const last_key_start: usize = @as(usize, last_off) + 4;
            const last_key = page[last_key_start .. last_key_start + last_key_len];
            if (mem.order(u8, key, last_key) != .gt) {
                // Need a real scan — linear search for insertion point.
                slot = 0;
                while (slot < num_keys) : (slot += 1) {
                    const off = slotOffset(page, slot);
                    const ek_len = mem.readInt(u16, page[off..][0..2], .little);
                    const ek_start: usize = @as(usize, off) + 4;
                    const ek = page[ek_start .. ek_start + ek_len];
                    switch (mem.order(u8, key, ek)) {
                        .lt => break,
                        .eq => return false, // replace path — slow path handles it
                        .gt => {},
                    }
                }
            }
        }

        const entry_size: usize = 4 + key.len + value.len;
        const new_slot_dir_end: usize = @as(usize, node_header_size) + (@as(usize, num_keys) + 1) * slot_size;
        if (new_slot_dir_end + entry_size > entry_start) return false; // doesn't fit

        const new_offset: u16 = @intCast(@as(usize, entry_start) - entry_size);

        // Write the entry payload.
        mem.writeInt(u16, page[new_offset..][0..2], @intCast(key.len), .little);
        mem.writeInt(u16, page[new_offset + 2 ..][0..2], @intCast(value.len), .little);
        @memcpy(page[new_offset + 4 ..][0..key.len], key);
        @memcpy(page[new_offset + 4 + key.len ..][0..value.len], value);

        // Shift slot dir entries [slot..num_keys] right by one slot_size.
        if (slot < num_keys) {
            const src_start: usize = @as(usize, node_header_size) + @as(usize, slot) * slot_size;
            const len: usize = (@as(usize, num_keys) - slot) * slot_size;
            std.mem.copyBackwards(
                u8,
                page[src_start + slot_size .. src_start + slot_size + len],
                page[src_start .. src_start + len],
            );
        }

        // Write the new slot offset.
        const new_slot_pos: usize = @as(usize, node_header_size) + @as(usize, slot) * slot_size;
        mem.writeInt(u16, page[new_slot_pos..][0..2], new_offset, .little);

        // Patch header in place.
        mem.writeInt(u16, page[2..4], num_keys + 1, .little);
        mem.writeInt(u16, page[4..6], new_offset, .little);

        return true;
    }

    fn insertIntoLeafCow(
        self: BTree,
        src: *const [page_size]u8,
        hdr: NodeHeader,
        current_id: PageId,
        key: []const u8,
        value: []const u8,
    ) !CowResult {
        var entries = try parseLeafEntries(self.allocator, src);
        defer entries.deinit(self.allocator);

        const old_len = entries.items.len;
        var slot: usize = old_len;
        var found = false;
        for (entries.items, 0..) |e, idx| {
            switch (mem.order(u8, key, e.key)) {
                .lt => {
                    slot = idx;
                    break;
                },
                .eq => {
                    slot = idx;
                    found = true;
                    break;
                },
                .gt => {},
            }
        }
        if (found) {
            entries.items[slot] = .{ .key = key, .value = value };
        } else {
            try entries.insert(self.allocator, slot, .{ .key = key, .value = value });
        }
        // Append-style split heuristic: when the new entry landed at the
        // end of the leaf, splitting balanced just moves half the existing
        // entries to a fresh page for nothing — sequential-id inserts
        // immediately fill the right page anyway. Splitting all-old-left,
        // single-new-right halves the per-split memcpy and lets the next
        // insert flow through the in-place fast path on the new leaf.
        const append_style: bool = !found and slot == old_len;

        var data_size: usize = 0;
        for (entries.items) |e| data_size += leafEntrySize(e.key.len, e.value.len);
        const slots_size: usize = entries.items.len * slot_size;

        if (node_header_size + slots_size + data_size <= page_size) {
            // Reuse the existing dirty buffer if this leaf was already
            // CoW'd in this txn — saves a fresh allocPage and a 4 KB
            // disk write at commit time.
            const new_id: PageId = if (self.pager.isDirty(current_id))
                current_id
            else
                try self.pager.allocPage();
            var out: [page_size]u8 = undefined;
            try buildLeaf(&out, entries.items, hdr.next_leaf);
            try self.pager.write(new_id, &out);
            // Wherever the descent landed, that's the next-likely-target
            // leaf for an append-style insert.
            self.pager.txn_append_hint = new_id;
            return .{ .new_id = new_id, .split = null };
        }

        const split_at: usize = if (append_style) old_len else balancedLeafSplit(entries.items);
        const left = entries.items[0..split_at];
        const right = entries.items[split_at..];
        const left_id: PageId = if (self.pager.isDirty(current_id))
            current_id
        else
            try self.pager.allocPage();
        const right_id = try self.pager.allocPage();
        // Dupe the promoted key BEFORE the writes — when `src` is a dirty
        // pointer and `left_id == current_id`, `pager.write(left_id, ...)`
        // overwrites the bytes that `right[0].key` slices into.
        const promoted = try self.allocator.dupe(u8, right[0].key);
        errdefer self.allocator.free(promoted);
        var left_page: [page_size]u8 = undefined;
        var right_page: [page_size]u8 = undefined;
        try buildLeaf(&left_page, left, right_id);
        try buildLeaf(&right_page, right, hdr.next_leaf);
        try self.pager.write(left_id, &left_page);
        try self.pager.write(right_id, &right_page);

        // Invalidate the append cursor: after this split the rightmost leaf
        // is `right_id`, but our caller may still hold an older hint
        // pointing at `left_id` (= current_id for dedup splits). Letting
        // the next put re-descend ensures we land on the actual rightmost.
        self.pager.txn_append_hint = null;

        return .{
            .new_id = left_id,
            .split = .{
                .promoted_key = promoted,
                .new_right_id = right_id,
            },
        };
    }

    fn insertIntoInternalCow(
        self: BTree,
        src: *const [page_size]u8,
        hdr: NodeHeader,
        current_id: PageId,
        follow_idx: u16,
        child_result: CowResult,
    ) !CowResult {
        var entries = try parseInternalEntries(self.allocator, src);
        defer entries.deinit(self.allocator);

        var promoted_key_owned: ?[]u8 = null;
        defer if (promoted_key_owned) |k| self.allocator.free(k);

        var new_leftmost = hdr.leftmost_child;
        if (follow_idx == 0) {
            new_leftmost = child_result.new_id;
        } else {
            entries.items[follow_idx - 1].child = child_result.new_id;
        }

        var promoted_inserted_at_end: bool = false;
        if (child_result.split) |sp| {
            promoted_key_owned = sp.promoted_key;
            const before_len = entries.items.len;
            var slot: usize = before_len;
            for (entries.items, 0..) |e, idx| {
                if (mem.order(u8, sp.promoted_key, e.key) == .lt) {
                    slot = idx;
                    break;
                }
            }
            try entries.insert(self.allocator, slot, .{ .key = sp.promoted_key, .child = sp.new_right_id });
            promoted_inserted_at_end = (slot == before_len);
        }

        var data_size: usize = 0;
        for (entries.items) |e| data_size += internalEntrySize(e.key.len);
        const slots_size: usize = entries.items.len * slot_size;

        if (node_header_size + slots_size + data_size <= page_size) {
            const new_id: PageId = if (self.pager.isDirty(current_id))
                current_id
            else
                try self.pager.allocPage();
            var out: [page_size]u8 = undefined;
            try buildInternal(&out, entries.items, new_leftmost);
            try self.pager.write(new_id, &out);
            return .{ .new_id = new_id, .split = null };
        }

        // Append-style split for monotonic workloads: the entry just
        // promoted from the child split landed at the end → all old
        // entries stay on left, the new entry becomes the promoted middle,
        // and right has zero entries (just leftmost_child). Halves the
        // per-split memcpy on the sequential-id path.
        var promote_idx: usize = if (promoted_inserted_at_end)
            entries.items.len - 1
        else
            balancedInternalSplit(entries.items);
        if (promote_idx == 0) promote_idx = 1;
        if (promote_idx >= entries.items.len) promote_idx = entries.items.len - 1;
        const middle = entries.items[promote_idx];
        const left = entries.items[0..promote_idx];
        const right = entries.items[promote_idx + 1 ..];

        const left_id: PageId = if (self.pager.isDirty(current_id))
            current_id
        else
            try self.pager.allocPage();
        const right_id = try self.pager.allocPage();
        // See note in insertIntoLeafCow's split path — dupe before writes.
        const promoted = try self.allocator.dupe(u8, middle.key);
        errdefer self.allocator.free(promoted);
        var left_page: [page_size]u8 = undefined;
        var right_page: [page_size]u8 = undefined;
        try buildInternal(&left_page, left, new_leftmost);
        try buildInternal(&right_page, right, middle.child);
        try self.pager.write(left_id, &left_page);
        try self.pager.write(right_id, &right_page);

        return .{
            .new_id = left_id,
            .split = .{
                .promoted_key = promoted,
                .new_right_id = right_id,
            },
        };
    }

    pub fn delete(self: BTree, key: []const u8) !bool {
        if (self.pager.in_txn) {
            try self.pager.recordDelete(self.collection_id, key);
            return self.deleteTxn(key);
        }
        try self.pager.begin(self.collection_id);
        errdefer self.pager.abort();
        try self.pager.recordDelete(self.collection_id, key);
        const found = try self.deleteTxn(key);
        try self.pager.commit();
        return found;
    }

    fn deleteTxn(self: BTree, key: []const u8) !bool {
        const old_root = self.pager.bTreeRoot(self.collection_id);
        if (old_root == 0) return false;
        const result = try self.deleteRec(old_root, key) orelse return false;
        if (result.new_id != old_root) {
            try self.pager.setBTreeRoot(self.collection_id, result.new_id);
        }
        // Conservative: any delete invalidates the append hint. The cached
        // last-key may have been the deleted entry; rather than verify,
        // just force the next put to re-descend.
        self.pager.txn_append_hint = null;
        return true;
    }

    /// Returns null if `key` was not found in the subtree (parent shouldn't
    /// CoW). Otherwise returns the new replacement node id (CoW).
    /// `new_id == 0` signals that the subtree became empty.
    fn deleteRec(self: BTree, node_id: PageId, key: []const u8) !?struct { new_id: PageId } {
        var page: [page_size]u8 = undefined;
        try self.pager.read(node_id, &page);
        const hdr = readHeader(&page);

        if (hdr.type == .leaf) {
            var entries = try parseLeafEntries(self.allocator, &page);
            defer entries.deinit(self.allocator);

            var found_idx: ?usize = null;
            for (entries.items, 0..) |e, idx| {
                switch (mem.order(u8, key, e.key)) {
                    .lt => break,
                    .eq => {
                        found_idx = idx;
                        break;
                    },
                    .gt => {},
                }
            }
            if (found_idx == null) return null;
            _ = entries.orderedRemove(found_idx.?);

            if (entries.items.len == 0) {
                return .{ .new_id = 0 };
            }
            const new_id: PageId = if (self.pager.isDirty(node_id))
                node_id
            else
                try self.pager.allocPage();
            var out: [page_size]u8 = undefined;
            try buildLeaf(&out, entries.items, hdr.next_leaf);
            try self.pager.write(new_id, &out);
            return .{ .new_id = new_id };
        }

        // Internal: descend to appropriate child.
        var child: PageId = hdr.leftmost_child;
        var follow_idx: u16 = 0;
        var i: u16 = 0;
        while (i < hdr.num_keys) : (i += 1) {
            const e = readInternalEntry(&page, slotOffset(&page, i));
            if (mem.order(u8, key, e.key) == .lt) break;
            child = e.child;
            follow_idx = i + 1;
        }
        const old_child = child;
        const child_result = (try self.deleteRec(child, key)) orelse return null;

        // Short-circuit: child unchanged → this internal is unchanged too.
        if (child_result.new_id == old_child) {
            return .{ .new_id = node_id };
        }

        var entries = try parseInternalEntries(self.allocator, &page);
        defer entries.deinit(self.allocator);

        // If a child became empty, drop the corresponding child pointer.
        if (child_result.new_id == 0) {
            if (follow_idx == 0) {
                if (entries.items.len == 0) {
                    return .{ .new_id = 0 };
                }
                const new_leftmost = entries.items[0].child;
                _ = entries.orderedRemove(0);
                if (entries.items.len == 0) {
                    return .{ .new_id = new_leftmost };
                }
                const new_id: PageId = if (self.pager.isDirty(node_id))
                    node_id
                else
                    try self.pager.allocPage();
                var out: [page_size]u8 = undefined;
                try buildInternal(&out, entries.items, new_leftmost);
                try self.pager.write(new_id, &out);
                return .{ .new_id = new_id };
            } else {
                _ = entries.orderedRemove(follow_idx - 1);
                if (entries.items.len == 0) {
                    return .{ .new_id = hdr.leftmost_child };
                }
                const new_id: PageId = if (self.pager.isDirty(node_id))
                    node_id
                else
                    try self.pager.allocPage();
                var out: [page_size]u8 = undefined;
                try buildInternal(&out, entries.items, hdr.leftmost_child);
                try self.pager.write(new_id, &out);
                return .{ .new_id = new_id };
            }
        }

        // Child changed but didn't empty — repoint and CoW this internal.
        var new_leftmost = hdr.leftmost_child;
        if (follow_idx == 0) {
            new_leftmost = child_result.new_id;
        } else {
            entries.items[follow_idx - 1].child = child_result.new_id;
        }

        const new_id: PageId = if (self.pager.isDirty(node_id))
            node_id
        else
            try self.pager.allocPage();
        var out: [page_size]u8 = undefined;
        try buildInternal(&out, entries.items, new_leftmost);
        try self.pager.write(new_id, &out);
        return .{ .new_id = new_id };
    }
};

const testing = std.testing;

fn openTestPager(tmp: anytype) !Pager {
    return Pager.open(testing.allocator, testing.io, tmp.dir, "btree.db");
}

test "empty tree: get returns null" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var p = try openTestPager(&tmp);
    defer p.close();
    const bt = BTree.init(testing.allocator, &p, pager_mod.default_collection_id);
    const got = try bt.get(testing.allocator, "anything");
    try testing.expect(got == null);
}

test "single put/get roundtrip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var p = try openTestPager(&tmp);
    defer p.close();
    const bt = BTree.init(testing.allocator, &p, pager_mod.default_collection_id);

    try bt.put("hello", "world");
    const got = (try bt.get(testing.allocator, "hello")).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("world", got);

    const miss = try bt.get(testing.allocator, "nope");
    try testing.expect(miss == null);
}

test "many puts trigger splits and remain ordered" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var p = try openTestPager(&tmp);
    defer p.close();
    const bt = BTree.init(testing.allocator, &p, pager_mod.default_collection_id);

    var key_buf: [16]u8 = undefined;
    var val_buf: [200]u8 = undefined;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const key = try std.fmt.bufPrint(&key_buf, "k{d:0>6}", .{i});
        @memset(&val_buf, @intCast(i & 0xff));
        try bt.put(key, &val_buf);
    }

    i = 0;
    while (i < 200) : (i += 1) {
        const key = try std.fmt.bufPrint(&key_buf, "k{d:0>6}", .{i});
        const got = (try bt.get(testing.allocator, key)).?;
        defer testing.allocator.free(got);
        try testing.expect(got.len == val_buf.len);
        try testing.expect(mem.allEqual(u8, got, @intCast(i & 0xff)));
    }

    var root_page: [page_size]u8 = undefined;
    try p.read(p.bTreeRoot(pager_mod.default_collection_id), &root_page);
    try testing.expectEqual(NodeType.internal, readHeader(&root_page).type);
}

test "insertion in random order, iterator yields ascending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var p = try openTestPager(&tmp);
    defer p.close();
    const bt = BTree.init(testing.allocator, &p, pager_mod.default_collection_id);

    var prng = std.Random.DefaultPrng.init(0x1234);
    const r = prng.random();
    var inserted: [300]u32 = undefined;
    for (&inserted, 0..) |*slot, idx| slot.* = @intCast(idx);
    r.shuffle(u32, &inserted);

    var key_buf: [16]u8 = undefined;
    for (inserted) |n| {
        const key = try std.fmt.bufPrint(&key_buf, "k{d:0>6}", .{n});
        try bt.put(key, "v");
    }

    var it = try bt.iterator(testing.allocator);
    defer it.deinit();
    var last: ?u32 = null;
    var seen: u32 = 0;
    while (try it.next()) |e| {
        const n = try std.fmt.parseInt(u32, e.key[1..], 10);
        if (last) |l| try testing.expect(n > l);
        last = n;
        seen += 1;
    }
    try testing.expectEqual(@as(u32, inserted.len), seen);
}

test "update replaces value in place" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var p = try openTestPager(&tmp);
    defer p.close();
    const bt = BTree.init(testing.allocator, &p, pager_mod.default_collection_id);

    try bt.put("k", "v1");
    try bt.put("k", "v2-longer");
    const got = (try bt.get(testing.allocator, "k")).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("v2-longer", got);
}

test "delete: removes key, others remain" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var p = try openTestPager(&tmp);
    defer p.close();
    const bt = BTree.init(testing.allocator, &p, pager_mod.default_collection_id);

    try bt.put("a", "1");
    try bt.put("b", "2");
    try bt.put("c", "3");

    try testing.expect(try bt.delete("b"));
    try testing.expect(!try bt.delete("b"));

    try testing.expect(try bt.get(testing.allocator, "b") == null);
    const a = (try bt.get(testing.allocator, "a")).?;
    defer testing.allocator.free(a);
    const c = (try bt.get(testing.allocator, "c")).?;
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("1", a);
    try testing.expectEqualStrings("3", c);
}

test "delete last entry of root leaf empties the tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var p = try openTestPager(&tmp);
    defer p.close();
    const bt = BTree.init(testing.allocator, &p, pager_mod.default_collection_id);

    try bt.put("x", "1");
    try testing.expect(try bt.delete("x"));
    try testing.expectEqual(@as(PageId, 0), p.bTreeRoot(pager_mod.default_collection_id));
    try testing.expect(try bt.get(testing.allocator, "x") == null);
}

test "data survives close + reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ally = testing.allocator;
    const io = testing.io;

    {
        var p = try Pager.open(ally, io, tmp.dir, "persist.db");
        defer p.close();
        const bt = BTree.init(ally, &p, pager_mod.default_collection_id);
        try bt.put("alpha", "A");
        try bt.put("bravo", "B");
        try bt.put("charlie", "C");
    }
    {
        var p = try Pager.open(ally, io, tmp.dir, "persist.db");
        defer p.close();
        const bt = BTree.init(ally, &p, pager_mod.default_collection_id);
        const a = (try bt.get(ally, "alpha")).?;
        defer ally.free(a);
        const b = (try bt.get(ally, "bravo")).?;
        defer ally.free(b);
        const c = (try bt.get(ally, "charlie")).?;
        defer ally.free(c);
        try testing.expectEqualStrings("A", a);
        try testing.expectEqualStrings("B", b);
        try testing.expectEqualStrings("C", c);
    }
}

test "rejects oversized key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var p = try openTestPager(&tmp);
    defer p.close();
    const bt = BTree.init(testing.allocator, &p, pager_mod.default_collection_id);

    var big_key: [max_key_size + 1]u8 = @splat('k');
    try testing.expectError(Error.KeyTooLarge, bt.put(&big_key, "v"));
}

test "stress: mixed-size values, random keys, all readable after" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var p = try openTestPager(&tmp);
    defer p.close();
    const bt = BTree.init(testing.allocator, &p, pager_mod.default_collection_id);

    var prng = std.Random.DefaultPrng.init(0xfeedface);
    const r = prng.random();

    const n = 400;
    var keys: [n]u32 = undefined;
    for (&keys, 0..) |*k, i| k.* = @intCast(i);
    r.shuffle(u32, &keys);

    const big_buf = try testing.allocator.alloc(u8, max_value_size);
    defer testing.allocator.free(big_buf);

    var key_buf: [16]u8 = undefined;
    for (keys) |k| {
        const key = try std.fmt.bufPrint(&key_buf, "k{d:0>6}", .{k});
        const len: usize = switch (k % 4) {
            0 => 8,
            1 => 64,
            2 => 512,
            else => max_value_size,
        };
        for (big_buf[0..len], 0..) |*b, i| b.* = @intCast((k +% i) & 0xff);
        try bt.put(key, big_buf[0..len]);
    }

    for (0..n) |k| {
        const key = try std.fmt.bufPrint(&key_buf, "k{d:0>6}", .{k});
        const got = (try bt.get(testing.allocator, key)) orelse return error.KeyMissing;
        defer testing.allocator.free(got);
        const expected_len: usize = switch (k % 4) {
            0 => 8,
            1 => 64,
            2 => 512,
            else => max_value_size,
        };
        try testing.expectEqual(expected_len, got.len);
        for (got, 0..) |b, i| {
            try testing.expectEqual(@as(u8, @intCast((k +% i) & 0xff)), b);
        }
    }
}

test "snapshot: view at captured root keeps seeing old data after writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var p = try openTestPager(&tmp);
    defer p.close();
    const bt = BTree.init(testing.allocator, &p, pager_mod.default_collection_id);

    try bt.put("a", "v1");
    try bt.put("b", "v1");

    // Capture snapshot.
    const snap = bt.view();

    // Mutate after snapshot.
    try bt.put("a", "v2");
    try bt.put("c", "v1");
    _ = try bt.delete("b");

    // Snapshot still sees pre-mutation state.
    const sa = (try snap.get(testing.allocator, "a")).?;
    defer testing.allocator.free(sa);
    const sb = (try snap.get(testing.allocator, "b")).?;
    defer testing.allocator.free(sb);
    try testing.expectEqualStrings("v1", sa);
    try testing.expectEqualStrings("v1", sb);
    try testing.expect(try snap.get(testing.allocator, "c") == null);

    // Latest view sees mutations.
    const latest = bt.view();
    const la = (try latest.get(testing.allocator, "a")).?;
    defer testing.allocator.free(la);
    const lc = (try latest.get(testing.allocator, "c")).?;
    defer testing.allocator.free(lc);
    try testing.expectEqualStrings("v2", la);
    try testing.expectEqualStrings("v1", lc);
    try testing.expect(try latest.get(testing.allocator, "b") == null);
}

test "snapshot iterator unaffected by concurrent writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var p = try openTestPager(&tmp);
    defer p.close();
    const bt = BTree.init(testing.allocator, &p, pager_mod.default_collection_id);

    var key_buf: [16]u8 = undefined;
    for (0..50) |i| {
        const key = try std.fmt.bufPrint(&key_buf, "k{d:0>3}", .{i});
        try bt.put(key, "v");
    }

    const snap = bt.view();
    var snap_iter = try snap.iterator(testing.allocator);
    defer snap_iter.deinit();

    // Read first 10 entries.
    var seen: u32 = 0;
    while (seen < 10) : (seen += 1) {
        const e = (try snap_iter.next()).?;
        _ = e;
    }

    // Mutate the tree heavily mid-iteration.
    for (50..150) |i| {
        const key = try std.fmt.bufPrint(&key_buf, "k{d:0>3}", .{i});
        try bt.put(key, "v");
    }
    for (0..30) |i| {
        const key = try std.fmt.bufPrint(&key_buf, "k{d:0>3}", .{i});
        _ = try bt.delete(key);
    }

    // Snapshot iteration continues from where it left off, sees remaining 40
    // pre-mutation entries.
    while (try snap_iter.next()) |_| seen += 1;
    try testing.expectEqual(@as(u32, 50), seen);
}


test "sharding 2B: trees rooted at different CollectionIds are isolated" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var p = try openTestPager(&tmp);
    defer p.close();

    const bt0 = BTree.init(testing.allocator, &p, 0);
    const bt1 = BTree.init(testing.allocator, &p, 1);

    try bt0.put("alpha", "in-0");
    try bt1.put("alpha", "in-1");
    try bt0.put("only-0", "v");
    try bt1.put("only-1", "v");

    // Each tree's view of "alpha" is its own value.
    const a0 = (try bt0.get(testing.allocator, "alpha")).?;
    defer testing.allocator.free(a0);
    const a1 = (try bt1.get(testing.allocator, "alpha")).?;
    defer testing.allocator.free(a1);
    try testing.expectEqualStrings("in-0", a0);
    try testing.expectEqualStrings("in-1", a1);

    // Cross-collection key lookups miss.
    try testing.expect(try bt0.get(testing.allocator, "only-1") == null);
    try testing.expect(try bt1.get(testing.allocator, "only-0") == null);

    // Roots are different page ids.
    try testing.expect(p.bTreeRoot(0) != p.bTreeRoot(1));
}

test "sharding 2B: per-collection roots survive close/reopen + lost shm" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var p = try openTestPager(&tmp);
        defer p.close();
        const bt0 = BTree.init(testing.allocator, &p, 0);
        const bt5 = BTree.init(testing.allocator, &p, 5);
        try bt0.put("default-key", "default-val");
        try bt5.put("shard-5-key", "shard-5-val");
        try p.checkpoint();
    }
    // Simulate machine reboot: shm + WAL are gone, only the data file
    // is on disk. The reopen path must reconstruct shm slots from the
    // header v2's collection_roots[].
    tmp.dir.deleteFile(testing.io, "btree.db.wal") catch {};
    tmp.dir.deleteFile(testing.io, "btree.db-shm") catch {};

    var p = try openTestPager(&tmp);
    defer p.close();

    // Both trees come back with the right contents — proving header v2's
    // collection_roots[] array round-tripped through serialize/deserialize
    // and the WAL replay (if any) dispatched to the right tree.
    const bt0 = BTree.init(testing.allocator, &p, 0);
    const bt5 = BTree.init(testing.allocator, &p, 5);
    const v0 = (try bt0.get(testing.allocator, "default-key")).?;
    defer testing.allocator.free(v0);
    const v5 = (try bt5.get(testing.allocator, "shard-5-key")).?;
    defer testing.allocator.free(v5);
    try testing.expectEqualStrings("default-val", v0);
    try testing.expectEqualStrings("shard-5-val", v5);

    // Cross-tree checks.
    try testing.expect(try bt0.get(testing.allocator, "shard-5-key") == null);
    try testing.expect(try bt5.get(testing.allocator, "default-key") == null);
}
