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

    fn matchesVariants(s: []const u8, comptime v1: []const u8, comptime v2: []const u8, comptime v3: []const u8) bool {
        comptime {
            std.debug.assert(v1.len == v2.len and v2.len == v3.len);
        }
        if (s.len != v1.len) return false;
        return std.mem.eql(u8, s, v1) or std.mem.eql(u8, s, v2) or std.mem.eql(u8, s, v3);
    }

    pub fn isReservedWord(s: []const u8) bool {
        if (s.len == 0) return false;
        switch (s[0]) {
            'n' => return std.mem.eql(u8, s, "null"),
            'N' => return std.mem.eql(u8, s, "Null") or std.mem.eql(u8, s, "NULL"),
            '~' => return s.len == 1,
            't' => return std.mem.eql(u8, s, "true"),
            'T' => return std.mem.eql(u8, s, "True") or std.mem.eql(u8, s, "TRUE"),
            'f' => return std.mem.eql(u8, s, "false"),
            'F' => return std.mem.eql(u8, s, "False") or std.mem.eql(u8, s, "FALSE"),
            else => return false,
        }
    }

    pub fn looksLikeNumber(s: []const u8) bool {
        if (s.len == 0) return false;
        const first = s[0];
        var start: usize = 0;
        if (first == '+' or first == '-') {
            if (s.len == 1) return false;
            start = 1;
        } else if (first < '0' or first > '9') {
            if (first != '.') return false;
        }
        var seen_dot = first == '.';
        var seen_e = false;
        var seen_digit = first >= '0' and first <= '9';
        var allow_sign = false;
        for (s[start..]) |ch| {
            switch (ch) {
                '0'...'9' => {
                    seen_digit = true;
                    allow_sign = false;
                },
                '.' => {
                    if (seen_dot or seen_e) return false;
                    seen_dot = true;
                    allow_sign = false;
                },
                'e', 'E' => {
                    if (seen_e or !seen_digit) return false;
                    seen_e = true;
                    allow_sign = true;
                },
                '+', '-' => {
                    if (!allow_sign) return false;
                    allow_sign = false;
                },
                '_' => allow_sign = false,
                else => return false,
            }
        }
        return seen_digit;
    }

    fn resolveKeyword(str: []const u8) ?Value {
        if (str.len == 0) return .null;
        switch (str[0]) {
            'n' => {
                if (std.mem.eql(u8, str, "null")) return .null;
            },
            'N' => {
                if (std.mem.eql(u8, str, "Null") or std.mem.eql(u8, str, "NULL")) return .null;
                if (std.mem.eql(u8, str, "NaN")) return .{ .float = std.math.nan(f64) };
            },
            't' => {
                if (std.mem.eql(u8, str, "true")) return .{ .boolean = true };
            },
            'T' => {
                if (std.mem.eql(u8, str, "True") or std.mem.eql(u8, str, "TRUE")) return .{ .boolean = true };
            },
            'f' => {
                if (std.mem.eql(u8, str, "false")) return .{ .boolean = false };
            },
            'F' => {
                if (std.mem.eql(u8, str, "False") or std.mem.eql(u8, str, "FALSE")) return .{ .boolean = false };
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
                    new_seq.appendAssumeCapacity(try item.deepClone(allocator));
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
                    new_map.putAssumeCapacity(key, try entry.value_ptr.deepClone(allocator));
                }
                return .{ .mapping = new_map };
            },
        };
    }
};
