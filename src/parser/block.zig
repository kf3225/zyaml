const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Token = @import("token.zig").Token;
const Value = @import("../ast/value.zig").Value;
const YamlError = @import("../error.zig").YamlError;
const _parser = @import("parser.zig");
const scalar_mod = @import("scalar.zig");
const directive_mod = @import("directive.zig");
const mapping_mod = @import("mapping.zig");

pub fn appendFoldedSeparator(result: *std.ArrayList(u8), trailing: usize, first: bool, extra_sep: bool) !void {
    if (first and trailing == 0) return;
    if (trailing >= 1) {
        const extra: usize = if (!first and extra_sep) 1 else 0;
        try result.appendNTimes('\n', trailing + extra);
        return;
    }
    if (first) return;
    if (extra_sep) {
        try result.append('\n');
        return;
    }
    try result.append(' ');
}

pub fn readRestOfLine(parser: *Parser) []const u8 {
    const start = parser.scanner.pos;
    const remaining = parser.scanner.source[start..];
    const end = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
    parser.scanner.pos += end;
    parser.scanner.column += end;
    return parser.scanner.source[start..parser.scanner.pos];
}

pub fn handleBlockScalarEof(ctx: *scalar_mod.BlockScalarCtx, result: *std.ArrayList(u8), line_indent: usize) YamlError!bool {
    if (ctx.indent_detected and line_indent >= ctx.content_indent) {
        if (line_indent > ctx.content_indent) {
            if (!ctx.first_content) try result.appendNTimes('\n', ctx.trailing_newlines + 1);
            try result.appendNTimes(' ', line_indent - ctx.content_indent);
            ctx.first_content = false;
        }
        ctx.trailing_newlines += 1;
    } else if (!ctx.indent_detected and line_indent > 0) {
        ctx.trailing_newlines += 1;
    }
    return true;
}

pub fn handleBlockScalarBlankLine(parser: *Parser, ctx: *scalar_mod.BlockScalarCtx, result: *std.ArrayList(u8), line_indent: usize) YamlError!void {
    parser.scanner.skip();
    if (!ctx.indent_detected) {
        ctx.trailing_newlines += 1;
        if (line_indent > ctx.max_blank_indent) ctx.max_blank_indent = line_indent;
        return;
    }
    if (line_indent > ctx.content_indent) {
        if (!ctx.first_content) try result.appendNTimes('\n', ctx.trailing_newlines + 1);
        ctx.trailing_newlines = 0;
        try result.appendNTimes(' ', line_indent - ctx.content_indent);
        ctx.first_content = false;
        return;
    }
    ctx.trailing_newlines += 1;
}

pub fn detectBlockScalarIndent(parser: *Parser, ctx: *scalar_mod.BlockScalarCtx, result: *std.ArrayList(u8), line_indent: usize, tab_content: bool, parent_indent: usize) YamlError!void {
    if (line_indent == 0 and parent_indent > 0 and !tab_content) return;
    if (tab_content and line_indent == 0 and parent_indent > 0) {
        const at_tok = parser.scanner.peekTokenAt(1);
        if (at_tok == .newline or at_tok == .eof) return YamlError.TabIndentation;
    }
    if (ctx.max_blank_indent > 0 and ctx.max_blank_indent > line_indent) {
        return YamlError.InvalidIndentation;
    }
    ctx.content_indent = @max(line_indent, ctx.max_blank_indent);
    ctx.indent_detected = true;
    if (ctx.trailing_newlines > 0) {
        try result.appendNTimes('\n', ctx.trailing_newlines);
        ctx.trailing_newlines = 0;
    }
}

pub fn emitBlockScalarLine(parser: *Parser, ctx: *scalar_mod.BlockScalarCtx, result: *std.ArrayList(u8), indicator: Token, line_indent: usize, tab_content: bool, explicit_indent: ?usize) !void {
    if (explicit_indent) |expected| {
        if (line_indent < expected) return YamlError.InvalidIndentation;
    }
    const current_extra = line_indent > ctx.content_indent or tab_content;
    if (indicator == .greater) {
        try appendFoldedSeparator(result, ctx.trailing_newlines, ctx.first_content, ctx.prev_line_extra or current_extra);
    } else if (!ctx.first_content) {
        try result.appendNTimes('\n', ctx.trailing_newlines + 1);
    }
    ctx.trailing_newlines = 0;
    ctx.prev_line_extra = current_extra;

    const line_content = readRestOfLine(parser);
    try result.appendSlice(line_content);

    if (parser.scanner.peek() == .newline) parser.scanner.skip();
    ctx.first_content = false;
}

pub fn applyBlockScalarChomp(header: scalar_mod.BlockScalarHeader, result: *std.ArrayList(u8), trailing_newlines: usize) !void {
    switch (header.chomp) {
        .clip => if (result.items.len > 0) try result.append('\n'),
        .keep => {
            if (result.items.len > 0) try result.append('\n');
            try result.appendNTimes('\n', trailing_newlines);
        },
        .strip => {},
    }
}

pub fn parseBlockScalarHeader(parser: *Parser) YamlError!scalar_mod.BlockScalarHeader {
    var header: scalar_mod.BlockScalarHeader = .{ .chomp = .clip, .explicit_indent = null };
    var has_space = false;
    while (!parser.scanner.isEof()) {
        const tok = parser.scanner.peek();
        switch (tok) {
            .plus => {
                header.chomp = .keep;
                parser.scanner.skip();
                has_space = false;
            },
            .dash => {
                header.chomp = .strip;
                parser.scanner.skip();
                has_space = false;
            },
            .space, .tab => {
                parser.scanner.skip();
                has_space = true;
            },
            else => {
                if (tok == .other) {
                    const ch = parser.scanner.source[parser.scanner.pos];
                    if (ch >= '0' and ch <= '9') {
                        const digit: usize = @intCast(ch - '0');
                        if (digit == 0) return YamlError.InvalidIndentation;
                        parser.scanner.skip();
                        if (header.explicit_indent != null) return YamlError.UnexpectedToken;
                        header.explicit_indent = digit;
                        has_space = false;
                        continue;
                    }
                }
                break;
            },
        }
    }
    switch (parser.scanner.peek()) {
        .eof => {},
        .hash => if (has_space) parser.scanner.skipLine() else return YamlError.UnexpectedToken,
        .newline => parser.scanner.skip(),
        else => return YamlError.UnexpectedToken,
    }
    return header;
}

pub fn parseBlockScalar(parser: *Parser, parent_indent: usize) YamlError!Value {
    const indicator = parser.scanner.peek();
    std.debug.assert(indicator == .pipe or indicator == .greater);
    parser.scanner.skip();

    const header = try parseBlockScalarHeader(parser);

    var result = std.ArrayList(u8).init(parser.allocator);
    errdefer result.deinit();

    if (parser.scanner.isEof()) return .{ .string = try result.toOwnedSlice() };

    var ctx = scalar_mod.BlockScalarCtx{
        .content_indent = if (header.explicit_indent) |ei| (parent_indent -| _parser.DEFAULT_INDENT_STEP) + ei else 0,
        .indent_detected = header.explicit_indent != null,
        .trailing_newlines = 0,
        .first_content = true,
        .max_blank_indent = 0,
        .prev_line_extra = false,
    };

    while (!parser.scanner.isEof()) {
        const line_indent = parser.scanner.countLeadingSpaces();
        const pre_skip = parser.scanner.pos;
        const pre_column = parser.scanner.column;
        const tab_pos = parser.scanner.pos + line_indent;
        const tab_content = tab_pos < parser.scanner.source.len and parser.scanner.source[tab_pos] == '\t';
        if (ctx.indent_detected and line_indent > ctx.content_indent) {
            parser.scanner.skipKnownSpaces(ctx.content_indent);
        } else {
            parser.scanner.skipKnownSpaces(line_indent);
        }

        if (parser.scanner.isEof()) {
            if (try handleBlockScalarEof(&ctx, &result, line_indent)) break;
        }
        if (line_indent == 0 and (parser.scanner.startWith(_parser.DOC_BOUNDARY) or parser.scanner.startWith(_parser.DOC_TERMINATOR))) {
            if (directive_mod.isDocBoundaryTerminator(parser.scanner.peekTokenAt(_parser.DOC_BOUNDARY_LEN))) {
                parser.scanner.pos = pre_skip;
                break;
            }
        }
        if (parser.scanner.peek() == .newline) {
            try handleBlockScalarBlankLine(parser, &ctx, &result, line_indent);
            continue;
        }

        if (!ctx.indent_detected) {
            try detectBlockScalarIndent(parser, &ctx, &result, line_indent, tab_content, parent_indent);
            if (!ctx.indent_detected) break;
        } else if (line_indent < ctx.content_indent) {
            parser.scanner.pos = pre_skip;
            parser.scanner.column = pre_column;
            break;
        }

        try emitBlockScalarLine(parser, &ctx, &result, indicator, line_indent, tab_content, header.explicit_indent);
    }

    try applyBlockScalarChomp(header, &result, ctx.trailing_newlines);
    return .{ .string = try result.toOwnedSlice() };
}

fn skipDashValueWhitespace(parser: *Parser, next: Token) bool {
    var saw_tab = next == .tab;
    if (next == .space or next == .tab) {
        parser.scanner.skip();
    }
    while (parser.scanner.peek() == .space) {
        parser.scanner.skip();
    }
    while (parser.scanner.peek() == .tab) {
        saw_tab = true;
        parser.scanner.skip();
    }
    return saw_tab;
}

fn checkTabAfterDash(parser: *Parser) bool {
    const tok = parser.scanner.peek();
    if (!tok.isBlockIndicator()) return false;
    return parser.scanner.peekTokenAt(1).isColonValueSep();
}

pub fn parseBlockSequence(parser: *Parser, indent: usize) YamlError!Value {
    var seq = Value.Sequence.init(parser.allocator);
    errdefer {
        for (seq.items) |*item| {
            item.deinit(parser.allocator);
        }
        seq.deinit();
    }

    var first_item = true;
    var seq_indent = indent;

    while (!parser.scanner.isEof()) {
        if (!first_item) {
            directive_mod.skipInlineComment(parser);
            parser.skipNewlines();
            mapping_mod.skipBlankLinesAndComments(parser);

            if (parser.scanner.isEof()) break;

            const current_indent = parser.scanner.countIndentAtLineStart();
            if (current_indent < seq_indent) break;
            if (current_indent > seq_indent) return YamlError.InvalidIndentation;

            try parser.checkTabIndent();
            parser.scanner.skipKnownSpaces(current_indent);
        }

        if (parser.scanner.peek() != .dash) break;
        const next = parser.scanner.peekTokenAt(1);
        if (!next.isColonValueSep()) break;

        if (first_item) seq_indent = parser.scanner.column - 1;

        parser.scanner.skip();

        const saw_tab = skipDashValueWhitespace(parser, next);
        if (saw_tab and checkTabAfterDash(parser)) return YamlError.TabIndentation;

        parser.scanner.skipWhitespace();

        if (parser.scanner.peek() == .hash) {
            parser.scanner.skipLine();
            parser.skipNewlines();
            try parseBlockSeqSubEntry(parser, &seq, seq_indent, &first_item);
            continue;
        }

        if (parser.scanner.peek() == .newline) {
            parser.scanner.skip();
            parser.skipNewlines();
            try parseBlockSeqSubEntry(parser, &seq, seq_indent, &first_item);
            continue;
        }

        if (parser.scanner.isEof()) {
            try seq.append(.null);
            first_item = false;
            continue;
        }

        const content_indent = parser.scanner.column - 1;
        const val = try parser.parseValueWithContext(content_indent, false);
        try seq.append(val);
        first_item = false;
    }

    return .{ .sequence = seq };
}

pub fn parseBlockSeqSubEntry(parser: *Parser, seq: *Value.Sequence, seq_indent: usize, first_item: *bool) YamlError!void {
    const next_indent = parser.scanner.countIndentAtLineStart();
    if (next_indent > seq_indent) {
        parser.scanner.skipKnownSpaces(next_indent);
        const val = try parser.parseValueWithContext(next_indent, false);
        try seq.append(val);
        first_item.* = false;
        return;
    }
    try seq.append(.null);
    first_item.* = false;
}
