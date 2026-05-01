const std = @import("std");
const yaml_spec = @import("mod.zig");

const cases = [_]yaml_spec.TestCase{
    .{
        .name = "CM01: line_comment",
        .input = "k: v # comment",
        .spec_ref = "2.2",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "k", .value = yaml_spec.s("v") },
        })),
    },
    .{
        .name = "CM02: standalone_comment",
        .input = "# comment\na: b",
        .spec_ref = "2.9",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.s("b") },
        })),
    },
    .{
        .name = "CM03: comment_after_mapping",
        .input = "a: b\n  # comment",
        .spec_ref = "6.6",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.s("b") },
        })),
    },
    .{
        .name = "CM04: comment_in_flow",
        .input = "[a, # comment\n b]",
        .spec_ref = "7.4",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.s("a"),
            yaml_spec.s("b"),
        })),
    },
    .{
        .name = "CM05: comment_not_in_scalar",
        .input = "\"# not comment\"",
        .spec_ref = "3.2.3.3",
        .expected = yaml_spec.ok(yaml_spec.s("# not comment")),
    },
};

test "comments" {
    try yaml_spec.runTestSuite(std.testing.allocator, &cases);
}
