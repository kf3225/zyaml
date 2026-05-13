const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Token = @import("token.zig").Token;
const Value = @import("../ast/value.zig").Value;
const YamlError = @import("../error.zig").YamlError;
const _parser = @import("parser.zig");
const directive_mod = @import("directive.zig");
const scalar_mod = @import("scalar.zig");
const anchor_mod = @import("anchor.zig");
const block_mod = @import("block.zig");

pub const EntryAction = enum { consumed, skip };

fn isTabOnlyBlankLine(source: []const u8, pos: usize) bool {
    var check = pos;
    while (check < source.len and source[check] != '\n') : (check += 1) {
        const tok = Token.from(source[check]);
        if (tok != .space and tok != .tab) return false;
    }
    return check < source.len and source[check] == '\n';
}

pub fn skipBlankLinesAndComments(parser: *Parser) void {
    while (!parser.scanner.isEof()) {
        const indent = parser.scanner.countIndentAtLineStart();
        const pos = parser.scanner.line_start + indent;
        if (pos >= parser.scanner.source.len) break;
        switch (Token.from(parser.scanner.source[pos])) {
            .newline => {
                parser.scanner.pos = pos + 1;
                parser.scanner.line += 1;
                parser.scanner.column = 1;
                parser.scanner.line_start = pos + 1;
            },
            .hash => {
                parser.scanner.pos = pos;
                parser.scanner.skipLine();
            },
            .tab => if (isTabOnlyBlankLine(parser.scanner.source, pos)) {
                parser.scanner.pos = pos;
                parser.scanner.skipLine();
            } else break,
            else => break,
        }
    }
}

fn notContinuable(parser: *Parser, saved_pos: usize) bool {
    parser.scanner.pos = saved_pos;
    return false;
}

fn lineContainsColonSep(source: []const u8, start: usize) bool {
    var scan = start;
    while (scan < source.len) : (scan += 1) {
        const c = source[scan];
        if (c == '\n') return false;
        if (c == ':' and scan + 1 < source.len and Token.from(source[scan + 1]).isWsOrNewline()) return true;
    }
    return false;
}

pub fn isNewlineContinuable(parser: *Parser, saved_pos: usize, indent: usize) bool {
    const next_indent = parser.scanner.countLeadingSpaces();
    if (next_indent < indent) return notContinuable(parser, saved_pos);

    if (next_indent == 0 and indent == 0) {
        const tok = parser.scanner.peek();
        if ((tok == .dash and parser.scanner.startWith(_parser.DOC_BOUNDARY) and
            directive_mod.isDocBoundaryTerminator(parser.scanner.peekTokenAt(_parser.DOC_BOUNDARY_LEN))) or
            (tok == .dot and parser.scanner.startWith(_parser.DOC_TERMINATOR) and
                directive_mod.isDocBoundaryTerminator(parser.scanner.peekTokenAt(_parser.DOC_BOUNDARY_LEN))))
        {
            return notContinuable(parser, saved_pos);
        }
    }
    if (next_indent == 0 and indent > 0) return notContinuable(parser, saved_pos);

    const next_tok = parser.scanner.peekTokenAt(next_indent);
    if (next_tok == .hash or next_tok == .newline) return notContinuable(parser, saved_pos);
    if (next_tok == .colon and parser.scanner.peekTokenAt(next_indent + 1).isColonValueSep()) return notContinuable(parser, saved_pos);
    if (next_tok == .dash and parser.scanner.peekTokenAt(next_indent + 1).isColonValueSep() and next_indent < indent) return notContinuable(parser, saved_pos);
    if (next_tok == .question and parser.scanner.peekTokenAt(next_indent + 1) == .space) return notContinuable(parser, saved_pos);
    if (parser.flow_depth == 0 and lineContainsColonSep(parser.scanner.source, parser.scanner.pos + next_indent)) return notContinuable(parser, saved_pos);

    parser.scanner.skipKnownSpaces(next_indent);
    return true;
}

pub fn hasTrailingColonOnLine(parser: *Parser) bool {
    var pos = parser.scanner.pos;
    while (pos < parser.scanner.source.len) : (pos += 1) {
        const ch = parser.scanner.source[pos];
        if (ch == ':') {
            if (pos + 1 >= parser.scanner.source.len) return true;
            return Token.from(parser.scanner.source[pos + 1]).isWsOrNewline();
        }
        if (ch == ' ' or ch == '\t') continue;
        return false;
    }
    return false;
}

pub fn isNextAnchorOnOwnLine(parser: *Parser) bool {
    if (parser.scanner.peek() != .ampersand) return false;
    const saved = parser.scanner.pos;
    parser.scanner.skip();
    while (parser.scanner.peek() == .other or parser.scanner.peek().isAnchorTerminator() == false) {
        if (parser.scanner.peek() == .space or parser.scanner.peek() == .newline) break;
        parser.scanner.skip();
    }
    if (parser.scanner.peek() == .newline or parser.scanner.isEof()) {
        parser.scanner.pos = saved;
        return true;
    }
    while (parser.scanner.peek() == .space) {
        parser.scanner.skip();
    }
    const result = parser.scanner.peek() == .hash or parser.scanner.isEof();
    parser.scanner.pos = saved;
    return result;
}

pub fn parseExplicitKeyPart(parser: *Parser, indent: usize) YamlError!Value {
    if (parser.scanner.peek() == .space) parser.scanner.skip();
    if (parser.scanner.peek() == .tab) return YamlError.TabIndentation;
    if (parser.hasInlineValue()) {
        const val = try parser.parseValueWithContext(indent + _parser.DEFAULT_INDENT_STEP, true);
        if (hasTrailingColonOnLine(parser)) {
            const is_inline = parser.scanner.pos > 0 and
                parser.scanner.source[parser.scanner.pos - 1] != '\n';
            if (parser.flow_depth == 0 and is_inline) {
                return buildInlineMappingKey(parser, val, indent);
            }
            return val;
        }
        return parser.tryAsMappingOrReturn(val, indent, false);
    }
    if (parser.scanner.peek() == .hash) directive_mod.skipInlineComment(parser);
    parser.skipNewlines();
    skipBlankLinesAndComments(parser);
    const key_indent = parser.scanner.countIndentAtLineStart();
    if (key_indent < indent) return .null;
    parser.scanner.skipKnownSpaces(key_indent);
    const val = try parser.parseValueWithContext(key_indent, true);
    if (hasTrailingColonOnLine(parser)) {
        const is_inline = parser.scanner.pos > 0 and
            parser.scanner.source[parser.scanner.pos - 1] != '\n';
        if (parser.flow_depth == 0 and is_inline) {
            return buildInlineMappingKey(parser, val, indent);
        }
        return val;
    }
    return parser.tryAsMappingOrReturn(val, indent, false);
}

pub fn buildInlineMappingKey(parser: *Parser, key_val: Value, indent: usize) YamlError!Value {
    parser.scanner.skipWhitespace();
    std.debug.assert(parser.scanner.peek() == .colon);
    parser.scanner.skip();
    parser.scanner.skipWhitespace();
    const inner_val = if (parser.hasInlineValue())
        try parser.parseValueWithContext(indent + _parser.DEFAULT_INDENT_STEP, true)
    else
        Value.null;
    var map = Value.Mapping.init(parser.allocator);
    errdefer parser.deinitMappingEntries(&map);
    const key_str = try parser.keyToString(key_val);
    key_val.deinit(parser.allocator);
    try map.put(key_str, inner_val);
    return .{ .mapping = map };
}

pub fn parseExplicitValuePart(parser: *Parser, indent: usize) YamlError!Value {
    std.debug.assert(parser.scanner.peek() == .colon);
    parser.scanner.skip();
    if (parser.scanner.peek() == .tab) return YamlError.TabIndentation;
    parser.scanner.skipWhitespace();
    return parseEntryValueAfterColon(parser, indent, true);
}

pub fn parseBlockMapping(parser: *Parser, indent: usize) YamlError!Value {
    std.debug.assert(parser.scanner.peek() == .question);
    parser.scanner.skip();

    var map = Value.Mapping.init(parser.allocator);
    errdefer parser.deinitMappingEntries(&map);

    const key = try parseExplicitKeyPart(parser, indent);
    var key_consumed = false;
    errdefer if (!key_consumed) key.deinit(parser.allocator);

    directive_mod.skipCommentsAndBlankLines(parser);
    const at_indent = parser.scanner.countIndentAtLineStart() == indent;
    const value = if (at_indent and parser.scanner.peek() == .colon)
        try parseExplicitValuePart(parser, indent)
    else if (parser.scanner.peek() == .colon) blk: {
        parser.scanner.skip();
        parser.scanner.skipWhitespace();
        break :blk if (parser.hasInlineValue())
            try parser.parseValueWithContext(indent + _parser.DEFAULT_INDENT_STEP, true)
        else
            Value.null;
    } else Value.null;

    const key_str = try parser.keyToString(key);
    key.deinit(parser.allocator);
    key_consumed = true;

    errdefer parser.allocator.free(key_str);
    try map.put(key_str, value);
    try parseNextMappingEntries(parser, &map, indent);
    return .{ .mapping = map };
}

pub fn parseBlockMappingWithKey(parser: *Parser, key_val: Value, indent: usize) YamlError!Value {
    var map = Value.Mapping.init(parser.allocator);
    errdefer parser.deinitMappingEntries(&map);

    const key_str = try parser.keyToString(key_val);
    var key_in_map = false;
    errdefer if (!key_in_map) parser.allocator.free(key_str);

    std.debug.assert(parser.scanner.peek() == .colon);
    parser.scanner.skip();
    parser.scanner.skipWhitespace();

    const value = try parseEntryValueAfterColon(parser, indent, false);
    try map.put(key_str, value);
    key_in_map = true;

    try parseNextMappingEntries(parser, &map, indent);

    key_val.deinit(parser.allocator);

    return .{ .mapping = map };
}

fn resolvePendingAnchors(parser: *Parser, seq: Value) !void {
    var anchor_it = parser.anchors.iterator();
    while (anchor_it.next()) |entry| {
        if (entry.value_ptr.* == .null) {
            const name = try parser.allocator.dupe(u8, entry.key_ptr.*);
            const removed = parser.anchors.fetchRemove(entry.key_ptr.*) orelse unreachable;
            parser.allocator.free(removed.key);
            removed.value.deinit(parser.allocator);
            const cloned = try seq.deepClone(parser.allocator);
            try parser.anchors.put(name, cloned);
            break;
        }
    }
}

pub fn parseEntryValueAfterColon(parser: *Parser, indent: usize, allow_mapping: bool) YamlError!Value {
    if (parser.hasInlineValue()) {
        if (isNextAnchorOnOwnLine(parser)) {
            return anchor_mod.parseAnchoredValue(parser, indent + 1);
        }
        if (!allow_mapping) {
            if (parser.scanner.peek() == .dash and parser.scanner.peekTokenAt(1).isColonValueSep()) {
                return YamlError.UnexpectedToken;
            }
        }
        const value = try parser.parseValueWithContext(indent + _parser.DEFAULT_INDENT_STEP, true);
        if (hasTrailingColonOnLine(parser)) {
            if (allow_mapping) return parser.tryAsMappingOrReturn(value, indent, false);
            value.deinit(parser.allocator);
            return YamlError.UnexpectedToken;
        }
        return value;
    }

    if (parser.scanner.peek() == .hash) {
        parser.scanner.skipLine();
    }
    parser.skipNewlines();
    skipBlankLinesAndComments(parser);

    const next_indent = parser.scanner.countIndentAtLineStart();
    if (next_indent > indent) {
        parser.scanner.skipKnownSpaces(next_indent);
        if (parser.scanner.peek() == .ampersand) blk: {
            const saved = parser.scanner.pos;
            const anchor_val = anchor_mod.parseAnchoredValue(parser, next_indent) catch {
                parser.scanner.pos = saved;
                break :blk;
            };
            if (anchor_val != .null) return anchor_val;
            const after_indent = parser.scanner.countIndentAtLineStart();
            if (after_indent != indent) break :blk;
            parser.scanner.skipKnownSpaces(after_indent);
            if (parser.scanner.peek() != .dash or !parser.scanner.peekTokenAt(1).isColonValueSep()) break :blk;
            const seq = try block_mod.parseBlockSequence(parser, indent);
            try resolvePendingAnchors(parser, seq);
            return seq;
        }
        return parser.parseValueWithContext(next_indent, false);
    }

    if (next_indent == indent) {
        parser.scanner.skipKnownSpaces(next_indent);
        if (parser.scanner.peek() == .dash and parser.scanner.peekTokenAt(1).isColonValueSep()) {
            return block_mod.parseBlockSequence(parser, indent);
        }
        parser.scanner.pos -= next_indent;
    }
    return .null;
}

pub fn mergeSubMapping(parser: *Parser, map: *Value.Mapping, sub: Value) YamlError!void {
    var owned = sub;
    var iter = owned.mapping.iterator();
    while (iter.next()) |entry| {
        const gop = try map.getOrPut(entry.key_ptr.*);
        if (gop.found_existing) {
            entry.value_ptr.*.deinit(parser.allocator);
            parser.allocator.free(entry.key_ptr.*);
            return YamlError.DuplicateKey;
        }
        gop.value_ptr.* = entry.value_ptr.*;
    }
    owned.mapping.deinit();
}

pub fn skipToEntry(parser: *Parser, indent: usize) ?usize {
    parser.skipNewlines();
    directive_mod.skipInlineComment(parser);
    skipBlankLinesAndComments(parser);
    if (parser.scanner.isEof()) return null;
    const current_indent = parser.scanner.countIndentAtLineStart();
    if (current_indent != indent) return null;
    if (parser.scanner.startWith(_parser.DOC_BOUNDARY) or parser.scanner.startWith(_parser.DOC_TERMINATOR)) return null;
    return current_indent;
}

pub fn tryExplicitKeyEntry(parser: *Parser, map: *Value.Mapping, indent: usize) YamlError!EntryAction {
    if (parser.scanner.peek() != .question) return .skip;
    const next_tok = parser.scanner.peekTokenAt(1);
    if (next_tok != .space and next_tok != .tab) return .skip;
    const sub = try parseBlockMapping(parser, indent);
    try mergeSubMapping(parser, map, sub);
    return .consumed;
}

pub fn tryInlineAnchorKey(parser: *Parser, map: *Value.Mapping, indent: usize) YamlError!EntryAction {
    if (parser.scanner.peek() != .ampersand) return .skip;
    parser.scanner.skip();
    const anchor_name = try anchor_mod.readAnchorName(parser);
    errdefer parser.allocator.free(anchor_name);
    parser.scanner.skipWhitespace();
    if (parser.scanner.peek() == .asterisk) return YamlError.AnchorOnAlias;

    const key_val = try parser.parseValueWithContext(indent, true);
    const akey = try parser.keyToString(key_val);
    key_val.deinit(parser.allocator);

    parser.scanner.skipWhitespace();
    const val: Value = if (parser.scanner.peek() == .colon) blk: {
        parser.scanner.skip();
        parser.scanner.skipWhitespace();
        break :blk try parseEntryValueAfterColon(parser, indent, false);
    } else .null;

    if (parser.anchors.fetchRemove(anchor_name)) |removed| {
        parser.allocator.free(removed.key);
        removed.value.deinit(parser.allocator);
    }
    const cloned = try val.deepClone(parser.allocator);
    errdefer cloned.deinit(parser.allocator);
    const replaced = try parser.anchors.fetchPut(anchor_name, cloned);
    if (replaced) |r| {
        parser.allocator.free(r.key);
        r.value.deinit(parser.allocator);
    }
    try map.put(akey, val);
    return .consumed;
}

pub fn tryBareColonKey(parser: *Parser, map: *Value.Mapping, indent: usize) YamlError!EntryAction {
    if (parser.scanner.peek() != .colon) return .skip;
    const next_tok = parser.scanner.peekTokenAt(1);
    if (next_tok != .space and next_tok != .newline and next_tok != .eof) return .skip;
    parser.scanner.skip();
    parser.scanner.skipWhitespace();
    const colon_val = try parseEntryValueAfterColon(parser, indent, false);
    try map.put(try parser.allocator.dupe(u8, ""), colon_val);
    return .consumed;
}

pub fn tryQuotedKeyEntry(parser: *Parser, map: *Value.Mapping, indent: usize, quote: Token) YamlError!EntryAction {
    const saved = parser.scanner.pos;
    var has_newline = false;
    parser.scanner.skip();
    while (!parser.scanner.isEof()) {
        const tok = parser.scanner.peek();
        if (tok == quote) {
            parser.scanner.skip();
            break;
        }
        if (tok == .newline) {
            has_newline = true;
            break;
        }
        if (tok == .backslash and quote == .double_quote and parser.scanner.peekTokenAt(1) != .eof) parser.scanner.skip();
        parser.scanner.skip();
    }
    if (has_newline) {
        parser.scanner.pos = saved;
        return .skip;
    }
    parser.scanner.pos = saved;
    const scalar = if (quote == .double_quote) try scalar_mod.parseDoubleQuotedScalar(parser) else try scalar_mod.parseSingleQuotedScalar(parser);
    const qkey = try parser.keyToString(scalar);
    scalar.deinit(parser.allocator);
    parser.scanner.skipWhitespace();
    if (parser.scanner.peek() != .colon) {
        parser.allocator.free(qkey);
        return .skip;
    }
    parser.scanner.skip();
    parser.scanner.skipWhitespace();
    const qval = try parseNextEntryValue(parser, indent);
    try map.put(qkey, qval);
    return .consumed;
}

pub fn tryAnchorAliasKeyEntry(parser: *Parser, map: *Value.Mapping, indent: usize) YamlError!EntryAction {
    const peek_tok = parser.scanner.peek();
    if (peek_tok != .ampersand and peek_tok != .asterisk) return .skip;
    const saved = parser.scanner.pos;
    parser.scanner.skip();
    while (true) {
        const t = parser.scanner.peek();
        if (t == .space or t == .tab or t == .newline) break;
        if (t == .eof) break;
        parser.scanner.skip();
    }
    parser.scanner.skipWhitespace();
    const is_key = parser.scanner.peek() == .colon;
    parser.scanner.pos = saved;
    if (!is_key) return .skip;

    const key_val = if (peek_tok == .ampersand) try anchor_mod.parseAnchoredValue(parser, indent) else try anchor_mod.parseAlias(parser);
    const key_str = try parser.keyToString(key_val);
    key_val.deinit(parser.allocator);
    parser.scanner.skipWhitespace();
    std.debug.assert(parser.scanner.peek() == .colon);
    parser.scanner.skip();
    parser.scanner.skipWhitespace();
    const val = try parseEntryValueAfterColon(parser, indent, false);
    try map.put(key_str, val);
    return .consumed;
}

pub fn tryTaggedKeyEntry(parser: *Parser, map: *Value.Mapping, indent: usize) YamlError!EntryAction {
    if (parser.scanner.peek() != .bang) return .skip;
    const saved = parser.scanner.pos;
    const tagged_val = try anchor_mod.parseTaggedValue(parser, indent);
    var tv = tagged_val;
    const tkey = try parser.keyToString(tv);
    tv.deinit(parser.allocator);
    parser.scanner.skipWhitespace();
    if (parser.scanner.peek() != .colon) {
        parser.allocator.free(tkey);
        parser.scanner.pos = saved;
        return .skip;
    }
    parser.scanner.skip();
    parser.scanner.skipWhitespace();
    const tval = try parseNextEntryValue(parser, indent);
    try map.put(tkey, tval);
    return .consumed;
}

pub fn tryAliasKeyEntry(parser: *Parser, map: *Value.Mapping, indent: usize) YamlError!EntryAction {
    if (parser.scanner.peek() != .asterisk) return .skip;
    const alias_key = try anchor_mod.parseAlias(parser);
    const alkey = try parser.keyToString(alias_key);
    alias_key.deinit(parser.allocator);
    parser.scanner.skipWhitespace();
    if (parser.scanner.peek() != .colon) {
        parser.allocator.free(alkey);
        return .skip;
    }
    parser.scanner.skip();
    parser.scanner.skipWhitespace();
    const alval = try parseNextEntryValue(parser, indent);
    try map.put(alkey, alval);
    return .consumed;
}

pub fn tryPlainScalarKeyEntry(parser: *Parser, map: *Value.Mapping, indent: usize) YamlError!EntryAction {
    if (parser.scanner.isEof()) return .skip;
    if (!_parser.isPlainKey(parser.scanner.source[parser.scanner.pos])) return .skip;

    const saved_line_start = parser.scanner.line_start;
    const before_key = parser.scanner.pos;
    const next_key_val = try scalar_mod.parsePlainScalar(parser, indent);
    const next_key_str = try parser.keyToString(next_key_val);
    next_key_val.deinit(parser.allocator);
    var next_key_in_map = false;
    errdefer if (!next_key_in_map) parser.allocator.free(next_key_str);

    parser.scanner.skipWhitespace();
    if (parser.scanner.peek() != .colon) {
        parser.allocator.free(next_key_str);
        if (before_key == saved_line_start or parser.scanner.peek() == .eof) {
            parser.scanner.pos = before_key;
        }
        return .skip;
    }
    parser.scanner.skip();
    parser.scanner.skipWhitespace();

    var next_value = try parseNextEntryValue(parser, indent);

    const gop = try map.getOrPut(next_key_str);
    if (gop.found_existing) {
        next_key_in_map = true;
        parser.allocator.free(next_key_str);
        next_value.deinit(parser.allocator);
        return YamlError.DuplicateKey;
    }
    gop.value_ptr.* = next_value;
    next_key_in_map = true;
    return .consumed;
}

pub fn parseNextMappingEntries(parser: *Parser, map: *Value.Mapping, indent: usize) YamlError!void {
    while (!parser.scanner.isEof()) {
        const current_indent = skipToEntry(parser, indent) orelse break;
        try parser.checkTabIndent();
        parser.scanner.skipKnownSpaces(current_indent);

        if (try tryExplicitKeyEntry(parser, map, indent) == .consumed) continue;
        if (try tryInlineAnchorKey(parser, map, indent) == .consumed) continue;

        if (parser.scanner.isEof() or !_parser.isPlainKey(parser.scanner.source[parser.scanner.pos])) {
            if (try tryBareColonKey(parser, map, indent) == .consumed) continue;
            const peek_tok = parser.scanner.peek();
            if (peek_tok == .double_quote or peek_tok == .single_quote) {
                if (try tryQuotedKeyEntry(parser, map, indent, peek_tok) == .consumed) continue;
                break;
            }
            if (try tryAnchorAliasKeyEntry(parser, map, indent) == .consumed) continue;
            break;
        }

        if (try tryTaggedKeyEntry(parser, map, indent) == .consumed) continue;
        if (try tryAliasKeyEntry(parser, map, indent) == .consumed) continue;
        if (try tryBareColonKey(parser, map, indent) == .consumed) continue;
        if (try tryPlainScalarKeyEntry(parser, map, indent) == .consumed) continue;
        break;
    }
}

pub fn parseNextEntryValue(parser: *Parser, indent: usize) YamlError!Value {
    if (parser.hasInlineValue()) {
        if (isNextAnchorOnOwnLine(parser)) {
            return anchor_mod.parseAnchoredValue(parser, indent + 1);
        }
        return parser.parseValueWithContext(indent + _parser.DEFAULT_INDENT_STEP, true);
    }

    if (parser.scanner.peek() == .hash) {
        parser.scanner.skipLine();
    }
    if (parser.scanner.peek() == .newline) parser.scanner.skip();
    parser.skipNewlines();
    skipBlankLinesAndComments(parser);

    const val_indent = parser.scanner.countIndentAtLineStart();
    if (val_indent > indent) {
        parser.scanner.skipKnownSpaces(val_indent);
        return parser.parseValueWithContext(val_indent, false);
    }
    if (val_indent == indent) {
        parser.scanner.skipKnownSpaces(val_indent);
        if (parser.scanner.peek() == .dash and parser.scanner.peekTokenAt(1).isColonValueSep()) {
            return block_mod.parseBlockSequence(parser, indent);
        }
        parser.scanner.pos -= val_indent;
    }
    return .null;
}
