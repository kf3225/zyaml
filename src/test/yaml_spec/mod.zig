const std = @import("std");
const zyaml = @import("zyaml");

pub const TestCase = struct {
    name: []const u8,
    input: []const u8,
    expected: Expected,
    spec_ref: []const u8,
};

pub const Expected = union(enum) {
    value: ExpectedValue,
    err: ExpectedError,
};

pub const MappingEntry = struct {
    key: []const u8,
    value: ExpectedValue,
};

pub const ExpectedValue = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    sequence: []const ExpectedValue,
    mapping: []const MappingEntry,
};

pub const ExpectedError = struct {
    kind: ErrorKind,
    line: usize,
    column: usize,
};

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

pub fn runTestSuite(allocator: std.mem.Allocator, cases: []const TestCase) !void {
    var passed: usize = 0;
    var failed: usize = 0;

    for (cases) |case| {
        const result = runTest(allocator, case);
        if (result) |_| {
            passed += 1;
            std.debug.print("  PASS: {s}\n", .{case.name});
        } else |test_err| {
            failed += 1;
            std.debug.print("  FAIL: {s} - {}\n", .{ case.name, test_err });
        }
    }

    std.debug.print("\nResults: {}/{} passed\n", .{ passed, cases.len });
    if (failed > 0) {
        return error.TestFailed;
    }
}

pub fn runTest(allocator: std.mem.Allocator, case: TestCase) !void {
    var result = zyaml.parse(allocator, case.input) catch |err| {
        switch (case.expected) {
            .err => |expected_err| {
                const matched = matchError(err, expected_err.kind);
                if (!matched) {
                    std.debug.print("    Expected error: {}, got: {}\n", .{ expected_err.kind, err });
                    return error.TestFailed;
                }
                return;
            },
            .value => {
                std.debug.print("    Expected value, got error: {}\n", .{err});
                return error.TestFailed;
            },
        }
    };
    defer result.deinit(allocator);

    switch (case.expected) {
        .err => |expected_err| {
            std.debug.print("    Expected error: {}, got value\n", .{expected_err.kind});
            return error.TestFailed;
        },
        .value => |expected_val| {
            try assertValueEqual(allocator, result, expected_val);
        },
    }
}

fn matchError(err: anyerror, kind: ErrorKind) bool {
    return switch (kind) {
        .tab_indentation => err == error.TabIndentation,
        .invalid_indentation => err == error.InvalidIndentation,
        .unclosed_flow_sequence => err == error.UnclosedFlowSequence,
        .unclosed_flow_mapping => err == error.UnclosedFlowMapping,
        .unclosed_scalar => err == error.UnclosedScalar,
        .invalid_escape_sequence => err == error.InvalidEscapeSequence,
        .duplicate_key => err == error.DuplicateKey,
        .unknown_alias => err == error.UnknownAlias,
        .invalid_tag => err == error.InvalidTag,
        .unsupported_version => err == error.UnsupportedVersion,
        .invalid_document => err == error.InvalidDocument,
        .circular_reference => err == error.CircularReference,
        .unexpected_token => err == error.UnexpectedToken,
        .expected_value => err == error.ExpectedValue,
    };
}

fn assertFloatEqual(expected: f64, actual: f64) !void {
    if (std.math.isNan(expected)) {
        if (std.math.isNan(actual)) return;
        std.debug.print("    Expected NaN, got: {}\n", .{actual});
        return error.TestFailed;
    }
    if (std.math.isInf(expected)) {
        if (std.math.isInf(actual) and std.math.sign(expected) == std.math.sign(actual)) return;
        std.debug.print("    Expected inf: {}, got: {}\n", .{ expected, actual });
        return error.TestFailed;
    }
    if (@abs(actual - expected) <= 0.0001) return;
    std.debug.print("    Expected float: {}, got: {}\n", .{ expected, actual });
    return error.TestFailed;
}

fn assertValueEqual(allocator: std.mem.Allocator, actual: zyaml.YamlValue, expected: ExpectedValue) !void {
    switch (expected) {
        .null => {
            if (actual != .null) {
                std.debug.print("    Expected null, got: {s}\n", .{@tagName(actual)});
                return error.TestFailed;
            }
        },
        .boolean => |expected_bool| {
            if (actual != .boolean or actual.boolean != expected_bool) {
                if (actual == .boolean) {
                    std.debug.print("    Expected boolean: {}, got: {}\n", .{ expected_bool, actual.boolean });
                } else {
                    std.debug.print("    Expected boolean: {}, got: {s}\n", .{ expected_bool, @tagName(actual) });
                }
                return error.TestFailed;
            }
        },
        .integer => |expected_int| {
            if (actual != .integer or actual.integer != expected_int) {
                if (actual == .integer) {
                    std.debug.print("    Expected integer: {}, got: {}\n", .{ expected_int, actual.integer });
                } else {
                    std.debug.print("    Expected integer: {}, got: {s}\n", .{ expected_int, @tagName(actual) });
                }
                return error.TestFailed;
            }
        },
        .float => |expected_float| {
            if (actual != .float) {
                std.debug.print("    Expected float: {}, got: {s}\n", .{ expected_float, @tagName(actual) });
                return error.TestFailed;
            }
            try assertFloatEqual(expected_float, actual.float);
        },
        .string => |expected_str| {
            if (actual != .string) {
                std.debug.print("    Expected string, got: {s}\n", .{@tagName(actual)});
                return error.TestFailed;
            }
            if (!std.mem.eql(u8, actual.string, expected_str)) {
                std.debug.print("    Expected string: \"{s}\", got: \"{s}\"\n", .{ expected_str, actual.string });
                return error.TestFailed;
            }
        },
        .sequence => |expected_seq| {
            if (actual != .sequence) {
                std.debug.print("    Expected sequence, got: {s}\n", .{@tagName(actual)});
                return error.TestFailed;
            }
            if (actual.sequence.items.len != expected_seq.len) {
                std.debug.print("    Expected sequence length: {}, got: {}\n", .{ expected_seq.len, actual.sequence.items.len });
                return error.TestFailed;
            }
            for (expected_seq, 0..) |expected_item, idx| {
                try assertValueEqual(allocator, actual.sequence.items[idx], expected_item);
            }
        },
        .mapping => |entries| {
            if (actual != .mapping) {
                std.debug.print("    Expected mapping, got: {s}\n", .{@tagName(actual)});
                return error.TestFailed;
            }
            if (actual.mapping.count() != entries.len) {
                std.debug.print("    Expected mapping count: {}, got: {}\n", .{ entries.len, actual.mapping.count() });
                return error.TestFailed;
            }
            for (entries) |entry| {
                if (actual.mapping.get(entry.key)) |val| {
                    try assertValueEqual(allocator, val, entry.value);
                } else {
                    std.debug.print("    Missing key: \"{s}\"\n", .{entry.key});
                    return error.TestFailed;
                }
            }
        },
    }
}

pub fn e(kind: ErrorKind, line_arg: usize, column_arg: usize) Expected {
    return .{ .err = .{
        .kind = kind,
        .line = line_arg,
        .column = column_arg,
    } };
}

pub fn ok(expected_val: ExpectedValue) Expected {
    return .{ .value = expected_val };
}

pub fn s(str: []const u8) ExpectedValue {
    return .{ .string = str };
}

pub fn i(num: i64) ExpectedValue {
    return .{ .integer = num };
}

pub fn f(num: f64) ExpectedValue {
    return .{ .float = num };
}

pub fn b(bool_val: bool) ExpectedValue {
    return .{ .boolean = bool_val };
}

pub fn n() ExpectedValue {
    return .null;
}

pub fn seq(values: []const ExpectedValue) ExpectedValue {
    return .{ .sequence = values };
}

pub fn map(entries: []const MappingEntry) ExpectedValue {
    return .{ .mapping = entries };
}

test "test utilities" {
    try std.testing.expect(true);
}
