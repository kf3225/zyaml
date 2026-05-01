const std = @import("std");

pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    sequence: Sequence,
    mapping: Mapping,

    pub const Sequence = std.ArrayList(Value);
    pub const Mapping = std.StringArrayHashMap(Value);

    fn matchesVariants(s: []const u8, v1: []const u8, v2: []const u8, v3: []const u8) bool {
        return std.mem.eql(u8, s, v1) or std.mem.eql(u8, s, v2) or std.mem.eql(u8, s, v3);
    }

    fn tryParsePrefixedInt(str: []const u8, p1: []const u8, p2: []const u8, base: u8) ?i64 {
        if (std.mem.startsWith(u8, str, p1) or std.mem.startsWith(u8, str, p2)) {
            return std.fmt.parseInt(i64, str[2..], base) catch null;
        }
        return null;
    }

    pub fn isReservedWord(s: []const u8) bool {
        if (matchesVariants(s, "null", "Null", "NULL")) return true;
        if (std.mem.eql(u8, s, "~")) return true;
        if (matchesVariants(s, "true", "True", "TRUE")) return true;
        if (matchesVariants(s, "false", "False", "FALSE")) return true;
        return false;
    }

    pub fn looksLikeNumber(s: []const u8) bool {
        if (s.len == 0) return false;
        const first = s[0];
        if (first == '+' or first == '-') {
            if (s.len == 1) return false;
        } else if (first < '0' or first > '9') {
            if (first != '.') return false;
        }
        var seen_dot = false;
        var seen_e = false;
        var seen_digit = false;
        for (s, 0..) |ch, i| {
            switch (ch) {
                '0'...'9' => {
                    seen_digit = true;
                },
                '.' => {
                    if (seen_dot or seen_e) return false;
                    seen_dot = true;
                },
                'e', 'E' => {
                    if (seen_e or !seen_digit) return false;
                    seen_e = true;
                },
                '+', '-' => {
                    if (i == 0) continue;
                    const prev = s[i - 1];
                    if (prev != 'e' and prev != 'E') return false;
                },
                '_' => {},
                else => return false,
            }
        }
        return seen_digit;
    }

    fn resolveKeyword(str: []const u8) ?Value {
        if (str.len == 0) return .null;
        switch (str[0]) {
            'n' => {
                if (matchesVariants(str, "null", "Null", "NULL")) return .null;
            },
            'N' => {
                if (std.mem.eql(u8, str, "Null") or std.mem.eql(u8, str, "NULL")) return .null;
                if (std.mem.eql(u8, str, "NaN")) return .{ .float = std.math.nan(f64) };
            },
            't', 'T' => {
                if (matchesVariants(str, "true", "True", "TRUE")) return .{ .boolean = true };
            },
            'f', 'F' => {
                if (matchesVariants(str, "false", "False", "FALSE")) return .{ .boolean = false };
            },
            '~' => return .null,
            else => {},
        }
        return null;
    }

    fn resolveNumber(str: []const u8) ?Value {
        if (str.len == 0) return null;
        switch (str[0]) {
            '0' => {
                if (str.len == 1) return .{ .integer = 0 };
                if (resolvePrefixedInt(str)) |v| return v;
                if (std.fmt.parseInt(i64, str, 10)) |i| return .{ .integer = i } else |_| {}
            },
            '1'...'9' => {
                if (std.fmt.parseInt(i64, str, 10)) |i| return .{ .integer = i } else |_| {}
            },
            '-', '+' => {
                if (str.len == 1) return null;
                if (str[0] == '-') {
                    if (matchesVariants(str, "-.inf", "-.Inf", "-.INF")) return .{ .float = -std.math.inf(f64) };
                }
                if (resolvePrefixedInt(str)) |v| return v;
                if (std.fmt.parseInt(i64, str, 10)) |i| return .{ .integer = i } else |_| {}
            },
            '.' => {
                if (matchesVariants(str, ".inf", ".Inf", ".INF")) return .{ .float = std.math.inf(f64) };
                if (matchesVariants(str, ".nan", ".NaN", ".NAN")) return .{ .float = std.math.nan(f64) };
            },
            else => return null,
        }
        if (std.fmt.parseFloat(f64, str)) |f| return .{ .float = f } else |_| {}
        return null;
    }

    fn resolvePrefixedInt(str: []const u8) ?Value {
        if (str.len < 3) return null;
        const second = str[1];
        if (second == 'x' or second == 'X') {
            if (std.fmt.parseInt(i64, str[2..], 16)) |i| return .{ .integer = i } else |_| {}
        } else if (second == 'o' or second == 'O') {
            if (std.fmt.parseInt(i64, str[2..], 8)) |i| return .{ .integer = i } else |_| {}
        } else if (second == 'b' or second == 'B') {
            if (std.fmt.parseInt(i64, str[2..], 2)) |i| return .{ .integer = i } else |_| {}
        }
        return null;
    }

    pub fn resolveScalar(str: []const u8) Value {
        if (str.len == 0) return .null;
        if (resolveKeyword(str)) |v| return v;
        if (resolveNumber(str)) |v| return v;
        return .{ .string = str };
    }

    fn formatSequence(seq: Sequence, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        try writer.writeAll("[");
        for (seq.items, 0..) |item, i| {
            if (i > 0) try writer.writeAll(", ");
            try item.format(fmt, options, writer);
        }
        try writer.writeAll("]");
    }

    fn formatMapping(map: Mapping, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        try writer.writeAll("{");
        var iter = map.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try writer.writeAll(", ");
            first = false;
            try writer.writeAll(entry.key_ptr.*);
            try writer.writeAll(": ");
            try entry.value_ptr.format(fmt, options, writer);
        }
        try writer.writeAll("}");
    }

    pub fn format(self: Value, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .null => try writer.writeAll("null"),
            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try std.fmt.formatInt(i, 10, .lower, .{}, writer),
            .float => |f| {
                var buf: [64]u8 = undefined;
                const str = std.fmt.formatFloat(&buf, f, .{}) catch "NaN";
                try writer.writeAll(str);
            },
            .string => |s| try writer.writeAll(s),
            .sequence => |seq| try formatSequence(seq, fmt, options, writer),
            .mapping => |map| try formatMapping(map, fmt, options, writer),
        }
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .null, .boolean, .integer, .float => {},
            .string => |s| allocator.free(s),
            .sequence => |*seq| {
                for (seq.items) |*item| {
                    item.deinit(allocator);
                }
                seq.deinit();
            },
            .mapping => |*map| {
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                map.deinit();
            },
        }
    }

    pub fn deepClone(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self) {
            .null => .null,
            .boolean => |b| .{ .boolean = b },
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .sequence => |seq| {
                var new_seq = Sequence.init(allocator);
                errdefer new_seq.deinit();
                try new_seq.ensureTotalCapacity(seq.items.len);
                for (seq.items) |item| {
                    try new_seq.append(try item.deepClone(allocator));
                }
                return .{ .sequence = new_seq };
            },
            .mapping => |map| {
                var new_map = Mapping.init(allocator);
                errdefer new_map.deinit();
                try new_map.ensureTotalCapacity(map.count());
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key);
                    try new_map.put(key, try entry.value_ptr.deepClone(allocator));
                }
                return .{ .mapping = new_map };
            },
        };
    }
};
