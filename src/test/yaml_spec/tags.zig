const std = @import("std");
const yaml_spec = @import("mod.zig");

const cases = [_]yaml_spec.TestCase{
    .{
        .name = "T01: local_tag",
        .input = "!local value",
        .spec_ref = "2.23",
        .expected = yaml_spec.ok(yaml_spec.s("value")),
    },
    .{
        .name = "T02: global_tag_shorthand",
        .input = "%TAG ! !\n--- !tag value",
        .spec_ref = "2.24",
        .expected = yaml_spec.ok(yaml_spec.s("value")),
    },
    .{
        .name = "T03: global_tag_uri",
        .input = "!!str 123",
        .spec_ref = "2.23",
        .expected = yaml_spec.ok(yaml_spec.s("123")),
    },
    .{
        .name = "T04: tag_override",
        .input = "!!str 2001-01-01",
        .spec_ref = "2.23",
        .expected = yaml_spec.ok(yaml_spec.s("2001-01-01")),
    },
    .{
        .name = "T05: yaml_directive",
        .input = "%YAML 1.2\n---",
        .spec_ref = "6.8.1",
        .expected = yaml_spec.ok(yaml_spec.n()),
    },
    .{
        .name = "T06: tag_directive",
        .input = "%TAG !e! tag:example.com:\n--- !e!foo bar",
        .spec_ref = "6.8.2",
        .expected = yaml_spec.ok(yaml_spec.s("bar")),
    },
    .{
        .name = "T07: verbatim_tag",
        .input = "!<tag:example.com,2024:foo> bar",
        .spec_ref = "6.9.1",
        .expected = yaml_spec.ok(yaml_spec.s("bar")),
    },
};

test "tags" {
    try yaml_spec.runTestSuite(std.testing.allocator, &cases);
}
