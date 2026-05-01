const std = @import("std");
const Scanner = @import("scanner.zig").Scanner;
const Value = @import("../ast/value.zig").Value;
const YamlError = @import("../error.zig").YamlError;

const DEBUG = false;

fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (comptime DEBUG) {
        std.debug.print(fmt, args);
    }
}

pub const Parser = struct {
    allocator: std.mem.Allocator,
    scanner: Scanner,
    anchors: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .scanner = Scanner.init(source),
            .anchors = std.StringHashMap(Value).init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        var iter = self.anchors.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var val = entry.value_ptr.*;
            val.deinit(self.allocator);
        }
        self.anchors.deinit();
    }

    pub fn parse(self: *Parser) YamlError!Value {
        if (self.scanner.hasTabAtLineStart()) {
            return YamlError.TabIndentation;
        }
        try self.skipDirectives();
        self.skipDocumentStart();
        self.skipCommentsAndBlankLines();

        if (self.scanner.isEof()) return .null;

        const first_value = try self.parseValue(0);
        self.skipCommentsAndBlankLines();

        if (!self.scanner.startWith("---")) return first_value;
        return self.parseMultiDocument(first_value);
    }

    fn parseMultiDocument(self: *Parser, first_value: Value) YamlError!Value {
        var seq = Value.Sequence.init(self.allocator);
        errdefer {
            for (seq.items) |*item| item.deinit(self.allocator);
            seq.deinit();
        }
        try seq.append(first_value);

        while (self.scanner.startWith("---")) {
            self.skipDocumentSeparator();
            self.skipCommentsAndBlankLines();

            if (self.scanner.isEof()) {
                try seq.append(.null);
                break;
            }

            try seq.append(try self.parseValue(0));
            self.skipCommentsAndBlankLines();
        }

        return .{ .sequence = seq };
    }

    fn skipDocumentSeparator(self: *Parser) void {
        self.scanner.skipBytes(3);
        self.scanner.skipWhitespace();
        if (self.scanner.peek() == '\n') self.scanner.skip();
    }

    fn skipDirectives(self: *Parser) YamlError!void {
        while (!self.scanner.isEof()) {
            self.scanner.skipWhitespaceAndNewlines();
            if (self.scanner.peek() != '%') break;
            self.scanner.skip();
            if (self.scanner.startWith("YAML")) {
                try self.parseYamlVersionDirective();
            }
            self.scanner.skipLine();
        }
    }

    fn parseYamlVersionDirective(self: *Parser) YamlError!void {
        self.scanner.skipBytes(4);
        self.scanner.skipWhitespace();

        const major = self.parseVersionNumber();
        self.skipVersionMinor();

        if (major > 1) return YamlError.UnsupportedVersion;
    }

    fn parseVersionNumber(self: *Parser) usize {
        var n: usize = 0;
        while (self.scanner.peek()) |ch| {
            if (ch >= '0' and ch <= '9') {
                n = n * 10 + @as(usize, ch - '0');
                self.scanner.skip();
            } else break;
        }
        return n;
    }

    fn skipVersionMinor(self: *Parser) void {
        if (self.scanner.peek() == '.') self.scanner.skip();
        while (self.scanner.peek()) |ch| {
            if (ch >= '0' and ch <= '9') self.scanner.skip() else break;
        }
    }

    fn skipDocumentStart(self: *Parser) void {
        self.scanner.skipWhitespaceAndNewlines();
        if (self.scanner.startWith("---")) {
            self.scanner.skipBytes(3);
            self.scanner.skipWhitespace();
            if (self.scanner.peek() == '\n') {
                self.scanner.skip();
            }
        }
    }

    fn skipCommentsAndBlankLines(self: *Parser) void {
        while (!self.scanner.isEof()) {
            self.scanner.skipWhitespace();
            if (self.scanner.peek() == '#') {
                self.scanner.skipLine();
            } else if (self.scanner.peek() == '\n') {
                self.scanner.skip();
            } else {
                break;
            }
        }
    }

    fn parseValue(self: *Parser, indent: usize) YamlError!Value {
        return self.parseValueWithContext(indent, false);
    }

    fn tryScalarAsMappingKey(self: *Parser, scalar: Value, indent: usize, in_mapping_value: bool) YamlError!?Value {
        if (in_mapping_value) return null;
        self.scanner.skipWhitespace();
        if (self.scanner.peek() != ':') return null;
        const next = self.scanner.peekAt(1);
        if (next != ' ' and next != '\n' and next != null) return null;
        return self.parseBlockMappingWithKey(scalar, indent) catch |err| switch (err) {
            error.InvalidIndentation,
            error.TabIndentation,
            error.DuplicateKey,
            => err,
            else => null,
        };
    }

    fn parseValueWithContext(self: *Parser, indent: usize, in_mapping_value: bool) YamlError!Value {
        self.scanner.skipWhitespace();
        if (self.scanner.isEof()) return .null;
        const ch = self.scanner.peek() orelse return .null;

        switch (ch) {
            '[' => return self.parseFlowSequence(),
            '{' => return self.parseFlowMapping(),
            '"' => {
                const str = try self.parseDoubleQuotedScalar();
                if (try self.tryScalarAsMappingKey(str, indent, in_mapping_value)) |map| return map;
                return str;
            },
            '\'' => {
                const str = try self.parseSingleQuotedScalar();
                if (try self.tryScalarAsMappingKey(str, indent, in_mapping_value)) |map| return map;
                return str;
            },
            '|', '>' => return self.parseBlockScalar(),
            '-' => {
                if (self.scanner.peekAt(1) == ' ' or self.scanner.peekAt(1) == '\n')
                    return self.parseBlockSequence(indent);
            },
            '?' => {
                if (self.scanner.peekAt(1) == ' ') return self.parseBlockMapping(indent);
            },
            '&' => return self.parseAnchoredValue(indent),
            '*' => return self.parseAlias(),
            '!' => return self.parseTaggedValue(indent),
            '~' => {
                self.scanner.skip();
                return .null;
            },
            else => {},
        }

        if (isPlainKey(ch)) {
            const scalar = try self.parsePlainScalar(indent, in_mapping_value);
            if (try self.tryScalarAsMappingKey(scalar, indent, in_mapping_value)) |map| return map;
            return scalar;
        }

        return .null;
    }

    const plain_key_chars = blk: {
        var table: [256]bool = @splat(false);
        for ('a'..'z' + 1) |ch| table[ch] = true;
        for ('A'..'Z' + 1) |ch| table[ch] = true;
        for ('0'..'9' + 1) |ch| table[ch] = true;
        for ("_-.?:|>&!=<%@` \t") |ch| table[ch] = true;
        break :blk table;
    };

    fn isPlainKey(ch: u8) bool {
        return plain_key_chars[ch] or ch > 0x7F;
    }

    fn keyToString(self: *Parser, key_val: Value) YamlError![]const u8 {
        return switch (key_val) {
            .string => |s| s,
            else => |v| std.fmt.allocPrint(self.allocator, "{}", .{v}),
        };
    }

    fn deinitMappingEntries(self: *Parser, map: *Value.Mapping) void {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        map.deinit();
    }

    fn isNewlineContinuable(self: *Parser, saved_pos: usize, indent: usize) bool {
        const next_indent = self.scanner.countLeadingSpaces();
        if (next_indent <= 0) {
            self.scanner.pos = saved_pos;
            return false;
        }
        const next_ch = self.scanner.peekAt(next_indent) orelse {
            self.scanner.pos = saved_pos;
            return false;
        };
        if (next_ch == '#' or next_ch == '\n') {
            self.scanner.pos = saved_pos;
            return false;
        }
        if (next_ch == ':' and (self.scanner.peekAt(next_indent + 1) == ' ' or self.scanner.peekAt(next_indent + 1) == '\n')) {
            self.scanner.pos = saved_pos;
            return false;
        }
        if (next_indent < indent and next_ch == '-' and self.scanner.peekAt(next_indent + 1) == ' ') {
            self.scanner.pos = saved_pos;
            return false;
        }
        if (next_indent < indent and next_ch == '?' and self.scanner.peekAt(next_indent + 1) == ' ') {
            self.scanner.pos = saved_pos;
            return false;
        }
        if (next_indent < indent) {
            self.scanner.pos = saved_pos;
            return false;
        }
        self.scanner.skipBytes(next_indent);
        return true;
    }

    fn parsePlainScalar(self: *Parser, indent: usize, in_mapping_value: bool) YamlError!Value {
        const start_pos = self.scanner.pos;
        var has_newline = false;
        self.scanPlainScalarContent(indent, in_mapping_value, &has_newline);
        if (!has_newline) return self.resolvePlainScalarSlice(start_pos);
        return self.buildMultilinePlainScalar(start_pos, indent, in_mapping_value);
    }

    fn scanPlainScalarContent(self: *Parser, indent: usize, in_mapping_value: bool, has_newline: *bool) void {
        while (!self.scanner.isEof()) {
            const ch = self.scanner.peek() orelse break;
            if (ch == ',' or ch == ']' or ch == '}') break;
            if (ch == '\n') {
                const saved_pos = self.scanner.pos;
                self.scanner.skip();
                if (!self.isNewlineContinuable(saved_pos, indent)) break;
                has_newline.* = true;
                continue;
            }
            if (ch == ':') {
                const next = self.scanner.peekAt(1);
                if (next == ' ' or next == '\n' or next == null) {
                    if (!in_mapping_value) break;
                }
            }
            if (ch == ' ' or ch == '\t') {
                self.scanner.skip();
                while (self.scanner.peek()) |ws| {
                    if (ws == ' ' or ws == '\t') self.scanner.skip() else break;
                }
                const next = self.scanner.peek() orelse break;
                if (next == '\n') continue;
                if (next == ',' or next == ']' or next == '}') break;
                continue;
            }
            if (ch == '#') break;
            self.scanner.skip();
        }
    }

    fn resolvePlainScalarSlice(self: *Parser, start_pos: usize) YamlError!Value {
        const raw = self.scanner.source[start_pos..self.scanner.pos];
        const trimmed = std.mem.trim(u8, raw, " \t");
        const resolved = Value.resolveScalar(trimmed);
        if (resolved == .string) {
            return .{ .string = try self.allocator.dupe(u8, trimmed) };
        }
        return resolved;
    }

    fn buildMultilinePlainScalar(self: *Parser, start_pos: usize, indent: usize, in_mapping_value: bool) YamlError!Value {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();
        self.scanner.pos = start_pos;
        var first_line = true;
        while (!self.scanner.isEof()) {
            const ch = self.scanner.peek() orelse break;
            if (ch == ',' or ch == ']' or ch == '}') break;
            if (ch == '\n') {
                const saved_pos = self.scanner.pos;
                self.scanner.skip();
                if (!self.isNewlineContinuable(saved_pos, indent)) break;
                if (!first_line) try result.append(' ');
                first_line = false;
                continue;
            }
            if (ch == ':') {
                const next = self.scanner.peekAt(1);
                if (next == ' ' or next == '\n' or next == null) {
                    if (!in_mapping_value) break;
                }
            }
            if (ch == ' ' or ch == '\t') {
                try result.append(ch);
                self.scanner.skip();
                while (self.scanner.peek()) |ws| {
                    if (ws == ' ' or ws == '\t') {
                        try result.append(ws);
                        self.scanner.skip();
                    } else break;
                }
                const next = self.scanner.peek() orelse break;
                if (next == '\n') continue;
                if (next == ',' or next == ']' or next == '}') break;
                continue;
            }
            if (ch == '#') break;
            try result.append(ch);
            self.scanner.skip();
            first_line = false;
        }
        const raw = try result.toOwnedSlice();
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == raw.len) {
            const resolved = Value.resolveScalar(raw);
            if (resolved != .string) self.allocator.free(raw);
            return resolved;
        }
        const str = try self.allocator.dupe(u8, trimmed);
        self.allocator.free(raw);
        const resolved = Value.resolveScalar(str);
        if (resolved != .string) self.allocator.free(str);
        return resolved;
    }

    fn parseDoubleQuotedScalar(self: *Parser) YamlError!Value {
        std.debug.assert(self.scanner.peek() == '"');
        self.scanner.skip();

        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        while (!self.scanner.isEof()) {
            const ch = self.scanner.peek() orelse return YamlError.UnclosedScalar;

            if (ch == '"') {
                self.scanner.skip();
                const str = try result.toOwnedSlice();
                return .{ .string = str };
            }

            if (ch == '\\') {
                self.scanner.skip();
                try self.parseEscapeTo(&result);
                continue;
            }

            if (ch == '\n') {
                self.scanner.skip();
                self.scanner.skipWhitespace();
                try result.append(' ');
                continue;
            }

            try result.append(ch);
            self.scanner.skip();
        }

        return YamlError.UnclosedScalar;
    }

    fn readHexEscape(self: *Parser, comptime T: type, comptime n: usize) YamlError!T {
        var buf: [n]u8 = undefined;
        for (&buf) |*slot| {
            const h = self.scanner.peek() orelse return YamlError.InvalidEscapeSequence;
            self.scanner.skip();
            slot.* = h;
        }
        return std.fmt.parseInt(T, &buf, 16) catch YamlError.InvalidEscapeSequence;
    }

    fn appendCodepoint(result: *std.ArrayList(u8), code: anytype) YamlError!void {
        var out: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(code, &out) catch return YamlError.InvalidEscapeSequence;
        try result.appendSlice(out[0..len]);
    }

    const escape_single = blk: {
        var table: [256]?u8 = @splat(null);
        table['0'] = 0x00;
        table['a'] = 0x07;
        table['b'] = 0x08;
        table['t'] = '\t';
        table['n'] = '\n';
        table['v'] = 0x0B;
        table['f'] = 0x0C;
        table['r'] = '\r';
        table['e'] = 0x1B;
        table[' '] = ' ';
        table['"'] = '"';
        table['/'] = '/';
        table['\\'] = '\\';
        break :blk table;
    };

    const escape_multi = blk: {
        var table: [256]?[]const u8 = @splat(null);
        table['N'] = "\u{0085}";
        table['_'] = "\u{00A0}";
        table['L'] = "\u{2028}";
        table['P'] = "\u{2029}";
        break :blk table;
    };

    fn parseEscapeTo(self: *Parser, result: *std.ArrayList(u8)) YamlError!void {
        const ch = self.scanner.peek() orelse return YamlError.InvalidEscapeSequence;
        self.scanner.skip();

        if (escape_single[ch]) |byte| {
            try result.append(byte);
            return;
        }
        if (escape_multi[ch]) |slice| {
            try result.appendSlice(slice);
            return;
        }
        switch (ch) {
            'x' => {
                const code = try self.readHexEscape(u8, 2);
                try result.append(code);
            },
            'u' => {
                const code = try self.readHexEscape(u16, 4);
                try appendCodepoint(result, code);
            },
            'U' => {
                const code = try self.readHexEscape(u21, 8);
                try appendCodepoint(result, code);
            },
            '\n' => {},
            else => try result.append(ch),
        }
    }

    fn parseSingleQuotedScalar(self: *Parser) YamlError!Value {
        std.debug.assert(self.scanner.peek() == '\'');
        self.scanner.skip();

        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        while (!self.scanner.isEof()) {
            const ch = self.scanner.peek() orelse return YamlError.UnclosedScalar;

            if (ch == '\'') {
                self.scanner.skip();
                if (self.scanner.peek() == '\'') {
                    try result.append('\'');
                    self.scanner.skip();
                    continue;
                }
                const str = try result.toOwnedSlice();
                return .{ .string = str };
            }

            if (ch == '\n') {
                self.scanner.skip();
                self.scanner.skipWhitespace();
                try result.append(' ');
                continue;
            }

            try result.append(ch);
            self.scanner.skip();
        }

        return YamlError.UnclosedScalar;
    }

    const BlockScalarHeader = struct {
        chomp: enum { clip, strip, keep },
        explicit_indent: ?usize,
    };

    fn parseBlockScalarHeader(self: *Parser) BlockScalarHeader {
        var header: BlockScalarHeader = .{ .chomp = .clip, .explicit_indent = null };
        while (self.scanner.peek()) |ch| {
            if (ch == '+' or ch == '-') {
                header.chomp = if (ch == '+') .keep else .strip;
                self.scanner.skip();
            } else if (ch >= '0' and ch <= '9') {
                header.explicit_indent = 0;
                while (self.scanner.peek()) |d| {
                    if (d >= '0' and d <= '9') {
                        header.explicit_indent.? = header.explicit_indent.? * 10 + @as(usize, d - '0');
                        self.scanner.skip();
                    } else break;
                }
            } else if (ch == ' ' or ch == '\t') {
                self.scanner.skip();
            } else break;
        }
        if (self.scanner.peek() == '#') self.scanner.skipLine();
        if (self.scanner.peek() == '\n') self.scanner.skip();
        return header;
    }

    fn appendFoldedSeparator(result: *std.ArrayList(u8), trailing: usize, line_indent: usize, content_indent: usize, first: bool) !void {
        if (first) return;
        if (trailing >= 1) {
            if (line_indent > content_indent) {
                for (0..trailing + 1) |_| try result.append('\n');
            } else {
                try result.append('\n');
            }
        } else if (line_indent > content_indent) {
            try result.append('\n');
        } else {
            try result.append(' ');
        }
    }

    fn parseBlockScalar(self: *Parser) YamlError!Value {
        const indicator = self.scanner.peek().?;
        std.debug.assert(indicator == '|' or indicator == '>');
        self.scanner.skip();

        const header = self.parseBlockScalarHeader();

        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        if (self.scanner.isEof()) return .{ .string = try result.toOwnedSlice() };

        const first_line_indent = self.scanner.countLeadingSpaces();
        const content_indent = header.explicit_indent orelse first_line_indent;

        if (content_indent == 0) return .{ .string = try result.toOwnedSlice() };
        if (header.explicit_indent) |expected| {
            if (first_line_indent < expected) return YamlError.InvalidIndentation;
        }

        self.scanner.skipBytes(content_indent);

        var trailing_newlines: usize = 0;
        var first_content = true;

        while (!self.scanner.isEof()) {
            const line_indent = self.scanner.countLeadingSpaces();

            if (self.scanner.peek() == '\n') {
                trailing_newlines += 1;
                self.scanner.skip();
                first_content = false;
                continue;
            }

            if (line_indent < content_indent and !first_content) break;
            if (!first_content) self.scanner.skipBytes(line_indent);
            if (self.scanner.peek() == null) break;

            if (indicator == '>') {
                try appendFoldedSeparator(&result, trailing_newlines, line_indent, content_indent, first_content);
                trailing_newlines = 0;
            } else {
                if (!first_content) {
                    for (0..trailing_newlines + 1) |_| try result.append('\n');
                }
                trailing_newlines = 0;
            }

            const line_start = self.scanner.pos;
            while (self.scanner.peek()) |ch| {
                if (ch == '\n') break;
                self.scanner.skip();
            }
            const line_content = self.scanner.source[line_start..self.scanner.pos];

            if (indicator == '>') {
                try result.appendSlice(std.mem.trimRight(u8, line_content, " \t"));
            } else {
                try result.appendSlice(line_content);
            }

            if (self.scanner.peek() == '\n') self.scanner.skip();
            first_content = false;
        }

        switch (header.chomp) {
            .clip => if (result.items.len > 0) try result.append('\n'),
            .keep => {
                if (result.items.len > 0) try result.append('\n');
                for (0..trailing_newlines) |_| try result.append('\n');
            },
            .strip => {},
        }

        return .{ .string = try result.toOwnedSlice() };
    }

    fn parseFlowSequence(self: *Parser) YamlError!Value {
        std.debug.assert(self.scanner.peek() == '[');
        self.scanner.skip();

        var seq = Value.Sequence.init(self.allocator);
        errdefer {
            for (seq.items) |*item| item.deinit(self.allocator);
            seq.deinit();
        }

        while (!self.scanner.isEof()) {
            self.skipFlowWhitespaceAndComments();

            if (self.scanner.peek() == ']') {
                self.scanner.skip();
                return .{ .sequence = seq };
            }

            if (self.scanner.peek() == ',') {
                if (seq.items.len == 0) return YamlError.UnexpectedToken;
                self.scanner.skip();
                self.skipFlowWhitespaceAndComments();
                if (self.scanner.peek() == ']') {
                    self.scanner.skip();
                    return .{ .sequence = seq };
                }
                continue;
            }

            const val = try self.parseValue(0);
            try seq.append(val);

            self.skipFlowWhitespaceAndComments();

            if (self.scanner.peek() == ',') {
                self.scanner.skip();
                self.skipFlowWhitespaceAndComments();
                if (self.scanner.peek() == ']') {
                    self.scanner.skip();
                    return .{ .sequence = seq };
                }
                continue;
            }
        }

        return YamlError.UnclosedFlowSequence;
    }

    fn parseFlowMapping(self: *Parser) YamlError!Value {
        std.debug.assert(self.scanner.peek() == '{');
        self.scanner.skip();

        var map = Value.Mapping.init(self.allocator);
        errdefer self.deinitMappingEntries(&map);

        self.skipFlowWhitespaceAndComments();

        while (!self.scanner.isEof()) {
            self.skipFlowWhitespaceAndComments();

            if (self.scanner.peek() == '}') {
                self.scanner.skip();
                return .{ .mapping = map };
            }

            if (self.scanner.peek() == ',') {
                if (map.count() == 0) return YamlError.UnexpectedToken;
                self.scanner.skip();
                self.skipFlowWhitespaceAndComments();
                if (self.scanner.peek() == '}') {
                    self.scanner.skip();
                    return .{ .mapping = map };
                }
                continue;
            }

            const key_str = try self.keyToString(try self.parseFlowKey());

            self.scanner.skipWhitespaceAndNewlines();

            if (self.scanner.peek() != ':') {
                self.allocator.free(key_str);
                return YamlError.UnexpectedToken;
            }
            self.scanner.skip();
            self.skipFlowWhitespaceAndComments();

            var value: Value = .null;
            if (self.scanner.peek() != '}' and self.scanner.peek() != ',') {
                value = try self.parseValue(0);
            }

            try map.put(key_str, value);

            self.skipFlowWhitespaceAndComments();

            if (self.scanner.peek() == ',') {
                self.scanner.skip();
                self.skipFlowWhitespaceAndComments();
                if (self.scanner.peek() == '}') {
                    self.scanner.skip();
                    return .{ .mapping = map };
                }
                continue;
            }
        }

        return YamlError.UnclosedFlowMapping;
    }

    fn parseBlockSequence(self: *Parser, indent: usize) YamlError!Value {
        var seq = Value.Sequence.init(self.allocator);
        errdefer {
            for (seq.items) |*item| {
                item.deinit(self.allocator);
            }
            seq.deinit();
        }

        var first_item = true;

        while (!self.scanner.isEof()) {
            if (!first_item) {
                self.skipNewlines();

                const current_indent = self.scanner.countIndentAtLineStart();
                if (current_indent < indent) break;

                self.scanner.skipBytes(current_indent);
            }

            const ch = self.scanner.peek() orelse break;
            if (ch != '-') break;
            const next = self.scanner.peekAt(1);
            if (next != null and next != ' ' and next != '\n') break;

            self.scanner.skip();

            if (next == ' ') {
                self.scanner.skip();
            }

            self.scanner.skipWhitespace();

            if (self.scanner.peek() == '\n' or self.scanner.isEof()) {
                try seq.append(.null);
                if (self.scanner.peek() == '\n') self.scanner.skip();
                first_item = false;
                continue;
            }

            const val = try self.parseValue(indent + 2);
            try seq.append(val);
            first_item = false;
        }

        return .{ .sequence = seq };
    }

    fn parseFlowKey(self: *Parser) YamlError!Value {
        self.scanner.skipWhitespace();

        const ch = self.scanner.peek() orelse return .null;

        if (ch == '"') return self.parseDoubleQuotedScalar();
        if (ch == '\'') return self.parseSingleQuotedScalar();

        return self.parsePlainScalarFlowKey();
    }

    fn parsePlainScalarFlowKey(self: *Parser) YamlError!Value {
        const start_pos = self.scanner.pos;

        while (!self.scanner.isEof()) {
            const ch = self.scanner.peek() orelse break;

            if (ch == ',' or ch == ']' or ch == '}' or ch == ':') break;
            if (ch == '#' or ch == '\n') break;

            self.scanner.skip();
        }

        const raw = self.scanner.source[start_pos..self.scanner.pos];
        const resolved = Value.resolveScalar(raw);
        if (resolved == .string) {
            return .{ .string = try self.allocator.dupe(u8, raw) };
        }
        return resolved;
    }

    fn skipCommentsInFlow(self: *Parser) void {
        while (self.scanner.peek() == '#') {
            self.scanner.skipLine();
            self.scanner.skipWhitespace();
        }
    }

    fn skipNewlines(self: *Parser) void {
        while (self.scanner.peek() == '\n') self.scanner.skip();
    }

    fn hasInlineValue(self: *Parser) bool {
        return self.scanner.peek() != '\n' and !self.scanner.isEof();
    }

    fn skipFlowWhitespaceAndComments(self: *Parser) void {
        self.scanner.skipWhitespaceAndNewlines();
        self.skipCommentsInFlow();
    }

    fn parseBlockMapping(self: *Parser, indent: usize) YamlError!Value {
        _ = self.scanner.skip();
        _ = self.scanner.skip();

        var map = Value.Mapping.init(self.allocator);
        errdefer self.deinitMappingEntries(&map);

        self.scanner.skipWhitespace();
        var key = try self.parseValue(indent + 2);
        errdefer key.deinit(self.allocator);

        while (self.scanner.peek() == '\n') {
            self.scanner.skip();
        }
        const current_indent = self.scanner.countIndentAtLineStart();
        if (current_indent == indent and self.scanner.peek() == ':') {
            self.scanner.skip();
            self.scanner.skipWhitespace();
        } else {
            self.scanner.skipWhitespace();
            if (self.scanner.peek() != ':') return YamlError.UnexpectedToken;
            self.scanner.skip();
            self.scanner.skipWhitespace();
        }

        var value: Value = .null;
        if (self.hasInlineValue()) {
            value = try self.parseValueWithContext(indent + 2, true);
        } else if (self.scanner.peek() == '\n') {
            self.scanner.skip();
            self.skipNewlines();
            const val_indent = self.scanner.countIndentAtLineStart();
            if (val_indent > indent) {
                const spaces = self.scanner.countLeadingSpaces();
                self.scanner.skipBytes(spaces);
                value = try self.parseValueWithContext(val_indent, true);
            }
        }

        const key_str = try self.keyToString(key);
        if (key != .string) {
            key.deinit(self.allocator);
        } else {
            key = .null;
        }
        errdefer self.allocator.free(key_str);
        try map.put(key_str, value);
        return .{ .mapping = map };
    }

    fn parseBlockMappingWithKey(self: *Parser, key_val: Value, indent: usize) YamlError!Value {
        var map = Value.Mapping.init(self.allocator);
        errdefer self.deinitMappingEntries(&map);

        const key_str = try self.keyToString(key_val);

        std.debug.assert(self.scanner.peek() == ':');
        self.scanner.skip();
        self.scanner.skipWhitespace();

        const value = try self.parseEntryValueAfterColon(indent, key_str);
        try map.put(key_str, value);

        try self.parseNextMappingEntries(&map, indent);
        return .{ .mapping = map };
    }

    fn parseEntryValueAfterColon(self: *Parser, indent: usize, key_str: []const u8) YamlError!Value {
        if (self.hasInlineValue()) {
            return self.parseValueWithContext(indent + 2, true) catch |err| {
                self.allocator.free(key_str);
                return err;
            };
        }

        if (self.scanner.peek() == '\n') self.scanner.skip();
        self.skipNewlines();

        if (self.scanner.hasTabAtLineStart()) {
            self.allocator.free(key_str);
            return YamlError.TabIndentation;
        }

        const next_indent = self.scanner.countIndentAtLineStart();
        if (next_indent > indent) {
            // YAML 1.2: 1-space indent after colon is ambiguous
            if (next_indent - indent == 1) {
                self.allocator.free(key_str);
                return YamlError.InvalidIndentation;
            }
            const leading_spaces = self.scanner.countLeadingSpaces();
            self.scanner.skipBytes(leading_spaces);
            return self.parseValueWithContext(next_indent, false) catch |err| {
                self.allocator.free(key_str);
                return err;
            };
        }

        if (next_indent == indent) {
            const leading_spaces = self.scanner.countLeadingSpaces();
            self.scanner.skipBytes(leading_spaces);
            const ch = self.scanner.peek() orelse 0;
            if (ch == '-' and (self.scanner.peekAt(1) == ' ' or self.scanner.peekAt(1) == '\n')) {
                return self.parseBlockSequence(indent) catch |err| {
                    self.allocator.free(key_str);
                    return err;
                };
            }
            self.scanner.pos -= leading_spaces;
        }
        return .null;
    }

    fn parseNextMappingEntries(self: *Parser, map: *Value.Mapping, indent: usize) YamlError!void {
        while (!self.scanner.isEof()) {
            self.skipNewlines();

            const current_indent = self.scanner.countIndentAtLineStart();
            if (current_indent != indent) break;

            if (self.scanner.startWith("---") or self.scanner.startWith("...")) break;

            const leading_spaces = self.scanner.countLeadingSpaces();
            self.scanner.skipBytes(leading_spaces);

            if (!isPlainKey(self.scanner.peek() orelse 0)) break;

            const next_key_str = try self.keyToString(try self.parsePlainScalar(indent, false));

            self.scanner.skipWhitespace();
            if (self.scanner.peek() != ':') {
                self.allocator.free(next_key_str);
                break;
            }
            self.scanner.skip();
            self.scanner.skipWhitespace();

            const next_value = try self.parseNextEntryValue(indent);

            const gop = try map.getOrPut(next_key_str);
            if (gop.found_existing) {
                self.allocator.free(next_key_str);
                if (next_value != .null) {
                    var nv = next_value;
                    nv.deinit(self.allocator);
                }
                return YamlError.DuplicateKey;
            }
            gop.value_ptr.* = next_value;
        }
    }

    fn parseNextEntryValue(self: *Parser, indent: usize) YamlError!Value {
        if (self.hasInlineValue()) {
            return self.parseValue(indent + 2);
        }

        if (self.scanner.peek() == '\n') self.scanner.skip();
        self.skipNewlines();

        const val_indent = self.scanner.countIndentAtLineStart();
        if (val_indent > indent) {
            const spaces = self.scanner.countLeadingSpaces();
            self.scanner.skipBytes(spaces);
            return self.parseValue(val_indent);
        }
        if (val_indent == indent) {
            const spaces = self.scanner.countLeadingSpaces();
            self.scanner.skipBytes(spaces);
            const ch = self.scanner.peek() orelse 0;
            if (ch == '-' and (self.scanner.peekAt(1) == ' ' or self.scanner.peekAt(1) == '\n')) {
                return self.parseBlockSequence(indent);
            }
            self.scanner.pos -= spaces;
        }
        return .null;
    }

    fn readAnchorName(self: *Parser) YamlError![]const u8 {
        var anchor_name = std.ArrayList(u8).init(self.allocator);
        errdefer anchor_name.deinit();

        while (self.scanner.peek()) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                try anchor_name.append(ch);
                self.scanner.skip();
            } else break;
        }

        return anchor_name.toOwnedSlice();
    }

    fn parseAnchoredValue(self: *Parser, indent: usize) YamlError!Value {
        std.debug.assert(self.scanner.peek() == '&');
        self.scanner.skip();

        const anchor = try self.readAnchorName();

        self.scanner.skipWhitespace();

        try self.anchors.put(anchor, .{ .sequence = Value.Sequence.init(self.allocator) });

        const value = self.parseValue(indent) catch |err| {
            if (self.anchors.fetchRemove(anchor)) |removed| {
                self.allocator.free(removed.key);
            }
            self.allocator.free(anchor);
            return err;
        };

        _ = self.anchors.fetchRemove(anchor);

        const cloned = try value.deepClone(self.allocator);
        try self.anchors.put(anchor, cloned);

        return value;
    }

    fn parseAlias(self: *Parser) YamlError!Value {
        std.debug.assert(self.scanner.peek() == '*');
        self.scanner.skip();

        const anchor = try self.readAnchorName();
        defer self.allocator.free(anchor);

        if (self.anchors.get(anchor)) |value| {
            return value.deepClone(self.allocator);
        }

        return YamlError.UnknownAlias;
    }

    fn parseTaggedValue(self: *Parser, indent: usize) YamlError!Value {
        std.debug.assert(self.scanner.peek() == '!');
        self.scanner.skip();

        var is_str_tag = false;
        if (self.scanner.peek() == '!') {
            self.scanner.skip();
            if (self.scanner.peek() == 's') {
                if (self.scanner.startWith("str") or self.scanner.startWith("str ")) {
                    is_str_tag = true;
                    self.scanner.skipBytes(3);
                }
            }
        }

        while (self.scanner.peek()) |ch| {
            if (ch == ' ' or ch == '\n') break;
            self.scanner.skip();
        }

        self.scanner.skipWhitespace();

        if (is_str_tag) {
            return self.parseAsString(indent);
        }
        return self.parseValue(indent);
    }

    fn parseAsString(self: *Parser, indent: usize) YamlError!Value {
        const ch = self.scanner.peek() orelse return .null;

        if (ch == '"') {
            return self.parseDoubleQuotedScalar();
        }
        if (ch == '\'') {
            return self.parseSingleQuotedScalar();
        }

        return self.parsePlainScalarAsString(indent);
    }

    fn parsePlainScalarAsString(self: *Parser, indent: usize) YamlError!Value {
        _ = indent;
        const start_pos = self.scanner.pos;

        while (!self.scanner.isEof()) {
            const ch = self.scanner.peek() orelse break;

            if (ch == ',' or ch == ']' or ch == '}' or ch == '\n') break;
            if (ch == '#') break;
            if (ch == ':') {
                const next = self.scanner.peekAt(1);
                if (next == ' ' or next == '\n' or next == null) break;
            }

            self.scanner.skip();
        }

        const raw = self.scanner.source[start_pos..self.scanner.pos];
        const trimmed = std.mem.trim(u8, raw, " \t");
        const str = try self.allocator.dupe(u8, trimmed);
        return .{ .string = str };
    }
};
