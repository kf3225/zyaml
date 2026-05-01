const std = @import("std");
const Value = @import("../ast/value.zig").Value;

pub const FlowStyle = enum {
    block,
    flow,
};

pub const EmitOptions = struct {
    indent: usize = 2,
    flow_style: FlowStyle = .block,
    sort_keys: bool = false,
};

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    writer: std.ArrayList(u8).Writer,
    options: EmitOptions,
    indent_level: usize,

    pub fn init(allocator: std.mem.Allocator, writer: std.ArrayList(u8).Writer, options: EmitOptions) Emitter {
        return .{
            .allocator = allocator,
            .writer = writer,
            .options = options,
            .indent_level = 0,
        };
    }

    pub const EmitError = error{OutOfMemory};

    pub fn isScalar(value: Value) bool {
        return switch (value) {
            .null, .boolean, .integer, .float, .string => true,
            else => false,
        };
    }

    pub fn emitValue(self: *Emitter, value: Value) EmitError!void {
        switch (value) {
            .null => try self.writer.writeAll("null"),
            .boolean => |b| try self.writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try std.fmt.formatInt(i, 10, .lower, .{}, self.writer),
            .float => |f| try self.emitFloat(f),
            .string => |s| try self.emitString(s),
            .sequence => |seq| try self.emitSequence(seq),
            .mapping => |map| try self.emitMapping(map),
        }
    }

    fn emitFloat(self: *Emitter, f: f64) EmitError!void {
        if (std.math.isNan(f)) {
            try self.writer.writeAll(".nan");
        } else if (std.math.isInf(f)) {
            try self.writer.writeAll(if (f < 0) "-.inf" else ".inf");
        } else {
            var buf: [64]u8 = undefined;
            // decimal mode avoids scientific notation for typical YAML floats
        const str = std.fmt.formatFloat(&buf, f, .{ .mode = .decimal }) catch "0.0";
            try self.writer.writeAll(str);
        }
    }

    fn emitString(self: *Emitter, s: []const u8) EmitError!void {
        if (!needsQuoting(s)) {
            try self.writer.writeAll(s);
            return;
        }
        try self.emitSingleQuoted(s);
    }

    fn needsQuoting(s: []const u8) bool {
        if (s.len == 0) return true;
        if (s[0] == ' ' or s[s.len - 1] == ' ') return true;
        if (Value.isReservedWord(s)) return true;
        if (Value.looksLikeNumber(s)) return true;
        const first = s[0];
        switch (first) {
            '-', '?', ':', ',', '[', ']', '{', '}', '#', '&', '*', '!', '%', '@', '`', '"', '\'', '|', '>' => return true,
            else => {},
        }
        for (s) |ch| {
            if (ch == ':' or ch == '#' or ch == '\n') return true;
        }
        return false;
    }

    fn emitSingleQuoted(self: *Emitter, s: []const u8) EmitError!void {
        try self.writer.writeByte('\'');
        for (s) |ch| {
            if (ch == '\'') {
                try self.writer.writeAll("''");
            } else {
                try self.writer.writeByte(ch);
            }
        }
        try self.writer.writeByte('\'');
    }

    fn collectKeys(self: *Emitter, map: Value.Mapping) ![]const []const u8 {
        var keys = std.ArrayList([]const u8).init(self.allocator);
        try keys.ensureTotalCapacity(map.count());
        var iter = map.iterator();
        while (iter.next()) |entry| {
            try keys.append(entry.key_ptr.*);
        }
        if (self.options.sort_keys) {
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);
        }
        return keys.toOwnedSlice();
    }

    fn emitSeqChild(self: *Emitter, item: Value) EmitError!void {
        switch (item) {
            .mapping => |map| {
                if (map.count() == 0) {
                    try self.writer.writeAll("{}");
                    return;
                }
                try self.emitMappingInline(map, self.indent_level + self.options.indent);
            },
            .sequence => |inner_seq| {
                const saved = self.indent_level;
                self.indent_level = saved + self.options.indent;
                try self.emitSequence(inner_seq);
                self.indent_level = saved;
            },
            else => try self.emitValue(item),
        }
    }

    fn emitSequence(self: *Emitter, seq: Value.Sequence) EmitError!void {
        if (seq.items.len == 0) {
            try self.writer.writeAll("[]");
            return;
        }
        if (self.options.flow_style == .flow) {
            try self.writer.writeByte('[');
            for (seq.items, 0..) |item, i| {
                if (i > 0) try self.writer.writeAll(", ");
                try self.emitValue(item);
            }
            try self.writer.writeByte(']');
            return;
        }
        for (seq.items, 0..) |item, i| {
            if (i > 0 or self.indent_level > 0) {
                try self.writeNewlineIndent();
            }
            try self.writer.writeAll("- ");
            try self.emitSeqChild(item);
        }
    }

    fn emitMapEntry(self: *Emitter, key: []const u8, val: Value) EmitError!void {
        if (key.len == 0) {
            try self.writer.writeAll("? ''");
            try self.emitMapEntryValue(val, true);
            return;
        }
        try self.emitString(key);
        try self.emitMapEntryValue(val, false);
    }

    fn emitMapEntryValue(self: *Emitter, val: Value, empty_key: bool) EmitError!void {
        if (isScalar(val)) {
            if (empty_key) {
                try self.writeNewlineIndent();
            }
            try self.writer.writeAll(": ");
            try self.emitValue(val);
            return;
        }
        if (empty_key) {
            try self.writeNewlineIndent();
            try self.writer.writeAll(":");
            self.indent_level += self.options.indent;
            try self.emitValue(val);
            self.indent_level -= self.options.indent;
            return;
        }
        try self.writer.writeAll(":");
        const saved = self.indent_level;
        switch (val) {
            .sequence => {
                // Top-level sequence as map value needs a newline before the first '-'
                if (self.indent_level == 0) try self.writer.writeByte('\n');
                try self.emitValue(val);
            },
            else => {
                self.indent_level = saved + self.options.indent;
                try self.emitValue(val);
                self.indent_level = saved;
            },
        }
    }

    fn emitMappingInline(self: *Emitter, map: Value.Mapping, base_indent: usize) EmitError!void {
        const saved = self.indent_level;
        const keys = try self.collectKeys(map);
        defer self.allocator.free(keys);
        for (keys, 0..) |key, i| {
            if (i > 0) {
                self.indent_level = base_indent;
                try self.writeNewlineIndent();
            }
            try self.emitMapEntry(key, map.get(key).?);
        }
        self.indent_level = saved;
    }

    fn emitMapping(self: *Emitter, map: Value.Mapping) EmitError!void {
        if (map.count() == 0) {
            try self.writer.writeAll("{}");
            return;
        }
        if (self.options.flow_style == .flow) {
            try self.emitMappingFlow(map);
            return;
        }
        const keys = try self.collectKeys(map);
        defer self.allocator.free(keys);
        for (keys, 0..) |key, i| {
            if (i > 0 or self.indent_level > 0) {
                try self.writeNewlineIndent();
            }
            try self.emitMapEntry(key, map.get(key).?);
        }
    }

    fn emitMappingFlow(self: *Emitter, map: Value.Mapping) EmitError!void {
        try self.writer.writeByte('{');
        const keys = try self.collectKeys(map);
        defer self.allocator.free(keys);
        for (keys, 0..) |key, i| {
            if (i > 0) try self.writer.writeAll(", ");
            try self.emitString(key);
            try self.writer.writeAll(": ");
            try self.emitValue(map.get(key).?);
        }
        try self.writer.writeByte('}');
    }

    fn writeIndent(self: *Emitter) EmitError!void {
        try self.writer.writeByteNTimes(' ', self.indent_level);
    }

    fn writeNewlineIndent(self: *Emitter) EmitError!void {
        try self.writer.writeByte('\n');
        try self.writeIndent();
    }
};

pub fn stringify(allocator: std.mem.Allocator, value: Value, options: EmitOptions) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();
    var emitter = Emitter.init(allocator, buffer.writer(), options);
    try emitter.emitValue(value);
    return buffer.toOwnedSlice();
}

test "emit null" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .null, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("null", result);
}

test "emit boolean" {
    const allocator = std.testing.allocator;
    const r1 = try stringify(allocator, .{ .boolean = true }, .{});
    defer allocator.free(r1);
    try std.testing.expectEqualStrings("true", r1);
    const r2 = try stringify(allocator, .{ .boolean = false }, .{});
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("false", r2);
}

test "emit integer" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .integer = 42 }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("42", result);
}

test "emit float" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .float = 3.14 }, .{});
    defer allocator.free(result);
    try std.testing.expect(result.len > 0);
}

test "emit string" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .string = "hello" }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "emit string that needs quoting" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .string = "true" }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("'true'", result);
}

test "emit empty sequence" {
    const allocator = std.testing.allocator;
    var seq = Value.Sequence.init(allocator);
    defer seq.deinit();
    const result = try stringify(allocator, .{ .sequence = seq }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[]", result);
}

test "emit empty mapping" {
    const allocator = std.testing.allocator;
    var map = Value.Mapping.init(allocator);
    defer map.deinit();
    const result = try stringify(allocator, .{ .mapping = map }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("{}", result);
}

test "emit sequence" {
    const allocator = std.testing.allocator;
    var seq = Value.Sequence.init(allocator);
    defer {
        for (seq.items) |*item| item.deinit(allocator);
        seq.deinit();
    }
    try seq.append(.{ .integer = 1 });
    try seq.append(.{ .integer = 2 });
    try seq.append(.{ .integer = 3 });
    const result = try stringify(allocator, .{ .sequence = seq }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("- 1\n- 2\n- 3", result);
}

test "emit mapping" {
    const allocator = std.testing.allocator;
    var map = Value.Mapping.init(allocator);
    defer {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        map.deinit();
    }
    const key = try allocator.dupe(u8, "key");
    const val: Value = .{ .string = try allocator.dupe(u8, "value") };
    try map.put(key, val);
    const result = try stringify(allocator, .{ .mapping = map }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings("key: value", result);
}

test "emit nan" {
    const allocator = std.testing.allocator;
    const result = try stringify(allocator, .{ .float = std.math.nan(f64) }, .{});
    defer allocator.free(result);
    try std.testing.expectEqualStrings(".nan", result);
}

test "emit infinity" {
    const allocator = std.testing.allocator;
    const r1 = try stringify(allocator, .{ .float = std.math.inf(f64) }, .{});
    defer allocator.free(r1);
    try std.testing.expectEqualStrings(".inf", r1);
    const r2 = try stringify(allocator, .{ .float = -std.math.inf(f64) }, .{});
    defer allocator.free(r2);
    try std.testing.expectEqualStrings("-.inf", r2);
}
