const std = @import("std");
const Value = @import("../ast/value.zig").Value;
const Parser = @import("../parser/parser.zig").Parser;

pub const Composer = struct {
    allocator: std.mem.Allocator,
    anchors: std.StringHashMap(*Value),

    pub fn init(allocator: std.mem.Allocator) Composer {
        return .{
            .allocator = allocator,
            .anchors = std.StringHashMap(*Value).init(allocator),
        };
    }

    pub fn deinit(self: *Composer) void {
        var iter = self.anchors.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.anchors.deinit();
    }

    pub fn compose(self: *Composer, source: []const u8) !Value {
        var parser = Parser.init(self.allocator, source);
        defer parser.deinit();
        var value = try parser.parse();
        errdefer value.deinit(self.allocator);

        try self.collectAnchors(&value);
        try self.resolveAliases(&value);

        return value;
    }

    fn collectAnchors(self: *Composer, value: *Value) !void {
        switch (value.*) {
            .null, .boolean, .integer, .float, .string => {},
            .sequence => |*seq| {
                for (seq.items) |*item| {
                    try self.collectAnchors(item);
                }
            },
            .mapping => |*map| {
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    try self.collectAnchors(entry.value_ptr);
                }
            },
        }
    }

    fn resolveAliases(self: *Composer, value: *Value) !void {
        switch (value.*) {
            .null, .boolean, .integer, .float, .string => {},
            .sequence => |*seq| {
                var i: usize = 0;
                while (i < seq.items.len) : (i += 1) {
                    try self.resolveAliases(&seq.items[i]);
                }
            },
            .mapping => |*map| {
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    try self.resolveAliases(entry.value_ptr);
                }
            },
        }
    }
};

pub fn compose(allocator: std.mem.Allocator, source: []const u8) !Value {
    var composer = Composer.init(allocator);
    defer composer.deinit();
    return composer.compose(source);
}

test "compose simple scalar" {
    const allocator = std.testing.allocator;
    var value = try compose(allocator, "hello");
    defer value.deinit(allocator);
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings("hello", value.string);
}

test "compose sequence" {
    const allocator = std.testing.allocator;
    var value = try compose(allocator, "[1, 2, 3]");
    defer value.deinit(allocator);
    try std.testing.expect(value == .sequence);
    try std.testing.expectEqual(@as(usize, 3), value.sequence.items.len);
}

test "compose mapping" {
    const allocator = std.testing.allocator;
    var value = try compose(allocator, "key: value");
    defer value.deinit(allocator);
    try std.testing.expect(value == .mapping);
    try std.testing.expectEqual(@as(usize, 1), value.mapping.count());
}

test "compose null" {
    const allocator = std.testing.allocator;
    var value = try compose(allocator, "null");
    defer value.deinit(allocator);
    try std.testing.expect(value == .null);
}

test "compose boolean" {
    const allocator = std.testing.allocator;
    var v1 = try compose(allocator, "true");
    defer v1.deinit(allocator);
    try std.testing.expect(v1 == .boolean);
    try std.testing.expect(v1.boolean == true);

    var v2 = try compose(allocator, "false");
    defer v2.deinit(allocator);
    try std.testing.expect(v2 == .boolean);
    try std.testing.expect(v2.boolean == false);
}
