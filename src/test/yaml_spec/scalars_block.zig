const std = @import("std");
const yaml_spec = @import("mod.zig");

const cases = [_]yaml_spec.TestCase{
    .{
        .name = "B01: literal_basic",
        .input = "|\n  line1\n  line2",
        .spec_ref = "2.13, 8.1.2",
        .expected = yaml_spec.ok(yaml_spec.s("line1\nline2\n")),
    },
    .{
        .name = "B02: literal_strip",
        .input = "|-\n  line1\n  line2",
        .spec_ref = "8.1.2",
        .expected = yaml_spec.ok(yaml_spec.s("line1\nline2")),
    },
    .{
        .name = "B03: literal_keep",
        .input = "|+\n  line1\n  line2\n\n",
        .spec_ref = "8.1.2",
        .expected = yaml_spec.ok(yaml_spec.s("line1\nline2\n\n")),
    },
    .{
        .name = "B04: folded_basic",
        .input = ">\n  line1\n  line2",
        .spec_ref = "2.14, 8.1.3",
        .expected = yaml_spec.ok(yaml_spec.s("line1 line2\n")),
    },
    .{
        .name = "B05: folded_more_indented",
        .input = ">\n  text\n\n    indented",
        .spec_ref = "2.15",
        .expected = yaml_spec.ok(yaml_spec.s("text\n\nindented\n")),
    },
    .{
        .name = "B06: folded_with_blank",
        .input = ">\n  para1\n\n  para2",
        .spec_ref = "8.1.3",
        .expected = yaml_spec.ok(yaml_spec.s("para1\npara2\n")),
    },
    .{
        .name = "B07: block_indent_indicator",
        .input = "|2\n    line1",
        .spec_ref = "8.1.1",
        .expected = yaml_spec.ok(yaml_spec.s("  line1\n")),
    },
    .{
        .name = "B08: literal_empty",
        .input = "|",
        .spec_ref = "8.1.2",
        .expected = yaml_spec.ok(yaml_spec.s("")),
    },
};

test "scalars_block" {
    try yaml_spec.runTestSuite(std.testing.allocator, &cases);
}
