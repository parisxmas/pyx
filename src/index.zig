//! Secondary indexes. Persistent equality indexes on string and i64 fields,
//! auto-maintained on writes.
//!
//! Index entries live in the same global B+Tree as primary docs; the
//! namespace byte at the start of each key disambiguates them.
//!
//! Key layouts (all values inside one B+Tree):
//!   primary entry:    \x00 + varint(coll_len) + coll + u64_BE(doc_id)
//!   index entry:      \x01 + varint(coll_len) + coll + varint(field_len) + field
//!                     + type_tag(1) + encoded_value + u64_BE(doc_id)
//!   index registry:   \x02 + varint(coll_len) + coll + varint(field_len) + field
//!
//! Encoded value (in index entries):
//!   string  (tag 0x05): varint(len) + bytes
//!   i64     (tag 0x03): u64_BE(value XOR 1<<63)  -- sign-bit flip so negatives sort first
//!
//! v0 limitations:
//!   - Equality only (no range queries; though the prefix encoding supports them)
//!   - Single-field indexes (no compound)
//!   - String / i64 only — null/bool/f64/array/object skipped
//!   - findOne returns the lowest-doc_id match; full scan iterator is on Collection.find

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const pager_mod = @import("pager.zig");
const btree_mod = @import("btree.zig");
const doc_mod = @import("doc.zig");

const PageId = pager_mod.PageId;

pub const Error = error{
    UnsupportedFieldType,
    KeyTooLarge,
};

pub const ns_primary: u8 = 0x00;
pub const ns_index: u8 = 0x01;
pub const ns_registry: u8 = 0x02;
/// Compound-index registry: `\x03 + varint(coll_len) + coll + varint(N) +
/// N × (varint(field_len) + field_name)`.
pub const ns_registry_compound: u8 = 0x03;
/// Compound-index entry: `\x04 + (compound registry body) +
/// N × (tag + encoded_value) + u64_BE(doc_id)`. Using a separate
/// namespace from single-field entries keeps the two formats isolated
/// — old DBs with single-field indexes are unaffected by this addition.
pub const ns_index_compound: u8 = 0x04;
/// Collection-catalog entry (sharding phase 2C): `\x05 + name`.
/// Value is `u32 LE` — the CollectionId allocated for this name.
/// Lives in the default tree (id 0), which acts as the metadata
/// home for the entire DB.
pub const ns_collection_catalog: u8 = 0x05;

const max_collection_name: usize = 200;
const max_field_path: usize = 200;
const max_index_value_size: usize = 256;
// Worst case index key: \x01 + 2 varints + names + tag + value + u64. ~700 bytes (under btree max_key=256? no — wait)
// btree.max_key_size is 256 — too small for index keys with long values. We'll cap.
const max_index_key_size: usize = btree_mod.max_key_size;

pub const IndexDef = struct {
    coll_name: []u8, // owned
    field_path: []u8, // owned

    fn deinit(self: IndexDef, allocator: Allocator) void {
        allocator.free(self.coll_name);
        allocator.free(self.field_path);
    }

    fn matches(self: IndexDef, coll: []const u8) bool {
        return mem.eql(u8, self.coll_name, coll);
    }
};

/// Multi-field index definition. Lookups must supply values in the same
/// order the index was created with — `(last, first)` is a different
/// index from `(first, last)`.
pub const CompoundIndexDef = struct {
    coll_name: []u8,           // owned
    /// N field names in order. Each name is allocator-owned; the outer
    /// slice is too.
    fields: [][]u8,

    fn deinit(self: CompoundIndexDef, allocator: Allocator) void {
        allocator.free(self.coll_name);
        for (self.fields) |f| allocator.free(f);
        allocator.free(self.fields);
    }

    fn matches(self: CompoundIndexDef, coll: []const u8) bool {
        return mem.eql(u8, self.coll_name, coll);
    }

    /// True if this index's field list matches the given names in order.
    pub fn fieldsEql(self: CompoundIndexDef, fields: []const []const u8) bool {
        if (self.fields.len != fields.len) return false;
        for (self.fields, fields) |a, b| {
            if (!mem.eql(u8, a, b)) return false;
        }
        return true;
    }
};

pub const Manager = struct {
    allocator: Allocator,
    indexes: ArrayList(IndexDef),
    compound: ArrayList(CompoundIndexDef),

    pub fn init(allocator: Allocator) Manager {
        return .{
            .allocator = allocator,
            .indexes = .empty,
            .compound = .empty,
        };
    }

    pub fn deinit(self: *Manager) void {
        for (self.indexes.items) |idx| idx.deinit(self.allocator);
        self.indexes.deinit(self.allocator);
        for (self.compound.items) |idx| idx.deinit(self.allocator);
        self.compound.deinit(self.allocator);
        self.* = undefined;
    }

    /// Restore in-memory index lists by scanning both registry
    /// namespaces (single-field at \x02, compound at \x03).
    pub fn loadFromPager(self: *Manager, pager: *pager_mod.Pager) !void {
        const view = btree_mod.View{ .pager = pager, .file = pager.file, .io = pager.io, .root = pager.bTreeRoot(pager_mod.default_collection_id) };
        {
            var it = try view.iteratorFrom(self.allocator, &.{ns_registry});
            defer it.deinit();
            while (try it.next()) |entry| {
                if (entry.key.len == 0 or entry.key[0] != ns_registry) break;
                const parsed = try parseRegistryKey(entry.key);
                const def = IndexDef{
                    .coll_name = try self.allocator.dupe(u8, parsed.coll),
                    .field_path = try self.allocator.dupe(u8, parsed.field),
                };
                try self.indexes.append(self.allocator, def);
            }
        }
        {
            var it = try view.iteratorFrom(self.allocator, &.{ns_registry_compound});
            defer it.deinit();
            while (try it.next()) |entry| {
                if (entry.key.len == 0 or entry.key[0] != ns_registry_compound) break;
                const def = try parseCompoundRegistryKey(self.allocator, entry.key);
                try self.compound.append(self.allocator, def);
            }
        }
    }

    /// Look up indexes registered for a collection.
    pub fn forCollection(self: *const Manager, coll: []const u8, out: *ArrayList(*const IndexDef), allocator: Allocator) !void {
        for (self.indexes.items) |*def| {
            if (def.matches(coll)) try out.append(allocator, def);
        }
    }

    /// Hook called after a primary insert. Adds index entries for each
    /// matching active index whose field is present and supported.
    /// `collection_id` is the tree the doc was inserted into; index
    /// entries live in the same tree so a snapshot of that collection
    /// is internally consistent w.r.t. its indexes.
    pub fn afterInsert(
        self: *Manager,
        pager: *pager_mod.Pager,
        collection_id: pager_mod.CollectionId,
        coll: []const u8,
        doc_id: u64,
        doc_bytes: []const u8,
    ) !void {
        const bt = btree_mod.BTree.init(self.allocator, pager, collection_id);
        for (self.indexes.items) |def| {
            if (!def.matches(coll)) continue;
            try addIndexEntry(self.allocator, bt, def, doc_id, doc_bytes);
        }
        for (self.compound.items) |def| {
            if (!def.matches(coll)) continue;
            try addCompoundIndexEntry(self.allocator, bt, def, doc_id, doc_bytes);
        }
    }

    /// Hook called before a primary delete (we need the old doc to know
    /// which index entries to remove).
    pub fn beforeDelete(
        self: *Manager,
        pager: *pager_mod.Pager,
        collection_id: pager_mod.CollectionId,
        coll: []const u8,
        doc_id: u64,
        old_doc: []const u8,
    ) !void {
        const bt = btree_mod.BTree.init(self.allocator, pager, collection_id);
        for (self.indexes.items) |def| {
            if (!def.matches(coll)) continue;
            try removeIndexEntry(self.allocator, bt, def, doc_id, old_doc);
        }
        for (self.compound.items) |def| {
            if (!def.matches(coll)) continue;
            try removeCompoundIndexEntry(self.allocator, bt, def, doc_id, old_doc);
        }
    }

    /// Add a new index. Caller is responsible for opening a transaction
    /// (these calls themselves don't open one).
    ///
    /// Three-phase to stay safe under the pager's within-txn CoW dedup:
    ///   1. Scan the collection BEFORE any writes — the view's iterator
    ///      then walks pristine on-disk pages (none in `dirty`), so
    ///      subsequent in-place modifications can't perturb it.
    ///   2. Write the registry entry.
    ///   3. Apply the index entries from the collected pairs.
    pub fn createIndex(
        self: *Manager,
        pager: *pager_mod.Pager,
        collection_id: pager_mod.CollectionId,
        coll: []const u8,
        field: []const u8,
    ) !void {
        if (coll.len == 0 or coll.len > max_collection_name) return Error.KeyTooLarge;
        if (field.len == 0 or field.len > max_field_path) return Error.KeyTooLarge;

        for (self.indexes.items) |def| {
            if (def.matches(coll) and mem.eql(u8, def.field_path, field)) return;
        }

        // Registry is global — one entry per (coll, field) pair, in the
        // default tree. Index entries (added in phase 3) live in the
        // collection's own tree so a per-collection snapshot is
        // internally consistent.
        const registry_bt = btree_mod.BTree.init(self.allocator, pager, pager_mod.default_collection_id);
        const entry_bt = btree_mod.BTree.init(self.allocator, pager, collection_id);

        // Phase 1: scan upfront, dupe each value so it survives subsequent
        // tree mutations.
        const Pair = struct { doc_id: u64, value: []u8 };
        var pairs: ArrayList(Pair) = .empty;
        defer {
            for (pairs.items) |p| self.allocator.free(p.value);
            pairs.deinit(self.allocator);
        }

        var prefix_buf: [max_index_key_size]u8 = undefined;
        const prefix_len = encodeCollectionPrefix(&prefix_buf, coll);
        const view = btree_mod.View{ .pager = pager, .file = pager.file, .io = pager.io, .root = pager.bTreeRoot(collection_id) };
        {
            var it = try view.iteratorFrom(self.allocator, prefix_buf[0..prefix_len]);
            defer it.deinit();
            while (try it.next()) |entry| {
                if (!startsWithPrefix(entry.key, prefix_buf[0..prefix_len])) break;
                if (entry.key.len != prefix_len + 8) continue;
                const doc_id = mem.readInt(u64, entry.key[prefix_len..][0..8], .big);
                try pairs.append(self.allocator, .{
                    .doc_id = doc_id,
                    .value = try self.allocator.dupe(u8, entry.value),
                });
            }
        }

        // Phase 2: write the registry entry into the default tree.
        var key_buf: [max_index_key_size]u8 = undefined;
        const key_len = encodeRegistryKey(&key_buf, coll, field);
        try registry_bt.put(key_buf[0..key_len], &.{});

        const def = IndexDef{
            .coll_name = try self.allocator.dupe(u8, coll),
            .field_path = try self.allocator.dupe(u8, field),
        };
        errdefer def.deinit(self.allocator);

        // Phase 3: insert index entries from the snapshot we collected.
        // Entries live in the collection's own tree. Done BEFORE
        // appending to self.indexes so a partial-failure path leaves a
        // clean errdefer (no double-free between def.deinit and
        // Manager.deinit).
        for (pairs.items) |p| {
            try addIndexEntry(self.allocator, entry_bt, def, p.doc_id, p.value);
        }

        try self.indexes.append(self.allocator, def);
    }

    /// Drop an index: remove the registry entry and all its index entries.
    pub fn dropIndex(
        self: *Manager,
        pager: *pager_mod.Pager,
        collection_id: pager_mod.CollectionId,
        coll: []const u8,
        field: []const u8,
    ) !void {
        // Find and remove from in-memory list.
        var found_idx: ?usize = null;
        for (self.indexes.items, 0..) |def, i| {
            if (def.matches(coll) and mem.eql(u8, def.field_path, field)) {
                found_idx = i;
                break;
            }
        }
        if (found_idx == null) return;
        const removed = self.indexes.orderedRemove(found_idx.?);
        defer removed.deinit(self.allocator);

        const registry_bt = btree_mod.BTree.init(self.allocator, pager, pager_mod.default_collection_id);
        const entry_bt = btree_mod.BTree.init(self.allocator, pager, collection_id);

        // Remove registry entry from the default tree.
        var key_buf: [max_index_key_size]u8 = undefined;
        const key_len = encodeRegistryKey(&key_buf, coll, field);
        _ = try registry_bt.delete(key_buf[0..key_len]);

        // Walk all index entries with our (coll, field) prefix and delete
        // them from the collection's tree.
        var prefix_buf: [max_index_key_size]u8 = undefined;
        const prefix_len = encodeIndexFieldPrefix(&prefix_buf, coll, field);
        var to_delete: ArrayList([]u8) = .empty;
        defer {
            for (to_delete.items) |k| self.allocator.free(k);
            to_delete.deinit(self.allocator);
        }
        const view = btree_mod.View{ .pager = pager, .file = pager.file, .io = pager.io, .root = pager.bTreeRoot(collection_id) };
        var it = try view.iteratorFrom(self.allocator, prefix_buf[0..prefix_len]);
        defer it.deinit();
        while (try it.next()) |entry| {
            if (!startsWithPrefix(entry.key, prefix_buf[0..prefix_len])) break;
            try to_delete.append(self.allocator, try self.allocator.dupe(u8, entry.key));
        }
        for (to_delete.items) |k| _ = try entry_bt.delete(k);
    }

    /// Compound-index variant of `createIndex`. `fields` is the ordered
    /// list of field names; an index `(last, first)` is distinct from
    /// `(first, last)`. Same three-phase build-while-scanning strategy
    /// as the single-field path.
    pub fn createCompoundIndex(
        self: *Manager,
        pager: *pager_mod.Pager,
        collection_id: pager_mod.CollectionId,
        coll: []const u8,
        fields: []const []const u8,
    ) !void {
        if (coll.len == 0 or coll.len > max_collection_name) return Error.KeyTooLarge;
        if (fields.len == 0) return Error.UnsupportedFieldType;
        for (fields) |f| if (f.len == 0 or f.len > max_field_path) return Error.KeyTooLarge;

        for (self.compound.items) |def| {
            if (def.matches(coll) and def.fieldsEql(fields)) return;
        }

        const registry_bt = btree_mod.BTree.init(self.allocator, pager, pager_mod.default_collection_id);
        const entry_bt = btree_mod.BTree.init(self.allocator, pager, collection_id);

        // Phase 1: snapshot the collection's primary entries before any
        // writes, so subsequent index inserts can't perturb our scan.
        const Pair = struct { doc_id: u64, value: []u8 };
        var pairs: ArrayList(Pair) = .empty;
        defer {
            for (pairs.items) |p| self.allocator.free(p.value);
            pairs.deinit(self.allocator);
        }
        var prefix_buf: [max_index_key_size]u8 = undefined;
        const prefix_len = encodeCollectionPrefix(&prefix_buf, coll);
        const view = btree_mod.View{ .pager = pager, .file = pager.file, .io = pager.io, .root = pager.bTreeRoot(collection_id) };
        {
            var it = try view.iteratorFrom(self.allocator, prefix_buf[0..prefix_len]);
            defer it.deinit();
            while (try it.next()) |entry| {
                if (!startsWithPrefix(entry.key, prefix_buf[0..prefix_len])) break;
                if (entry.key.len != prefix_len + 8) continue;
                const doc_id = mem.readInt(u64, entry.key[prefix_len..][0..8], .big);
                try pairs.append(self.allocator, .{
                    .doc_id = doc_id,
                    .value = try self.allocator.dupe(u8, entry.value),
                });
            }
        }

        // Phase 2: build the def, write the registry entry to default tree.
        const owned_fields = try self.allocator.alloc([]u8, fields.len);
        errdefer self.allocator.free(owned_fields);
        var allocated: usize = 0;
        errdefer for (owned_fields[0..allocated]) |f| self.allocator.free(f);
        for (fields, 0..) |src, i| {
            owned_fields[i] = try self.allocator.dupe(u8, src);
            allocated = i + 1;
        }
        const def = CompoundIndexDef{
            .coll_name = try self.allocator.dupe(u8, coll),
            .fields = owned_fields,
        };
        errdefer self.allocator.free(def.coll_name);

        var key_buf: [max_index_key_size]u8 = undefined;
        const key_len = try encodeCompoundRegistryKey(&key_buf, coll, fields);
        try registry_bt.put(key_buf[0..key_len], &.{});

        // Phase 3: index the snapshot. Entries go in the per-collection
        // tree. Done BEFORE appending to self.compound for the same
        // reason as createIndex — a partial-failure path leaves a
        // clean errdefer.
        for (pairs.items) |p| {
            try addCompoundIndexEntry(self.allocator, entry_bt, def, p.doc_id, p.value);
        }

        try self.compound.append(self.allocator, def);
    }

    /// Drop a compound index by exact-match field list.
    pub fn dropCompoundIndex(
        self: *Manager,
        pager: *pager_mod.Pager,
        collection_id: pager_mod.CollectionId,
        coll: []const u8,
        fields: []const []const u8,
    ) !void {
        var found_idx: ?usize = null;
        for (self.compound.items, 0..) |def, i| {
            if (def.matches(coll) and def.fieldsEql(fields)) {
                found_idx = i;
                break;
            }
        }
        if (found_idx == null) return;
        const removed = self.compound.orderedRemove(found_idx.?);
        defer removed.deinit(self.allocator);

        const registry_bt = btree_mod.BTree.init(self.allocator, pager, pager_mod.default_collection_id);
        const entry_bt = btree_mod.BTree.init(self.allocator, pager, collection_id);

        var key_buf: [max_index_key_size]u8 = undefined;
        const key_len = try encodeCompoundRegistryKey(&key_buf, coll, fields);
        _ = try registry_bt.delete(key_buf[0..key_len]);

        // Walk the entry namespace in the collection's tree.
        var prefix_buf: [max_index_key_size]u8 = undefined;
        const prefix_len = try encodeCompoundEntryFieldsPrefix(&prefix_buf, coll, fields);
        var to_delete: ArrayList([]u8) = .empty;
        defer {
            for (to_delete.items) |k| self.allocator.free(k);
            to_delete.deinit(self.allocator);
        }
        const view = btree_mod.View{ .pager = pager, .file = pager.file, .io = pager.io, .root = pager.bTreeRoot(collection_id) };
        var it = try view.iteratorFrom(self.allocator, prefix_buf[0..prefix_len]);
        defer it.deinit();
        while (try it.next()) |entry| {
            if (!startsWithPrefix(entry.key, prefix_buf[0..prefix_len])) break;
            try to_delete.append(self.allocator, try self.allocator.dupe(u8, entry.key));
        }
        for (to_delete.items) |k| _ = try entry_bt.delete(k);
    }

    pub fn hasCompoundIndex(self: *const Manager, coll: []const u8, fields: []const []const u8) bool {
        for (self.compound.items) |def| {
            if (def.matches(coll) and def.fieldsEql(fields)) return true;
        }
        return false;
    }

    /// Equality lookup against a compound index. `values` must align in
    /// order with the index's `fields` array.
    pub fn findOneCompound(
        self: *const Manager,
        pager: *pager_mod.Pager,
        collection_id: pager_mod.CollectionId,
        coll: []const u8,
        fields: []const []const u8,
        values: []const doc_mod.Value,
    ) !?u64 {
        const view = btree_mod.View{ .pager = pager, .file = pager.file, .io = pager.io, .root = pager.bTreeRoot(collection_id) };
        return self.findOneCompoundInView(view, coll, fields, values);
    }

    pub fn findOneCompoundInView(
        self: *const Manager,
        view: btree_mod.View,
        coll: []const u8,
        fields: []const []const u8,
        values: []const doc_mod.Value,
    ) !?u64 {
        if (!self.hasCompoundIndex(coll, fields)) return error.NoSuchIndex;
        if (values.len != fields.len) return error.NoSuchIndex;

        var prefix_buf: [max_index_key_size]u8 = undefined;
        const prefix_len = try encodeCompoundLookupKey(&prefix_buf, coll, fields, values);
        var key_buf: [max_index_key_size]u8 = undefined;
        const matched_len = (try view.findFirstByPrefix(prefix_buf[0..prefix_len], &key_buf)) orelse return null;
        const matched_key = key_buf[0..matched_len];
        if (matched_key.len != prefix_len + 8) return null;
        return mem.readInt(u64, matched_key[prefix_len..][0..8], .big);
    }

    /// Equality lookup: returns the doc_id of the first match (lowest doc_id),
    /// or null. Errors if no index exists for (coll, field).
    /// Convenience wrapper: builds a pager-mediated `View` and delegates.
    pub fn findOne(
        self: *const Manager,
        pager: *pager_mod.Pager,
        collection_id: pager_mod.CollectionId,
        coll: []const u8,
        field: []const u8,
        value: doc_mod.Value,
    ) !?u64 {
        const view = btree_mod.View{ .pager = pager, .file = pager.file, .io = pager.io, .root = pager.bTreeRoot(collection_id) };
        return self.findOneInView(view, coll, field, value);
    }

    /// Same as `findOne`, but reads through an externally-provided `View`.
    /// Snapshot readers pass a `View` with `pager = null` so the lookup
    /// goes straight to disk via `pread` and never touches the writer's
    /// dirty buffer or page cache.
    pub fn findOneInView(
        self: *const Manager,
        view: btree_mod.View,
        coll: []const u8,
        field: []const u8,
        value: doc_mod.Value,
    ) !?u64 {
        if (!self.hasIndex(coll, field)) return error.NoSuchIndex;

        var prefix_buf: [max_index_key_size]u8 = undefined;
        const prefix_len = try encodeIndexLookupKey(&prefix_buf, coll, field, value);
        // Stack-based prefix lookup — no iterator alloc.
        var key_buf: [max_index_key_size]u8 = undefined;
        const matched_len = (try view.findFirstByPrefix(prefix_buf[0..prefix_len], &key_buf)) orelse return null;
        const matched_key = key_buf[0..matched_len];
        if (matched_key.len != prefix_len + 8) return null;
        return mem.readInt(u64, matched_key[prefix_len..][0..8], .big);
    }

    /// Equality scan: yields all doc_ids matching value (ascending). Caller
    /// must `deinit` the returned iterator.
    pub fn findAll(
        self: *const Manager,
        allocator: Allocator,
        pager: *pager_mod.Pager,
        collection_id: pager_mod.CollectionId,
        coll: []const u8,
        field: []const u8,
        value: doc_mod.Value,
    ) !LookupIterator {
        const view = btree_mod.View{ .pager = pager, .file = pager.file, .io = pager.io, .root = pager.bTreeRoot(collection_id) };
        return self.findAllInView(allocator, view, coll, field, value);
    }

    /// Same as `findAll`, but reads through an externally-provided `View`
    /// (lock-free disk reads when `view.pager == null`).
    pub fn findAllInView(
        self: *const Manager,
        allocator: Allocator,
        view: btree_mod.View,
        coll: []const u8,
        field: []const u8,
        value: doc_mod.Value,
    ) !LookupIterator {
        if (!self.hasIndex(coll, field)) return error.NoSuchIndex;
        var buf: [max_index_key_size]u8 = undefined;
        const prefix_len = try encodeIndexLookupKey(&buf, coll, field, value);
        const inner = try view.iteratorFrom(allocator, buf[0..prefix_len]);
        var lookup = LookupIterator{
            .inner = inner,
            .prefix_buf = undefined,
            .prefix_len = prefix_len,
        };
        @memcpy(lookup.prefix_buf[0..prefix_len], buf[0..prefix_len]);
        return lookup;
    }

    pub fn hasIndex(self: *const Manager, coll: []const u8, field: []const u8) bool {
        for (self.indexes.items) |def| {
            if (def.matches(coll) and mem.eql(u8, def.field_path, field)) return true;
        }
        return false;
    }

    /// Range scan over an indexed field. Convenience wrapper that builds a
    /// pager-mediated `View`.
    pub fn findRange(
        self: *const Manager,
        allocator: Allocator,
        pager: *pager_mod.Pager,
        collection_id: pager_mod.CollectionId,
        coll: []const u8,
        field: []const u8,
        lo: Bound,
        hi: Bound,
    ) !RangeIterator {
        const view = btree_mod.View{ .pager = pager, .file = pager.file, .io = pager.io, .root = pager.bTreeRoot(collection_id) };
        return self.findRangeInView(allocator, view, coll, field, lo, hi);
    }

    /// Range scan via an externally-provided `View`. When the view has
    /// `pager = null`, the entire scan is lock-free (direct disk reads).
    ///
    /// The scan walks index entries with key in [seek_key, stop_key)
    /// (or `..stop_key]` for inclusive upper bounds), where seek_key and
    /// stop_key are derived lexicographically from `lo` and `hi`. Because
    /// the index encoding preserves sort order (i64s are sign-flipped,
    /// strings are length-prefixed), lex order matches value order
    /// within a single type — so this works for type-monotonic indexes.
    pub fn findRangeInView(
        self: *const Manager,
        allocator: Allocator,
        view: btree_mod.View,
        coll: []const u8,
        field: []const u8,
        lo: Bound,
        hi: Bound,
    ) !RangeIterator {
        if (!self.hasIndex(coll, field)) return error.NoSuchIndex;

        var field_prefix_buf: [max_index_key_size]u8 = undefined;
        const field_prefix_len = encodeIndexFieldPrefix(&field_prefix_buf, coll, field);

        // Build the seek key (where the iterator starts).
        var seek_buf: [max_index_key_size]u8 = undefined;
        @memcpy(seek_buf[0..field_prefix_len], field_prefix_buf[0..field_prefix_len]);
        var seek_len: usize = field_prefix_len;
        switch (lo) {
            .none => {},
            .inclusive => |v| {
                seek_len += try encodeValue(seek_buf[seek_len..], v);
            },
            .exclusive => |v| {
                seek_len += try encodeValue(seek_buf[seek_len..], v);
                // Pad with 0xFF*8 to skip every entry whose value equals lo
                // — those keys are at most field_prefix + tag + encoded_v
                // + 0xFF*8, so seeking right after that puts us on the
                // first entry with a strictly greater value.
                if (seek_len + 8 > seek_buf.len) return error.KeyTooLarge;
                @memset(seek_buf[seek_len..][0..8], 0xFF);
                seek_len += 8;
            },
        }

        // Build the stop key for upper-bound checks.
        var stop_buf: [max_index_key_size]u8 = undefined;
        var stop_len: usize = 0;
        var stop_inclusive: bool = false;
        switch (hi) {
            .none => {}, // stop_len = 0 means "no upper bound; use field prefix"
            .inclusive => |v| {
                @memcpy(stop_buf[0..field_prefix_len], field_prefix_buf[0..field_prefix_len]);
                stop_len = field_prefix_len;
                stop_len += try encodeValue(stop_buf[stop_len..], v);
                if (stop_len + 8 > stop_buf.len) return error.KeyTooLarge;
                @memset(stop_buf[stop_len..][0..8], 0xFF);
                stop_len += 8;
                stop_inclusive = true;
            },
            .exclusive => |v| {
                @memcpy(stop_buf[0..field_prefix_len], field_prefix_buf[0..field_prefix_len]);
                stop_len = field_prefix_len;
                stop_len += try encodeValue(stop_buf[stop_len..], v);
                stop_inclusive = false;
            },
        }

        const inner = try view.iteratorFrom(allocator, seek_buf[0..seek_len]);
        var iter = RangeIterator{
            .inner = inner,
            .field_prefix_buf = undefined,
            .field_prefix_len = field_prefix_len,
            .stop_buf = undefined,
            .stop_len = stop_len,
            .stop_inclusive = stop_inclusive,
        };
        @memcpy(iter.field_prefix_buf[0..field_prefix_len], field_prefix_buf[0..field_prefix_len]);
        if (stop_len > 0) @memcpy(iter.stop_buf[0..stop_len], stop_buf[0..stop_len]);
        return iter;
    }
};

pub const Bound = union(enum) {
    none,
    inclusive: doc_mod.Value,
    exclusive: doc_mod.Value,
};

pub const RangeIterator = struct {
    inner: btree_mod.Iterator,
    field_prefix_buf: [max_index_key_size]u8,
    field_prefix_len: usize,
    /// Comparison sentinel for the upper bound. When `stop_len == 0` there
    /// is no upper bound and we just check the field prefix.
    stop_buf: [max_index_key_size]u8,
    stop_len: usize,
    /// When true, entries with `key == stop_buf` are still in range.
    stop_inclusive: bool,

    pub fn deinit(self: *RangeIterator) void {
        self.inner.deinit();
    }

    pub fn next(self: *RangeIterator) !?u64 {
        const field_prefix = self.field_prefix_buf[0..self.field_prefix_len];
        while (try self.inner.next()) |entry| {
            // Past this field's entries → done.
            if (!startsWithPrefix(entry.key, field_prefix)) return null;
            // A valid index entry has at least: field_prefix + tag(1) + u64(8).
            if (entry.key.len < self.field_prefix_len + 9) continue;
            // Check upper bound.
            if (self.stop_len > 0) {
                const stop = self.stop_buf[0..self.stop_len];
                const cmp = mem.order(u8, entry.key, stop);
                const past_bound = if (self.stop_inclusive)
                    cmp == .gt
                else
                    cmp != .lt;
                if (past_bound) return null;
            }
            // Last 8 bytes are the doc_id (BE u64).
            return mem.readInt(u64, entry.key[entry.key.len - 8 ..][0..8], .big);
        }
        return null;
    }
};

pub const LookupIterator = struct {
    inner: btree_mod.Iterator,
    prefix_buf: [max_index_key_size]u8,
    prefix_len: usize,

    pub fn deinit(self: *LookupIterator) void {
        self.inner.deinit();
    }

    pub fn next(self: *LookupIterator) !?u64 {
        while (try self.inner.next()) |entry| {
            const prefix = self.prefix_buf[0..self.prefix_len];
            if (!startsWithPrefix(entry.key, prefix)) return null;
            if (entry.key.len != self.prefix_len + 8) continue;
            return mem.readInt(u64, entry.key[self.prefix_len..][0..8], .big);
        }
        return null;
    }
};

// =========================================================================
// Internals
// =========================================================================

fn startsWithPrefix(key: []const u8, prefix: []const u8) bool {
    return key.len >= prefix.len and mem.eql(u8, key[0..prefix.len], prefix);
}

fn encodeRegistryKey(buf: []u8, coll: []const u8, field: []const u8) usize {
    var pos: usize = 0;
    buf[pos] = ns_registry;
    pos += 1;
    pos += doc_mod.writeVarint(buf[pos..], coll.len);
    @memcpy(buf[pos .. pos + coll.len], coll);
    pos += coll.len;
    pos += doc_mod.writeVarint(buf[pos..], field.len);
    @memcpy(buf[pos .. pos + field.len], field);
    pos += field.len;
    return pos;
}

const ParsedRegistry = struct { coll: []const u8, field: []const u8 };

fn parseRegistryKey(key: []const u8) !ParsedRegistry {
    if (key.len < 1 or key[0] != ns_registry) return error.BadRegistryKey;
    var pos: usize = 1;
    const c = try readVarint(key[pos..]);
    pos += c.len;
    const coll = key[pos .. pos + c.value];
    pos += c.value;
    const f = try readVarint(key[pos..]);
    pos += f.len;
    const field = key[pos .. pos + f.value];
    return .{ .coll = coll, .field = field };
}

fn encodeIndexFieldPrefix(buf: []u8, coll: []const u8, field: []const u8) usize {
    var pos: usize = 0;
    buf[pos] = ns_index;
    pos += 1;
    pos += doc_mod.writeVarint(buf[pos..], coll.len);
    @memcpy(buf[pos .. pos + coll.len], coll);
    pos += coll.len;
    pos += doc_mod.writeVarint(buf[pos..], field.len);
    @memcpy(buf[pos .. pos + field.len], field);
    pos += field.len;
    return pos;
}

fn encodeCollectionPrefix(buf: []u8, coll: []const u8) usize {
    var pos: usize = 0;
    buf[pos] = ns_primary;
    pos += 1;
    pos += doc_mod.writeVarint(buf[pos..], coll.len);
    @memcpy(buf[pos .. pos + coll.len], coll);
    pos += coll.len;
    return pos;
}

/// Encode a value into the sortable representation used in index keys.
/// Returns bytes written into buf (after position `start`).
fn encodeValue(buf: []u8, value: doc_mod.Value) !usize {
    switch (value) {
        .i64 => |n| {
            if (buf.len < 9) return Error.KeyTooLarge;
            buf[0] = 0x03;
            const flipped: u64 = @as(u64, @bitCast(n)) ^ (@as(u64, 1) << 63);
            mem.writeInt(u64, buf[1..9], flipped, .big);
            return 9;
        },
        .string => |s| {
            const vlen_size = doc_mod.varintSize(s.len);
            const total = 1 + vlen_size + s.len;
            if (buf.len < total) return Error.KeyTooLarge;
            buf[0] = 0x05;
            const wrote = doc_mod.writeVarint(buf[1..], s.len);
            @memcpy(buf[1 + wrote .. 1 + wrote + s.len], s);
            return 1 + wrote + s.len;
        },
        else => return Error.UnsupportedFieldType,
    }
}

/// Build index entry key: \x01 + coll + field + value + u64_BE doc_id.
fn encodeIndexEntryKey(
    buf: []u8,
    coll: []const u8,
    field: []const u8,
    value: doc_mod.Value,
    doc_id: u64,
) !usize {
    var pos: usize = encodeIndexFieldPrefix(buf, coll, field);
    pos += try encodeValue(buf[pos..], value);
    if (buf.len < pos + 8) return Error.KeyTooLarge;
    mem.writeInt(u64, buf[pos..][0..8], doc_id, .big);
    pos += 8;
    return pos;
}

/// Same as encodeIndexEntryKey but stops after the value (no doc_id) — used
/// as the lookup prefix.
fn encodeIndexLookupKey(
    buf: []u8,
    coll: []const u8,
    field: []const u8,
    value: doc_mod.Value,
) !usize {
    var pos: usize = encodeIndexFieldPrefix(buf, coll, field);
    pos += try encodeValue(buf[pos..], value);
    return pos;
}

fn addIndexEntry(
    allocator: Allocator,
    bt: btree_mod.BTree,
    def: IndexDef,
    doc_id: u64,
    doc_bytes: []const u8,
) !void {
    _ = allocator;
    const value = (try doc_mod.lookup(doc_bytes, def.field_path)) orelse return;
    var buf: [max_index_key_size]u8 = undefined;
    const len = encodeIndexEntryKey(&buf, def.coll_name, def.field_path, value, doc_id) catch |err| {
        // Skip unsupported types or oversized values silently — index becomes sparse.
        if (err == Error.UnsupportedFieldType or err == Error.KeyTooLarge) return;
        return err;
    };
    try bt.put(buf[0..len], &.{});
}

fn removeIndexEntry(
    allocator: Allocator,
    bt: btree_mod.BTree,
    def: IndexDef,
    doc_id: u64,
    old_doc: []const u8,
) !void {
    _ = allocator;
    const value = (try doc_mod.lookup(old_doc, def.field_path)) orelse return;
    var buf: [max_index_key_size]u8 = undefined;
    const len = encodeIndexEntryKey(&buf, def.coll_name, def.field_path, value, doc_id) catch |err| {
        if (err == Error.UnsupportedFieldType or err == Error.KeyTooLarge) return;
        return err;
    };
    _ = try bt.delete(buf[0..len]);
}

// =========================================================================
// Compound index encoding
// =========================================================================

/// `\x03 + varint(coll_len) + coll + varint(N) + N × (varint(len)+name)`
fn encodeCompoundRegistryKey(
    buf: []u8,
    coll: []const u8,
    fields: []const []const u8,
) !usize {
    var pos: usize = 0;
    if (buf.len < 1) return Error.KeyTooLarge;
    buf[pos] = ns_registry_compound;
    pos += 1;
    pos += doc_mod.writeVarint(buf[pos..], coll.len);
    if (buf.len < pos + coll.len) return Error.KeyTooLarge;
    @memcpy(buf[pos .. pos + coll.len], coll);
    pos += coll.len;
    pos += doc_mod.writeVarint(buf[pos..], fields.len);
    for (fields) |f| {
        pos += doc_mod.writeVarint(buf[pos..], f.len);
        if (buf.len < pos + f.len) return Error.KeyTooLarge;
        @memcpy(buf[pos .. pos + f.len], f);
        pos += f.len;
    }
    return pos;
}

fn parseCompoundRegistryKey(allocator: Allocator, key: []const u8) !CompoundIndexDef {
    if (key.len < 1 or key[0] != ns_registry_compound) return error.BadRegistryKey;
    var pos: usize = 1;
    const c = try readVarint(key[pos..]);
    pos += c.len;
    const coll = key[pos .. pos + c.value];
    pos += c.value;
    const n = try readVarint(key[pos..]);
    pos += n.len;
    const fields_owned = try allocator.alloc([]u8, @intCast(n.value));
    var allocated: usize = 0;
    errdefer {
        for (fields_owned[0..allocated]) |f| allocator.free(f);
        allocator.free(fields_owned);
    }
    var i: usize = 0;
    while (i < n.value) : (i += 1) {
        const f = try readVarint(key[pos..]);
        pos += f.len;
        const name = key[pos .. pos + f.value];
        pos += f.value;
        fields_owned[i] = try allocator.dupe(u8, name);
        allocated = i + 1;
    }
    const coll_owned = try allocator.dupe(u8, coll);
    return .{ .coll_name = coll_owned, .fields = fields_owned };
}

/// `\x04 + varint(coll_len) + coll + varint(N) + N × (varint(len)+name)`.
/// This is the prefix that all entries for a given compound index share —
/// useful as a scan starting point and for dropIndex.
fn encodeCompoundEntryFieldsPrefix(
    buf: []u8,
    coll: []const u8,
    fields: []const []const u8,
) !usize {
    var pos: usize = 0;
    if (buf.len < 1) return Error.KeyTooLarge;
    buf[pos] = ns_index_compound;
    pos += 1;
    pos += doc_mod.writeVarint(buf[pos..], coll.len);
    if (buf.len < pos + coll.len) return Error.KeyTooLarge;
    @memcpy(buf[pos .. pos + coll.len], coll);
    pos += coll.len;
    pos += doc_mod.writeVarint(buf[pos..], fields.len);
    for (fields) |f| {
        pos += doc_mod.writeVarint(buf[pos..], f.len);
        if (buf.len < pos + f.len) return Error.KeyTooLarge;
        @memcpy(buf[pos .. pos + f.len], f);
        pos += f.len;
    }
    return pos;
}

/// Lookup prefix: fields-prefix + N × (tag+value), no doc_id.
fn encodeCompoundLookupKey(
    buf: []u8,
    coll: []const u8,
    fields: []const []const u8,
    values: []const doc_mod.Value,
) !usize {
    var pos = try encodeCompoundEntryFieldsPrefix(buf, coll, fields);
    for (values) |v| {
        pos += try encodeValue(buf[pos..], v);
    }
    return pos;
}

fn encodeCompoundEntryKey(
    buf: []u8,
    coll: []const u8,
    fields: []const []const u8,
    values: []const doc_mod.Value,
    doc_id: u64,
) !usize {
    const pos = try encodeCompoundLookupKey(buf, coll, fields, values);
    if (buf.len < pos + 8) return Error.KeyTooLarge;
    mem.writeInt(u64, buf[pos..][0..8], doc_id, .big);
    return pos + 8;
}

fn addCompoundIndexEntry(
    allocator: Allocator,
    bt: btree_mod.BTree,
    def: CompoundIndexDef,
    doc_id: u64,
    doc_bytes: []const u8,
) !void {
    _ = allocator;
    // Resolve all field values from the doc. If any field is missing,
    // skip indexing this doc entirely (sparse-index semantics, same as
    // the single-field path).
    var values_buf: [16]doc_mod.Value = undefined;
    if (def.fields.len > values_buf.len) return; // pathological; skip
    for (def.fields, 0..) |fname, i| {
        const v = (try doc_mod.lookup(doc_bytes, fname)) orelse return;
        values_buf[i] = v;
    }
    const values = values_buf[0..def.fields.len];
    var buf: [max_index_key_size]u8 = undefined;
    const len = encodeCompoundEntryKey(&buf, def.coll_name, def.fields, values, doc_id) catch |err| {
        if (err == Error.UnsupportedFieldType or err == Error.KeyTooLarge) return;
        return err;
    };
    try bt.put(buf[0..len], &.{});
}

fn removeCompoundIndexEntry(
    allocator: Allocator,
    bt: btree_mod.BTree,
    def: CompoundIndexDef,
    doc_id: u64,
    old_doc: []const u8,
) !void {
    _ = allocator;
    var values_buf: [16]doc_mod.Value = undefined;
    if (def.fields.len > values_buf.len) return;
    for (def.fields, 0..) |fname, i| {
        const v = (try doc_mod.lookup(old_doc, fname)) orelse return;
        values_buf[i] = v;
    }
    const values = values_buf[0..def.fields.len];
    var buf: [max_index_key_size]u8 = undefined;
    const len = encodeCompoundEntryKey(&buf, def.coll_name, def.fields, values, doc_id) catch |err| {
        if (err == Error.UnsupportedFieldType or err == Error.KeyTooLarge) return;
        return err;
    };
    _ = try bt.delete(buf[0..len]);
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
