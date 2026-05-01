const std = @import("std");
const YamlError = @import("../error.zig").YamlError;

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

    pub fn peek(self: Scanner) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    pub fn peekAt(self: Scanner, offset: usize) ?u8 {
        // Wrapping add so overflow is detectable via idx < self.pos below
        const idx = self.pos +% offset;
        if (idx < self.pos or idx >= self.source.len) return null;
        return self.source[idx];
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

    pub fn startWith(self: *Scanner, prefix: []const u8) bool {
        if (prefix.len > self.source.len or self.pos > self.source.len - prefix.len) return false;
        return std.mem.eql(u8, self.source[self.pos .. self.pos + prefix.len], prefix);
    }

    pub fn skipBytes(self: *Scanner, count: usize) void {
        const end = @min(self.pos + count, self.source.len);
        for (self.source[self.pos..end]) |ch| {
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

    pub fn skipWhitespace(self: *Scanner) void {
        while (self.peek()) |ch| {
            if (ch != ' ' and ch != '\t') break;
            self.skip();
        }
    }

    pub fn skipWhitespaceAndNewlines(self: *Scanner) void {
        while (self.peek()) |ch| {
            if (ch != ' ' and ch != '\t' and ch != '\n') break;
            self.skip();
        }
    }

    pub fn skipLine(self: *Scanner) void {
        while (self.peek()) |ch| {
            if (ch == '\n') {
                self.skip();
                break;
            }
            self.skip();
        }
    }

    fn lineStartOffset(self: Scanner) usize {
        return self.line_start;
    }

    fn countSpacesFrom(self: Scanner, start: usize) usize {
        var count: usize = 0;
        var pos = start;
        while (pos < self.source.len) : (pos += 1) {
            if (self.source[pos] != ' ') break;
            count += 1;
        }
        return count;
    }

    pub fn countLeadingSpaces(self: Scanner) usize {
        return self.countSpacesFrom(self.pos);
    }

    pub fn countIndentAtLineStart(self: Scanner) usize {
        return self.countSpacesFrom(self.lineStartOffset());
    }

    pub fn hasTabAtLineStart(self: Scanner) bool {
        var pos = self.lineStartOffset();
        while (pos < self.source.len) : (pos += 1) {
            if (self.source[pos] == '\t') return true;
            if (self.source[pos] != ' ') break;
        }
        return false;
    }
};
