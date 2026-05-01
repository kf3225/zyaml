const std = @import("std");
const yaml_spec = @import("mod.zig");

const cases = [_]yaml_spec.TestCase{
    .{
        .name = "SC01: null_tilde",
        .input = "~",
        .spec_ref = "10.2.1.1",
        .expected = yaml_spec.ok(yaml_spec.n()),
    },
    .{
        .name = "SC02: null_word",
        .input = "null",
        .spec_ref = "10.2.1.1",
        .expected = yaml_spec.ok(yaml_spec.n()),
    },
    .{
        .name = "SC03: bool_true",
        .input = "true",
        .spec_ref = "10.2.1.2",
        .expected = yaml_spec.ok(yaml_spec.b(true)),
    },
    .{
        .name = "SC04: bool_false",
        .input = "false",
        .spec_ref = "10.2.1.2",
        .expected = yaml_spec.ok(yaml_spec.b(false)),
    },
    .{
        .name = "SC05: int_decimal",
        .input = "12345",
        .spec_ref = "10.2.1.3",
        .expected = yaml_spec.ok(yaml_spec.i(12345)),
    },
    .{
        .name = "SC06: int_octal",
        .input = "0o14",
        .spec_ref = "10.3.2",
        .expected = yaml_spec.ok(yaml_spec.i(12)),
    },
    .{
        .name = "SC07: int_hex",
        .input = "0xC",
        .spec_ref = "10.3.2",
        .expected = yaml_spec.ok(yaml_spec.i(12)),
    },
    .{
        .name = "SC08: int_negative",
        .input = "-123",
        .spec_ref = "10.2.1.3",
        .expected = yaml_spec.ok(yaml_spec.i(-123)),
    },
    .{
        .name = "SC09: float_canonical",
        .input = "1.23015e+3",
        .spec_ref = "10.2.1.4",
        .expected = yaml_spec.ok(yaml_spec.f(1230.15)),
    },
    .{
        .name = "SC10: float_negative_inf",
        .input = "-.inf",
        .spec_ref = "10.2.1.4",
        .expected = yaml_spec.ok(yaml_spec.f(-std.math.inf(f64))),
    },
    .{
        .name = "SC11: float_nan",
        .input = ".nan",
        .spec_ref = "10.2.1.4",
        .expected = yaml_spec.ok(yaml_spec.f(std.math.nan(f64))),
    },
    .{
        .name = "SC12: string_unquoted",
        .input = "hello",
        .spec_ref = "10.1.1.3",
        .expected = yaml_spec.ok(yaml_spec.s("hello")),
    },
    .{
        .name = "SC13: timestamp",
        .input = "2001-12-15T02:59:43Z",
        .spec_ref = "10.3.2",
        .expected = yaml_spec.ok(yaml_spec.s("2001-12-15T02:59:43Z")),
    },
};

test "schemas" {
    try yaml_spec.runTestSuite(std.testing.allocator, &cases);
}
