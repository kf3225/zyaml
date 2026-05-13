const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Token = @import("token.zig").Token;
const Value = @import("../ast/value.zig").Value;
const YamlError = @import("../error.zig").YamlError;
const _parser = @import("parser.zig");

pub fn isDocBoundaryTerminator(tok: Token) bool {
    return tok == .eof or tok.isWsOrNewline();
}

pub fn isDocStart(parser: *Parser) bool {
    if (!parser.scanner.startWith(_parser.DOC_BOUNDARY)) return false;
    return isDocBoundaryTerminator(parser.scanner.peekTokenAt(_parser.DOC_BOUNDARY_LEN));
}

pub fn isDocEnd(parser: *Parser) bool {
    if (!parser.scanner.startWith(_parser.DOC_TERMINATOR)) return false;
    return isDocBoundaryTerminator(parser.scanner.peekTokenAt(_parser.DOC_BOUNDARY_LEN));
}

pub fn clearTagHandles(parser: *Parser) void {
    var it = parser.tag_handles.iterator();
    while (it.next()) |entry| {
        parser.allocator.free(entry.key_ptr.*);
        parser.allocator.free(entry.value_ptr.*);
    }
    parser.tag_handles.clearAndFree();
}

pub fn skipCommentsAndBlankLines(parser: *Parser) void {
    while (!parser.scanner.isEof()) {
        parser.scanner.skipWhitespace();
        switch (parser.scanner.peek()) {
            .hash => parser.scanner.skipLine(),
            .newline => parser.scanner.skip(),
            else => break,
        }
    }
}

pub fn skipInlineComment(parser: *Parser) void {
    if (parser.scanner.peek() == .hash) {
        parser.scanner.skipLine();
    }
}

pub fn skipDirectives(parser: *Parser) YamlError!void {
    parser.has_yaml_directive = false;
    clearTagHandles(parser);
    while (!parser.scanner.isEof()) {
        parser.scanner.skipWhitespaceAndNewlines();
        if (parser.scanner.peek() != .percent) break;
        parser.scanner.skip();
        if (parser.scanner.startWith("YAML") and
            (parser.scanner.peekTokenAt(4) == .space or parser.scanner.peekTokenAt(4) == .tab))
        {
            if (parser.has_yaml_directive) return YamlError.UnexpectedToken;
            parser.has_yaml_directive = true;
            try parseYamlVersionDirective(parser);
        }
        if (parser.scanner.startWith("TAG") and
            (parser.scanner.peekTokenAt(3) == .space))
        {
            try parseTagDirective(parser);
        }
        parser.scanner.skipLine();
    }
}

pub fn parseYamlVersionDirective(parser: *Parser) YamlError!void {
    parser.scanner.skipBytes(4);
    const ws_start = parser.scanner.pos;
    parser.scanner.skipWhitespace();
    if (parser.scanner.pos == ws_start) return YamlError.UnexpectedToken;

    const major = parseVersionNumber(parser);
    skipVersionMinor(parser);

    if (major > 1) return YamlError.UnsupportedVersion;

    const ws2_start = parser.scanner.pos;
    parser.scanner.skipWhitespace();
    const tok = parser.scanner.peek();
    if (tok == .hash and parser.scanner.pos == ws2_start) return YamlError.UnexpectedToken;
    if (tok != .hash and tok != .newline and tok != .cr) return YamlError.UnexpectedToken;
}

pub fn parseVersionNumber(parser: *Parser) usize {
    var n: usize = 0;
    while (parser.scanner.peek() == .other) {
        const ch = parser.scanner.source[parser.scanner.pos];
        if (ch < '0' or ch > '9') break;
        n = n * 10 + @as(usize, ch - '0');
        parser.scanner.skip();
    }
    return n;
}

pub fn skipVersionMinor(parser: *Parser) void {
    if (parser.scanner.peek() == .dot) parser.scanner.skip();
    while (parser.scanner.peek() == .other) {
        const ch = parser.scanner.source[parser.scanner.pos];
        if (ch < '0' or ch > '9') break;
        parser.scanner.skip();
    }
}

pub fn parseTagDirective(parser: *Parser) YamlError!void {
    parser.scanner.skipBytes(3);
    parser.scanner.skipWhitespace();
    const handle_start = parser.scanner.pos;
    while (parser.scanner.peek() != .space) {
        if (parser.scanner.isEof()) break;
        parser.scanner.skip();
    }
    const handle = parser.scanner.source[handle_start..parser.scanner.pos];
    if (handle.len == 0 or handle[0] != '!') return YamlError.UnexpectedToken;
    parser.scanner.skipWhitespace();
    const prefix_start = parser.scanner.pos;
    while (true) {
        const tok = parser.scanner.peek();
        if (tok == .space or tok == .newline or tok == .hash) break;
        if (tok == .eof) break;
        parser.scanner.skip();
    }
    const prefix = parser.scanner.source[prefix_start..parser.scanner.pos];
    if (prefix.len == 0) return YamlError.UnexpectedToken;
    const handle_copy = try parser.allocator.dupe(u8, handle);
    const prefix_copy = try parser.allocator.dupe(u8, prefix);
    const existing = try parser.tag_handles.fetchPut(handle_copy, prefix_copy);
    if (existing) |e| {
        parser.allocator.free(e.key);
        parser.allocator.free(e.value);
    }
}

pub fn skipDocumentStart(parser: *Parser) bool {
    if (!parser.scanner.startWith(_parser.DOC_BOUNDARY)) return false;
    if (!isDocBoundaryTerminator(parser.scanner.peekTokenAt(_parser.DOC_BOUNDARY_LEN))) return false;
    parser.had_document = true;
    parser.scanner.skipBytes(_parser.DOC_BOUNDARY_LEN);
    parser.scanner.skipWhitespace();
    if (parser.scanner.peek() == .newline) parser.scanner.skip();
    return true;
}

pub fn skipDocumentSeparator(parser: *Parser) void {
    parser.scanner.skipBytes(_parser.DOC_BOUNDARY_LEN);
    parser.scanner.skipWhitespace();
    if (parser.scanner.peek() == .newline) parser.scanner.skip();
}

pub fn appendDocValue(parser: *Parser, seq: *Value.Sequence) YamlError!void {
    skipCommentsAndBlankLines(parser);
    if (parser.scanner.isEof()) {
        try seq.append(.null);
        return;
    }
    if (isDocStart(parser) or isDocEnd(parser)) {
        try seq.append(.null);
        return;
    }
    try seq.append(try parser.parseValueWithContext(0, false));
    skipCommentsAndBlankLines(parser);
}

pub fn handleDocEnd(parser: *Parser, seq: *Value.Sequence) YamlError!void {
    parser.scanner.skipBytes(_parser.DOC_BOUNDARY_LEN);
    parser.scanner.skipWhitespace();
    const after_tok = parser.scanner.peek();
    if (after_tok != .eof and after_tok != .newline and after_tok != .hash) {
        parser.scanner.skipLine();
        skipCommentsAndBlankLines(parser);
        if (!isDocStart(parser)) {
            try seq.append(try parser.parseValueWithContext(0, false));
            skipCommentsAndBlankLines(parser);
            return;
        }
        skipDocumentSeparator(parser);
        skipCommentsAndBlankLines(parser);
        if (parser.scanner.isEof()) {
            try seq.append(.null);
            return;
        }
        try seq.append(try parser.parseValueWithContext(0, false));
        skipCommentsAndBlankLines(parser);
        return;
    }
    parser.scanner.skipLine();
    skipCommentsAndBlankLines(parser);
    try skipDirectives(parser);
    skipCommentsAndBlankLines(parser);
    if (!isDocStart(parser) and !isDocEnd(parser)) {
        if (!parser.scanner.isEof() and parser.scanner.peek() != .eof and parser.scanner.peek() != .newline) {
            try seq.append(try parser.parseValueWithContext(0, false));
            skipCommentsAndBlankLines(parser);
            return;
        }
    }
}

pub fn parseMultiDocument(parser: *Parser, first_value: Value) YamlError!Value {
    var seq = Value.Sequence.init(parser.allocator);
    errdefer {
        for (seq.items) |*item| item.deinit(parser.allocator);
        seq.deinit();
    }
    try seq.append(first_value);

    if (!parser.scanner.isEof() and !isDocStart(parser) and !isDocEnd(parser) and parser.scanner.peek() != .percent) {
        try seq.append(try parser.parseValueWithContext(0, false));
        skipCommentsAndBlankLines(parser);
    }

    while (isDocStart(parser) or isDocEnd(parser) or parser.scanner.peek() == .percent) {
        if (parser.scanner.peek() == .percent) {
            parser.has_yaml_directive = false;
            try skipDirectives(parser);
            skipCommentsAndBlankLines(parser);
            if (!isDocStart(parser)) break;
            skipDocumentSeparator(parser);
            try appendDocValue(parser, &seq);
            continue;
        }
        if (isDocEnd(parser)) {
            try handleDocEnd(parser, &seq);
            continue;
        }
        skipDocumentSeparator(parser);
        try skipDirectives(parser);
        try appendDocValue(parser, &seq);
    }

    if (seq.items.len == 1) {
        const single = seq.items[0];
        seq.deinit();
        return single;
    }

    return .{ .sequence = seq };
}

fn anchorPrecedesMappingKey(source: []const u8, start: usize) bool {
    var scan = start;
    while (scan < source.len) : (scan += 1) {
        const c = source[scan];
        if (c == '\n') return false;
        if (c == ':' and scan + 1 < source.len and Token.from(source[scan + 1]).isWsOrNewline()) return true;
    }
    return false;
}

pub fn parse(parser: *Parser) YamlError!Value {
    try skipDirectives(parser);
    const first_marker = skipDocumentStart(parser);
    skipCommentsAndBlankLines(parser);
    if (!first_marker) _ = skipDocumentStart(parser);

    if (parser.scanner.isEof()) {
        if (parser.has_yaml_directive and !parser.had_document) return YamlError.UnexpectedToken;
        return .null;
    }

    if (parser.scanner.peek() == .percent) return YamlError.UnexpectedToken;

    if (first_marker and parser.scanner.peek() == .ampersand) {
        if (anchorPrecedesMappingKey(parser.scanner.source, parser.scanner.pos)) return YamlError.UnexpectedToken;
    }

    if (!parser.scanner.isEof()) {
        const tok = parser.scanner.peek();
        if (tok != .open_bracket and tok != .open_brace and tok != .dash and tok != .question) {
            try parser.checkTabIndent();
        }
    }

    if (isDocStart(parser) or isDocEnd(parser)) {
        if (isDocEnd(parser) and !isDocStart(parser) and parser.has_yaml_directive) return YamlError.UnexpectedToken;
        return parseMultiDocument(parser, .null);
    }

    const first_value = try parser.parseValueWithContext(0, false);
    parser.had_document = true;
    skipCommentsAndBlankLines(parser);

    if (parser.scanner.isEof()) return first_value;

    if (isDocStart(parser)) {
        return parseMultiDocument(parser, first_value);
    }
    if (isDocEnd(parser)) {
        parser.scanner.skipBytes(_parser.DOC_BOUNDARY_LEN);
        parser.scanner.skipWhitespace();
        const after_tok = parser.scanner.peek();
        if (after_tok != .eof and after_tok != .newline and after_tok != .hash) {
            first_value.deinit(parser.allocator);
            return YamlError.UnexpectedToken;
        }
        parser.scanner.skipLine();
        skipCommentsAndBlankLines(parser);
        if (!parser.scanner.isEof()) {
            return parseMultiDocument(parser, first_value);
        }
        return first_value;
    }
    first_value.deinit(parser.allocator);
    return YamlError.UnexpectedToken;
}
