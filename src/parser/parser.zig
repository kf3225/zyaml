const std = @import("std");
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("token.zig").Token;
const Value = @import("../ast/value.zig").Value;
const YamlError = @import("../error.zig").YamlError;

const directive = @import("directive.zig");
const scalar = @import("scalar.zig");
const flow = @import("flow.zig");
const block = @import("block.zig");
const mapping = @import("mapping.zig");
const anchor = @import("anchor.zig");

pub const MAX_DEPTH = 256;
pub const MAX_ALIAS_CLONES = 1000;
pub const DEFAULT_INDENT_STEP = 2;
pub const DOC_BOUNDARY = "---";
pub const DOC_TERMINATOR = "...";
pub const DOC_BOUNDARY_LEN = DOC_BOUNDARY.len;

pub fn isPlainKey(ch: u8) bool {
    return switch (Token.from(ch)) {
        .space,
        .tab,
        .colon,
        .dash,
        .question,
        .pipe,
        .greater,
        .less,
        .ampersand,
        .bang,
        .dot,
        .percent,
        => true,
        .other => (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '_' or ch == '=' or ch == '@' or ch == '`' or ch == '/' or
            ch > 0x7F,
        else => false,
    };
}

pub inline fn isDashEntry(scanner: *Scanner) bool {
    if (scanner.peek() != .dash) return false;
    return scanner.peekTokenAt(1).isColonValueSep();
}

pub const Parser = struct {
    allocator: std.mem.Allocator,
    scanner: Scanner,
    anchors: std.StringHashMap(Value),
    pending_anchors: std.ArrayList([]const u8),
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
            .pending_anchors = std.ArrayList([]const u8).init(allocator),
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
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.anchors.deinit();
        for (self.pending_anchors.items) |p| self.allocator.free(p);
        self.pending_anchors.deinit();
        directive.clearTagHandles(self);
    }

    pub fn parse(self: *Parser) YamlError!Value {
        return directive.parse(self);
    }

    pub fn checkTabIndent(self: *Parser) YamlError!void {
        if (self.scanner.hasTabAsLeadingIndent()) return YamlError.TabIndentation;
    }

    pub fn parseValueWithContext(self: *Parser, indent: usize, in_mapping_value: bool) YamlError!Value {
        if (self.depth >= MAX_DEPTH) return YamlError.InvalidDocument;
        self.depth += 1;
        defer self.depth -= 1;
        self.quoted_scalar_indent = indent;

        self.scanner.skipWhitespace();
        if (self.scanner.isEof()) return .null;

        switch (self.scanner.peek()) {
            .eof => return .null,
            .open_bracket => {
                if (self.flow_depth == 0) self.flow_block_indent = indent;
                return self.tryAsMappingOrReturn(try flow.parseFlowSequence(self), indent, in_mapping_value);
            },
            .open_brace => {
                if (self.flow_depth == 0) self.flow_block_indent = indent;
                return self.tryAsMappingOrReturn(try flow.parseFlowMapping(self), indent, in_mapping_value);
            },
            .double_quote => return self.tryAsMappingOrReturn(try scalar.parseDoubleQuotedScalar(self), indent, in_mapping_value),
            .single_quote => return self.tryAsMappingOrReturn(try scalar.parseSingleQuotedScalar(self), indent, in_mapping_value),
            .pipe, .greater => return block.parseBlockScalar(self, indent),
            .dash => {
                if (self.scanner.peekTokenAt(1).isColonValueSep())
                    return block.parseBlockSequence(self, indent);
                if (self.flow_depth > 0 and self.scanner.peekTokenAt(1) != .other)
                    return YamlError.UnexpectedToken;
                return self.tryAsMappingOrReturn(try scalar.parsePlainScalar(self, indent), indent, in_mapping_value);
            },
            .question => {
                if (self.scanner.peekTokenAt(1).isColonValueSep())
                    return mapping.parseBlockMapping(self, indent);
                return self.tryAsMappingOrReturn(try scalar.parsePlainScalar(self, indent), indent, in_mapping_value);
            },
            .ampersand => return self.tryAsMappingOrReturn(try anchor.parseAnchoredValue(self, indent), indent, in_mapping_value),
            .asterisk => return self.tryAsMappingOrReturn(try anchor.parseAlias(self), indent, in_mapping_value),
            .bang => return self.tryAsMappingOrReturn(try anchor.parseTaggedValue(self, indent), indent, in_mapping_value),
            .tilde => {
                self.scanner.skip();
                return .null;
            },
            else => {
                if (!isPlainKey(self.scanner.source[self.scanner.pos])) {
                    if (self.flow_depth > 0) return YamlError.UnexpectedToken;
                    return .null;
                }
                return self.tryAsMappingOrReturn(try scalar.parsePlainScalar(self, indent), indent, in_mapping_value);
            },
        }

        return .null;
    }

    pub fn tryScalarAsMappingKey(self: *Parser, scalar_val: Value, indent: usize, in_mapping_value: bool) YamlError!?Value {
        if (in_mapping_value) return null;
        const saved_pos = self.scanner.pos;
        const saved_column = self.scanner.column;
        const at_line_start = saved_pos == self.scanner.line_start;
        self.scanner.skipWhitespace();
        if (self.scanner.peek() != .colon) {
            if (at_line_start) {
                self.scanner.pos = saved_pos;
                self.scanner.column = saved_column;
            }
            return null;
        }
        switch (scalar_val) {
            .sequence, .mapping => {
                if (self.flow_depth == 0 and self.scanner.line != self.flow_start_line) return YamlError.UnexpectedToken;
            },
            else => {},
        }
        if (!self.scanner.peekTokenAt(1).isColonValueSep()) {
            if (self.flow_depth == 0) return null;
        }
        return mapping.parseBlockMappingWithKey(self, scalar_val, indent) catch |err| switch (err) {
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

    pub fn tryAsMappingOrReturn(self: *Parser, value: Value, indent: usize, in_mapping_value: bool) YamlError!Value {
        const map = self.tryScalarAsMappingKey(value, indent, in_mapping_value) catch |err| {
            value.deinit(self.allocator);
            return err;
        };
        if (map) |m| return m;
        return value;
    }

    pub fn keyToString(self: *Parser, key_val: Value) YamlError![]const u8 {
        return switch (key_val) {
            .string => |s| self.allocator.dupe(u8, s),
            else => |v| std.fmt.allocPrint(self.allocator, "{}", .{v}),
        };
    }

    pub fn deinitMappingEntries(self: *Parser, map: *Value.Mapping) void {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        map.deinit();
    }

    pub fn skipNewlines(self: *Parser) void {
        while (self.scanner.peek() == .newline) self.scanner.skip();
    }

    pub fn hasInlineValue(self: *Parser) bool {
        return switch (self.scanner.peek()) {
            .eof, .newline, .hash => false,
            else => true,
        };
    }
};
