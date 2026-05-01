const std = @import("std");
const yaml_spec = @import("mod.zig");

const cases = [_]yaml_spec.TestCase{
    .{
        .name = "C01: block_sequence_basic",
        .input = "- a\n- b\n- c",
        .spec_ref = "2.1",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.s("a"),
            yaml_spec.s("b"),
            yaml_spec.s("c"),
        })),
    },
    .{
        .name = "C02: block_sequence_nested",
        .input = "- - a\n  - b",
        .spec_ref = "2.3",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.seq(&.{
                yaml_spec.s("a"),
                yaml_spec.s("b"),
            }),
        })),
    },
    .{
        .name = "C03: block_sequence_empty",
        .input = "-\n-",
        .spec_ref = "8.2.1",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.n(),
            yaml_spec.n(),
        })),
    },
    .{
        .name = "C04: block_mapping_basic",
        .input = "k1: v1\nk2: v2",
        .spec_ref = "2.2",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "k1", .value = yaml_spec.s("v1") },
            .{ .key = "k2", .value = yaml_spec.s("v2") },
        })),
    },
    .{
        .name = "C05: block_mapping_nested",
        .input = "a:\n  b: c",
        .spec_ref = "2.3",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.map(&.{
                .{ .key = "b", .value = yaml_spec.s("c") },
            }) },
        })),
    },
    .{
        .name = "C06: block_mapping_complex_key",
        .input = "? - a\n  - b\n: c",
        .spec_ref = "2.11",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "[a, b]", .value = yaml_spec.s("c") },
        })),
    },
    .{
        .name = "C07: block_sequence_of_mappings",
        .input = "- k: v1\n- k: v2",
        .spec_ref = "2.4",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.map(&.{
                .{ .key = "k", .value = yaml_spec.s("v1") },
            }),
            yaml_spec.map(&.{
                .{ .key = "k", .value = yaml_spec.s("v2") },
            }),
        })),
    },
    .{
        .name = "C08: compact_nested_mapping",
        .input = "- k1: v1\n  k2: v2",
        .spec_ref = "2.12",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.map(&.{
                .{ .key = "k1", .value = yaml_spec.s("v1") },
                .{ .key = "k2", .value = yaml_spec.s("v2") },
            }),
        })),
    },
};

test "collections" {
    try yaml_spec.runTestSuite(std.testing.allocator, &cases);
}
