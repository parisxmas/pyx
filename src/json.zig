//! JSON ↔ binary document conversion. The encoder runs std.json's value
//! parser and translates the resulting tree into `doc.Builder` calls.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const json = std.json;

const doc = @import("doc.zig");

pub const Error = error{
    NotAJsonObject,
    NumberOutOfRange,
};

/// Parse a JSON string and emit document bytes. Top-level must be an object
/// (since our document format requires a top-level object).
pub fn fromJson(allocator: Allocator, json_str: []const u8) ![]u8 {
    var parsed = try json.parseFromSlice(json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return Error.NotAJsonObject;

    var b = doc.Builder.init(allocator);
    defer b.deinit();
    try b.beginDocument();
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        try emit(&b, kv.key_ptr.*, kv.value_ptr.*);
    }
    try b.endDocument();
    return b.finish();
}

fn emit(b: *doc.Builder, key: ?[]const u8, v: json.Value) !void {
    switch (v) {
        .null => try b.putNull(key),
        .bool => |x| try b.putBool(key, x),
        .integer => |x| try b.putI64(key, x),
        .float => |x| try b.putF64(key, x),
        .number_string => |s| {
            if (std.fmt.parseInt(i64, s, 10)) |n| {
                try b.putI64(key, n);
            } else |_| {
                if (std.fmt.parseFloat(f64, s)) |f| {
                    try b.putF64(key, f);
                } else |_| {
                    return Error.NumberOutOfRange;
                }
            }
        },
        .string => |s| try b.putString(key, s),
        .array => |arr| {
            try b.beginArray(key);
            for (arr.items) |item| try emit(b, null, item);
            try b.endArray();
        },
        .object => |o| {
            try b.beginObject(key);
            var it = o.iterator();
            while (it.next()) |kv| try emit(b, kv.key_ptr.*, kv.value_ptr.*);
            try b.endObject();
        },
    }
}

const testing = std.testing;

test "json roundtrip via doc.lookup" {
    const src =
        \\{
        \\  "name": "Alice",
        \\  "age": 30,
        \\  "active": true,
        \\  "score": 99.5,
        \\  "email": null,
        \\  "address": { "city": "Istanbul", "zip": 34000 },
        \\  "tags": ["vip", "early"]
        \\}
    ;
    const bytes = try fromJson(testing.allocator, src);
    defer testing.allocator.free(bytes);

    try testing.expectEqualStrings("Alice", (try doc.lookup(bytes, "name")).?.string);
    try testing.expectEqual(@as(i64, 30), (try doc.lookup(bytes, "age")).?.i64);
    try testing.expectEqual(true, (try doc.lookup(bytes, "active")).?.bool);
    try testing.expectEqual(@as(f64, 99.5), (try doc.lookup(bytes, "score")).?.f64);
    try testing.expectEqual(@as(?doc.Value, .null), try doc.lookup(bytes, "email"));
    try testing.expectEqualStrings("Istanbul", (try doc.lookup(bytes, "address.city")).?.string);
    try testing.expectEqual(@as(i64, 34000), (try doc.lookup(bytes, "address.zip")).?.i64);

    const tags = (try doc.lookup(bytes, "tags")).?.array;
    var it = tags.iterator();
    try testing.expectEqualStrings("vip", (try it.next()).?.string);
    try testing.expectEqualStrings("early", (try it.next()).?.string);
    try testing.expect((try it.next()) == null);
}

test "rejects non-object top-level" {
    try testing.expectError(Error.NotAJsonObject, fromJson(testing.allocator, "[1, 2, 3]"));
    try testing.expectError(Error.NotAJsonObject, fromJson(testing.allocator, "42"));
}
