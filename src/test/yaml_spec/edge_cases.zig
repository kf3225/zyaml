const std = @import("std");
const yaml_spec = @import("mod.zig");

const cases = [_]yaml_spec.TestCase{
    .{
        .name = "X01: whitespace_only",
        .input = "   \n  ",
        .spec_ref = "9.1",
        .expected = yaml_spec.ok(yaml_spec.n()),
    },
    .{
        .name = "X02: scalar_with_colon",
        .input = "a: b: c",
        .spec_ref = "7.3.3",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.s("b: c") },
        })),
    },
    .{
        .name = "X03: unicode_key",
        .input = "日本語: 値",
        .spec_ref = "5.1",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "日本語", .value = yaml_spec.s("値") },
        })),
    },
    .{
        .name = "X04: unicode_value",
        .input = "key: 日本語🎉",
        .spec_ref = "5.1",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "key", .value = yaml_spec.s("日本語🎉") },
        })),
    },
    .{
        .name = "X05: very_long_scalar",
        .input = "a: " ++ "a" ** 500,
        .spec_ref = "7.3.3",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.s("a" ** 500) },
        })),
    },
    .{
        .name = "X06: anchor_self_referencing",
        .input = "&a [*a]",
        .spec_ref = "3.2.2.2",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.seq(&.{}),
        })),
    },
};

test "edge_cases" {
    try yaml_spec.runTestSuite(std.testing.allocator, &cases);
}
