const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Token = @import("token.zig").Token;
const Value = @import("../ast/value.zig").Value;
const YamlError = @import("../error.zig").YamlError;
const _parser = @import("parser.zig");
const scalar_mod = @import("scalar.zig");
const anchor_mod = @import("anchor.zig");

pub fn ensureValidAfterFlowClose(parser: *Parser) YamlError!void {
    if (parser.flow_depth > 1) return;
    const tok = parser.scanner.peek();
    if (tok == .eof or tok.isWsOrNewline() or tok.isFlowDelim() or tok == .colon or tok == .percent)
        return;
    if (tok == .hash and parser.scanner.pos > 0) {
        const prev = Token.from(parser.scanner.source[parser.scanner.pos - 1]);
        if (prev == .space or prev == .tab) return;
    }
    return YamlError.UnexpectedToken;
}

pub fn skipCommentsInFlow(parser: *Parser) void {
    while (parser.scanner.peek() == .hash) {
        if (parser.scanner.pos > 0) {
            const prev = Token.from(parser.scanner.source[parser.scanner.pos - 1]);
            if (prev != .space and prev != .tab and prev != .newline) return;
        }
        parser.scanner.skipLine();
        parser.scanner.skipWhitespace();
    }
}

fn validateFlowNewlineIndent(parser: *Parser, ws_start: usize) YamlError!void {
    if (parser.scanner.isEof()) return;
    const tok = parser.scanner.peek();
    if (tok.isFlowDelim() or tok == .hash or tok == .newline) return;
    if (parser.scanner.column < parser.flow_block_indent) return YamlError.InvalidIndentation;
    if (parser.scanner.column > parser.flow_block_indent) return;
    for (parser.scanner.source[ws_start..parser.scanner.pos]) |c| {
        if (c == '\t') return YamlError.TabIndentation;
    }
}

pub fn skipFlowWhitespaceAndComments(parser: *Parser) !void {
    if (parser.flow_depth == 0 or parser.flow_block_indent == 0) {
        parser.scanner.skipWhitespaceAndNewlines();
        skipCommentsInFlow(parser);
        return;
    }
    while (!parser.scanner.isEof()) {
        switch (parser.scanner.peek()) {
            .eof => break,
            .space, .tab => parser.scanner.skip(),
            .newline => {
                parser.scanner.skip();
                const ws_start = parser.scanner.pos;
                parser.scanner.skipWhitespace();
                try validateFlowNewlineIndent(parser, ws_start);
            },
            .hash => {
                const directive_mod = @import("directive.zig");
                directive_mod.skipInlineComment(parser);
            },
            else => break,
        }
    }
}

pub fn skipTrailingComma(parser: *Parser, close: Token) !bool {
    if (parser.scanner.peek() != .comma) return false;
    parser.scanner.skip();
    try skipFlowWhitespaceAndComments(parser);
    if (parser.scanner.peek() == close) {
        parser.scanner.skip();
        return true;
    }
    return false;
}

pub fn tryCloseFlowSeq(parser: *Parser, seq: Value.Sequence) YamlError!?Value {
    if (parser.scanner.peek() != .close_bracket) return null;
    parser.scanner.skip();
    try ensureValidAfterFlowClose(parser);
    parser.flow_depth -= 1;
    return .{ .sequence = seq };
}

pub fn handleFlowSeqComma(parser: *Parser, seq: Value.Sequence) YamlError!?Value {
    if (parser.scanner.peek() != .comma) return null;
    if (seq.items.len == 0) return YamlError.UnexpectedToken;
    parser.scanner.skip();
    try skipFlowWhitespaceAndComments(parser);
    if (parser.scanner.peek() == .comma) return YamlError.UnexpectedToken;
    return tryCloseFlowSeq(parser, seq);
}

pub fn putFlowMapEntry(parser: *Parser, map: *Value.Mapping, key_str: []const u8, value: Value) YamlError!void {
    if (map.fetchSwapRemove(key_str)) |old| {
        parser.allocator.free(old.key);
        old.value.deinit(parser.allocator);
    }
    try map.put(key_str, value);
}

pub fn parseFlowMappingEntry(parser: *Parser, map: *Value.Mapping) YamlError!void {
    const key_val = try parseFlowKey(parser);
    const key_str = try parser.keyToString(key_val);
    key_val.deinit(parser.allocator);

    try skipFlowWhitespaceAndComments(parser);

    const tok = parser.scanner.peek();
    if (tok == .comma or tok == .close_brace) {
        try putFlowMapEntry(parser, map, key_str, .null);
        return;
    }
    if (tok != .colon) {
        parser.allocator.free(key_str);
        return YamlError.UnexpectedToken;
    }
    parser.scanner.skip();
    try skipFlowWhitespaceAndComments(parser);

    const after_tok = parser.scanner.peek();
    const value: Value = if (after_tok != .close_brace and after_tok != .comma)
        try parser.parseValueWithContext(0, true)
    else
        .null;

    try putFlowMapEntry(parser, map, key_str, value);
}

pub fn parseFlowSequence(parser: *Parser) YamlError!Value {
    std.debug.assert(parser.scanner.peek() == .open_bracket);
    const start_column = parser.scanner.column;
    parser.scanner.skip();
    const start_line = parser.scanner.line;
    if (parser.flow_depth == 0) {
        parser.flow_start_line = start_line;
        parser.flow_start_column = start_column;
    }
    parser.flow_depth += 1;
    errdefer parser.flow_depth -= 1;

    var seq = Value.Sequence.init(parser.allocator);
    errdefer {
        for (seq.items) |*item| item.deinit(parser.allocator);
        seq.deinit();
    }

    while (!parser.scanner.isEof()) {
        try skipFlowWhitespaceAndComments(parser);

        if (try tryCloseFlowSeq(parser, seq)) |val| return val;

        if (try handleFlowSeqComma(parser, seq)) |val| return val;

        const val = try parser.parseValueWithContext(0, false);
        try seq.append(val);

        try skipFlowWhitespaceAndComments(parser);
        if (parser.scanner.peek() == .comma) {
            parser.scanner.skip();
            try skipFlowWhitespaceAndComments(parser);
            if (parser.scanner.peek() == .comma) return YamlError.UnexpectedToken;
            if (try tryCloseFlowSeq(parser, seq)) |v| return v;
            continue;
        }
        if (try tryCloseFlowSeq(parser, seq)) |v| return v;
        if (seq.items.len > 0) return YamlError.UnexpectedToken;
    }

    return YamlError.UnclosedFlowSequence;
}

pub fn parseFlowMapping(parser: *Parser) YamlError!Value {
    std.debug.assert(parser.scanner.peek() == .open_brace);
    const start_column = parser.scanner.column;
    parser.scanner.skip();
    if (parser.flow_depth == 0) {
        parser.flow_start_line = parser.scanner.line;
        parser.flow_start_column = start_column;
    }
    parser.flow_depth += 1;
    errdefer parser.flow_depth -= 1;

    var map = Value.Mapping.init(parser.allocator);
    errdefer parser.deinitMappingEntries(&map);

    try skipFlowWhitespaceAndComments(parser);

    while (!parser.scanner.isEof()) {
        try skipFlowWhitespaceAndComments(parser);

        if (parser.scanner.peek() == .close_brace) {
            parser.scanner.skip();
            try ensureValidAfterFlowClose(parser);
            parser.flow_depth -= 1;
            return .{ .mapping = map };
        }

        if (parser.scanner.peek() == .comma) {
            if (map.count() == 0) return YamlError.UnexpectedToken;
            if (try skipTrailingComma(parser, .close_brace)) {
                try ensureValidAfterFlowClose(parser);
                parser.flow_depth -= 1;
                return .{ .mapping = map };
            }
            continue;
        }

        try parseFlowMappingEntry(parser, &map);

        try skipFlowWhitespaceAndComments(parser);
        const saved_pos = parser.scanner.pos;
        if (try skipTrailingComma(parser, .close_brace)) {
            parser.flow_depth -= 1;
            return .{ .mapping = map };
        }
        if (parser.scanner.pos == saved_pos and parser.scanner.peek() != .eof and
            parser.scanner.peek() != .close_brace)
        {
            return YamlError.UnexpectedToken;
        }
    }

    return YamlError.UnclosedFlowMapping;
}

pub fn parseFlowKey(parser: *Parser) YamlError!Value {
    parser.scanner.skipWhitespace();

    switch (parser.scanner.peek()) {
        .eof => return .null,
        .double_quote => return scalar_mod.parseDoubleQuotedScalar(parser),
        .single_quote => return scalar_mod.parseSingleQuotedScalar(parser),
        .open_bracket => return parseFlowSequence(parser),
        .open_brace => return parseFlowMapping(parser),
        .ampersand => {
            const anchored = try anchor_mod.parseAnchoredValue(parser, 0);
            parser.scanner.skipWhitespace();
            return anchored;
        },
        .asterisk => {
            const alias_val = try anchor_mod.parseAlias(parser);
            parser.scanner.skipWhitespace();
            return alias_val;
        },
        .bang => {
            const saved = parser.scanner.pos;
            var tagged = try anchor_mod.parseTaggedValue(parser, 0);
            parser.scanner.skipWhitespace();
            if (parser.scanner.peek() == .colon) return tagged;
            tagged.deinit(parser.allocator);
            parser.scanner.pos = saved;
        },
        else => {},
    }

    return scalar_mod.parsePlainScalarFlowKey(parser);
}
