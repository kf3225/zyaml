const std = @import("std");
const zyaml = @import("zyaml_lib");

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("zyaml - YAML 1.2.2 Parser for Zig\n", .{});
    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit();
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "parse simple scalar" {
    const allocator = std.testing.allocator;
    var doc = try zyaml.parse(allocator, "hello");
    defer doc.deinit(allocator);
    try std.testing.expectEqualStrings("hello", doc.string);
}

test "parse nested sequence" {
    const allocator = std.testing.allocator;
    var doc = try zyaml.parse(allocator, "- - a\n  - b");
    defer doc.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), doc.sequence.items.len);
    try std.testing.expectEqual(@as(usize, 2), doc.sequence.items[0].sequence.items.len);
}

test "parse simple sequence" {
    const allocator = std.testing.allocator;
    var doc = try zyaml.parse(allocator, "[a, b, c]");
    defer doc.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), doc.sequence.items.len);
}

test "parse simple mapping" {
    const allocator = std.testing.allocator;
    var doc = try zyaml.parse(allocator, "{k: v}");
    defer doc.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), doc.mapping.count());
}
