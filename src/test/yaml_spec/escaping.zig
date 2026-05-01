const std = @import("std");
const yaml_spec = @import("mod.zig");

const cases = [_]yaml_spec.TestCase{
    .{
        .name = "E01: escape_n",
        .input = "\"\\n\"",
        .spec_ref = "5.7",
        .expected = yaml_spec.ok(yaml_spec.s("\n")),
    },
    .{
        .name = "E02: escape_t",
        .input = "\"\\t\"",
        .spec_ref = "5.7",
        .expected = yaml_spec.ok(yaml_spec.s("\t")),
    },
    .{
        .name = "E03: escape_r",
        .input = "\"\\r\"",
        .spec_ref = "5.7",
        .expected = yaml_spec.ok(yaml_spec.s("\r")),
    },
    .{
        .name = "E04: escape_backslash",
        .input = "\"\\\\\"",
        .spec_ref = "5.7",
        .expected = yaml_spec.ok(yaml_spec.s("\\")),
    },
    .{
        .name = "E05: escape_quote",
        .input = "\"\\\"\"",
        .spec_ref = "5.7",
        .expected = yaml_spec.ok(yaml_spec.s("\"")),
    },
    .{
        .name = "E06: escape_0",
        .input = "\"\\0\"",
        .spec_ref = "5.7",
        .expected = yaml_spec.ok(yaml_spec.s("\x00")),
    },
    .{
        .name = "E07: escape_hex_2",
        .input = "\"\\x41\"",
        .spec_ref = "5.7",
        .expected = yaml_spec.ok(yaml_spec.s("A")),
    },
    .{
        .name = "E08: escape_hex_4",
        .input = "\"\\u0041\"",
        .spec_ref = "5.7",
        .expected = yaml_spec.ok(yaml_spec.s("A")),
    },
    .{
        .name = "E09: escape_hex_8",
        .input = "\"\\U00000041\"",
        .spec_ref = "5.7",
        .expected = yaml_spec.ok(yaml_spec.s("A")),
    },
    .{
        .name = "E10: escape_linebreak",
        .input = "\"line1\\\nline2\"",
        .spec_ref = "5.7",
        .expected = yaml_spec.ok(yaml_spec.s("line1line2")),
    },
    .{
        .name = "E11: escape_all",
        .input = "\"\\0\\a\\b\\t\\n\\v\\f\\r\\e\\\"\\\\\"",
        .spec_ref = "5.7",
        .expected = yaml_spec.ok(yaml_spec.s("\x00\x07\x08\t\n\x0B\x0C\r\x1B\"\\")),
    },
};

test "escaping" {
    try yaml_spec.runTestSuite(std.testing.allocator, &cases);
}
