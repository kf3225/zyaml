pub const Token = enum {
    eof,
    newline,
    space,
    tab,
    colon,
    hash,
    dash,
    ampersand,
    asterisk,
    bang,
    open_bracket,
    close_bracket,
    open_brace,
    close_brace,
    comma,
    double_quote,
    single_quote,
    question,
    percent,
    pipe,
    greater,
    less,
    plus,
    dot,
    tilde,
    backslash,
    cr,
    other,

    pub fn from(byte: ?u8) Token {
        return if (byte == null) .eof else switch (byte.?) {
            '\n' => .newline,
            ' ' => .space,
            '\t' => .tab,
            ':' => .colon,
            '#' => .hash,
            '-' => .dash,
            '&' => .ampersand,
            '*' => .asterisk,
            '!' => .bang,
            '[' => .open_bracket,
            ']' => .close_bracket,
            '{' => .open_brace,
            '}' => .close_brace,
            ',' => .comma,
            '"' => .double_quote,
            '\'' => .single_quote,
            '?' => .question,
            '%' => .percent,
            '|' => .pipe,
            '>' => .greater,
            '<' => .less,
            '+' => .plus,
            '.' => .dot,
            '~' => .tilde,
            '\\' => .backslash,
            '\r' => .cr,
            else => .other,
        };
    }

    pub fn isColonValueSep(self: Token) bool {
        return switch (self) {
            .space, .tab, .newline, .cr, .eof => true,
            else => false,
        };
    }

    pub fn isFlowDelim(self: Token) bool {
        return switch (self) {
            .comma, .close_bracket, .close_brace => true,
            else => false,
        };
    }

    pub fn isWsOrNewline(self: Token) bool {
        return switch (self) {
            .space, .tab, .newline, .cr => true,
            else => false,
        };
    }

    pub fn isAnchorTerminator(self: Token) bool {
        return switch (self) {
            .eof, .space, .tab, .newline, .cr, .comma, .open_bracket, .close_bracket, .open_brace, .close_brace => true,
            else => false,
        };
    }

    pub fn isTagTerminator(self: Token) bool {
        return switch (self) {
            .eof, .space, .newline, .comma, .close_brace, .close_bracket => true,
            else => false,
        };
    }

    pub fn isBlockIndicator(self: Token) bool {
        return switch (self) {
            .dash, .question, .colon, .pipe, .greater => true,
            else => false,
        };
    }
};
