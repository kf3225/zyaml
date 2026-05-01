const std = @import("std");
const yaml_spec = @import("mod.zig");

const cases = [_]yaml_spec.TestCase{
    .{
        .name = "ER01: tab_at_start",
        .input = "\ta: b",
        .spec_ref = "6.1",
        .expected = yaml_spec.e(.tab_indentation, 1, 1),
    },
    .{
        .name = "ER02: wrong_indent",
        .input = "a:\n b: c",
        .spec_ref = "6.1",
        .expected = yaml_spec.e(.invalid_indentation, 2, 1),
    },
    .{
        .name = "ER03: unclosed_bracket",
        .input = "[a, b",
        .spec_ref = "7.4.1",
        .expected = yaml_spec.e(.unclosed_flow_sequence, 1, 5),
    },
    .{
        .name = "ER04: unclosed_brace",
        .input = "{a: b",
        .spec_ref = "7.4.2",
        .expected = yaml_spec.e(.unclosed_flow_mapping, 1, 5),
    },
    .{
        .name = "ER05: unclosed_quote",
        .input = "\"unclosed",
        .spec_ref = "7.3.1",
        .expected = yaml_spec.e(.unclosed_scalar, 1, 1),
    },
    .{
        .name = "ER06: duplicate_key",
        .input = "a: 1\na: 2",
        .spec_ref = "3.2.1.3",
        .expected = yaml_spec.e(.duplicate_key, 2, 1),
    },
    .{
        .name = "ER07: unknown_alias",
        .input = "*unknown",
        .spec_ref = "3.2.2.2",
        .expected = yaml_spec.e(.unknown_alias, 1, 1),
    },
    .{
        .name = "ER08: invalid_escape",
        .input = "\"\\xGG\"",
        .spec_ref = "5.7",
        .expected = yaml_spec.e(.invalid_escape_sequence, 1, 2),
    },
    .{
        .name = "ER09: invalid_yaml_version",
        .input = "%YAML 3.0\n---",
        .spec_ref = "6.8.1",
        .expected = yaml_spec.e(.unsupported_version, 1, 1),
    },
    .{
        .name = "ER10: mapping_key_no_value",
        .input = "a:\nb:",
        .spec_ref = "8.2.2",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.n() },
            .{ .key = "b", .value = yaml_spec.n() },
        })),
    },
    .{
        .name = "ER11: flow_comma_trailing",
        .input = "[a,]",
        .spec_ref = "7.4.1",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.s("a"),
        })),
    },
    .{
        .name = "ER12: block_scalar_bad_indent",
        .input = "|2\n line",
        .spec_ref = "8.1.1",
        .expected = yaml_spec.e(.invalid_indentation, 2, 1),
    },
};

test "errors" {
    try yaml_spec.runTestSuite(std.testing.allocator, &cases);
}
