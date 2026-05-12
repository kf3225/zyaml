const std = @import("std");
const zyaml = @import("zyaml");

fn readfile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

fn benchParse(allocator: std.mem.Allocator, input: []const u8, iterations: usize, label: []const u8) void {
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        var result = zyaml.parse(allocator, input) catch unreachable;
        result.deinit(allocator);
    }
    const elapsed = std.time.nanoTimestamp() - start;
    const ns_per_iter = @divTrunc(elapsed, @as(i128, @intCast(iterations)));
    const us_per_iter = @divTrunc(ns_per_iter, @as(i128, 1000));
    std.debug.print("{s}: {} iterations, {} us/op, {} ops/sec\n", .{
        label,
        iterations,
        us_per_iter,
        @divTrunc(@as(i128, 1_000_000), us_per_iter),
    });
}

fn benchStringify(allocator: std.mem.Allocator, input: []const u8, iterations: usize, label: []const u8) void {
    var result = zyaml.parse(allocator, input) catch unreachable;
    defer result.deinit(allocator);
    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        const output = zyaml.stringify(allocator, result) catch unreachable;
        allocator.free(output);
    }
    const elapsed = std.time.nanoTimestamp() - start;
    const ns_per_iter = @divTrunc(elapsed, @as(i128, @intCast(iterations)));
    const us_per_iter = @divTrunc(ns_per_iter, @as(i128, 1000));
    std.debug.print("{s} stringify: {} iterations, {} us/op, {} ops/sec\n", .{
        label,
        iterations,
        us_per_iter,
        @divTrunc(@as(i128, 1_000_000), us_per_iter),
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const small = "key: value\nlist:\n  - a\n  - b\n  - c\n";
    const medium = try readfile(allocator, "src/test/fixtures/09_realistic_config.yaml");
    defer allocator.free(medium);
    const large = try readfile(allocator, "/tmp/bench_large.yaml");
    defer allocator.free(large);

    std.debug.print("\n=== Parse Benchmark ===\n", .{});
    benchParse(allocator, small, 100000, "small (37B)");
    benchParse(allocator, medium, 10000, "medium (778B)");
    benchParse(allocator, large, 1000, "large (20KB)");

    std.debug.print("\n=== Stringify Benchmark ===\n", .{});
    benchStringify(allocator, small, 100000, "small (37B)");
    benchStringify(allocator, medium, 10000, "medium (778B)");
    benchStringify(allocator, large, 1000, "large (20KB)");
}
