const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Token = @import("token.zig").Token;
const Value = @import("../ast/value.zig").Value;
const YamlError = @import("../error.zig").YamlError;
const _parser = @import("parser.zig");
const mapping_mod = @import("mapping.zig");

pub const ScalarWriter = union(enum) {
    counter,
    builder: *std.ArrayList(u8),

    pub fn writeByte(self: ScalarWriter, byte: u8) !void {
        if (self == .builder) try self.builder.append(byte);
    }

    pub fn writeSlice(self: ScalarWriter, slice: []const u8) !void {
        if (self == .builder) try self.builder.appendSlice(slice);
    }
};

pub const BlockScalarHeader = struct {
    chomp: enum { clip, strip, keep },
    explicit_indent: ?usize,
};

pub const BlockScalarCtx = struct {
    content_indent: usize,
    indent_detected: bool,
    trailing_newlines: usize,
    first_content: bool,
    max_blank_indent: usize,
    prev_line_extra: bool,
};

pub fn isLineBlank(parser: *Parser) bool {
    var pos = parser.scanner.pos;
    while (pos < parser.scanner.source.len) : (pos += 1) {
        const c = parser.scanner.source[pos];
        if (c == '\n') return true;
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

pub fn appendCodepoint(result: *std.ArrayList(u8), code: anytype) YamlError!void {
    var out: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(code, &out) catch return YamlError.InvalidEscapeSequence;
    try result.appendSlice(out[0..len]);
}

pub fn readHexEscape(parser: *Parser, comptime T: type, comptime n: usize) YamlError!T {
    var buf: [n]u8 = undefined;
    for (&buf) |*slot| {
        slot.* = parser.scanner.advance() orelse return YamlError.InvalidEscapeSequence;
    }
    return std.fmt.parseInt(T, &buf, 16) catch YamlError.InvalidEscapeSequence;
}

pub fn parseEscapeTo(parser: *Parser, result: *std.ArrayList(u8)) YamlError!void {
    const ch = parser.scanner.advance() orelse return YamlError.InvalidEscapeSequence;
    switch (ch) {
        '0' => try result.append(0x00),
        'a' => try result.append(0x07),
        'b' => try result.append(0x08),
        't' => try result.append('\t'),
        '\t' => try result.append('\t'),
        'n' => try result.append('\n'),
        'v' => try result.append(0x0B),
        'f' => try result.append(0x0C),
        'r' => try result.append('\r'),
        'e' => try result.append(0x1B),
        ' ' => try result.append(' '),
        '"' => try result.append('"'),
        '/' => try result.append('/'),
        '\\' => try result.append('\\'),
        'N' => try result.appendSlice("\u{0085}"),
        '_' => try result.appendSlice("\u{00A0}"),
        'L' => try result.appendSlice("\u{2028}"),
        'P' => try result.appendSlice("\u{2029}"),
        'x' => {
            const code = try readHexEscape(parser, u8, 2);
            try result.append(code);
        },
        'u' => {
            const code = try readHexEscape(parser, u16, 4);
            try appendCodepoint(result, code);
        },
        'U' => {
            const code = try readHexEscape(parser, u21, 8);
            try appendCodepoint(result, code);
        },
        '\n' => {
            parser.scanner.skipWhitespace();
        },
        else => return YamlError.InvalidEscapeSequence,
    }
}

pub fn scanPlainScalarConsecutiveNewlines(parser: *Parser, writer: ScalarWriter, saved_pos: usize, cont_indent: usize) YamlError!?bool {
    var blank_count: usize = 0;
    while (parser.scanner.peek() == .newline) {
        parser.scanner.skip();
        if (parser.scanner.countLeadingSpaces() >= cont_indent) {
            blank_count += 1;
        } else if (parser.scanner.peek() != .eof and parser.scanner.peek() != .newline) {
            break;
        }
    }
    if (parser.scanner.peek() == .newline or parser.scanner.isEof()) {
        parser.scanner.pos = saved_pos;
        return null;
    }
    if (parser.scanner.countLeadingSpaces() < cont_indent) {
        parser.scanner.pos = saved_pos;
        return null;
    }
    for (0..blank_count) |_| {
        try writer.writeByte('\n');
    }
    parser.scanner.skipWhitespace();
    return true;
}

pub fn scanPlainScalarNewline(parser: *Parser, writer: ScalarWriter, saved_pos: usize, indent: usize, cont_indent: usize) YamlError!?bool {
    const line_start_pos = parser.scanner.pos;
    if (!mapping_mod.isNewlineContinuable(parser, saved_pos, cont_indent)) {
        parser.scanner.pos = saved_pos;
        return null;
    }
    if (isLineBlank(parser)) {
        parser.scanner.pos = line_start_pos;
        if (!mapping_mod.isNewlineContinuable(parser, saved_pos, indent)) {
            parser.scanner.pos = saved_pos;
            return null;
        }
    }
    parser.scanner.skipWhitespace();
    if (parser.scanner.peek() == .newline) {
        try writer.writeByte('\n');
        const inner_saved = parser.scanner.pos;
        parser.scanner.skip();
        if (!mapping_mod.isNewlineContinuable(parser, inner_saved, indent)) {
            parser.scanner.pos = inner_saved;
            return true;
        }
        parser.scanner.skipWhitespace();
        while (parser.scanner.peek() == .newline) {
            try writer.writeByte('\n');
            const blank_saved = parser.scanner.pos;
            parser.scanner.skip();
            if (!mapping_mod.isNewlineContinuable(parser, blank_saved, indent)) {
                parser.scanner.pos = blank_saved;
                break;
            }
            parser.scanner.skipWhitespace();
        }
    } else {
        try writer.writeByte(' ');
    }
    return true;
}

pub fn scanPlainScalar(parser: *Parser, writer: ScalarWriter, indent: usize, cont_indent: usize) YamlError!bool {
    var has_newline = false;
    var first_line = true;
    while (!parser.scanner.isEof()) {
        const tok = parser.scanner.peek();
        if (parser.flow_depth > 0 and tok.isFlowDelim()) break;
        switch (tok) {
            .eof => break,
            .newline => {
                const saved_pos = parser.scanner.pos;
                parser.scanner.skip();
                if (parser.scanner.peek() == .newline) {
                    has_newline = true;
                    first_line = false;
                    const result = try scanPlainScalarConsecutiveNewlines(parser, writer, saved_pos, cont_indent);
                    if (result == null) break;
                    continue;
                }
                const nl_result = try scanPlainScalarNewline(parser, writer, saved_pos, indent, cont_indent);
                if (nl_result == null) break;
                has_newline = true;
                first_line = false;
                continue;
            },
            .colon => {
                if (parser.scanner.peekTokenAt(1).isColonValueSep()) break;
                try writer.writeByte(':');
                parser.scanner.skip();
            },
            .space, .tab => {
                parser.scanner.skipWhitespace();
                const next_tok = parser.scanner.peek();
                if (next_tok == .newline) continue;
                if (next_tok.isFlowDelim()) break;
                if (next_tok == .hash) {
                    const prev = parser.scanner.source[parser.scanner.pos - 1];
                    if (prev == ' ' or prev == '\t') break;
                }
                if (next_tok == .colon) {
                    if (parser.scanner.peekTokenAt(1).isColonValueSep()) break;
                }
                try writer.writeByte(' ');
            },
            .hash => {
                if (parser.scanner.pos > 0) {
                    const prev = parser.scanner.source[parser.scanner.pos - 1];
                    if (prev == ' ' or prev == '\t') break;
                } else break;
                try writer.writeByte('#');
                parser.scanner.skip();
            },
            else => {
                try writer.writeByte(parser.scanner.advance().?);
            },
        }
        first_line = false;
    }
    return has_newline;
}

pub fn parsePlainScalar(parser: *Parser, indent: usize) YamlError!Value {
    const cont_indent: usize = if (indent > 0) indent - 1 else 0;
    const start_pos = parser.scanner.pos;
    const has_newline = try scanPlainScalar(parser, .counter, indent, cont_indent);
    if (!has_newline) return resolvePlainScalarSlice(parser, start_pos);

    parser.scanner.pos = start_pos;
    var result = std.ArrayList(u8).init(parser.allocator);
    errdefer result.deinit();
    _ = try scanPlainScalar(parser, .{ .builder = &result }, indent, cont_indent);

    const raw = try result.toOwnedSlice();
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == raw.len) {
        const resolved = Value.resolveScalar(raw);
        if (resolved != .string) parser.allocator.free(raw);
        return resolved;
    }
    const resolved = Value.resolveScalar(trimmed);
    if (resolved != .string) {
        parser.allocator.free(raw);
        return resolved;
    }
    const duped = try parser.allocator.dupe(u8, trimmed);
    parser.allocator.free(raw);
    return .{ .string = duped };
}

pub fn resolvePlainScalarSlice(parser: *Parser, start_pos: usize) YamlError!Value {
    const raw = parser.scanner.source[start_pos..parser.scanner.pos];
    const trimmed = std.mem.trim(u8, raw, " \t");
    const resolved = Value.resolveScalar(trimmed);
    if (resolved == .string) {
        return .{ .string = try parser.allocator.dupe(u8, trimmed) };
    }
    return resolved;
}

pub fn foldQuotedNewline(parser: *Parser, result: *std.ArrayList(u8), strip_trailing: bool) YamlError!void {
    if (strip_trailing) {
        while (result.items.len > 0 and (result.items[result.items.len - 1] == ' ' or result.items[result.items.len - 1] == '\t')) {
            _ = result.pop();
        }
    }
    parser.scanner.skip();
    const ws_start = parser.scanner.pos;
    parser.scanner.skipWhitespace();
    const aw_tok = parser.scanner.peek();
    if (aw_tok == .newline) {
        try result.append('\n');
        parser.scanner.skip();
        parser.scanner.skipWhitespace();
        return;
    }
    if ((aw_tok == .double_quote or aw_tok == .single_quote) and result.items.len > 0 and result.items[result.items.len - 1] == '\n') {
        try result.append('\n');
        return;
    }
    if (parser.flow_depth == 0 and parser.quoted_scalar_indent > 0) {
        var has_tab = false;
        var space_count: usize = 0;
        for (parser.scanner.source[ws_start..parser.scanner.pos]) |c| {
            if (c == '\t') has_tab = true;
            if (c == ' ') space_count += 1;
        }
        if (has_tab and space_count < parser.quoted_scalar_indent) return YamlError.TabIndentation;
    }
    const directive_mod = @import("directive.zig");
    if (parser.flow_depth == 0 and parser.scanner.column <= 1) {
        if (parser.scanner.startWith(_parser.DOC_BOUNDARY) and directive_mod.isDocBoundaryTerminator(parser.scanner.peekTokenAt(_parser.DOC_BOUNDARY_LEN))) return YamlError.UnclosedScalar;
        if (parser.scanner.startWith(_parser.DOC_TERMINATOR) and directive_mod.isDocBoundaryTerminator(parser.scanner.peekTokenAt(_parser.DOC_BOUNDARY_LEN))) return YamlError.UnclosedScalar;
        if (parser.quoted_scalar_indent > 0) return YamlError.UnclosedScalar;
    }
    if (result.items.len > 0 and result.items[result.items.len - 1] != '\n') {
        try result.append(' ');
    } else if (result.items.len == 0) {
        try result.append(' ');
    }
}

pub fn ensureValidAfterScalar(parser: *Parser) YamlError!void {
    const tok = parser.scanner.peek();
    if (parser.flow_depth > 0) {
        if (!tok.isFlowDelim() and tok != .colon and !tok.isWsOrNewline())
            return YamlError.UnexpectedToken;
        return;
    }
    switch (tok) {
        .eof => return,
        .colon => {
            if (parser.scanner.peekTokenAt(1).isColonValueSep()) return;
            return YamlError.UnexpectedToken;
        },
        .space, .tab => {
            const saved = parser.scanner.pos;
            parser.scanner.skipWhitespace();
            const after_tok = parser.scanner.peek();
            if (after_tok.isWsOrNewline() or after_tok == .eof or after_tok == .hash) return;
            switch (after_tok) {
                .colon => {
                    if (parser.scanner.peekTokenAt(1).isColonValueSep()) {
                        parser.scanner.pos = saved;
                        return;
                    }
                },
                else => {},
            }
            parser.scanner.pos = saved;
            return YamlError.UnexpectedToken;
        },
        .newline, .cr => return,
        else => return YamlError.UnexpectedToken,
    }
}

pub fn parseDoubleQuotedScalar(parser: *Parser) YamlError!Value {
    std.debug.assert(parser.scanner.peek() == .double_quote);
    parser.scanner.skip();

    var result = std.ArrayList(u8).init(parser.allocator);
    errdefer result.deinit();

    while (!parser.scanner.isEof()) {
        switch (parser.scanner.peek()) {
            .double_quote => {
                parser.scanner.skip();
                try ensureValidAfterScalar(parser);
                const str = try result.toOwnedSlice();
                return .{ .string = str };
            },
            .backslash => {
                parser.scanner.skip();
                try parseEscapeTo(parser, &result);
            },
            .newline => {
                const nl_pos = parser.scanner.pos;
                var src_ws: usize = 0;
                while (src_ws < nl_pos) {
                    const prev = parser.scanner.source[nl_pos - 1 - src_ws];
                    if (prev == ' ' or prev == '\t') src_ws += 1 else break;
                }
                if (src_ws > 0 and nl_pos > src_ws) {
                    const before_ws = parser.scanner.source[nl_pos - 1 - src_ws];
                    if (before_ws == '\\') src_ws -|= 1;
                }
                while (src_ws > 0 and result.items.len > 0) {
                    const last = result.items[result.items.len - 1];
                    if (last == ' ' or last == '\t') {
                        _ = result.pop();
                        src_ws -= 1;
                    } else break;
                }
                try foldQuotedNewline(parser, &result, false);
            },
            else => {
                try result.append(parser.scanner.advance().?);
            },
        }
    }

    return YamlError.UnclosedScalar;
}

pub fn parseSingleQuotedScalar(parser: *Parser) YamlError!Value {
    std.debug.assert(parser.scanner.peek() == .single_quote);
    parser.scanner.skip();

    var result = std.ArrayList(u8).init(parser.allocator);
    errdefer result.deinit();

    while (!parser.scanner.isEof()) {
        switch (parser.scanner.peek()) {
            .single_quote => {
                parser.scanner.skip();
                if (parser.scanner.peek() == .single_quote) {
                    try result.append('\'');
                    parser.scanner.skip();
                    continue;
                }
                try ensureValidAfterScalar(parser);
                const str = try result.toOwnedSlice();
                return .{ .string = str };
            },
            .newline => {
                try foldQuotedNewline(parser, &result, true);
            },
            else => {
                try result.append(parser.scanner.advance().?);
            },
        }
    }

    return YamlError.UnclosedScalar;
}

pub fn parsePlainScalarFlowKey(parser: *Parser) YamlError!Value {
    var result = std.ArrayList(u8).init(parser.allocator);
    errdefer result.deinit();

    while (!parser.scanner.isEof()) {
        switch (parser.scanner.peek()) {
            .comma, .close_bracket, .close_brace, .colon, .hash => break,
            .eof => break,
            .newline => {
                if (parser.flow_depth == 0) break;
                parser.scanner.skip();
                parser.scanner.skipWhitespace();
                const next_tok = parser.scanner.peek();
                if (next_tok.isFlowDelim() or next_tok == .colon or next_tok == .hash) break;
                try result.append(' ');
            },
            else => {
                try result.append(parser.scanner.advance().?);
            },
        }
    }

    const trimmed = std.mem.trimRight(u8, result.items, " \t");
    const resolved = Value.resolveScalar(trimmed);
    if (resolved == .string) {
        const duped = try parser.allocator.dupe(u8, trimmed);
        result.deinit();
        return .{ .string = duped };
    }
    result.deinit();
    return resolved;
}

pub fn parsePlainScalarAsString(parser: *Parser, indent: usize) YamlError!Value {
    _ = indent;
    const start_pos = parser.scanner.pos;

    while (!parser.scanner.isEof()) {
        const tok = parser.scanner.peek();
        if (tok.isFlowDelim() or tok == .newline or tok == .hash) break;
        if (tok == .colon and parser.scanner.peekTokenAt(1).isColonValueSep()) break;
        parser.scanner.skip();
    }

    const raw = parser.scanner.source[start_pos..parser.scanner.pos];
    const trimmed = std.mem.trim(u8, raw, " \t");
    const str = try parser.allocator.dupe(u8, trimmed);
    return .{ .string = str };
}

pub fn parseAsString(parser: *Parser, indent: usize) YamlError!Value {
    const tok = parser.scanner.peek();

    if (tok == .double_quote) {
        return parseDoubleQuotedScalar(parser);
    }
    if (tok == .single_quote) {
        return parseSingleQuotedScalar(parser);
    }

    return parsePlainScalarAsString(parser, indent);
}
