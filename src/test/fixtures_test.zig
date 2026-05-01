const std = @import("std");
const zyaml = @import("zyaml");
const Value = zyaml.YamlValue;

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

fn isKind(v: Value, comptime tag: @Type(.enum_literal)) bool {
    return switch (tag) {
        .null => v == .null,
        .boolean => v == .boolean,
        .integer => v == .integer,
        .float => v == .float,
        .string => v == .string,
        .sequence => v == .sequence,
        .mapping => v == .mapping,
        else => false,
    };
}

fn mapGet(v: Value, key: []const u8) ?Value {
    if (v != .mapping) return null;
    return v.mapping.get(key);
}

fn parseFile(allocator: std.mem.Allocator, path: []const u8) !Value {
    const source = try readFile(allocator, path);
    defer allocator.free(source);
    return try zyaml.parse(allocator, source);
}

fn testParseAndPrint(comptime name: []const u8, path: []const u8) !void {
    const allocator = std.testing.allocator;
    var doc = try parseFile(allocator, path);
    defer doc.deinit(allocator);

    var errors = std.ArrayList([]const u8).init(allocator);
    defer errors.deinit();

    std.debug.print("=== {s} ===\n", .{name});
    std.debug.print("Root type: {}\n", .{std.meta.activeTag(doc)});

    switch (doc) {
        .mapping => |m| {
            var iter = m.iterator();
            while (iter.next()) |entry| {
                std.debug.print("  key: {s} = {}\n", .{ entry.key_ptr.*, std.meta.activeTag(entry.value_ptr.*) });
            }
            try std.testing.expect(m.count() > 0);
        },
        .sequence => |s| {
            std.debug.print("  items: {}\n", .{s.items.len});
            try std.testing.expect(s.items.len > 0);
        },
        else => {},
    }

    std.debug.print("PASS {s}\n\n", .{name});
}

test "fixture 01: scalars" {
    const allocator = std.testing.allocator;
    var doc = try parseFile(allocator, "src/test/fixtures/01_scalars.yaml");
    defer doc.deinit(allocator);

    try std.testing.expect(isKind(doc, .mapping));
    try std.testing.expectEqualStrings("hello world", mapGet(doc, "string_value").?.string);
    try std.testing.expectEqualStrings("hello world", mapGet(doc, "quoted_string").?.string);
    try std.testing.expectEqual(@as(i64, 42), mapGet(doc, "integer_value").?.integer);
    try std.testing.expectEqual(@as(i64, -7), mapGet(doc, "negative_integer").?.integer);
    try std.testing.expect(std.math.approxEqAbs(f64, 3.14, mapGet(doc, "float_value").?.float, 0.001));
    try std.testing.expect(mapGet(doc, "boolean_true").?.boolean == true);
    try std.testing.expect(mapGet(doc, "boolean_false").?.boolean == false);
    try std.testing.expect(isKind(mapGet(doc, "null_value").?, .null));
    try std.testing.expect(isKind(mapGet(doc, "tilde_null").?, .null));
    try std.testing.expectEqual(@as(i64, 255), mapGet(doc, "hex_integer").?.integer);
    try std.testing.expectEqual(@as(i64, 63), mapGet(doc, "octal_integer").?.integer);
    try std.testing.expectEqual(@as(i64, 10), mapGet(doc, "binary_integer").?.integer);
    try std.testing.expect(isKind(mapGet(doc, "not_a_number").?, .float));
    std.debug.print("PASS 01_scalars\n", .{});
}

test "fixture 02: sequences" {
    try testParseAndPrint("02_sequences", "src/test/fixtures/02_sequences.yaml");
}

test "fixture 03: mappings" {
    const allocator = std.testing.allocator;
    var doc = try parseFile(allocator, "src/test/fixtures/03_mappings.yaml");
    defer doc.deinit(allocator);

    try std.testing.expect(isKind(doc, .mapping));
    try std.testing.expectEqualStrings("John", mapGet(doc, "name").?.string);
    try std.testing.expectEqual(@as(i64, 30), mapGet(doc, "age").?.integer);

    const person = mapGet(doc, "person");
    if (person) |p| {
        try std.testing.expect(isKind(p, .mapping));
    }
    std.debug.print("PASS 03_mappings\n", .{});
}

test "fixture 04: flow style" {
    try testParseAndPrint("04_flow_style", "src/test/fixtures/04_flow_style.yaml");
}

test "fixture 05: block scalars" {
    try testParseAndPrint("05_block_scalars", "src/test/fixtures/05_block_scalars.yaml");
}

test "fixture 06: anchors" {
    try testParseAndPrint("06_anchors", "src/test/fixtures/06_anchors.yaml");
}

test "fixture 07: multi document" {
    try testParseAndPrint("07_multi_document", "src/test/fixtures/07_multi_document.yaml");
}

test "fixture 08: edge cases" {
    try testParseAndPrint("08_edge_cases", "src/test/fixtures/08_edge_cases.yaml");
}

test "fixture 09: realistic config" {
    try testParseAndPrint("09_realistic_config", "src/test/fixtures/09_realistic_config.yaml");
}

test "fixture: roundtrip parse-stringify-parse" {
    const allocator = std.testing.allocator;
    const filenames = [_][]const u8{
        "src/test/fixtures/01_scalars.yaml",
        "src/test/fixtures/03_mappings.yaml",
        "src/test/fixtures/04_flow_style.yaml",
        "src/test/fixtures/05_block_scalars.yaml",
        "src/test/fixtures/06_anchors.yaml",
    };

    for (&filenames) |fname| {
        const source = readFile(allocator, fname) catch continue;
        defer allocator.free(source);

        var doc = zyaml.parse(allocator, source) catch continue;
        defer doc.deinit(allocator);

        const output = zyaml.stringify(allocator, doc) catch continue;
        defer allocator.free(output);
        try std.testing.expect(output.len > 0);

        var reparsed = zyaml.parse(allocator, output) catch continue;
        defer reparsed.deinit(allocator);

        std.debug.print("ROUNDTRIP {s}: {} -> {} bytes\n", .{ fname, source.len, output.len });
    }
}
