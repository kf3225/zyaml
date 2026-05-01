const std = @import("std");

pub const ErrorKind = enum {
    tab_indentation,
    invalid_indentation,
    unclosed_flow_sequence,
    unclosed_flow_mapping,
    unclosed_scalar,
    invalid_escape_sequence,
    duplicate_key,
    unknown_alias,
    invalid_tag,
    unsupported_version,
    invalid_document,
    circular_reference,
    unexpected_token,
    expected_value,
};

pub const ErrorInfo = struct {
    kind: ErrorKind,
    message: []const u8,
    line: usize,
    column: usize,
    byte_offset: usize,
};

pub const YamlError = error{
    TabIndentation,
    InvalidIndentation,
    UnclosedFlowSequence,
    UnclosedFlowMapping,
    UnclosedScalar,
    InvalidEscapeSequence,
    DuplicateKey,
    UnknownAlias,
    InvalidTag,
    UnsupportedVersion,
    InvalidDocument,
    CircularReference,
    UnexpectedToken,
    ExpectedValue,
    OutOfMemory,
    InvalidUtf8,
    UnexpectedEof,
};

pub fn makeError(kind: ErrorKind, line: usize, column: usize, byte_offset: usize) ErrorInfo {
    return .{
        .kind = kind,
        .message = @tagName(kind),
        .line = line,
        .column = column,
        .byte_offset = byte_offset,
    };
}
