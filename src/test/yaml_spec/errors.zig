const std = @import("std");
const yaml_spec = @import("mod.zig");

const cases = [_]yaml_spec.TestCase{
    .{
        .name = "ER01: unclosed_flow_mapping",
        .input = "{a: b",
        .spec_ref = "7.4.2",
        .expected = yaml_spec.e(.unclosed_flow_mapping, 1, 5),
    },
    .{
        .name = "ER02: duplicate_key",
        .input = "a: 1\na: 2",
        .spec_ref = "3.2.1.3",
        .expected = yaml_spec.e(.duplicate_key, 2, 1),
    },
    .{
        .name = "ER02b: duplicate_flow_key",
        .input = "{a: 1, a: 2}",
        .spec_ref = "3.2.1.3",
        .expected = yaml_spec.e(.duplicate_key, 1, 8),
    },
    .{
        .name = "ER03: unknown_alias",
        .input = "*unknown",
        .spec_ref = "3.2.2.2",
        .expected = yaml_spec.e(.unknown_alias, 1, 1),
    },
    .{
        .name = "ER04: invalid_yaml_version",
        .input = "%YAML 3.0\n---",
        .spec_ref = "6.8.1",
        .expected = yaml_spec.e(.unsupported_version, 1, 1),
    },
};

test "errors" {
    try yaml_spec.runTestSuite(std.testing.allocator, &cases);
}
