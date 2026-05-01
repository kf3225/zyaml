const std = @import("std");
const yaml_spec = @import("mod.zig");

const cases = [_]yaml_spec.TestCase{
    .{
        .name = "F01: flow_sequence_basic",
        .input = "[a, b, c]",
        .spec_ref = "2.5",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.s("a"),
            yaml_spec.s("b"),
            yaml_spec.s("c"),
        })),
    },
    .{
        .name = "F02: flow_sequence_empty",
        .input = "[]",
        .spec_ref = "7.4.1",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{})),
    },
    .{
        .name = "F03: flow_sequence_nested",
        .input = "[[a], [b]]",
        .spec_ref = "7.4.1",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.seq(&.{
                yaml_spec.s("a"),
            }),
            yaml_spec.seq(&.{
                yaml_spec.s("b"),
            }),
        })),
    },
    .{
        .name = "F04: flow_mapping_basic",
        .input = "{k1: v1, k2: v2}",
        .spec_ref = "2.6",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "k1", .value = yaml_spec.s("v1") },
            .{ .key = "k2", .value = yaml_spec.s("v2") },
        })),
    },
    .{
        .name = "F05: flow_mapping_empty",
        .input = "{}",
        .spec_ref = "7.4.2",
        .expected = yaml_spec.ok(yaml_spec.map(&.{})),
    },
    .{
        .name = "F06: flow_mapping_nested",
        .input = "{a: {b: c}}",
        .spec_ref = "7.4.2",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.map(&.{
                .{ .key = "b", .value = yaml_spec.s("c") },
            }) },
        })),
    },
    .{
        .name = "F07: flow_mixed",
        .input = "{k: [a, b]}",
        .spec_ref = "7.4",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "k", .value = yaml_spec.seq(&.{
                yaml_spec.s("a"),
                yaml_spec.s("b"),
            }) },
        })),
    },
    .{
        .name = "F08: flow_multiline",
        .input = "[a,\n  b]",
        .spec_ref = "7.4",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.s("a"),
            yaml_spec.s("b"),
        })),
    },
    .{
        .name = "F09: flow_mapping_no_value",
        .input = "{k:}",
        .spec_ref = "7.4.2",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "k", .value = yaml_spec.n() },
        })),
    },
    .{
        .name = "F10: compact_mapping_in_sequence",
        .input = "- {k: v}",
        .spec_ref = "2.12",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.map(&.{
                .{ .key = "k", .value = yaml_spec.s("v") },
            }),
        })),
    },
};

test "flow_style" {
    try yaml_spec.runTestSuite(std.testing.allocator, &cases);
}
