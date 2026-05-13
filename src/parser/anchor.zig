const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Token = @import("token.zig").Token;
const Value = @import("../ast/value.zig").Value;
const YamlError = @import("../error.zig").YamlError;
const _parser = @import("parser.zig");
const mapping_mod = @import("mapping.zig");
const scalar_mod = @import("scalar.zig");

pub fn readAnchorName(parser: *Parser) YamlError![]const u8 {
    const start = parser.scanner.pos;
    while (true) {
        const tok = parser.scanner.peek();
        if (tok.isAnchorTerminator()) break;
        parser.scanner.skip();
    }
    return parser.allocator.dupe(u8, parser.scanner.source[start..parser.scanner.pos]);
}

pub fn parseAnchoredValue(parser: *Parser, indent: usize) YamlError!Value {
    std.debug.assert(parser.scanner.peek() == .ampersand);
    parser.scanner.skip();

    const anchor = try readAnchorName(parser);
    errdefer parser.allocator.free(anchor);

    parser.scanner.skipWhitespace();

    const after_tok = parser.scanner.peek();

    if (after_tok == .asterisk) return YamlError.AnchorOnAlias;

    if (after_tok == .dash and parser.scanner.peekTokenAt(1).isColonValueSep()) return YamlError.UnexpectedToken;

    try parser.pending_anchors.append(anchor);
    errdefer {
        _ = parser.pending_anchors.pop();
    }

    if (after_tok == .hash) {
        parser.scanner.skipLine();
    }

    const value = if (parser.scanner.peek() == .newline or after_tok == .hash) blk: {
        if (after_tok != .hash) {
            parser.scanner.skip();
        }
        parser.skipNewlines();
        mapping_mod.skipBlankLinesAndComments(parser);
        if (parser.scanner.isEof()) break :blk Value.null;
        const next_indent = parser.scanner.countIndentAtLineStart();
        if (next_indent >= indent) {
            parser.scanner.skipKnownSpaces(next_indent);
            const inner_is_anchor = parser.scanner.peek() == .ampersand;
            const val = try parser.parseValueWithContext(next_indent, false);
            if (inner_is_anchor and switch (val) {
                .sequence, .mapping => false,
                else => true,
            }) return YamlError.UnexpectedToken;
            break :blk val;
        }
        break :blk Value.null;
    } else try parser.parseValueWithContext(indent, true);

    const cloned = try value.deepClone(parser.allocator);
    errdefer {
        cloned.deinit(parser.allocator);
    }
    const old = parser.anchors.fetchRemove(anchor);
    if (old) |o| {
        parser.allocator.free(o.key);
        o.value.deinit(parser.allocator);
    }
    const anchor_key = try parser.allocator.dupe(u8, anchor);
    try parser.anchors.put(anchor_key, cloned);
    _ = parser.pending_anchors.pop();
    parser.allocator.free(anchor);

    return value;
}

pub fn parseAlias(parser: *Parser) YamlError!Value {
    std.debug.assert(parser.scanner.peek() == .asterisk);
    parser.scanner.skip();

    const anchor = try readAnchorName(parser);
    defer parser.allocator.free(anchor);

    if (parser.pending_anchors.items.len > 0) {
        for (parser.pending_anchors.items) |pending| {
            if (std.mem.eql(u8, anchor, pending)) {
                return .{ .sequence = Value.Sequence.init(parser.allocator) };
            }
        }
    }

    if (parser.anchors.get(anchor)) |value| {
        if (parser.alias_clone_count >= _parser.MAX_ALIAS_CLONES) return YamlError.InvalidDocument;
        parser.alias_clone_count += 1;
        return value.deepClone(parser.allocator);
    }

    return YamlError.UnknownAlias;
}

pub fn parseTaggedValue(parser: *Parser, indent: usize) YamlError!Value {
    std.debug.assert(parser.scanner.peek() == .bang);
    parser.scanner.skip();

    var is_str_tag = false;
    switch (parser.scanner.peek()) {
        .space => is_str_tag = true,
        .bang => {
            parser.scanner.skip();
            if (!parser.scanner.isEof() and parser.scanner.source[parser.scanner.pos] == 's') {
                if (parser.scanner.startWith("str") or parser.scanner.startWith("str ")) {
                    is_str_tag = true;
                    parser.scanner.skipBytes(comptime "str".len);
                }
            }
        },
        .less => {},
        else => {
            const handle_start = parser.scanner.pos - 1;
            while (!parser.scanner.isEof()) {
                const tok = parser.scanner.peek();
                if (tok.isTagTerminator()) break;
                const ch = parser.scanner.source[parser.scanner.pos];
                parser.scanner.skip();
                if (ch == '!') break;
            }
            const handle = parser.scanner.source[handle_start..parser.scanner.pos];
            if (handle.len > 1 and handle[handle.len - 1] == '!') {
                if (!parser.tag_handles.contains(handle)) return YamlError.UnknownTagHandle;
            }
        },
    }

    if (parser.scanner.peek() == .less) {
        while (!parser.scanner.isEof()) {
            const tok = parser.scanner.peek();
            parser.scanner.skip();
            if (tok == .greater) break;
        }
    }
    while (true) {
        const tok = parser.scanner.peek();
        if (tok == .space or tok == .newline or tok == .comma or tok == .close_brace or tok == .close_bracket) break;
        if (tok == .eof) break;
        parser.scanner.skip();
    }

    parser.scanner.skipWhitespace();
    if (parser.scanner.peek() == .ampersand) {
        const anchored = try parseAnchoredValue(parser, indent);
        if (is_str_tag and anchored == .string) return anchored;
        return anchored;
    }
    if (parser.scanner.peek() == .hash) {
        parser.scanner.skipLine();
        parser.skipNewlines();
        mapping_mod.skipBlankLinesAndComments(parser);
        if (parser.scanner.isEof()) {
            if (is_str_tag) return scalar_mod.parseAsString(parser, indent);
            return .null;
        }
        const next_indent = parser.scanner.countIndentAtLineStart();
        parser.scanner.skipKnownSpaces(next_indent);
        return parser.parseValueWithContext(next_indent, false);
    }
    if (parser.scanner.peek() == .newline) {
        parser.skipNewlines();
        mapping_mod.skipBlankLinesAndComments(parser);
        if (parser.scanner.isEof()) {
            if (is_str_tag) return scalar_mod.parseAsString(parser, indent);
            return .null;
        }
        const next_indent = parser.scanner.countIndentAtLineStart();
        parser.scanner.skipKnownSpaces(next_indent);
        return parser.parseValueWithContext(next_indent, false);
    }

    if (is_str_tag) {
        return scalar_mod.parseAsString(parser, indent);
    }
    return parser.parseValueWithContext(indent, false);
}
