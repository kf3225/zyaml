const std = @import("std");
const yaml_spec = @import("mod.zig");

const cases = [_]yaml_spec.TestCase{
    .{
        .name = "I01: indent_2_spaces",
        .input = "a:\n  b: c",
        .spec_ref = "6.1",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.map(&.{
                .{ .key = "b", .value = yaml_spec.s("c") },
            }) },
        })),
    },
    .{
        .name = "I02: indent_4_spaces",
        .input = "a:\n    b: c",
        .spec_ref = "6.1",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.map(&.{
                .{ .key = "b", .value = yaml_spec.s("c") },
            }) },
        })),
    },
    .{
        .name = "I03: indent_mixed_levels",
        .input = "a:\n  b:\n    c: d",
        .spec_ref = "6.1",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.map(&.{
                .{ .key = "b", .value = yaml_spec.map(&.{
                    .{ .key = "c", .value = yaml_spec.s("d") },
                }) },
            }) },
        })),
    },
    .{
        .name = "I04: indent_less",
        .input = "a:\n  b: c\nd: e",
        .spec_ref = "6.1",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.map(&.{
                .{ .key = "b", .value = yaml_spec.s("c") },
            }) },
            .{ .key = "d", .value = yaml_spec.s("e") },
        })),
    },
    .{
        .name = "I05: indent_zero",
        .input = "a: b\nc: d",
        .spec_ref = "6.1",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.s("b") },
            .{ .key = "c", .value = yaml_spec.s("d") },
        })),
    },
    .{
        .name = "I06: indent_tab_error",
        .input = "\ta: b",
        .spec_ref = "6.1",
        .expected = yaml_spec.e(.tab_indentation, 1, 1),
    },
};

test "indentation" {
    try yaml_spec.runTestSuite(std.testing.allocator, &cases);
}
