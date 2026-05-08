//! Binary document format. Self-describing typed values, length-prefixed
//! containers for O(1) skip during path lookup.
//!
//! Wire format:
//!   value := type:u8 | payload
//!
//! Type tags:
//!   0x00  null
//!   0x01  false
//!   0x02  true
//!   0x03  i64    (8 bytes little-endian)
//!   0x04  f64    (8 bytes IEEE 754 little-endian)
//!   0x05  string (varint length + UTF-8 bytes)
//!   0x06  bytes  (varint length + raw bytes)
//!   0x07  array  (u32 payload length + sequence of values)
//!   0x08  object (u32 payload length + sequence of entries)
//!
//! Object entry: type:u8 | varint key_len | key bytes | value payload
//! Array element:  type:u8 | value payload
//!
//! A "document" is a top-level object — i.e., the encoded bytes always start
//! with the object tag (0x08).

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

pub const Tag = enum(u8) {
    null = 0,
    false = 1,
    true = 2,
    i64 = 3,
    f64 = 4,
    string = 5,
    bytes = 6,
    array = 7,
    object = 8,
    _,
};

pub const Error = error{
    Truncated,
    BadTag,
    BadVarint,
    NotInScope,
    NotInObject,
    BadScope,
    MismatchedScope,
    MissingKey,
    UnexpectedKey,
    UnclosedScopes,
    NotAtRoot,
    PayloadTooLarge,
};

// =========================================================================
// Varint (LEB128 unsigned)
// =========================================================================

pub fn writeVarint(buf: []u8, n: u64) usize {
    var v = n;
    var i: usize = 0;
    while (true) {
        const lo: u8 = @intCast(v & 0x7f);
        v >>= 7;
        const more: u8 = if (v != 0) 0x80 else 0;
        buf[i] = lo | more;
        i += 1;
        if (more == 0) return i;
    }
}

pub fn varintSize(n: u64) usize {
    var v = n;
    var size: usize = 0;
    while (true) {
        size += 1;
        v >>= 7;
        if (v == 0) return size;
    }
}

const ReadVarintResult = struct { value: u64, len: usize };

fn readVarint(buf: []const u8) Error!ReadVarintResult {
    var v: u64 = 0;
    var shift: u6 = 0;
    var i: usize = 0;
    while (i < buf.len) {
        const b = buf[i];
        i += 1;
        v |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return .{ .value = v, .len = i };
        if (shift >= 64 - 7) return Error.BadVarint;
        shift += 7;
    }
    return Error.Truncated;
}

// =========================================================================
// Value views (lazy parsing — array/object hold raw slices)
// =========================================================================

pub const Value = union(enum) {
    null,
    bool: bool,
    i64: i64,
    f64: f64,
    string: []const u8,
    bytes: []const u8,
    array: Array,
    object: Object,
};

pub const Array = struct {
    bytes: []const u8,

    pub fn iterator(self: Array) Iterator {
        return .{ .bytes = self.bytes, .pos = 0 };
    }

    pub const Iterator = struct {
        bytes: []const u8,
        pos: usize,

        pub fn next(self: *Iterator) Error!?Value {
            if (self.pos >= self.bytes.len) return null;
            const tag: Tag = @enumFromInt(self.bytes[self.pos]);
            self.pos += 1;
            const r = try readPayload(tag, self.bytes[self.pos..]);
            self.pos += r.consumed;
            return r.value;
        }
    };
};

pub const Object = struct {
    bytes: []const u8,

    pub fn iterator(self: Object) Iterator {
        return .{ .bytes = self.bytes, .pos = 0 };
    }

    pub const Entry = struct { key: []const u8, value: Value };

    pub const Iterator = struct {
        bytes: []const u8,
        pos: usize,

        pub fn next(self: *Iterator) Error!?Entry {
            if (self.pos >= self.bytes.len) return null;
            const tag: Tag = @enumFromInt(self.bytes[self.pos]);
            self.pos += 1;
            const k = try readVarint(self.bytes[self.pos..]);
            self.pos += k.len;
            const key = self.bytes[self.pos .. self.pos + k.value];
            self.pos += k.value;
            const r = try readPayload(tag, self.bytes[self.pos..]);
            self.pos += r.consumed;
            return .{ .key = key, .value = r.value };
        }
    };

    pub fn get(self: Object, key: []const u8) Error!?Value {
        var it = self.iterator();
        while (try it.next()) |entry| {
            if (mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

const PayloadRead = struct { value: Value, consumed: usize };

fn readPayload(tag: Tag, payload: []const u8) Error!PayloadRead {
    switch (tag) {
        .null => return .{ .value = .null, .consumed = 0 },
        .false => return .{ .value = .{ .bool = false }, .consumed = 0 },
        .true => return .{ .value = .{ .bool = true }, .consumed = 0 },
        .i64 => {
            if (payload.len < 8) return Error.Truncated;
            return .{
                .value = .{ .i64 = mem.readInt(i64, payload[0..8], .little) },
                .consumed = 8,
            };
        },
        .f64 => {
            if (payload.len < 8) return Error.Truncated;
            const bits = mem.readInt(u64, payload[0..8], .little);
            return .{ .value = .{ .f64 = @bitCast(bits) }, .consumed = 8 };
        },
        .string => {
            const k = try readVarint(payload);
            const start = k.len;
            const end = start + k.value;
            if (end > payload.len) return Error.Truncated;
            return .{ .value = .{ .string = payload[start..end] }, .consumed = end };
        },
        .bytes => {
            const k = try readVarint(payload);
            const start = k.len;
            const end = start + k.value;
            if (end > payload.len) return Error.Truncated;
            return .{ .value = .{ .bytes = payload[start..end] }, .consumed = end };
        },
        .array => {
            if (payload.len < 4) return Error.Truncated;
            const len = mem.readInt(u32, payload[0..4], .little);
            const end: usize = 4 + len;
            if (end > payload.len) return Error.Truncated;
            return .{ .value = .{ .array = .{ .bytes = payload[4..end] } }, .consumed = end };
        },
        .object => {
            if (payload.len < 4) return Error.Truncated;
            const len = mem.readInt(u32, payload[0..4], .little);
            const end: usize = 4 + len;
            if (end > payload.len) return Error.Truncated;
            return .{ .value = .{ .object = .{ .bytes = payload[4..end] } }, .consumed = end };
        },
        _ => return Error.BadTag,
    }
}

// =========================================================================
// Parse / lookup
// =========================================================================

pub fn parse(bytes: []const u8) Error!Value {
    if (bytes.len == 0) return Error.Truncated;
    const tag: Tag = @enumFromInt(bytes[0]);
    const r = try readPayload(tag, bytes[1..]);
    return r.value;
}

/// Walk a dotted path through nested objects. An empty `path` returns the
/// top-level value. Returns null if any segment is missing or any
/// intermediate value isn't an object.
pub fn lookup(doc_bytes: []const u8, path: []const u8) Error!?Value {
    var current = try parse(doc_bytes);
    if (path.len == 0) return current;
    var iter = mem.splitScalar(u8, path, '.');
    while (iter.next()) |segment| {
        switch (current) {
            .object => |o| {
                if (try o.get(segment)) |v| {
                    current = v;
                } else return null;
            },
            else => return null,
        }
    }
    return current;
}

// =========================================================================
// Builder
// =========================================================================

pub const Builder = struct {
    allocator: Allocator,
    buf: ArrayList(u8),
    stack: ArrayList(StackFrame),

    const StackFrame = struct {
        tag: Tag,
        size_offset: usize, // offset of the u32 length placeholder
    };

    pub fn init(allocator: Allocator) Builder {
        return .{
            .allocator = allocator,
            .buf = .empty,
            .stack = .empty,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.buf.deinit(self.allocator);
        self.stack.deinit(self.allocator);
    }

    /// Begin building a document (top-level object).
    pub fn beginDocument(self: *Builder) !void {
        if (self.stack.items.len != 0) return Error.NotAtRoot;
        try self.buf.append(self.allocator, @intFromEnum(Tag.object));
        const off = self.buf.items.len;
        try self.buf.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });
        try self.stack.append(self.allocator, .{ .tag = .object, .size_offset = off });
    }

    pub fn endDocument(self: *Builder) !void {
        if (self.stack.items.len != 1 or self.stack.items[0].tag != .object) return Error.MismatchedScope;
        try self.endContainer();
    }

    fn currentScope(self: *const Builder) ?Tag {
        if (self.stack.items.len == 0) return null;
        return self.stack.items[self.stack.items.len - 1].tag;
    }

    fn writeEntryHeader(self: *Builder, key: ?[]const u8, tag: Tag) !void {
        const cur = self.currentScope() orelse return Error.NotInScope;
        try self.buf.append(self.allocator, @intFromEnum(tag));
        switch (cur) {
            .object => {
                if (key == null) return Error.MissingKey;
                var vb: [10]u8 = undefined;
                const n = writeVarint(&vb, key.?.len);
                try self.buf.appendSlice(self.allocator, vb[0..n]);
                try self.buf.appendSlice(self.allocator, key.?);
            },
            .array => {
                if (key != null) return Error.UnexpectedKey;
            },
            else => return Error.BadScope,
        }
    }

    pub fn putNull(self: *Builder, key: ?[]const u8) !void {
        try self.writeEntryHeader(key, .null);
    }

    pub fn putBool(self: *Builder, key: ?[]const u8, b: bool) !void {
        try self.writeEntryHeader(key, if (b) .true else .false);
    }

    pub fn putI64(self: *Builder, key: ?[]const u8, n: i64) !void {
        try self.writeEntryHeader(key, .i64);
        var b: [8]u8 = undefined;
        mem.writeInt(i64, &b, n, .little);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn putF64(self: *Builder, key: ?[]const u8, n: f64) !void {
        try self.writeEntryHeader(key, .f64);
        var b: [8]u8 = undefined;
        mem.writeInt(u64, &b, @bitCast(n), .little);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn putString(self: *Builder, key: ?[]const u8, s: []const u8) !void {
        try self.writeEntryHeader(key, .string);
        var vb: [10]u8 = undefined;
        const n = writeVarint(&vb, s.len);
        try self.buf.appendSlice(self.allocator, vb[0..n]);
        try self.buf.appendSlice(self.allocator, s);
    }

    pub fn putBytes(self: *Builder, key: ?[]const u8, b: []const u8) !void {
        try self.writeEntryHeader(key, .bytes);
        var vb: [10]u8 = undefined;
        const n = writeVarint(&vb, b.len);
        try self.buf.appendSlice(self.allocator, vb[0..n]);
        try self.buf.appendSlice(self.allocator, b);
    }

    pub fn beginObject(self: *Builder, key: ?[]const u8) !void {
        try self.writeEntryHeader(key, .object);
        const off = self.buf.items.len;
        try self.buf.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });
        try self.stack.append(self.allocator, .{ .tag = .object, .size_offset = off });
    }

    pub fn beginArray(self: *Builder, key: ?[]const u8) !void {
        try self.writeEntryHeader(key, .array);
        const off = self.buf.items.len;
        try self.buf.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 });
        try self.stack.append(self.allocator, .{ .tag = .array, .size_offset = off });
    }

    pub fn endObject(self: *Builder) !void {
        if (self.currentScope() != .object) return Error.MismatchedScope;
        try self.endContainer();
    }

    pub fn endArray(self: *Builder) !void {
        if (self.currentScope() != .array) return Error.MismatchedScope;
        try self.endContainer();
    }

    fn endContainer(self: *Builder) !void {
        const frame = self.stack.pop().?;
        const start = frame.size_offset + 4;
        const len = self.buf.items.len - start;
        if (len > std.math.maxInt(u32)) return Error.PayloadTooLarge;
        mem.writeInt(u32, self.buf.items[frame.size_offset..][0..4], @intCast(len), .little);
    }

    /// Returns owned bytes; resets the builder so it can be reused.
    pub fn finish(self: *Builder) ![]u8 {
        if (self.stack.items.len != 0) return Error.UnclosedScopes;
        const out = try self.buf.toOwnedSlice(self.allocator);
        // buf was emptied by toOwnedSlice; the stack still owns its capacity.
        self.stack.clearAndFree(self.allocator);
        return out;
    }
};

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

test "varint roundtrip" {
    const cases = [_]u64{ 0, 1, 127, 128, 1 << 14, 1 << 20, std.math.maxInt(u32), std.math.maxInt(u64) };
    for (cases) |n| {
        var buf: [10]u8 = undefined;
        const len = writeVarint(&buf, n);
        try testing.expectEqual(varintSize(n), len);
        const r = try readVarint(buf[0..len]);
        try testing.expectEqual(n, r.value);
        try testing.expectEqual(len, r.len);
    }
}

test "build and parse a flat document" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.beginDocument();
    try b.putString("name", "Alice");
    try b.putI64("age", 30);
    try b.putBool("active", true);
    try b.putNull("email");
    try b.putF64("score", 99.5);
    try b.endDocument();
    const bytes = try b.finish();
    defer testing.allocator.free(bytes);

    const v = try parse(bytes);
    const obj = v.object;
    try testing.expectEqualStrings("Alice", (try obj.get("name")).?.string);
    try testing.expectEqual(@as(i64, 30), (try obj.get("age")).?.i64);
    try testing.expectEqual(true, (try obj.get("active")).?.bool);
    try testing.expectEqual(@as(?Value, .null), try obj.get("email"));
    try testing.expectEqual(@as(f64, 99.5), (try obj.get("score")).?.f64);
    try testing.expect((try obj.get("missing")) == null);
}

test "nested objects and arrays via path lookup" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.beginDocument();
    try b.putString("name", "Alice");
    try b.beginObject("address");
    try b.putString("city", "Istanbul");
    try b.putI64("zip", 34000);
    try b.beginArray("tags");
    try b.putString(null, "vip");
    try b.putString(null, "early-adopter");
    try b.endArray();
    try b.endObject();
    try b.endDocument();
    const bytes = try b.finish();
    defer testing.allocator.free(bytes);

    const top = (try lookup(bytes, "")).?;
    try testing.expect(top == .object);

    const city = (try lookup(bytes, "address.city")).?;
    try testing.expectEqualStrings("Istanbul", city.string);

    const zip = (try lookup(bytes, "address.zip")).?;
    try testing.expectEqual(@as(i64, 34000), zip.i64);

    const tags = (try lookup(bytes, "address.tags")).?;
    var it = tags.array.iterator();
    const t0 = (try it.next()).?;
    const t1 = (try it.next()).?;
    try testing.expectEqualStrings("vip", t0.string);
    try testing.expectEqualStrings("early-adopter", t1.string);
    try testing.expect((try it.next()) == null);

    // Missing path returns null.
    try testing.expect((try lookup(bytes, "address.country")) == null);
    try testing.expect((try lookup(bytes, "name.deeper")) == null); // string isn't an object
}

test "object iteration yields entries in insertion order" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.beginDocument();
    try b.putI64("a", 1);
    try b.putI64("b", 2);
    try b.putI64("c", 3);
    try b.endDocument();
    const bytes = try b.finish();
    defer testing.allocator.free(bytes);

    const obj = (try parse(bytes)).object;
    var it = obj.iterator();
    const e0 = (try it.next()).?;
    const e1 = (try it.next()).?;
    const e2 = (try it.next()).?;
    try testing.expectEqualStrings("a", e0.key);
    try testing.expectEqualStrings("b", e1.key);
    try testing.expectEqualStrings("c", e2.key);
    try testing.expect((try it.next()) == null);
}

test "bytes roundtrip preserves binary content" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.beginDocument();
    const blob = [_]u8{ 0x00, 0xff, 0x10, 0x80, 0x7f };
    try b.putBytes("blob", &blob);
    try b.endDocument();
    const bytes = try b.finish();
    defer testing.allocator.free(bytes);

    const v = try parse(bytes);
    const got = (try v.object.get("blob")).?;
    try testing.expectEqualSlices(u8, &blob, got.bytes);
}

test "truncated document is detected" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.beginDocument();
    try b.putString("name", "Alice");
    try b.endDocument();
    const bytes = try b.finish();
    defer testing.allocator.free(bytes);

    // Lop off the final byte.
    try testing.expectError(Error.Truncated, parse(bytes[0 .. bytes.len - 1]));
}

test "deeply nested document" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.beginDocument();
    try b.beginObject("a");
    try b.beginObject("b");
    try b.beginObject("c");
    try b.putString("d", "found");
    try b.endObject();
    try b.endObject();
    try b.endObject();
    try b.endDocument();
    const bytes = try b.finish();
    defer testing.allocator.free(bytes);

    const v = (try lookup(bytes, "a.b.c.d")).?;
    try testing.expectEqualStrings("found", v.string);
}

test "unclosed scope on finish is rejected" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.beginDocument();
    try b.beginObject("nested");
    try testing.expectError(Error.UnclosedScopes, b.finish());
}
