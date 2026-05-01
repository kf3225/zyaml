const std = @import("std");
const yaml_spec = @import("mod.zig");

const cases = [_]yaml_spec.TestCase{
    .{
        .name = "S01: plain_scalar_basic",
        .input = "hello world",
        .spec_ref = "7.3.3",
        .expected = yaml_spec.ok(yaml_spec.s("hello world")),
    },
    .{
        .name = "S02: plain_scalar_multiline",
        .input = "plain:\n  this is\n  one line",
        .spec_ref = "2.18",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "plain", .value = yaml_spec.s("this is one line") },
        })),
    },
    .{
        .name = "S03: single_quoted_basic",
        .input = "'hello'",
        .spec_ref = "7.3.2",
        .expected = yaml_spec.ok(yaml_spec.s("hello")),
    },
    .{
        .name = "S04: single_quoted_escape",
        .input = "'it''s fine'",
        .spec_ref = "2.17",
        .expected = yaml_spec.ok(yaml_spec.s("it's fine")),
    },
    .{
        .name = "S05: single_quoted_multiline",
        .input = "'line1\n  line2'",
        .spec_ref = "7.3.2",
        .expected = yaml_spec.ok(yaml_spec.s("line1 line2")),
    },
    .{
        .name = "S06: double_quoted_basic",
        .input = "\"hello\"",
        .spec_ref = "7.3.1",
        .expected = yaml_spec.ok(yaml_spec.s("hello")),
    },
    .{
        .name = "S07: double_quoted_escape",
        .input = "\"line1\\nline2\"",
        .spec_ref = "2.17",
        .expected = yaml_spec.ok(yaml_spec.s("line1\nline2")),
    },
    .{
        .name = "S08: double_quoted_unicode",
        .input = "\"Sosa\\u263A\"",
        .spec_ref = "2.17",
        .expected = yaml_spec.ok(yaml_spec.s("Sosa\u{263A}")),
    },
    .{
        .name = "S09: double_quoted_hex",
        .input = "\"\\x0d\\x0a\"",
        .spec_ref = "2.17",
        .expected = yaml_spec.ok(yaml_spec.s("\r\n")),
    },
    .{
        .name = "S10: empty_scalar",
        .input = "",
        .spec_ref = "7.2",
        .expected = yaml_spec.ok(yaml_spec.n()),
    },
};

test "scalars_flow" {
    try yaml_spec.runTestSuite(std.testing.allocator, &cases);
}
