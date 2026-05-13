const std = @import("std");
const Token = @import("token.zig").Token;

pub const Scanner = struct {
    source: []const u8,
    pos: usize,
    line: usize,
    column: usize,
    line_start: usize,

    pub fn init(source: []const u8) Scanner {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .column = 1,
            .line_start = 0,
        };
    }

    pub fn peek(self: Scanner) Token {
        if (self.pos >= self.source.len) return .eof;
        return Token.from(self.source[self.pos]);
    }

    pub fn peekTokenAt(self: Scanner, offset: usize) Token {
        const idx = std.math.add(usize, self.pos, offset) catch return .eof;
        if (idx >= self.source.len) return .eof;
        return Token.from(self.source[idx]);
    }

    pub fn advance(self: *Scanner) ?u8 {
        if (self.pos >= self.source.len) return null;
        const ch = self.source[self.pos];
        self.pos += 1;
        if (ch == '\n') {
            self.line += 1;
            self.column = 1;
            self.line_start = self.pos;
        } else {
            self.column += 1;
        }
        return ch;
    }

    pub fn skip(self: *Scanner) void {
        _ = self.advance();
    }

    pub fn isEof(self: Scanner) bool {
        return self.pos >= self.source.len;
    }

    pub fn startWith(self: Scanner, comptime prefix: []const u8) bool {
        if (self.pos + prefix.len > self.source.len) return false;
        inline for (prefix, 0..) |ch, i| {
            if (self.source[self.pos + i] != ch) return false;
        }
        return true;
    }

    pub fn skipBytes(self: *Scanner, count: usize) void {
        const end = @min(self.pos + count, self.source.len);
        const slice = self.source[self.pos..end];
        if (std.mem.indexOfScalar(u8, slice, '\n')) |_| {
            for (slice) |ch| {
                self.pos += 1;
                if (ch == '\n') {
                    self.line += 1;
                    self.column = 1;
                    self.line_start = self.pos;
                } else {
                    self.column += 1;
                }
            }
        } else {
            self.pos = end;
            self.column += slice.len;
        }
    }

    pub fn skipKnownSpaces(self: *Scanner, count: usize) void {
        const actual = @min(count, self.source.len - self.pos);
        self.pos += actual;
        self.column += actual;
    }

    pub fn skipWhitespace(self: *Scanner) void {
        const remaining = self.source[self.pos..];
        var i: usize = 0;
        while (i < remaining.len) : (i += 1) {
            const ch = remaining[i];
            if (ch != ' ' and ch != '\t') break;
        }
        self.column += i;
        self.pos += i;
    }

    pub fn skipWhitespaceAndNewlines(self: *Scanner) void {
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch != ' ' and ch != '\t' and ch != '\n') break;
            self.pos += 1;
            if (ch == '\n') {
                self.line += 1;
                self.column = 1;
                self.line_start = self.pos;
            } else {
                self.column += 1;
            }
        }
    }

    pub fn skipLine(self: *Scanner) void {
        const remaining = self.source[self.pos..];
        if (std.mem.indexOfScalar(u8, remaining, '\n')) |nl_pos| {
            self.column += nl_pos;
            self.pos += nl_pos + 1;
            self.line += 1;
            self.column = 1;
            self.line_start = self.pos;
        } else {
            const skipped = remaining.len;
            self.column += skipped;
            self.pos = self.source.len;
        }
    }

    fn lineStartOffset(self: Scanner) usize {
        return self.line_start;
    }

    fn countSpacesFrom(self: Scanner, start: usize) usize {
        var pos = start;
        while (pos < self.source.len) : (pos += 1) {
            if (self.source[pos] != ' ') break;
        }
        return pos - start;
    }

    pub fn countLeadingSpaces(self: Scanner) usize {
        return self.countSpacesFrom(self.pos);
    }

    pub fn countIndentAtLineStart(self: Scanner) usize {
        return self.countSpacesFrom(self.lineStartOffset());
    }

    pub fn hasTabAsLeadingIndent(self: Scanner) bool {
        var pos = self.lineStartOffset();
        while (pos < self.source.len) : (pos += 1) {
            switch (self.source[pos]) {
                ' ' => continue,
                '\t' => return true,
                else => break,
            }
        }
        return false;
    }
};
