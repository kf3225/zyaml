const std = @import("std");
const yaml_spec = @import("mod.zig");

const cases = [_]yaml_spec.TestCase{
    .{
        .name = "D01: document_explicit",
        .input = "---\n- a\n- b",
        .spec_ref = "2.7",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.s("a"),
            yaml_spec.s("b"),
        })),
    },
    .{
        .name = "D02: document_explicit_end",
        .input = "---\na\n...",
        .spec_ref = "9.1.4",
        .expected = yaml_spec.ok(yaml_spec.s("a")),
    },
    .{
        .name = "D03: multiple_documents",
        .input = "--- a\n---\nb",
        .spec_ref = "2.7",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.s("a"),
            yaml_spec.s("b"),
        })),
    },
    .{
        .name = "D04: document_implicit",
        .input = "a: b",
        .spec_ref = "9.1.3",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.s("b") },
        })),
    },
    .{
        .name = "D05: document_bare",
        .input = "scalar",
        .spec_ref = "9.1.3",
        .expected = yaml_spec.ok(yaml_spec.s("scalar")),
    },
    .{
        .name = "D06: document_prefix",
        .input = "\n\n---\na",
        .spec_ref = "9.1.1",
        .expected = yaml_spec.ok(yaml_spec.s("a")),
    },
    .{
        .name = "D07: anchor_and_alias",
        .input = "- &a value\n- *a",
        .spec_ref = "2.10",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.s("value"),
            yaml_spec.s("value"),
        })),
    },
    .{
        .name = "D08: anchor_mapping",
        .input = "a: &x b\nc: *x",
        .spec_ref = "3.2.2.2",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.s("b") },
            .{ .key = "c", .value = yaml_spec.s("b") },
        })),
    },
    .{
        .name = "D09: anchor_circular",
        .input = "&a [*a]",
        .spec_ref = "3.2.2.2",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{
            yaml_spec.seq(&.{}),
        })),
    },
    .{
        .name = "D10: complex_key",
        .input = "? [a, b]\n: c",
        .spec_ref = "2.11",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "[a, b]", .value = yaml_spec.s("c") },
        })),
    },
};

test "structures" {
    try yaml_spec.runTestSuite(std.testing.allocator, &cases);
}
