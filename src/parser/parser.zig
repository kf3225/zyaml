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

const MAX_DEPTH = 256;
const MAX_ALIAS_CLONES = 1000;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    scanner: Scanner,
    anchors: std.StringHashMap(Value),
    building_anchors: std.ArrayList([]const u8),
    depth: usize,
    alias_clone_count: usize,
    flow_depth: usize,
    flow_start_line: usize,
    flow_start_column: usize,
    flow_block_indent: usize,
    has_yaml_directive: bool,
    had_document: bool,
    quoted_scalar_indent: usize,
    tag_handles: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .scanner = Scanner.init(source),
            .anchors = std.StringHashMap(Value).init(allocator),
            .building_anchors = std.ArrayList([]const u8).init(allocator),
            .depth = 0,
            .alias_clone_count = 0,
            .flow_depth = 0,
            .flow_start_line = 0,
            .flow_start_column = 0,
            .flow_block_indent = 0,
            .has_yaml_directive = false,
            .had_document = false,
            .quoted_scalar_indent = 0,
            .tag_handles = std.StringHashMap([]const u8).init(allocator),
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
        for (self.building_anchors.items) |key| self.allocator.free(key);
        self.building_anchors.deinit();
        self.clearTagHandles();
    }

    pub fn parse(self: *Parser) YamlError!Value {
        try self.skipDirectives();
        const first_marker = self.skipDocumentStart();
        self.skipCommentsAndBlankLines();
        if (!first_marker) _ = self.skipDocumentStart();

        if (self.scanner.isEof()) {
            if (self.has_yaml_directive and !self.had_document) return YamlError.UnexpectedToken;
            return .null;
        }

        if (self.scanner.peek() == '%') return YamlError.UnexpectedToken;

        if (first_marker and self.scanner.peek() == '&') {
            var scan = self.scanner.pos;
            while (scan < self.scanner.source.len) : (scan += 1) {
                const c = self.scanner.source[scan];
                if (c == '\n') break;
                if (c == ':') {
                    if (scan + 1 < self.scanner.source.len) {
                        const after = self.scanner.source[scan + 1];
                        if (after == ' ' or after == '\t' or after == '\n') {
                            return YamlError.UnexpectedToken;
                        }
                    }
                }
            }
        }

        if (!self.scanner.isEof()) {
            const ch = self.scanner.peek() orelse return .null;
            if (ch != '[' and ch != '{' and ch != '-' and ch != '?') {
                try self.checkTabIndent();
            }
        }

        if (self.isDocStart() or self.isDocEnd()) {
            if (self.isDocEnd() and !self.isDocStart() and self.has_yaml_directive) return YamlError.UnexpectedToken;
            return self.parseMultiDocument(.null);
        }

        const first_value = try self.parseValue(0);
        self.had_document = true;
        self.skipCommentsAndBlankLines();

        if (self.scanner.isEof()) return first_value;

        if (self.isDocStart()) {
            return self.parseMultiDocument(first_value);
        }
        if (self.isDocEnd()) {
            self.scanner.skipBytes(3);
            self.scanner.skipWhitespace();
            const after = self.scanner.peek();
            if (after != null and after != '\n' and after != '#') {
                var fv = first_value;
                fv.deinit(self.allocator);
                return YamlError.UnexpectedToken;
            }
            self.scanner.skipLine();
            self.skipCommentsAndBlankLines();
            if (!self.scanner.isEof()) {
                return self.parseMultiDocument(first_value);
            }
            return first_value;
        }
        var first = first_value;
        first.deinit(self.allocator);
        return YamlError.UnexpectedToken;
    }

    fn parseMultiDocument(self: *Parser, first_value: Value) YamlError!Value {
        var seq = Value.Sequence.init(self.allocator);
        errdefer {
            for (seq.items) |*item| item.deinit(self.allocator);
            seq.deinit();
        }
        try seq.append(first_value);

        if (!self.scanner.isEof() and !self.isDocStart() and !self.isDocEnd() and self.scanner.peek() != '%') {
            try seq.append(try self.parseValue(0));
            self.skipCommentsAndBlankLines();
        }

        while (self.isDocStart() or self.isDocEnd() or self.scanner.peek() == '%') {
            if (self.scanner.peek() == '%') {
                self.has_yaml_directive = false;
                try self.skipDirectives();
                self.skipCommentsAndBlankLines();
                if (!self.isDocStart()) break;
                self.skipDocumentSeparator();
                self.skipCommentsAndBlankLines();
                if (self.scanner.isEof()) {
                    try seq.append(.null);
                    break;
                }
                if (self.isDocStart() or self.isDocEnd()) {
                    try seq.append(.null);
                    continue;
                }
                try seq.append(try self.parseValue(0));
                self.skipCommentsAndBlankLines();
                continue;
            }
            if (self.isDocEnd()) {
                self.scanner.skipBytes(3);
                self.scanner.skipWhitespace();
                const after = self.scanner.peek();
                if (after != null and after != '\n' and after != '#') {
                    self.scanner.skipLine();
                    self.skipCommentsAndBlankLines();
                    if (!self.isDocStart()) {
                        try seq.append(try self.parseValue(0));
                        self.skipCommentsAndBlankLines();
                        continue;
                    }
                    self.skipDocumentSeparator();
                    self.skipCommentsAndBlankLines();
                    if (self.scanner.isEof()) {
                        try seq.append(.null);
                        break;
                    }
                    try seq.append(try self.parseValue(0));
                    self.skipCommentsAndBlankLines();
                    continue;
                }
                self.scanner.skipLine();
                self.skipCommentsAndBlankLines();
                try self.skipDirectives();
                self.skipCommentsAndBlankLines();
                if (!self.isDocStart() and !self.isDocEnd()) {
                    if (!self.scanner.isEof() and self.scanner.peek() != null and self.scanner.peek() != '\n') {
                        try seq.append(try self.parseValue(0));
                        self.skipCommentsAndBlankLines();
                        continue;
                    }
                    break;
                }
                continue;
            }
            self.skipDocumentSeparator();
            try self.skipDirectives();
            self.skipCommentsAndBlankLines();

            if (self.scanner.isEof()) {
                try seq.append(.null);
                break;
            }

            if (self.isDocStart() or self.isDocEnd()) {
                try seq.append(.null);
                continue;
            }

            try seq.append(try self.parseValue(0));
            self.skipCommentsAndBlankLines();
        }

        if (seq.items.len == 1) {
            const single = seq.items[0];
            seq.deinit();
            return single;
        }

        return .{ .sequence = seq };
    }

    fn isDocBoundaryTerminator(ch: ?u8) bool {
        return ch == null or ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
    }

    fn isDocStart(self: *Parser) bool {
        if (!self.scanner.startWith("---")) return false;
        return isDocBoundaryTerminator(self.scanner.peekAt(3));
    }

    fn isDocEnd(self: *Parser) bool {
        if (!self.scanner.startWith("...")) return false;
        return isDocBoundaryTerminator(self.scanner.peekAt(3));
    }

    fn clearTagHandles(self: *Parser) void {
        var it = self.tag_handles.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.tag_handles.clearAndFree();
    }

    fn skipDirectives(self: *Parser) YamlError!void {
        self.has_yaml_directive = false;
        self.clearTagHandles();
        while (!self.scanner.isEof()) {
            self.scanner.skipWhitespaceAndNewlines();
            if (self.scanner.peek() != '%') break;
            self.scanner.skip();
            if (self.scanner.startWith("YAML") and
                (self.scanner.peekAt(4) == ' ' or self.scanner.peekAt(4) == '\t'))
            {
                if (self.has_yaml_directive) return YamlError.UnexpectedToken;
                self.has_yaml_directive = true;
                try self.parseYamlVersionDirective();
            }
            if (self.scanner.startWith("TAG") and
                (self.scanner.peekAt(3) == ' '))
            {
                try self.parseTagDirective();
            }
            self.scanner.skipLine();
        }
    }

    fn parseYamlVersionDirective(self: *Parser) YamlError!void {
        self.scanner.skipBytes(4);
        const ws_start = self.scanner.pos;
        self.scanner.skipWhitespace();
        if (self.scanner.pos == ws_start) return YamlError.UnexpectedToken;

        const major = self.parseVersionNumber();
        self.skipVersionMinor();

        if (major > 1) return YamlError.UnsupportedVersion;

        const ws2_start = self.scanner.pos;
        self.scanner.skipWhitespace();
        const ch = self.scanner.peek() orelse return;
        if (ch == '#' and self.scanner.pos == ws2_start) return YamlError.UnexpectedToken;
        if (ch != '#' and ch != '\n' and ch != '\r') return YamlError.UnexpectedToken;
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

    fn parseTagDirective(self: *Parser) YamlError!void {
        self.scanner.skipBytes(3);
        self.scanner.skipWhitespace();
        const handle_start = self.scanner.pos;
        while (self.scanner.peek()) |ch| {
            if (ch == ' ') break;
            self.scanner.skip();
        }
        const handle = self.scanner.source[handle_start..self.scanner.pos];
        if (handle.len == 0 or handle[0] != '!') return YamlError.UnexpectedToken;
        self.scanner.skipWhitespace();
        const prefix_start = self.scanner.pos;
        while (self.scanner.peek()) |ch| {
            if (ch == ' ' or ch == '\n' or ch == '#') break;
            self.scanner.skip();
        }
        const prefix = self.scanner.source[prefix_start..self.scanner.pos];
        if (prefix.len == 0) return YamlError.UnexpectedToken;
        const handle_copy = try self.allocator.dupe(u8, handle);
        const prefix_copy = try self.allocator.dupe(u8, prefix);
        const existing = try self.tag_handles.fetchPut(handle_copy, prefix_copy);
        if (existing) |e| {
            self.allocator.free(e.key);
            self.allocator.free(e.value);
        }
    }

    fn skipDocumentStart(self: *Parser) bool {
        if (!self.scanner.startWith("---")) return false;
        if (!isDocBoundaryTerminator(self.scanner.peekAt(3))) return false;
        self.had_document = true;
        self.scanner.skipBytes(3);
        self.scanner.skipWhitespace();
        if (self.scanner.peek() == '\n') self.scanner.skip();
        return true;
    }

    fn skipDocumentSeparator(self: *Parser) void {
        self.scanner.skipBytes(3);
        self.scanner.skipWhitespace();
        if (self.scanner.peek() == '\n') self.scanner.skip();
    }

    fn skipInlineComment(self: *Parser) void {
        if (self.scanner.peek() == '#') {
            self.scanner.skipLine();
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

    fn checkTabIndent(self: *Parser) YamlError!void {
        if (self.scanner.hasTabAsLeadingIndent()) return YamlError.TabIndentation;
    }

    fn skipBlankLinesAndComments(self: *Parser) void {
        while (!self.scanner.isEof()) {
            const indent = self.scanner.countIndentAtLineStart();
            const pos = self.scanner.line_start + indent;
            if (pos >= self.scanner.source.len) break;
            const ch = self.scanner.source[pos];
            if (ch == '\n') {
                self.scanner.pos = pos + 1;
                self.scanner.line += 1;
                self.scanner.column = 1;
                self.scanner.line_start = pos + 1;
            } else if (ch == '#') {
                self.scanner.pos = pos;
                self.scanner.skipLine();
            } else if (ch == '\t') {
                var check = pos;
                while (check < self.scanner.source.len and self.scanner.source[check] != '\n') {
                    if (self.scanner.source[check] != ' ' and self.scanner.source[check] != '\t') break;
                    check += 1;
                }
                if (check < self.scanner.source.len and self.scanner.source[check] == '\n') {
                    self.scanner.pos = pos;
                    self.scanner.skipLine();
                } else {
                    break;
                }
            } else {
                break;
            }
        }
    }

    fn parseValue(self: *Parser, indent: usize) YamlError!Value {
        return self.parseValueWithContext(indent, false);
    }

    fn parseValueAsEntry(self: *Parser, indent: usize) YamlError!Value {
        return self.parseValueWithContext(indent, true);
    }

    fn tryScalarAsMappingKey(self: *Parser, scalar: Value, indent: usize, in_mapping_value: bool) YamlError!?Value {
        if (in_mapping_value) return null;
        const saved_pos = self.scanner.pos;
        const saved_column = self.scanner.column;
        const at_line_start = saved_pos == self.scanner.line_start;
        self.scanner.skipWhitespace();
        if (self.scanner.peek() != ':') {
            if (at_line_start) {
                self.scanner.pos = saved_pos;
                self.scanner.column = saved_column;
            }
            return null;
        }
        switch (scalar) {
            .sequence, .mapping => {
                if (self.flow_depth == 0 and self.scanner.line != self.flow_start_line) return YamlError.UnexpectedToken;
            },
            else => {},
        }
        const next = self.scanner.peekAt(1);
        if (next != ' ' and next != '\t' and next != '\n' and next != null) {
            if (self.flow_depth == 0) return null;
        }
        return self.parseBlockMappingWithKey(scalar, indent) catch |err| switch (err) {
            error.InvalidIndentation,
            error.TabIndentation,
            error.DuplicateKey,
            error.UnexpectedToken,
            error.UnclosedScalar,
            => err,
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        };
    }

    fn tryAsMappingOrReturn(self: *Parser, value: Value, indent: usize, in_mapping_value: bool) YamlError!Value {
        const map = self.tryScalarAsMappingKey(value, indent, in_mapping_value) catch |err| {
            var v = value;
            v.deinit(self.allocator);
            return err;
        };
        if (map) |m| return m;
        return value;
    }

    fn parseValueWithContext(self: *Parser, indent: usize, in_mapping_value: bool) YamlError!Value {
        if (self.depth >= MAX_DEPTH) return YamlError.InvalidDocument;
        self.depth += 1;
        defer self.depth -= 1;
        self.quoted_scalar_indent = indent;

        self.scanner.skipWhitespace();
        if (self.scanner.isEof()) return .null;
        const ch = self.scanner.peek() orelse return .null;

        switch (ch) {
            '[' => {
                if (self.flow_depth == 0) self.flow_block_indent = indent;
                return self.tryAsMappingOrReturn(try self.parseFlowSequence(), indent, in_mapping_value);
            },
            '{' => {
                if (self.flow_depth == 0) self.flow_block_indent = indent;
                return self.tryAsMappingOrReturn(try self.parseFlowMapping(), indent, in_mapping_value);
            },
            '"' => return self.tryAsMappingOrReturn(try self.parseDoubleQuotedScalar(), indent, in_mapping_value),
            '\'' => return self.tryAsMappingOrReturn(try self.parseSingleQuotedScalar(), indent, in_mapping_value),
            '|', '>' => return self.parseBlockScalar(indent),
            '-' => {
                const next = self.scanner.peekAt(1);
                if (next == null or next == ' ' or next == '\t' or next == '\n')
                    return self.parseBlockSequence(indent);
                if (self.flow_depth > 0 and !(next != null and next.? >= '0' and next.? <= '9'))
                    return YamlError.UnexpectedToken;
            },
            '?' => {
                if (self.scanner.peekAt(1) == ' ' or self.scanner.peekAt(1) == '\t' or self.scanner.peekAt(1) == '\n')
                    return self.parseBlockMapping(indent);
            },
            '&' => return self.tryAsMappingOrReturn(try self.parseAnchoredValue(indent), indent, in_mapping_value),
            '*' => return self.tryAsMappingOrReturn(try self.parseAlias(), indent, in_mapping_value),
            '!' => return self.tryAsMappingOrReturn(try self.parseTaggedValue(indent), indent, in_mapping_value),
            '~' => {
                self.scanner.skip();
                return .null;
            },
            else => {},
        }

        if (isPlainKey(ch)) {
            return self.tryAsMappingOrReturn(try self.parsePlainScalar(indent), indent, in_mapping_value);
        }

        if (self.flow_depth > 0) return YamlError.UnexpectedToken;
        return .null;
    }

    const plain_key_chars = blk: {
        var table: [256]bool = @splat(false);
        for ('a'..'z' + 1) |ch| table[ch] = true;
        for ('A'..'Z' + 1) |ch| table[ch] = true;
        for ('0'..'9' + 1) |ch| table[ch] = true;
        for ("_-.?:|>&!=<%@` \t/") |ch| table[ch] = true;
        break :blk table;
    };

    fn isPlainKey(ch: u8) bool {
        return plain_key_chars[ch] or ch > 0x7F;
    }

    fn keyToString(self: *Parser, key_val: Value) YamlError![]const u8 {
        return switch (key_val) {
            .string => |s| self.allocator.dupe(u8, s),
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
        if (next_indent < indent) {
            self.scanner.pos = saved_pos;
            return false;
        }
        if (next_indent == 0 and indent == 0) {
            const next_ch = self.scanner.peek() orelse {
                self.scanner.pos = saved_pos;
                return false;
            };
            if (next_ch == '-' and self.scanner.startWith("---") and
                (self.scanner.peekAt(3) == null or self.scanner.peekAt(3) == ' ' or self.scanner.peekAt(3) == '\t' or self.scanner.peekAt(3) == '\n' or self.scanner.peekAt(3) == '\r'))
            {
                self.scanner.pos = saved_pos;
                return false;
            }
            if (next_ch == '.' and self.scanner.startWith("...") and
                (self.scanner.peekAt(3) == null or self.scanner.peekAt(3) == ' ' or self.scanner.peekAt(3) == '\t' or self.scanner.peekAt(3) == '\n' or self.scanner.peekAt(3) == '\r'))
            {
                self.scanner.pos = saved_pos;
                return false;
            }
        }
        if (next_indent == 0 and indent > 0) {
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
        if (next_ch == ':' and (self.scanner.peekAt(next_indent + 1) == ' ' or self.scanner.peekAt(next_indent + 1) == '\t' or self.scanner.peekAt(next_indent + 1) == '\n')) {
            self.scanner.pos = saved_pos;
            return false;
        }
        if (next_ch == '-' and (self.scanner.peekAt(next_indent + 1) == ' ' or self.scanner.peekAt(next_indent + 1) == '\t' or self.scanner.peekAt(next_indent + 1) == '\n') and next_indent < indent) {
            self.scanner.pos = saved_pos;
            return false;
        }
        if (next_ch == '?' and self.scanner.peekAt(next_indent + 1) == ' ') {
            self.scanner.pos = saved_pos;
            return false;
        }
        if (self.flow_depth == 0) {
            var scan = self.scanner.pos + next_indent;
            while (scan < self.scanner.source.len) : (scan += 1) {
                const c = self.scanner.source[scan];
                if (c == '\n') break;
                if (c == ':') {
                    if (scan + 1 < self.scanner.source.len) {
                        const after = self.scanner.source[scan + 1];
                        if (after == ' ' or after == '\t' or after == '\n') {
                            self.scanner.pos = saved_pos;
                            return false;
                        }
                    }
                }
            }
        }
        self.scanner.skipKnownSpaces(next_indent);
        return true;
    }

    const ScalarWriter = union(enum) {
        counter,
        builder: *std.ArrayList(u8),

        fn writeByte(self: ScalarWriter, byte: u8) !void {
            if (self == .builder) try self.builder.append(byte);
        }

        fn writeSlice(self: ScalarWriter, slice: []const u8) !void {
            if (self == .builder) try self.builder.appendSlice(slice);
        }
    };

    fn isLineBlank(self: *Parser) bool {
        var pos = self.scanner.pos;
        while (pos < self.scanner.source.len) : (pos += 1) {
            const c = self.scanner.source[pos];
            if (c == '\n') return true;
            if (c != ' ' and c != '\t') return false;
        }
        return true;
    }

    fn scanPlainScalar(self: *Parser, writer: ScalarWriter, indent: usize, cont_indent: usize) YamlError!bool {
        var has_newline = false;
        var first_line = true;
        while (!self.scanner.isEof()) {
            const ch = self.scanner.peek() orelse break;
            if (self.flow_depth > 0 and (ch == ',' or ch == ']' or ch == '}')) break;
            if (ch == '\n') {
                const saved_pos = self.scanner.pos;
                self.scanner.skip();
                if (self.scanner.peek() == '\n') {
                    has_newline = true;
                    first_line = false;
                    var blank_count: usize = 0;
                    while (self.scanner.peek() == '\n') {
                        self.scanner.skip();
                        if (self.scanner.countLeadingSpaces() >= cont_indent) {
                            blank_count += 1;
                        } else if (self.scanner.peek() != null and self.scanner.peek() != '\n') {
                            break;
                        }
                    }
                    if (self.scanner.peek() == '\n' or self.scanner.isEof()) {
                        self.scanner.pos = saved_pos;
                        break;
                    }
                    if (self.scanner.countLeadingSpaces() < cont_indent) {
                        self.scanner.pos = saved_pos;
                        break;
                    }
                    for (0..blank_count) |_| {
                        try writer.writeByte('\n');
                    }
                    self.scanner.skipWhitespace();
                    continue;
                }
                const line_start_pos = self.scanner.pos;
                if (!self.isNewlineContinuable(saved_pos, cont_indent)) {
                    self.scanner.pos = saved_pos;
                    break;
                }
                if (self.isLineBlank()) {
                    self.scanner.pos = line_start_pos;
                    if (!self.isNewlineContinuable(saved_pos, indent)) {
                        self.scanner.pos = saved_pos;
                        break;
                    }
                }
                has_newline = true;
                first_line = false;
                self.scanner.skipWhitespace();
                if (self.scanner.peek() == '\n') {
                    try writer.writeByte('\n');
                    const inner_saved = self.scanner.pos;
                    self.scanner.skip();
                    if (!self.isNewlineContinuable(inner_saved, indent)) {
                        self.scanner.pos = inner_saved;
                        break;
                    }
                    self.scanner.skipWhitespace();
                    while (self.scanner.peek() == '\n') {
                        try writer.writeByte('\n');
                        const blank_saved = self.scanner.pos;
                        self.scanner.skip();
                        if (!self.isNewlineContinuable(blank_saved, indent)) {
                            self.scanner.pos = blank_saved;
                            break;
                        }
                        self.scanner.skipWhitespace();
                    }
                } else {
                    try writer.writeByte(' ');
                }
                continue;
            }
            if (ch == ':') {
                const next = self.scanner.peekAt(1);
                if (next == ' ' or next == '\t' or next == '\n' or next == null) break;
            }
            if (ch == ' ' or ch == '\t') {
                self.scanner.skipWhitespace();
                const next = self.scanner.peek() orelse break;
                if (next == '\n') continue;
                if (next == ',' or next == ']' or next == '}') break;
                if (next == '#') {
                    const prev = self.scanner.source[self.scanner.pos - 1];
                    if (prev == ' ' or prev == '\t') break;
                }
                if (next == ':') {
                    const after = self.scanner.peekAt(1);
                    if (after == ' ' or after == '\t' or after == '\n' or after == null) break;
                }
                try writer.writeByte(' ');
                continue;
            }
            if (ch == '#') {
                if (self.scanner.pos > 0) {
                    const prev = self.scanner.source[self.scanner.pos - 1];
                    if (prev == ' ' or prev == '\t') break;
                } else break;
            }
            try writer.writeByte(ch);
            self.scanner.skip();
            first_line = false;
        }
        return has_newline;
    }

    fn parsePlainScalar(self: *Parser, indent: usize) YamlError!Value {
        const cont_indent: usize = if (indent > 0) indent - 1 else 0;
        const start_pos = self.scanner.pos;
        const has_newline = try self.scanPlainScalar(.counter, indent, cont_indent);
        if (!has_newline) return self.resolvePlainScalarSlice(start_pos);

        self.scanner.pos = start_pos;
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();
        _ = try self.scanPlainScalar(.{ .builder = &result }, indent, cont_indent);

        const raw = try result.toOwnedSlice();
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == raw.len) {
            const resolved = Value.resolveScalar(raw);
            if (resolved != .string) self.allocator.free(raw);
            return resolved;
        }
        const resolved = Value.resolveScalar(trimmed);
        if (resolved != .string) {
            self.allocator.free(raw);
            return resolved;
        }
        const duped = try self.allocator.dupe(u8, trimmed);
        self.allocator.free(raw);
        return .{ .string = duped };
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

    fn foldQuotedNewline(self: *Parser, result: *std.ArrayList(u8), strip_trailing: bool) YamlError!void {
        if (strip_trailing) {
            while (result.items.len > 0 and (result.items[result.items.len - 1] == ' ' or result.items[result.items.len - 1] == '\t')) {
                _ = result.pop();
            }
        }
        self.scanner.skip();
        const ws_start = self.scanner.pos;
        self.scanner.skipWhitespace();
        const after_ws = self.scanner.peek() orelse 0;
        if (after_ws == '\n') {
            try result.append('\n');
            self.scanner.skip();
            self.scanner.skipWhitespace();
            return;
        }
        if ((after_ws == '"' or after_ws == '\'') and result.items.len > 0 and result.items[result.items.len - 1] == '\n') {
            try result.append('\n');
            return;
        }
        if (self.flow_depth == 0 and self.quoted_scalar_indent > 0) {
            var has_tab = false;
            var space_count: usize = 0;
            for (self.scanner.source[ws_start..self.scanner.pos]) |c| {
                if (c == '\t') has_tab = true;
                if (c == ' ') space_count += 1;
            }
            if (has_tab and space_count < self.quoted_scalar_indent) return YamlError.TabIndentation;
        }
        if (self.flow_depth == 0 and self.scanner.column <= 1) {
            if (self.scanner.startWith("---") and isDocBoundaryTerminator(self.scanner.peekAt(3))) return YamlError.UnclosedScalar;
            if (self.scanner.startWith("...") and isDocBoundaryTerminator(self.scanner.peekAt(3))) return YamlError.UnclosedScalar;
            if (self.quoted_scalar_indent > 0) return YamlError.UnclosedScalar;
        }
        if (result.items.len > 0 and result.items[result.items.len - 1] != '\n') {
            try result.append(' ');
        } else if (result.items.len == 0) {
            try result.append(' ');
        }
    }

    fn ensureValidAfterScalar(self: *Parser) YamlError!void {
        const ch = self.scanner.peek() orelse return;
        if (self.flow_depth > 0) {
            if (ch != ',' and ch != ']' and ch != '}' and ch != ':' and ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r')
                return YamlError.UnexpectedToken;
        } else {
            if (ch == ':') {
                const next = self.scanner.peekAt(1);
                if (next == ' ' or next == '\t' or next == '\n' or next == '\r' or next == null) return;
            }
            if (ch == ' ' or ch == '\t') {
                const saved = self.scanner.pos;
                self.scanner.skipWhitespace();
                const after = self.scanner.peek();
                if (after == '#' or after == '\n' or after == '\r' or after == null) {
                    return;
                }
                if (after == ':') {
                    const next2 = self.scanner.peekAt(1);
                    if (next2 == ' ' or next2 == '\t' or next2 == '\n' or next2 == '\r' or next2 == null) {
                        self.scanner.pos = saved;
                        return;
                    }
                }
                self.scanner.pos = saved;
                return YamlError.UnexpectedToken;
            }
            if (ch == '\n' or ch == '\r') return;
            return YamlError.UnexpectedToken;
        }
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
                try self.ensureValidAfterScalar();
                const str = try result.toOwnedSlice();
                return .{ .string = str };
            }

            if (ch == '\\') {
                self.scanner.skip();
                try self.parseEscapeTo(&result);
                continue;
            }

            if (ch == '\n') {
                const nl_pos = self.scanner.pos;
                var src_ws: usize = 0;
                while (src_ws < nl_pos) {
                    const prev = self.scanner.source[nl_pos - 1 - src_ws];
                    if (prev == ' ' or prev == '\t') src_ws += 1 else break;
                }
                if (src_ws > 0 and nl_pos > src_ws) {
                    const before_ws = self.scanner.source[nl_pos - 1 - src_ws];
                    if (before_ws == '\\') src_ws -|= 1;
                }
                while (src_ws > 0 and result.items.len > 0) {
                    const last = result.items[result.items.len - 1];
                    if (last == ' ' or last == '\t') {
                        _ = result.pop();
                        src_ws -= 1;
                    } else break;
                }
                try self.foldQuotedNewline(&result, false);
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
        table['\t'] = '\t';
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
            '\n' => {
                self.scanner.skipWhitespace();
            },
            else => return YamlError.InvalidEscapeSequence,
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
                try self.ensureValidAfterScalar();
                const str = try result.toOwnedSlice();
                return .{ .string = str };
            }

            if (ch == '\n') {
                try self.foldQuotedNewline(&result, true);
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

    fn parseBlockScalarHeader(self: *Parser) YamlError!BlockScalarHeader {
        var header: BlockScalarHeader = .{ .chomp = .clip, .explicit_indent = null };
        var has_space = false;
        while (self.scanner.peek()) |ch| {
            if (ch == '+' or ch == '-') {
                header.chomp = if (ch == '+') .keep else .strip;
                self.scanner.skip();
                has_space = false;
            } else if (ch >= '0' and ch <= '9') {
                const digit: usize = @intCast(ch - '0');
                if (digit == 0) return YamlError.InvalidIndentation;
                self.scanner.skip();
                if (header.explicit_indent != null) return YamlError.UnexpectedToken;
                header.explicit_indent = digit;
                has_space = false;
            } else if (ch == ' ' or ch == '\t') {
                self.scanner.skip();
                has_space = true;
            } else break;
        }
        if (self.scanner.peek() == '#' and has_space) {
            self.scanner.skipLine();
        } else if (self.scanner.peek() == '\n') {
            self.scanner.skip();
        } else if (self.scanner.peek() != null) {
            return YamlError.UnexpectedToken;
        }
        return header;
    }

    fn appendFoldedSeparator(result: *std.ArrayList(u8), trailing: usize, first: bool, extra_sep: bool) !void {
        if (first and trailing == 0) return;
        if (trailing >= 1) {
            const extra: usize = if (!first and extra_sep) 1 else 0;
            try result.appendNTimes('\n', trailing + extra);
        } else if (first) {
            return;
        } else if (extra_sep) {
            try result.append('\n');
        } else {
            try result.append(' ');
        }
    }

    fn readRestOfLine(self: *Parser) []const u8 {
        const start = self.scanner.pos;
        const remaining = self.scanner.source[start..];
        const end = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
        self.scanner.pos += end;
        self.scanner.column += end;
        return self.scanner.source[start..self.scanner.pos];
    }

    fn parseBlockScalar(self: *Parser, parent_indent: usize) YamlError!Value {
        const indicator = self.scanner.peek().?;
        std.debug.assert(indicator == '|' or indicator == '>');
        self.scanner.skip();

        const header = try self.parseBlockScalarHeader();

        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        if (self.scanner.isEof()) return .{ .string = try result.toOwnedSlice() };

        var content_indent: usize = if (header.explicit_indent) |ei| (parent_indent -| 2) + ei else 0;
        var indent_detected = header.explicit_indent != null;
        var trailing_newlines: usize = 0;
        var first_content = true;
        var max_blank_indent: usize = 0;
        var prev_line_extra = false;

        while (!self.scanner.isEof()) {
            const line_indent = self.scanner.countLeadingSpaces();
            const pre_skip = self.scanner.pos;
            const pre_column = self.scanner.column;
            const tab_pos = self.scanner.pos + line_indent;
            const tab_content = tab_pos < self.scanner.source.len and self.scanner.source[tab_pos] == '\t';
            if (indent_detected and line_indent > content_indent) {
                self.scanner.skipKnownSpaces(content_indent);
            } else {
                self.scanner.skipKnownSpaces(line_indent);
            }

            if (self.scanner.isEof()) {
                if (indent_detected and line_indent >= content_indent) {
                    if (line_indent > content_indent) {
                        if (!first_content) try result.appendNTimes('\n', trailing_newlines + 1);
                        try result.appendNTimes(' ', line_indent - content_indent);
                        first_content = false;
                    }
                    trailing_newlines += 1;
                } else if (!indent_detected and line_indent > 0) {
                    trailing_newlines += 1;
                }
                break;
            }
            if (line_indent == 0 and (self.scanner.startWith("---") or self.scanner.startWith("..."))) {
                if (isDocBoundaryTerminator(self.scanner.peekAt(3))) {
                    self.scanner.pos = pre_skip;
                    break;
                }
            }
            if (self.scanner.peek() == '\n') {
                if (!indent_detected) {
                    trailing_newlines += 1;
                    if (line_indent > max_blank_indent) max_blank_indent = line_indent;
                } else if (line_indent > content_indent) {
                    if (!first_content) try result.appendNTimes('\n', trailing_newlines + 1);
                    trailing_newlines = 0;
                    const extra = line_indent - content_indent;
                    try result.appendNTimes(' ', extra);
                    first_content = false;
                } else {
                    trailing_newlines += 1;
                }
                self.scanner.skip();
                continue;
            }

            if (!indent_detected) {
                if (line_indent == 0 and parent_indent > 0 and !tab_content) break;
                if (tab_content and line_indent == 0 and parent_indent > 0) {
                    const after_tab = self.scanner.peekAt(1);
                    if (after_tab == '\n' or after_tab == null) return YamlError.TabIndentation;
                }
                if (max_blank_indent > 0 and max_blank_indent > line_indent) {
                    return YamlError.InvalidIndentation;
                }
                content_indent = @max(line_indent, max_blank_indent);
                indent_detected = true;
                if (trailing_newlines > 0) {
                    try result.appendNTimes('\n', trailing_newlines);
                    trailing_newlines = 0;
                }
            } else if (line_indent < content_indent) {
                self.scanner.pos = pre_skip;
                self.scanner.column = pre_column;
                break;
            }

            if (header.explicit_indent) |expected| {
                if (line_indent < expected) return YamlError.InvalidIndentation;
            }

            if (indicator == '>') {
                const current_extra = line_indent > content_indent or tab_content;
                try appendFoldedSeparator(&result, trailing_newlines, first_content, prev_line_extra or current_extra);
            } else if (!first_content) {
                try result.appendNTimes('\n', trailing_newlines + 1);
            }
            trailing_newlines = 0;
            prev_line_extra = line_indent > content_indent or tab_content;

            const line_content = self.readRestOfLine();
            try result.appendSlice(line_content);

            if (self.scanner.peek() == '\n') self.scanner.skip();
            first_content = false;
        }

        switch (header.chomp) {
            .clip => if (result.items.len > 0) try result.append('\n'),
            .keep => {
                if (result.items.len > 0) try result.append('\n');
                try result.appendNTimes('\n', trailing_newlines);
            },
            .strip => {},
        }

        return .{ .string = try result.toOwnedSlice() };
    }

    fn ensureValidAfterFlowClose(self: *Parser) YamlError!void {
        if (self.flow_depth > 1) return;
        const ch = self.scanner.peek() orelse return;
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or
            ch == ',' or ch == ']' or ch == '}' or ch == ':' or ch == '%')
            return;
        if (ch == '#' and self.scanner.pos > 0) {
            const prev = self.scanner.source[self.scanner.pos - 1];
            if (prev == ' ' or prev == '\t') return;
        }
        return YamlError.UnexpectedToken;
    }

    fn parseFlowSequence(self: *Parser) YamlError!Value {
        std.debug.assert(self.scanner.peek() == '[');
        const start_column = self.scanner.column;
        self.scanner.skip();
        const start_line = self.scanner.line;
        if (self.flow_depth == 0) {
            self.flow_start_line = start_line;
            self.flow_start_column = start_column;
        }
        self.flow_depth += 1;
        errdefer self.flow_depth -= 1;

        var seq = Value.Sequence.init(self.allocator);
        errdefer {
            for (seq.items) |*item| item.deinit(self.allocator);
            seq.deinit();
        }

        while (!self.scanner.isEof()) {
            try self.skipFlowWhitespaceAndComments();

            if (self.scanner.peek() == ']') {
                self.scanner.skip();
                try self.ensureValidAfterFlowClose();
                self.flow_depth -= 1;
                return .{ .sequence = seq };
            }

            if (self.scanner.peek() == ',') {
                if (seq.items.len == 0) return YamlError.UnexpectedToken;
                self.scanner.skip();
                try self.skipFlowWhitespaceAndComments();
                if (self.scanner.peek() == ',') return YamlError.UnexpectedToken;
                if (self.scanner.peek() == ']') {
                    self.scanner.skip();
                    try self.ensureValidAfterFlowClose();
                    self.flow_depth -= 1;
                    return .{ .sequence = seq };
                }
                continue;
            }

            const val = try self.parseValue(0);
            try seq.append(val);

            try self.skipFlowWhitespaceAndComments();
            if (self.scanner.peek() == ',') {
                self.scanner.skip();
                try self.skipFlowWhitespaceAndComments();
                if (self.scanner.peek() == ',') return YamlError.UnexpectedToken;
                if (self.scanner.peek() == ']') {
                    self.scanner.skip();
                    try self.ensureValidAfterFlowClose();
                    self.flow_depth -= 1;
                    return .{ .sequence = seq };
                }
                continue;
            } else if (self.scanner.peek() == ']') {
                self.scanner.skip();
                try self.ensureValidAfterFlowClose();
                self.flow_depth -= 1;
                return .{ .sequence = seq };
            } else if (seq.items.len > 0) {
                return YamlError.UnexpectedToken;
            }
        }

        return YamlError.UnclosedFlowSequence;
    }

    fn parseFlowMapping(self: *Parser) YamlError!Value {
        std.debug.assert(self.scanner.peek() == '{');
        const start_column = self.scanner.column;
        self.scanner.skip();
        if (self.flow_depth == 0) {
            self.flow_start_line = self.scanner.line;
            self.flow_start_column = start_column;
        }
        self.flow_depth += 1;
        errdefer self.flow_depth -= 1;

        var map = Value.Mapping.init(self.allocator);
        errdefer self.deinitMappingEntries(&map);

        try self.skipFlowWhitespaceAndComments();

        while (!self.scanner.isEof()) {
            try self.skipFlowWhitespaceAndComments();

            if (self.scanner.peek() == '}') {
                self.scanner.skip();
                try self.ensureValidAfterFlowClose();
                self.flow_depth -= 1;
                return .{ .mapping = map };
            }

            if (self.scanner.peek() == ',') {
                if (map.count() == 0) return YamlError.UnexpectedToken;
                if (try self.skipTrailingComma('}')) {
                    try self.ensureValidAfterFlowClose();
                    self.flow_depth -= 1;
                    return .{ .mapping = map };
                }
                continue;
            }

            const key_val = try self.parseFlowKey();
            const key_str = try self.keyToString(key_val);
            var kv = key_val;
            kv.deinit(self.allocator);

            try self.skipFlowWhitespaceAndComments();

            if (self.scanner.peek() == ',' or self.scanner.peek() == '}') {
                try map.put(key_str, .null);
                continue;
            }
            if (self.scanner.peek() != ':') {
                self.allocator.free(key_str);
                return YamlError.UnexpectedToken;
            }
            self.scanner.skip();
            try self.skipFlowWhitespaceAndComments();

            var value: Value = .null;
            if (self.scanner.peek() != '}' and self.scanner.peek() != ',') {
                value = try self.parseValueAsEntry(0);
            }

            try map.put(key_str, value);

            try self.skipFlowWhitespaceAndComments();
            const saved_pos = self.scanner.pos;
            if (try self.skipTrailingComma('}')) {
                self.flow_depth -= 1;
                return .{ .mapping = map };
            }
            if (self.scanner.pos == saved_pos and self.scanner.peek() != null and self.scanner.peek() != '}') {
                return YamlError.UnexpectedToken;
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
        var seq_indent = indent;

        while (!self.scanner.isEof()) {
            if (!first_item) {
                self.skipInlineComment();
                self.skipNewlines();
                self.skipBlankLinesAndComments();

                if (self.scanner.isEof()) break;

                const current_indent = self.scanner.countIndentAtLineStart();
                if (current_indent < seq_indent) break;
                if (current_indent > seq_indent) return YamlError.InvalidIndentation;

                try self.checkTabIndent();
                self.scanner.skipKnownSpaces(current_indent);
            }

            const ch = self.scanner.peek() orelse break;
            if (ch != '-') break;
            const next = self.scanner.peekAt(1);
            if (next != null and next != ' ' and next != '\t' and next != '\n') break;

            if (first_item) seq_indent = self.scanner.column - 1;

            self.scanner.skip();

            if (next == ' ' or next == '\t') {
                self.scanner.skip();
            }

            var saw_tab = next == '\t';
            while (self.scanner.peek()) |c| {
                if (c == ' ') {
                    self.scanner.skip();
                } else if (c == '\t') {
                    saw_tab = true;
                    self.scanner.skip();
                } else break;
            }
            if (saw_tab) {
                const p = self.scanner.peek() orelse 0;
                if (p == '-' or p == '?' or p == ':' or p == '|' or p == '>') {
                    const p2 = self.scanner.peekAt(1);
                    if (p2 == ' ' or p2 == '\t' or p2 == '\n' or p2 == null)
                        return YamlError.TabIndentation;
                }
            }

            self.scanner.skipWhitespace();

            if (self.scanner.peek() == '#') {
                self.scanner.skipLine();
                self.skipNewlines();
                const next_indent = self.scanner.countIndentAtLineStart();
                if (next_indent > seq_indent) {
                    self.scanner.skipKnownSpaces(next_indent);
                    const val = try self.parseValueWithContext(next_indent, false);
                    try seq.append(val);
                    first_item = false;
                    continue;
                }
                try seq.append(.null);
                first_item = false;
                continue;
            }

            if (self.scanner.peek() == '\n') {
                self.scanner.skip();
                self.skipNewlines();
                const next_indent = self.scanner.countIndentAtLineStart();
                if (next_indent > seq_indent) {
                    self.scanner.skipKnownSpaces(next_indent);
                    const val = try self.parseValueWithContext(next_indent, false);
                    try seq.append(val);
                    first_item = false;
                    continue;
                }
                try seq.append(.null);
                first_item = false;
                continue;
            }

            if (self.scanner.isEof()) {
                try seq.append(.null);
                first_item = false;
                continue;
            }

            const content_indent = self.scanner.column - 1;
            const val = try self.parseValue(content_indent);
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
        if (ch == '[') return self.parseFlowSequence();
        if (ch == '{') return self.parseFlowMapping();
        if (ch == '&') {
            const anchored = try self.parseAnchoredValue(0);
            self.scanner.skipWhitespace();
            return anchored;
        }
        if (ch == '*') {
            const alias_val = try self.parseAlias();
            self.scanner.skipWhitespace();
            return alias_val;
        }
        if (ch == '!') {
            const saved = self.scanner.pos;
            const tagged = try self.parseTaggedValue(0);
            self.scanner.skipWhitespace();
            if (self.scanner.peek() == ':') return tagged;
            var tv = tagged;
            tv.deinit(self.allocator);
            self.scanner.pos = saved;
        }

        return self.parsePlainScalarFlowKey();
    }

    fn parsePlainScalarFlowKey(self: *Parser) YamlError!Value {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        while (!self.scanner.isEof()) {
            const ch = self.scanner.peek() orelse break;

            if (ch == ',' or ch == ']' or ch == '}' or ch == ':') break;
            if (ch == '#') break;
            if (ch == '\n') {
                if (self.flow_depth == 0) break;
                self.scanner.skip();
                self.scanner.skipWhitespace();
                const next = self.scanner.peek() orelse break;
                if (next == ',' or next == ']' or next == '}' or next == ':' or next == '#') break;
                try result.append(' ');
                continue;
            }

            try result.append(ch);
            self.scanner.skip();
        }

        const trimmed = std.mem.trimRight(u8, result.items, " \t");
        const resolved = Value.resolveScalar(trimmed);
        if (resolved == .string) {
            const duped = try self.allocator.dupe(u8, trimmed);
            result.deinit();
            return .{ .string = duped };
        }
        result.deinit();
        return resolved;
    }

    fn skipCommentsInFlow(self: *Parser) void {
        while (self.scanner.peek() == '#') {
            if (self.scanner.pos > 0) {
                const prev = self.scanner.source[self.scanner.pos - 1];
                if (prev != ' ' and prev != '\t' and prev != '\n') return;
            }
            self.scanner.skipLine();
            self.scanner.skipWhitespace();
        }
    }

    fn skipNewlines(self: *Parser) void {
        while (self.scanner.peek() == '\n') self.scanner.skip();
    }

    fn skipTrailingComma(self: *Parser, close: u8) !bool {
        if (self.scanner.peek() != ',') return false;
        self.scanner.skip();
        try self.skipFlowWhitespaceAndComments();
        if (self.scanner.peek() == close) {
            self.scanner.skip();
            return true;
        }
        return false;
    }

    fn hasInlineValue(self: *Parser) bool {
        const ch = self.scanner.peek() orelse return false;
        return ch != '\n' and ch != '#';
    }

    fn skipFlowWhitespaceAndComments(self: *Parser) !void {
        if (self.flow_depth == 0 or self.flow_block_indent == 0) {
            self.scanner.skipWhitespaceAndNewlines();
            self.skipCommentsInFlow();
            return;
        }
        while (!self.scanner.isEof()) {
            const ch = self.scanner.peek() orelse break;
            if (ch == ' ' or ch == '\t') {
                self.scanner.skip();
                continue;
            }
            if (ch == '\n') {
                self.scanner.skip();
                const ws_start = self.scanner.pos;
                self.scanner.skipWhitespace();
                if (!self.scanner.isEof()) {
                    const next = self.scanner.peek() orelse break;
                    if (next != ']' and next != '}' and next != '#' and next != '\n') {
                        if (self.scanner.column < self.flow_block_indent) return YamlError.InvalidIndentation;
                        if (self.scanner.column == self.flow_block_indent) {
                            for (self.scanner.source[ws_start..self.scanner.pos]) |c| {
                                if (c == '\t') return YamlError.TabIndentation;
                            }
                        }
                    }
                }
                continue;
            }
            if (ch == '#') {
                self.skipInlineComment();
                continue;
            }
            break;
        }
    }

    fn parseExplicitKeyPart(self: *Parser, indent: usize) YamlError!Value {
        if (self.scanner.peek() == ' ') self.scanner.skip();
        if (self.scanner.peek() == '\t') return YamlError.TabIndentation;
        if (self.hasInlineValue()) {
            const val = try self.parseValueWithContext(indent + 2, true);
            if (self.hasTrailingColonOnLine()) {
                const is_inline = self.scanner.pos > 0 and
                    self.scanner.source[self.scanner.pos - 1] != '\n';
                if (self.flow_depth == 0 and is_inline) {
                    return self.buildInlineMappingKey(val, indent);
                }
                return val;
            }
            return self.tryAsMappingOrReturn(val, indent, false);
        }
        if (self.scanner.peek() == '#') self.skipInlineComment();
        self.skipNewlines();
        self.skipBlankLinesAndComments();
        const key_indent = self.scanner.countIndentAtLineStart();
        if (key_indent < indent) return .null;
        self.scanner.skipKnownSpaces(key_indent);
        const val = try self.parseValueWithContext(key_indent, true);
        if (self.hasTrailingColonOnLine()) {
            const is_inline = self.scanner.pos > 0 and
                    self.scanner.source[self.scanner.pos - 1] != '\n';
            if (self.flow_depth == 0 and is_inline) {
                return self.buildInlineMappingKey(val, indent);
            }
            return val;
        }
        return self.tryAsMappingOrReturn(val, indent, false);
    }

    fn buildInlineMappingKey(self: *Parser, key_val: Value, indent: usize) YamlError!Value {
        self.scanner.skipWhitespace();
        std.debug.assert(self.scanner.peek() == ':');
        self.scanner.skip();
        self.scanner.skipWhitespace();
        const inner_val = if (self.hasInlineValue())
            try self.parseValueWithContext(indent + 2, true)
        else
            Value.null;
        var map = Value.Mapping.init(self.allocator);
        errdefer self.deinitMappingEntries(&map);
        const key_str = try self.keyToString(key_val);
        var kv = key_val;
        kv.deinit(self.allocator);
        try map.put(key_str, inner_val);
        return .{ .mapping = map };
    }

    fn parseExplicitValuePart(self: *Parser, indent: usize) YamlError!Value {
        std.debug.assert(self.scanner.peek() == ':');
        self.scanner.skip();
        if (self.scanner.peek() == '\t') return YamlError.TabIndentation;
        self.scanner.skipWhitespace();
        return self.parseEntryValueAfterColon(indent, true);
    }

    fn parseBlockMapping(self: *Parser, indent: usize) YamlError!Value {
        std.debug.assert(self.scanner.peek() == '?');
        self.scanner.skip();

        var map = Value.Mapping.init(self.allocator);
        errdefer self.deinitMappingEntries(&map);

        var key = try self.parseExplicitKeyPart(indent);
        var key_consumed = false;
        errdefer if (!key_consumed) key.deinit(self.allocator);

        self.skipCommentsAndBlankLines();
        var value: Value = .null;

        if (self.scanner.countIndentAtLineStart() == indent and self.scanner.peek() == ':') {
            value = try self.parseExplicitValuePart(indent);
        } else if (self.scanner.peek() == ':') {
            self.scanner.skip();
            self.scanner.skipWhitespace();
            if (self.hasInlineValue()) {
                value = try self.parseValueWithContext(indent + 2, true);
            }
        }

        const key_str = try self.keyToString(key);
        var kv = key;
        kv.deinit(self.allocator);
        key_consumed = true;

        errdefer self.allocator.free(key_str);
        try map.put(key_str, value);
        try self.parseNextMappingEntries(&map, indent);
        return .{ .mapping = map };
    }

    fn parseBlockMappingWithKey(self: *Parser, key_val: Value, indent: usize) YamlError!Value {
        var map = Value.Mapping.init(self.allocator);
        errdefer self.deinitMappingEntries(&map);

        const key_str = try self.keyToString(key_val);
        var key_in_map = false;
        errdefer if (!key_in_map) self.allocator.free(key_str);

        std.debug.assert(self.scanner.peek() == ':');
        self.scanner.skip();
        self.scanner.skipWhitespace();

        const value = try self.parseEntryValueAfterColon(indent, false);
        try map.put(key_str, value);
        key_in_map = true;

        try self.parseNextMappingEntries(&map, indent);

        var kv = key_val;
        kv.deinit(self.allocator);

        return .{ .mapping = map };
    }

    fn isNextAnchorOnOwnLine(self: *Parser) bool {
        if (self.scanner.peek() != '&') return false;
        const saved = self.scanner.pos;
        self.scanner.skip();
        while (self.scanner.peek()) |ch| {
            if (ch == ' ' or ch == '\n') break;
            self.scanner.skip();
        }
        if (self.scanner.peek() == '\n' or self.scanner.isEof()) {
            self.scanner.pos = saved;
            return true;
        }
        while (self.scanner.peek()) |ch| {
            if (ch == ' ') {
                self.scanner.skip();
            } else break;
        }
        const result = self.scanner.peek() == '#' or self.scanner.isEof();
        self.scanner.pos = saved;
        return result;
    }

    fn hasTrailingColonOnLine(self: *Parser) bool {
        var pos = self.scanner.pos;
        while (pos < self.scanner.source.len) : (pos += 1) {
            const ch = self.scanner.source[pos];
            if (ch == ':') {
                if (pos + 1 >= self.scanner.source.len) return true;
                const next = self.scanner.source[pos + 1];
                return next == ' ' or next == '\t' or next == '\n';
            }
            if (ch == ' ' or ch == '\t') continue;
            return false;
        }
        return false;
    }

    fn parseEntryValueAfterColon(self: *Parser, indent: usize, allow_mapping: bool) YamlError!Value {
        if (self.hasInlineValue()) {
            if (self.isNextAnchorOnOwnLine()) {
                return self.parseAnchoredValue(indent + 1);
            }
            if (!allow_mapping) {
                const ch = self.scanner.peek() orelse 0;
                if (ch == '-' and (self.scanner.peekAt(1) == ' ' or self.scanner.peekAt(1) == '\t' or self.scanner.peekAt(1) == '\n')) {
                    return YamlError.UnexpectedToken;
                }
            }
            const value = try self.parseValueWithContext(indent + 2, true);
            if (self.hasTrailingColonOnLine()) {
                if (allow_mapping) return self.tryAsMappingOrReturn(value, indent, false);
                var v = value;
                v.deinit(self.allocator);
                return YamlError.UnexpectedToken;
            }
            return value;
        }

        if (self.scanner.peek() == '#') {
            self.scanner.skipLine();
        }
        self.skipNewlines();
        self.skipBlankLinesAndComments();

        const next_indent = self.scanner.countIndentAtLineStart();
        if (next_indent > indent) {
            self.scanner.skipKnownSpaces(next_indent);
            if (self.scanner.peek() == '&') blk: {
                const saved = self.scanner.pos;
                const anchor_val = self.parseAnchoredValue(next_indent) catch {
                    self.scanner.pos = saved;
                    break :blk;
                };
                if (anchor_val != .null) return anchor_val;
                const after_indent = self.scanner.countIndentAtLineStart();
                if (after_indent == indent) {
                    self.scanner.skipKnownSpaces(after_indent);
                    const ch = self.scanner.peek() orelse break :blk;
                    if (ch == '-' and (self.scanner.peekAt(1) == ' ' or self.scanner.peekAt(1) == '\t' or self.scanner.peekAt(1) == '\n')) {
                        const seq = try self.parseBlockSequence(indent);
                        var anchor_it = self.anchors.iterator();
                        while (anchor_it.next()) |entry| {
                            if (entry.value_ptr.* == .null) {
                                const name = try self.allocator.dupe(u8, entry.key_ptr.*);
                                const removed = self.anchors.fetchRemove(entry.key_ptr.*) orelse unreachable;
                                self.allocator.free(removed.key);
                                var rv = removed.value;
                                rv.deinit(self.allocator);
                                const cloned = try seq.deepClone(self.allocator);
                                try self.anchors.put(name, cloned);
                                break;
                            }
                        }
                        return seq;
                    }
                    self.scanner.pos -= after_indent;
                }
                break :blk;
            }
            return self.parseValueWithContext(next_indent, false);
        }

        if (next_indent == indent) {
            self.scanner.skipKnownSpaces(next_indent);
            const ch = self.scanner.peek() orelse 0;
            if (ch == '-' and (self.scanner.peekAt(1) == ' ' or self.scanner.peekAt(1) == '\t' or self.scanner.peekAt(1) == '\n')) {
                return self.parseBlockSequence(indent);
            }
            self.scanner.pos -= next_indent;
        }
        return .null;
    }

    fn mergeSubMapping(self: *Parser, map: *Value.Mapping, sub: Value) YamlError!void {
        var owned = sub;
        var iter = owned.mapping.iterator();
        while (iter.next()) |entry| {
            const gop = try map.getOrPut(entry.key_ptr.*);
            if (gop.found_existing) {
                entry.value_ptr.*.deinit(self.allocator);
                self.allocator.free(entry.key_ptr.*);
                return YamlError.DuplicateKey;
            }
            gop.value_ptr.* = entry.value_ptr.*;
        }
        owned.mapping.deinit();
    }

    const EntryAction = enum { consumed, skip };

    fn skipToEntry(self: *Parser, indent: usize) ?usize {
        self.skipNewlines();
        self.skipInlineComment();
        self.skipBlankLinesAndComments();
        if (self.scanner.isEof()) return null;
        const current_indent = self.scanner.countIndentAtLineStart();
        if (current_indent != indent) return null;
        if (self.scanner.startWith("---") or self.scanner.startWith("...")) return null;
        return current_indent;
    }

    fn tryExplicitKeyEntry(self: *Parser, map: *Value.Mapping, indent: usize) YamlError!EntryAction {
        if (self.scanner.peek() != '?') return .skip;
        const next = self.scanner.peekAt(1);
        if (next != ' ' and next != '\t') return .skip;
        const sub = try self.parseBlockMapping(indent);
        try self.mergeSubMapping(map, sub);
        return .consumed;
    }

    fn tryInlineAnchorKey(self: *Parser, map: *Value.Mapping, indent: usize) YamlError!EntryAction {
        if (self.scanner.peek() != '&') return .skip;
        self.scanner.skip();
        const anchor_name = try self.readAnchorName();
        errdefer self.allocator.free(anchor_name);
        self.scanner.skipWhitespace();
        if (self.scanner.peek() == '*') return YamlError.AnchorOnAlias;

        const key_val = try self.parseValueWithContext(indent, true);
        const akey = try self.keyToString(key_val);
        var kv = key_val;
        kv.deinit(self.allocator);

        self.scanner.skipWhitespace();
        var val: Value = .null;
        if (self.scanner.peek() == ':') {
            self.scanner.skip();
            self.scanner.skipWhitespace();
            val = try self.parseEntryValueAfterColon(indent, false);
        }

        if (self.anchors.fetchRemove(anchor_name)) |removed| {
            self.allocator.free(removed.key);
            var rv = removed.value;
            rv.deinit(self.allocator);
        }
        const cloned = try val.deepClone(self.allocator);
        errdefer {
            var cv = cloned;
            cv.deinit(self.allocator);
        }
        try self.anchors.put(anchor_name, cloned);
        try map.put(akey, val);
        return .consumed;
    }

    fn tryBareColonKey(self: *Parser, map: *Value.Mapping, indent: usize) YamlError!EntryAction {
        if (self.scanner.peek() != ':') return .skip;
        const next = self.scanner.peekAt(1);
        if (next != ' ' and next != '\n' and next != null) return .skip;
        self.scanner.skip();
        self.scanner.skipWhitespace();
        const colon_val = try self.parseEntryValueAfterColon(indent, false);
        try map.put(try self.allocator.dupe(u8, ""), colon_val);
        return .consumed;
    }

    fn tryQuotedKeyEntry(self: *Parser, map: *Value.Mapping, indent: usize, quote: u8) YamlError!EntryAction {
        const saved = self.scanner.pos;
        var has_newline = false;
        self.scanner.skip();
        while (self.scanner.peek()) |c| {
            if (c == quote) {
                self.scanner.skip();
                break;
            }
            if (c == '\n') {
                has_newline = true;
                break;
            }
            if (c == '\\' and quote == '"' and self.scanner.peekAt(1) != null) self.scanner.skip();
            self.scanner.skip();
        }
        if (has_newline) {
            self.scanner.pos = saved;
            return .skip;
        }
        self.scanner.pos = saved;
        const scalar = if (quote == '"') try self.parseDoubleQuotedScalar() else try self.parseSingleQuotedScalar();
        const qkey = try self.keyToString(scalar);
        var qs = scalar;
        qs.deinit(self.allocator);
        self.scanner.skipWhitespace();
        if (self.scanner.peek() != ':') {
            self.allocator.free(qkey);
            return .skip;
        }
        self.scanner.skip();
        self.scanner.skipWhitespace();
        const qval = try self.parseEntryValueAfterColon(indent, false);
        try map.put(qkey, qval);
        return .consumed;
    }

    fn tryAnchorAliasKeyEntry(self: *Parser, map: *Value.Mapping, indent: usize) YamlError!EntryAction {
        const peek_ch = self.scanner.peek() orelse return .skip;
        if (peek_ch != '&' and peek_ch != '*') return .skip;
        const saved = self.scanner.pos;
        self.scanner.skip();
        while (self.scanner.peek()) |c| {
            if (c == ' ' or c == '\t' or c == '\n') break;
            self.scanner.skip();
        }
        self.scanner.skipWhitespace();
        const is_key = self.scanner.peek() == ':';
        self.scanner.pos = saved;
        if (!is_key) return .skip;

        const key_val = if (peek_ch == '&') try self.parseAnchoredValue(indent) else try self.parseAlias();
        const key_str = try self.keyToString(key_val);
        var kv = key_val;
        kv.deinit(self.allocator);
        self.scanner.skipWhitespace();
        std.debug.assert(self.scanner.peek() == ':');
        self.scanner.skip();
        self.scanner.skipWhitespace();
        const val = try self.parseEntryValueAfterColon(indent, false);
        try map.put(key_str, val);
        return .consumed;
    }

    fn tryTaggedKeyEntry(self: *Parser, map: *Value.Mapping, indent: usize) YamlError!EntryAction {
        if (self.scanner.peek() != '!') return .skip;
        const saved = self.scanner.pos;
        const tagged_val = try self.parseTaggedValue(indent);
        var tv = tagged_val;
        const tkey = try self.keyToString(tv);
        tv.deinit(self.allocator);
        self.scanner.skipWhitespace();
        if (self.scanner.peek() != ':') {
            self.allocator.free(tkey);
            self.scanner.pos = saved;
            return .skip;
        }
        self.scanner.skip();
        self.scanner.skipWhitespace();
        const tval = try self.parseNextEntryValue(indent);
        try map.put(tkey, tval);
        return .consumed;
    }

    fn tryAliasKeyEntry(self: *Parser, map: *Value.Mapping, indent: usize) YamlError!EntryAction {
        if (self.scanner.peek() != '*') return .skip;
        const alias_key = try self.parseAlias();
        const alkey = try self.keyToString(alias_key);
        var alk = alias_key;
        alk.deinit(self.allocator);
        self.scanner.skipWhitespace();
        if (self.scanner.peek() != ':') {
            self.allocator.free(alkey);
            return .skip;
        }
        self.scanner.skip();
        self.scanner.skipWhitespace();
        const alval = try self.parseNextEntryValue(indent);
        try map.put(alkey, alval);
        return .consumed;
    }

    fn tryPlainScalarKeyEntry(self: *Parser, map: *Value.Mapping, indent: usize) YamlError!EntryAction {
        const ch = self.scanner.peek() orelse return .skip;
        if (!isPlainKey(ch)) return .skip;

        const saved_line_start = self.scanner.line_start;
        const before_key = self.scanner.pos;
        const next_key_val = try self.parsePlainScalar(indent);
        const next_key_str = try self.keyToString(next_key_val);
        var nkv = next_key_val;
        nkv.deinit(self.allocator);
        var next_key_in_map = false;
        errdefer if (!next_key_in_map) self.allocator.free(next_key_str);

        self.scanner.skipWhitespace();
        if (self.scanner.peek() != ':') {
            self.allocator.free(next_key_str);
            if (before_key == saved_line_start or self.scanner.peek() == null) {
                self.scanner.pos = before_key;
            }
            return .skip;
        }
        self.scanner.skip();
        self.scanner.skipWhitespace();

        var next_value = try self.parseNextEntryValue(indent);

        const gop = try map.getOrPut(next_key_str);
        if (gop.found_existing) {
            next_key_in_map = true;
            self.allocator.free(next_key_str);
            next_value.deinit(self.allocator);
            return YamlError.DuplicateKey;
        }
        gop.value_ptr.* = next_value;
        next_key_in_map = true;
        return .consumed;
    }

    fn parseNextMappingEntries(self: *Parser, map: *Value.Mapping, indent: usize) YamlError!void {
        while (!self.scanner.isEof()) {
            const current_indent = self.skipToEntry(indent) orelse break;
            try self.checkTabIndent();
            self.scanner.skipKnownSpaces(current_indent);

            if (try self.tryExplicitKeyEntry(map, indent) == .consumed) continue;
            if (try self.tryInlineAnchorKey(map, indent) == .consumed) continue;

            if (!isPlainKey(self.scanner.peek() orelse 0)) {
                if (try self.tryBareColonKey(map, indent) == .consumed) continue;
                const peek_ch = self.scanner.peek() orelse break;
                if (peek_ch == '"' or peek_ch == '\'') {
                    if (try self.tryQuotedKeyEntry(map, indent, peek_ch) == .consumed) continue;
                    break;
                }
                if (try self.tryAnchorAliasKeyEntry(map, indent) == .consumed) continue;
                break;
            }

            if (try self.tryTaggedKeyEntry(map, indent) == .consumed) continue;
            if (try self.tryAliasKeyEntry(map, indent) == .consumed) continue;
            if (try self.tryBareColonKey(map, indent) == .consumed) continue;
            if (try self.tryPlainScalarKeyEntry(map, indent) == .consumed) continue;
            break;
        }
    }

    fn parseNextEntryValue(self: *Parser, indent: usize) YamlError!Value {
        if (self.hasInlineValue()) {
            if (self.isNextAnchorOnOwnLine()) {
                return self.parseAnchoredValue(indent + 1);
            }
            return self.parseValueAsEntry(indent + 2);
        }

        if (self.scanner.peek() == '#') {
            self.scanner.skipLine();
        }
        if (self.scanner.peek() == '\n') self.scanner.skip();
        self.skipNewlines();
        self.skipBlankLinesAndComments();

        const val_indent = self.scanner.countIndentAtLineStart();
        if (val_indent > indent) {
            self.scanner.skipKnownSpaces(val_indent);
            return self.parseValue(val_indent);
        }
        if (val_indent == indent) {
            self.scanner.skipKnownSpaces(val_indent);
            const ch = self.scanner.peek() orelse 0;
            if (ch == '-' and (self.scanner.peekAt(1) == ' ' or self.scanner.peekAt(1) == '\t' or self.scanner.peekAt(1) == '\n')) {
                return self.parseBlockSequence(indent);
            }
            self.scanner.pos -= val_indent;
        }
        return .null;
    }

    fn readAnchorName(self: *Parser) YamlError![]const u8 {
        const start = self.scanner.pos;
        while (self.scanner.peek()) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or
                ch == ',' or ch == '[' or ch == ']' or ch == '{' or ch == '}')
                break;
            self.scanner.skip();
        }
        return self.allocator.dupe(u8, self.scanner.source[start..self.scanner.pos]);
    }

    fn parseAnchoredValue(self: *Parser, indent: usize) YamlError!Value {
        std.debug.assert(self.scanner.peek() == '&');
        self.scanner.skip();

        const anchor = try self.readAnchorName();
        errdefer self.allocator.free(anchor);

        self.scanner.skipWhitespace();

        const after_anchor = self.scanner.peek() orelse 0;

        if (after_anchor == '*') return YamlError.AnchorOnAlias;

        if (after_anchor == '-' and (self.scanner.peekAt(1) == ' ' or self.scanner.peekAt(1) == '\t' or self.scanner.peekAt(1) == '\n')) return YamlError.UnexpectedToken;

        const anchor_copy = try self.allocator.dupe(u8, anchor);
        try self.building_anchors.append(anchor_copy);
        const building_idx = self.building_anchors.items.len - 1;
        errdefer {
            _ = self.building_anchors.pop();
            self.allocator.free(anchor_copy);
        }

        if (after_anchor == '#') {
            self.scanner.skipLine();
        }

        const value = if (self.scanner.peek() == '\n' or after_anchor == '#') blk: {
            if (after_anchor != '#') {
                self.scanner.skip();
            }
            self.skipNewlines();
            self.skipBlankLinesAndComments();
            if (self.scanner.isEof()) break :blk Value.null;
            const next_indent = self.scanner.countIndentAtLineStart();
            if (next_indent >= indent) {
                self.scanner.skipKnownSpaces(next_indent);
                const inner_is_anchor = self.scanner.peek() == '&';
                const val = try self.parseValueWithContext(next_indent, false);
                if (inner_is_anchor and switch (val) { .sequence, .mapping => false, else => true }) return YamlError.UnexpectedToken;
                break :blk val;
            }
            break :blk Value.null;
        } else try self.parseValueAsEntry(indent);

        const cloned = try value.deepClone(self.allocator);
        errdefer {
            var cv = cloned;
            cv.deinit(self.allocator);
        }
        try self.anchors.put(anchor, cloned);
        _ = self.building_anchors.swapRemove(building_idx);
        self.allocator.free(anchor_copy);

        return value;
    }

    fn parseAlias(self: *Parser) YamlError!Value {
        std.debug.assert(self.scanner.peek() == '*');
        self.scanner.skip();

        const anchor = try self.readAnchorName();
        defer self.allocator.free(anchor);

        for (self.building_anchors.items) |name| {
            if (std.mem.eql(u8, anchor, name)) {
                return .{ .sequence = Value.Sequence.init(self.allocator) };
            }
        }

        if (self.anchors.get(anchor)) |value| {
            if (self.alias_clone_count >= MAX_ALIAS_CLONES) return YamlError.InvalidDocument;
            self.alias_clone_count += 1;
            return value.deepClone(self.allocator);
        }

        return YamlError.UnknownAlias;
    }

    fn parseTaggedValue(self: *Parser, indent: usize) YamlError!Value {
        std.debug.assert(self.scanner.peek() == '!');
        self.scanner.skip();

        var is_str_tag = false;
        if (self.scanner.peek() == ' ') {
            is_str_tag = true;
        } else if (self.scanner.peek() == '!') {
            self.scanner.skip();
            if (self.scanner.peek() == 's') {
                if (self.scanner.startWith("str") or self.scanner.startWith("str ")) {
                    is_str_tag = true;
                    self.scanner.skipBytes(3);
                }
            }
        } else if (self.scanner.peek() != '<') {
            const handle_start = self.scanner.pos - 1;
            while (self.scanner.peek()) |ch| {
                if (ch == ' ' or ch == '\n' or ch == ',' or ch == '}' or ch == ']') break;
                self.scanner.skip();
                if (ch == '!') break;
            }
            const handle = self.scanner.source[handle_start..self.scanner.pos];
            if (handle.len > 1 and handle[handle.len - 1] == '!') {
                if (!self.tag_handles.contains(handle)) return YamlError.UnknownTagHandle;
            }
        }

        if (self.scanner.peek() == '<') {
            while (self.scanner.peek()) |ch| {
                self.scanner.skip();
                if (ch == '>') break;
            }
        }
        while (self.scanner.peek()) |ch| {
            if (ch == ' ' or ch == '\n' or ch == ',' or ch == '}' or ch == ']') break;
            self.scanner.skip();
        }

        self.scanner.skipWhitespace();
        if (self.scanner.peek() == '&') {
            const anchored = try self.parseAnchoredValue(indent);
            if (is_str_tag and anchored == .string) return anchored;
            return anchored;
        }
        if (self.scanner.peek() == '#') {
            self.scanner.skipLine();
            self.skipNewlines();
            self.skipBlankLinesAndComments();
            if (self.scanner.isEof()) {
                if (is_str_tag) return self.parseAsString(indent);
                return .null;
            }
            const next_indent = self.scanner.countIndentAtLineStart();
            self.scanner.skipKnownSpaces(next_indent);
            return self.parseValueWithContext(next_indent, false);
        }
        if (self.scanner.peek() == '\n') {
            self.skipNewlines();
            self.skipBlankLinesAndComments();
            if (self.scanner.isEof()) {
                if (is_str_tag) return self.parseAsString(indent);
                return .null;
            }
            const next_indent = self.scanner.countIndentAtLineStart();
            self.scanner.skipKnownSpaces(next_indent);
            return self.parseValueWithContext(next_indent, false);
        }

        if (is_str_tag) {
            return self.parseAsString(indent);
        }
        return self.parseValue(indent);
    }

    fn parseAsString(self: *Parser, indent: usize) YamlError!Value {
        const ch = self.scanner.peek() orelse return .{ .string = try self.allocator.dupe(u8, "") };

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
