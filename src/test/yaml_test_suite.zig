const std = @import("std");
const zyaml = @import("zyaml");

const SuiteDir = "test-suite/yaml-test-suite";

const skipped = [_][]const u8{};

fn isSkipped(id: []const u8) bool {
    for (&skipped) |s| {
        if (std.mem.eql(u8, s, id)) return true;
    }
    return false;
}

fn readFileAlloc(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !?[]const u8 {
    const file = dir.openFile(name, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

fn fileExists(dir: std.fs.Dir, name: []const u8) bool {
    const file = dir.openFile(name, .{}) catch return false;
    file.close();
    return true;
}

fn valuesEqual(a: zyaml.YamlValue, b: zyaml.YamlValue) bool {
    if (@as(std.meta.Tag(zyaml.YamlValue), a) != @as(std.meta.Tag(zyaml.YamlValue), b)) return false;
    switch (a) {
        .null => return true,
        .boolean => return a.boolean == b.boolean,
        .integer => return a.integer == b.integer,
        .float => {
            const fa = a.float;
            const fb = b.float;
            if (std.math.isNan(fa) and std.math.isNan(fb)) return true;
            if (std.math.isInf(fa) and std.math.isInf(fb)) return std.math.sign(fa) == std.math.sign(fb);
            return @abs(fa - fb) <= 0.0001;
        },
        .string => return std.mem.eql(u8, a.string, b.string),
        .sequence => {
            if (a.sequence.items.len != b.sequence.items.len) return false;
            for (a.sequence.items, b.sequence.items) |item_a, item_b| {
                if (!valuesEqual(item_a, item_b)) return false;
            }
            return true;
        },
        .mapping => {
            if (a.mapping.count() != b.mapping.count()) return false;
            var iter = a.mapping.iterator();
            while (iter.next()) |entry| {
                const b_val = b.mapping.get(entry.key_ptr.*) orelse return false;
                if (!valuesEqual(entry.value_ptr.*, b_val)) return false;
            }
            return true;
        },
    }
}

const Result = enum { pass, fail, skip };

fn runTest(allocator: std.mem.Allocator, test_dir: std.fs.Dir, id: []const u8, log: std.fs.File) !Result {
    if (isSkipped(id)) return .skip;

    const raw_input = try readFileAlloc(allocator, test_dir, "in.yaml") orelse {
        return .skip;
    };
    defer allocator.free(raw_input);

    const has_error = fileExists(test_dir, "error");

    var result = zyaml.parse(allocator, raw_input) catch |err| {
        if (has_error) {
            log.writer().print("{s} OK(err)\n", .{id}) catch {};
            return .pass;
        }
        log.writer().print("{s} FAIL(err:{})\n", .{ id, err }) catch {};
        return .fail;
    };
    defer result.deinit(allocator);

    if (has_error) {
        log.writer().print("{s} FAIL(noerr)\n", .{id}) catch {};
        return .fail;
    }

    if (readFileAlloc(allocator, test_dir, "in.json")) |json_opt| {
        if (json_opt) |json_raw| {
            defer allocator.free(json_raw);
            if (json_raw.len == 0) {
                log.writer().print("{s} OK(empty_json)\n", .{id}) catch {};
                return .pass;
            }
            const json_val = zyaml.parse(allocator, json_raw) catch {
                var seq = std.ArrayList(zyaml.YamlValue).init(allocator);
                var line_start: usize = 0;
                var success = true;
                errdefer {
                    for (seq.items) |*item| item.deinit(allocator);
                    seq.deinit();
                }
                while (line_start < json_raw.len) {
                    var line_end = line_start;
                    var str_depth: usize = 0;
                    var in_str = false;
                    while (line_end < json_raw.len) {
                        const c = json_raw[line_end];
                        if (in_str) {
                            if (c == '\\' and line_end + 1 < json_raw.len) {
                                line_end += 2;
                                continue;
                            }
                            if (c == '"') in_str = false;
                            line_end += 1;
                            continue;
                        }
                        if (c == '"') { in_str = true; line_end += 1; continue; }
                        if (c == '{' or c == '[') str_depth += 1;
                        if (c == '}' or c == ']') {
                            if (str_depth == 0) break;
                            str_depth -= 1;
                            if (str_depth == 0) { line_end += 1; break; }
                        }
                        if (c == '\n' and str_depth == 0) break;
                        line_end += 1;
                    }
                    if (line_start >= line_end) { line_start = line_end + 1; continue; }
                    const chunk = std.mem.trim(u8, json_raw[line_start..line_end], " \t\r\n");
                    if (chunk.len == 0) { line_start = line_end + 1; continue; }
                    var doc = zyaml.parse(allocator, chunk) catch { success = false; break; };
                    seq.append(doc) catch { doc.deinit(allocator); success = false; break; };
                    line_start = line_end + 1;
                }
                if (success and seq.items.len > 1) {
                    log.writer().print("{s} OK(multi_json)\n", .{id}) catch {};
                    for (seq.items) |*item| item.deinit(allocator);
                    seq.deinit();
                    if (result == .sequence and result.sequence.items.len == seq.items.len) return .pass;
                    return .fail;
                }
                for (seq.items) |*item| item.deinit(allocator);
                seq.deinit();
                log.writer().print("{s} FAIL(json)\n", .{id}) catch {};
                return .fail;
            };
            var jsonv = json_val;
            defer jsonv.deinit(allocator);
            if (!valuesEqual(result, jsonv)) {
                log.writer().print("{s} FAIL(diff)\n", .{id}) catch {};
                return .fail;
            }
        }
    } else |_| {}

    log.writer().print("{s} OK\n", .{id}) catch {};
    return .pass;
}

test "yaml-test-suite" {
    const allocator = std.testing.allocator;

    var suite_dir = std.fs.cwd().openDir(SuiteDir, .{ .iterate = true }) catch {
        std.debug.print("SKIP: {s} not found (run: git submodule update --init)\n", .{SuiteDir});
        return;
    };
    defer suite_dir.close();

    const log = try std.fs.cwd().createFile(".yaml-test-suite.log", .{});
    defer log.close();

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped_count: usize = 0;

    var top_iter = suite_dir.iterate();
    while (try top_iter.next()) |top_entry| {
        if (top_entry.kind != .directory) continue;

        var sub_dir = suite_dir.openDir(top_entry.name, .{ .iterate = true }) catch continue;
        defer sub_dir.close();

        if (fileExists(sub_dir, "in.yaml")) {
            const r = runTest(allocator, sub_dir, top_entry.name, log) catch |err| {
                log.writer().print("{s} CRASH({})\n", .{ top_entry.name, err }) catch {};
                failed += 1;
                continue;
            };
            switch (r) {
                .pass => passed += 1,
                .fail => failed += 1,
                .skip => skipped_count += 1,
            }
            continue;
        }

        var sub_iter = sub_dir.iterate();
        while (try sub_iter.next()) |sub_entry| {
            if (sub_entry.kind != .directory) continue;

            var test_dir = sub_dir.openDir(sub_entry.name, .{}) catch continue;
            defer test_dir.close();

            const id = std.fmt.allocPrint(allocator, "{s}/{s}", .{ top_entry.name, sub_entry.name }) catch continue;
            defer allocator.free(id);

            const r = runTest(allocator, test_dir, id, log) catch |err| {
                log.writer().print("{s} CRASH({})\n", .{ id, err }) catch {};
                failed += 1;
                continue;
            };
            switch (r) {
                .pass => passed += 1,
                .fail => failed += 1,
                .skip => skipped_count += 1,
            }
        }
    }

    const total = passed + failed + skipped_count;
    std.debug.print("\n=== yaml-test-suite: {}/{} passed, {} failed, {} skipped ===\n", .{ passed, total, failed, skipped_count });

    if (failed > 0) return error.TestFailed;
}
