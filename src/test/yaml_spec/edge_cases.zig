const std = @import("std");
const yaml_spec = @import("mod.zig");

const cases = [_]yaml_spec.TestCase{
    .{
        .name = "X01: empty_document",
        .input = "",
        .spec_ref = "9.1",
        .expected = yaml_spec.ok(yaml_spec.n()),
    },
    .{
        .name = "X02: whitespace_only",
        .input = "   \n  ",
        .spec_ref = "9.1",
        .expected = yaml_spec.ok(yaml_spec.n()),
    },
    .{
        .name = "X03: empty_mapping",
        .input = "{}",
        .spec_ref = "7.4.2",
        .expected = yaml_spec.ok(yaml_spec.map(&.{})),
    },
    .{
        .name = "X04: empty_sequence",
        .input = "[]",
        .spec_ref = "7.4.1",
        .expected = yaml_spec.ok(yaml_spec.seq(&.{})),
    },
    .{
        .name = "X05: mapping_key_colon",
        .input = "\"a: b\": c",
        .spec_ref = "7.3.1",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a: b", .value = yaml_spec.s("c") },
        })),
    },
    .{
        .name = "X06: scalar_with_colon",
        .input = "a: b: c",
        .spec_ref = "7.3.3",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.s("b: c") },
        })),
    },
    .{
        .name = "X07: multiline_plain",
        .input = "key: value\n  continues",
        .spec_ref = "7.3.3",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "key", .value = yaml_spec.s("value continues") },
        })),
    },
    .{
        .name = "X08: unicode_key",
        .input = "日本語: 値",
        .spec_ref = "5.1",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "日本語", .value = yaml_spec.s("値") },
        })),
    },
    .{
        .name = "X09: unicode_value",
        .input = "key: 日本語🎉",
        .spec_ref = "5.1",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "key", .value = yaml_spec.s("日本語🎉") },
        })),
    },
    .{
        .name = "X10: very_long_scalar",
        .input = "a: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .spec_ref = "7.3.3",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.s("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") },
        })),
    },
    .{
        .name = "X11: deeply_nested",
        .input = "a:\n  b:\n    c:\n      d:\n        e: f",
        .spec_ref = "6.1",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.map(&.{
                .{ .key = "b", .value = yaml_spec.map(&.{
                    .{ .key = "c", .value = yaml_spec.map(&.{
                        .{ .key = "d", .value = yaml_spec.map(&.{
                            .{ .key = "e", .value = yaml_spec.s("f") },
                        }) },
                    }) },
                }) },
            }) },
        })),
    },
    .{
        .name = "X12: mapping_in_sequence_key",
        .input = "? {a: b}\n: c",
        .spec_ref = "2.11",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "{a: b}", .value = yaml_spec.s("c") },
        })),
    },
    .{
        .name = "X13: sequence_as_mapping_key",
        .input = "? [a, b]\n: c",
        .spec_ref = "2.11",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "[a, b]", .value = yaml_spec.s("c") },
        })),
    },
    .{
        .name = "X14: colon_in_plain",
        .input = "a: http://example.com",
        .spec_ref = "7.3.3",
        .expected = yaml_spec.ok(yaml_spec.map(&.{
            .{ .key = "a", .value = yaml_spec.s("http://example.com") },
        })),
    },
};

test "edge_cases" {
    try yaml_spec.runTestSuite(std.testing.allocator, &cases);
}
