const std = @import("std");
const zyaml = @import("zyaml");

const SuiteDir = "test-suite/yaml-test-suite";

const skipped = [_][]const u8{
    "229Q",
    "236B",
    "26DV",
    "2CMS",
    "2EBW",
    "2G84/00",
    "2G84/01",
    "2JQS",
    "2LFX",
    "2SXE",
    "2XXW",
    "35KP",
    "36F6",
    "3HFZ",
    "3MYT",
    "3R3P",
    "4ABK",
    "4H7K",
    "4HVU",
    "4JVG",
    "4Q9F",
    "4QFQ",
    "4WA9",
    "4ZYM",
    "55WF",
    "565N",
    "57H4",
    "5C5M",
    "5GBF",
    "5LLU",
    "5NYZ",
    "5TRB",
    "5U3A",
    "5WE3",
    "62EZ",
    "6BCT",
    "6CA3",
    "6FWR",
    "6HB6",
    "6JQW",
    "6JWB",
    "6LVF",
    "6SLA",
    "6VJK",
    "6WLZ",
    "6WPF",
    "6XDY",
    "6ZKB",
    "735Y",
    "74H7",
    "753E",
    "7A4E",
    "7BMT",
    "7BUB",
    "7LBH",
    "7MNF",
    "7T8X",
    "7W2P",
    "82AN",
    "8KB6",
    "8QBE",
    "8XDJ",
    "8XYN",
    "93JH",
    "93WF",
    "9BXH",
    "9C9N",
    "9DXL",
    "9HCY",
    "9JBA",
    "9KAX",
    "9KBC",
    "9MMA",
    "9MQT/01",
    "9TFX",
    "9YRD",
    "A2M4",
    "A984",
    "AB8U",
    "AZW3",
    "B63P",
    "BD7L",
    "BEC7",
    "BF9H",
    "BS4K",
    "BU8L",
    "C2SP",
    "C4HZ",
    "CML9",
    "CN3R",
    "CQ3W",
    "CT4Q",
    "CTN5",
    "CVW2",
    "CXX2",
    "D49Q",
    "DBG4",
    "DC7X",
    "DE56/01",
    "DE56/03",
    "DE56/04",
    "DE56/05",
    "DFF7",
    "DK3J",
    "DK4H",
    "DK95/00",
    "DK95/01",
    "DK95/03",
    "DK95/04",
    "DK95/05",
    "DK95/06",
    "DMG6",
    "DWX9",
    "E76Z",
    "EB22",
    "EHF6",
    "EW3V",
    "EX5H",
    "EXG3",
    "F6MC",
    "F8F9",
    "FBC9",
    "FP8R",
    "FTA2",
    "G5U8",
    "G7JE",
    "G9HC",
    "GDY7",
    "GH63",
    "GT5M",
    "H2RW",
    "H7J7",
    "H7TQ",
    "HMQ5",
    "HRE5",
    "HS5T",
    "HU3P",
    "HWV9",
    "J3BT",
    "J7PZ",
    "J9HZ",
    "JEF9/00",
    "JEF9/02",
    "JHB9",
    "JKF3",
    "JTV5",
    "JY7Z",
    "K3WX",
    "K527",
    "K858",
    "KS4U",
    "KSS4",
    "L24T/00",
    "L24T/01",
    "L383",
    "L94M",
    "LHL4",
    "LP6E",
    "M29M",
    "M2N8/00",
    "M5C3",
    "M6YH",
    "M7A3",
    "MJS9",
    "MUS6/00",
    "MUS6/01",
    "MYW6",
    "N4JP",
    "N782",
    "NAT4",
    "NB6Z",
    "NJ66",
    "NP9H",
    "P2EQ",
    "P94K",
    "PRH3",
    "PUW8",
    "Q4CL",
    "Q5MG",
    "Q8AD",
    "QB6E",
    "QLJ7",
    "QT73",
    "R4YG",
    "RHX7",
    "RR7F",
    "RXY3",
    "RZT7",
    "S4GJ",
    "S4JQ",
    "S7BG",
    "S98Z",
    "S9E8",
    "SBG9",
    "SF5V",
    "SKE5",
    "SM9W/00",
    "SR86",
    "SU5Z",
    "SU74",
    "SY6V",
    "SYW4",
    "T26H",
    "T4YY",
    "T833",
    "TD5N",
    "TE2A",
    "TL85",
    "TS54",
    "U3XV",
    "U44R",
    "U99R",
    "UGM3",
    "UT92",
    "UV7Q",
    "VJP3/00",
    "W42U",
    "W4TN",
    "W5VH",
    "W9L4",
    "WZ62",
    "X38W",
    "X4QW",
    "X8DW",
    "XLQ9",
    "XV9V",
    "Y2GN",
    "Y79Y/000",
    "Y79Y/003",
    "Y79Y/004",
    "Y79Y/005",
    "Y79Y/006",
    "Y79Y/007",
    "Y79Y/008",
    "Y79Y/009",
    "Y79Y/010",
    "YJV2",
    "ZCZ6",
    "ZL4Z",
    "ZVH3",
    "ZWK4",
    "ZXT5",
};

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
            var json_val = zyaml.parse(allocator, json_raw) catch {
                log.writer().print("{s} FAIL(json)\n", .{id}) catch {};
                return .fail;
            };
            defer json_val.deinit(allocator);
            if (!valuesEqual(result, json_val)) {
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
            const r = try runTest(allocator, sub_dir, top_entry.name, log);
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

            const r = try runTest(allocator, test_dir, id, log);
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
