const std = @import("std");
const zyaml = @import("root.zig");
const Value = zyaml.YamlValue;
const Parser = zyaml.YamlParser;

const Allocator = std.mem.Allocator;
const c_alloc = std.heap.c_allocator;

threadlocal var tl_error_msg: ?[*:0]u8 = null;

fn setError(comptime fmt: []const u8, args: anytype) void {
    if (tl_error_msg) |ptr| {
        c_alloc.free(std.mem.sliceTo(ptr, 0));
        tl_error_msg = null;
    }
    const msg = std.fmt.allocPrintZ(c_alloc, fmt, args) catch return;
    tl_error_msg = @ptrCast(@constCast(msg.ptr));
}

fn clearError() void {
    if (tl_error_msg) |ptr| {
        c_alloc.free(std.mem.sliceTo(ptr, 0));
        tl_error_msg = null;
    }
}

pub const YamlType = enum(c_int) {
    null = 0,
    boolean = 1,
    integer = 2,
    float = 3,
    string = 4,
    sequence = 5,
    mapping = 6,
};

pub const YamlValueOpaque = opaque {};

fn fromValue(v: Value) *YamlValueOpaque {
    const box = c_alloc.create(Value) catch @panic("out of memory");
    box.* = v;
    return @ptrCast(@alignCast(box));
}

fn toValue(ptr: ?*YamlValueOpaque) ?*Value {
    if (ptr) |p| {
        return @ptrCast(@alignCast(p));
    }
    return null;
}

fn allocDupZ(s: []const u8) ?[*:0]const u8 {
    const duped = c_alloc.dupeZ(u8, s) catch return null;
    return duped.ptr;
}

export fn zyaml_parse(input: [*]const u8, len: usize) ?*YamlValueOpaque {
    clearError();
    const source = input[0..len];
    const owned = c_alloc.dupeZ(u8, source) catch @panic("out of memory");
    defer c_alloc.free(owned);
    var parser = Parser.init(c_alloc, owned);
    const value = parser.parse() catch |err| {
        setError("parse error: {}", .{err});
        return null;
    };
    parser.deinit();
    return fromValue(value);
}

export fn zyaml_parse_file(path: [*:0]const u8) ?*YamlValueOpaque {
    clearError();
    const path_slice = std.mem.sliceTo(path, 0);
    const file = std.fs.cwd().openFile(path_slice, .{}) catch |err| {
        setError("failed to open '{s}': {}", .{ path_slice, err });
        return null;
    };
    defer file.close();
    const source = file.readToEndAlloc(c_alloc, 100 * 1024 * 1024) catch |err| {
        setError("failed to read '{s}': {}", .{ path_slice, err });
        return null;
    };
    defer c_alloc.free(source);
    var parser = Parser.init(c_alloc, source);
    const value = parser.parse() catch |err| {
        parser.deinit();
        setError("parse error in '{s}': {}", .{ path_slice, err });
        return null;
    };
    return fromValue(value);
}

export fn zyaml_free(value: ?*YamlValueOpaque) void {
    if (toValue(value)) |v| {
        v.deinit(c_alloc);
        c_alloc.destroy(v);
    }
}

export fn zyaml_type(value: ?*YamlValueOpaque) YamlType {
    if (toValue(value)) |v| {
        return switch (v.*) {
            .null => .null,
            .boolean => .boolean,
            .integer => .integer,
            .float => .float,
            .string => .string,
            .sequence => .sequence,
            .mapping => .mapping,
        };
    }
    return .null;
}

export fn zyaml_as_bool(value: ?*YamlValueOpaque) bool {
    if (toValue(value)) |v| {
        if (v.* == .boolean) return v.boolean;
    }
    return false;
}

export fn zyaml_as_integer(value: ?*YamlValueOpaque) i64 {
    if (toValue(value)) |v| {
        if (v.* == .integer) return v.integer;
    }
    return 0;
}

export fn zyaml_as_float(value: ?*YamlValueOpaque) f64 {
    if (toValue(value)) |v| {
        if (v.* == .float) return v.float;
    }
    return 0.0;
}

export fn zyaml_as_string(value: ?*YamlValueOpaque) ?[*:0]const u8 {
    if (toValue(value)) |v| {
        if (v.* == .string) {
            return allocDupZ(v.string);
        }
    }
    return null;
}

export fn zyaml_free_string(s: ?[*:0]u8) void {
    if (s) |ptr| {
        const slice = std.mem.sliceTo(ptr, 0);
        c_alloc.free(slice);
    }
}

export fn zyaml_sequence_len(value: ?*YamlValueOpaque) usize {
    if (toValue(value)) |v| {
        if (v.* == .sequence) return v.sequence.items.len;
    }
    return 0;
}

export fn zyaml_sequence_get(value: ?*YamlValueOpaque, index: usize) ?*YamlValueOpaque {
    if (toValue(value)) |v| {
        if (v.* == .sequence) {
            if (index < v.sequence.items.len) {
                const box = c_alloc.create(Value) catch return null;
                box.* = v.sequence.items[index].deepClone(c_alloc) catch {
                    c_alloc.destroy(box);
                    return null;
                };
                return @ptrCast(@alignCast(box));
            }
        }
    }
    return null;
}

export fn zyaml_mapping_len(value: ?*YamlValueOpaque) usize {
    if (toValue(value)) |v| {
        if (v.* == .mapping) return v.mapping.count();
    }
    return 0;
}

export fn zyaml_mapping_get(value: ?*YamlValueOpaque, key: [*]const u8, key_len: usize) ?*YamlValueOpaque {
    if (toValue(value)) |v| {
        if (v.* == .mapping) {
            const key_slice = key[0..key_len];
            if (v.mapping.get(key_slice)) |found| {
                const box = c_alloc.create(Value) catch return null;
                box.* = found.deepClone(c_alloc) catch {
                    c_alloc.destroy(box);
                    return null;
                };
                return @ptrCast(@alignCast(box));
            }
        }
    }
    return null;
}

export fn zyaml_mapping_get_key(value: ?*YamlValueOpaque, index: usize) ?[*:0]const u8 {
    if (toValue(value)) |v| {
        if (v.* == .mapping) {
            var iter = v.mapping.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                if (i == index) {
                    return allocDupZ(entry.key_ptr.*);
                }
                i += 1;
            }
        }
    }
    return null;
}

export fn zyaml_mapping_get_key_borrow(value: ?*YamlValueOpaque, index: usize, out_len: *usize) ?[*]const u8 {
    out_len.* = 0;
    if (toValue(value)) |v| {
        if (v.* == .mapping) {
            var iter = v.mapping.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| {
                if (i == index) {
                    out_len.* = entry.key_ptr.*.len;
                    return entry.key_ptr.*.ptr;
                }
                i += 1;
            }
        }
    }
    return null;
}

export fn zyaml_sequence_get_borrow(value: ?*YamlValueOpaque, index: usize) ?*YamlValueOpaque {
    if (toValue(value)) |v| {
        if (v.* == .sequence) {
            if (index < v.sequence.items.len) {
                return @ptrCast(@alignCast(&v.sequence.items[index]));
            }
        }
    }
    return null;
}

export fn zyaml_mapping_get_borrow(value: ?*YamlValueOpaque, key: [*]const u8, key_len: usize) ?*YamlValueOpaque {
    if (toValue(value)) |v| {
        if (v.* == .mapping) {
            const key_slice = key[0..key_len];
            if (v.mapping.getPtr(key_slice)) |found| {
                return @ptrCast(@alignCast(found));
            }
        }
    }
    return null;
}

export fn zyaml_stringify(value: ?*YamlValueOpaque) ?[*:0]const u8 {
    if (toValue(value)) |v| {
        const output = zyaml.stringify(c_alloc, v.*) catch return null;
        const terminated = c_alloc.dupeZ(u8, output) catch {
            c_alloc.free(output);
            return null;
        };
        c_alloc.free(output);
        return terminated.ptr;
    }
    return null;
}

export fn zyaml_free_string_buf(s: ?[*]u8, len: usize) void {
    if (s) |ptr| {
        c_alloc.free(ptr[0..len]);
    }
}

export fn zyaml_to_json(value: ?*YamlValueOpaque, out_len: *usize) ?[*:0]const u8 {
    out_len.* = 0;
    if (toValue(value)) |v| {
        var buf = std.ArrayList(u8).init(c_alloc);
        valueToJson(v, &buf) catch {
            buf.deinit();
            return null;
        };
        const len = buf.items.len;
        const terminated = buf.toOwnedSliceSentinel(0) catch {
            buf.deinit();
            return null;
        };
        out_len.* = len;
        return terminated.ptr;
    }
    return null;
}

fn writeJsonEscapedChar(buf: *std.ArrayList(u8), ch: u8) JsonWriteError!void {
    switch (ch) {
        '"' => try buf.appendSlice("\\\""),
        '\\' => try buf.appendSlice("\\\\"),
        '\n' => try buf.appendSlice("\\n"),
        '\r' => try buf.appendSlice("\\r"),
        '\t' => try buf.appendSlice("\\t"),
        else => {
            if (ch < 0x20) {
                try buf.appendSlice("\\u00");
                const hex = "0123456789abcdef";
                try buf.append(hex[ch >> 4]);
                try buf.append(hex[ch & 0xf]);
            } else {
                try buf.append(ch);
            }
        },
    }
}

fn writeJsonString(buf: *std.ArrayList(u8), s: []const u8) JsonWriteError!void {
    try buf.append('"');
    for (s) |ch| try writeJsonEscapedChar(buf, ch);
    try buf.append('"');
}

fn valueToJson(v: *const Value, buf: *std.ArrayList(u8)) JsonWriteError!void {
    switch (v.*) {
        .null => try buf.writer().writeAll("null"),
        .boolean => |b| try buf.writer().writeAll(if (b) "true" else "false"),
        .integer => |i| try std.fmt.formatInt(i, 10, .lower, .{}, buf.writer()),
        .float => |f| try writeJsonFloat(buf, f),
        .string => |s| try writeJsonString(buf, s),
        .sequence => |seq| try writeJsonSequence(buf, seq),
        .mapping => |map| try writeJsonMapping(buf, map),
    }
}

fn writeJsonFloat(buf: *std.ArrayList(u8), f: f64) JsonWriteError!void {
    if (std.math.isNan(f)) {
        try buf.writer().writeAll("null");
    } else if (std.math.isInf(f)) {
        if (f > 0) try buf.writer().writeAll("1e999") else try buf.writer().writeAll("-1e999");
    } else {
        var tmp: [64]u8 = undefined;
        const str = std.fmt.formatFloat(&tmp, f, .{}) catch "null";
        try buf.writer().writeAll(str);
    }
}

const JsonWriteError = std.mem.Allocator.Error;

fn writeJsonSequence(buf: *std.ArrayList(u8), seq: Value.Sequence) JsonWriteError!void {
    try buf.append('[');
    for (seq.items, 0..) |*item, i| {
        if (i > 0) try buf.append(',');
        try valueToJson(item, buf);
    }
    try buf.append(']');
}

fn writeJsonMapping(buf: *std.ArrayList(u8), map: Value.Mapping) JsonWriteError!void {
    try buf.append('{');
    var iter = map.iterator();
    var first = true;
    while (iter.next()) |entry| {
        if (!first) try buf.append(',');
        first = false;
        try writeJsonString(buf, entry.key_ptr.*);
        try buf.append(':');
        try valueToJson(entry.value_ptr, buf);
    }
    try buf.append('}');
}

export fn zyaml_free_json(s: ?[*:0]u8) void {
    if (s) |ptr| {
        const slice = std.mem.sliceTo(ptr, 0);
        c_alloc.free(slice);
    }
}

fn jsonObjectToMapping(allocator: Allocator, obj: std.json.ObjectMap) Allocator.Error!Value {
    var map = Value.Mapping.init(allocator);
    errdefer {
        var it = map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        map.deinit();
    }
    try map.ensureTotalCapacity(obj.count());
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        try map.put(key, try jsonToValue(allocator, entry.value_ptr.*));
    }
    return .{ .mapping = map };
}

fn jsonToValue(allocator: Allocator, json_val: std.json.Value) Allocator.Error!Value {
    return switch (json_val) {
        .null => .null,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| {
            if (std.fmt.parseFloat(f64, s)) |f| {
                return .{ .float = f };
            } else |_| {}
            return .{ .string = try allocator.dupe(u8, s) };
        },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var seq = Value.Sequence.init(allocator);
            errdefer {
                for (seq.items) |*item| item.deinit(allocator);
                seq.deinit();
            }
            try seq.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| {
                try seq.append(try jsonToValue(allocator, item));
            }
            return .{ .sequence = seq };
        },
        .object => |obj| try jsonObjectToMapping(allocator, obj),
    };
}

fn buildEmitOptions(indent: c_int, sort_keys: bool, flow_style: c_int) zyaml.EmitOptions {
    const emit_indent: usize = if (indent > 0) @intCast(indent) else 2;
    const flow: zyaml.FlowStyle = if (flow_style == 1) .flow else .block;
    return .{ .indent = emit_indent, .sort_keys = sort_keys, .flow_style = flow };
}

fn nullTerminatedOutput(output: []const u8, out_len: *usize) ?[*:0]const u8 {
    const terminated = c_alloc.dupeZ(u8, output) catch return null;
    out_len.* = output.len;
    return terminated.ptr;
}

fn buildYamlOutput(value: Value, options: zyaml.EmitOptions, explicit_start: bool, explicit_end: bool, out_len: *usize) ?[*:0]const u8 {
    const output = zyaml.stringifyWithOptions(c_alloc, value, options) catch return null;
    defer c_alloc.free(output);

    var result = std.ArrayList(u8).init(c_alloc);
    errdefer result.deinit();
    if (explicit_start) result.appendSlice("---\n") catch return null;
    result.appendSlice(output) catch return null;
    result.appendSlice("\n") catch return null;
    if (explicit_end) result.appendSlice("...\n") catch return null;

    const len = result.items.len;
    const terminated = result.toOwnedSliceSentinel(0) catch {
        result.deinit();
        return null;
    };
    out_len.* = len;
    return terminated.ptr;
}

export fn zyaml_as_string_borrow(value: ?*YamlValueOpaque, out_len: *usize) ?[*]const u8 {
    out_len.* = 0;
    if (toValue(value)) |v| {
        if (v.* == .string) {
            out_len.* = v.string.len;
            return v.string.ptr;
        }
    }
    return null;
}

export fn zyaml_free_yaml(s: ?[*:0]u8) void {
    if (s) |ptr| {
        const slice = std.mem.sliceTo(ptr, 0);
        c_alloc.free(slice);
    }
}

export fn zyaml_value_null() ?*YamlValueOpaque {
    const box = c_alloc.create(Value) catch return null;
    box.* = .null;
    return @ptrCast(@alignCast(box));
}

export fn zyaml_value_bool(b: bool) ?*YamlValueOpaque {
    const box = c_alloc.create(Value) catch return null;
    box.* = .{ .boolean = b };
    return @ptrCast(@alignCast(box));
}

export fn zyaml_value_int(i: i64) ?*YamlValueOpaque {
    const box = c_alloc.create(Value) catch return null;
    box.* = .{ .integer = i };
    return @ptrCast(@alignCast(box));
}

export fn zyaml_value_float(f: f64) ?*YamlValueOpaque {
    const box = c_alloc.create(Value) catch return null;
    box.* = .{ .float = f };
    return @ptrCast(@alignCast(box));
}

export fn zyaml_value_string(s: [*]const u8, len: usize) ?*YamlValueOpaque {
    const box = c_alloc.create(Value) catch return null;
    const duped = c_alloc.dupeZ(u8, s[0..len]) catch {
        c_alloc.destroy(box);
        return null;
    };
    box.* = .{ .string = duped[0..len :0] };
    return @ptrCast(@alignCast(box));
}

export fn zyaml_value_sequence() ?*YamlValueOpaque {
    const box = c_alloc.create(Value) catch return null;
    box.* = .{ .sequence = Value.Sequence.init(c_alloc) };
    return @ptrCast(@alignCast(box));
}

export fn zyaml_value_sequence_append(seq: ?*YamlValueOpaque, val: ?*YamlValueOpaque) bool {
    if (toValue(seq)) |s| {
        if (s.* == .sequence) {
            if (toValue(val)) |v| {
                s.sequence.append(v.*) catch return false;
                c_alloc.destroy(v);
                return true;
            }
        }
    }
    return false;
}

export fn zyaml_value_mapping() ?*YamlValueOpaque {
    const box = c_alloc.create(Value) catch return null;
    box.* = .{ .mapping = Value.Mapping.init(c_alloc) };
    return @ptrCast(@alignCast(box));
}

export fn zyaml_value_mapping_put(map: ?*YamlValueOpaque, key: [*]const u8, key_len: usize, val: ?*YamlValueOpaque) bool {
    if (toValue(map)) |m| {
        if (m.* == .mapping) {
            if (toValue(val)) |v| {
                const duped_key = c_alloc.dupeZ(u8, key[0..key_len]) catch return false;
                m.mapping.put(duped_key[0..key_len :0], v.*) catch {
                    c_alloc.free(duped_key);
                    return false;
                };
                c_alloc.destroy(v);
                return true;
            }
        }
    }
    return false;
}

export fn zyaml_json_to_yaml(
    json_input: [*]const u8,
    json_len: usize,
    indent: c_int,
    sort_keys: bool,
    flow_style: c_int,
    explicit_start: bool,
    explicit_end: bool,
    out_len: *usize,
) ?[*:0]const u8 {
    out_len.* = 0;
    clearError();
    const source = json_input[0..json_len];

    const parsed = std.json.parseFromSlice(std.json.Value, c_alloc, source, .{}) catch |err| {
        setError("json parse error: {}", .{err});
        return null;
    };
    defer parsed.deinit();

    var value = jsonToValue(c_alloc, parsed.value) catch |err| {
        setError("json to value error: {}", .{err});
        return null;
    };
    defer value.deinit(c_alloc);

    const options = buildEmitOptions(indent, sort_keys, flow_style);
    const result = buildYamlOutput(value, options, explicit_start, explicit_end, out_len);
    if (result == null) setError("stringify error", .{});
    return result;
}

export fn zyaml_stringify_options(
    value: ?*YamlValueOpaque,
    indent: c_int,
    sort_keys: bool,
    flow: c_int,
    out_len: *usize,
) ?[*:0]const u8 {
    out_len.* = 0;
    if (toValue(value)) |v| {
        const options = buildEmitOptions(indent, sort_keys, flow);
        const output = zyaml.stringifyWithOptions(c_alloc, v.*, options) catch return null;
        defer c_alloc.free(output);
        return nullTerminatedOutput(output, out_len);
    }
    return null;
}

export fn zyaml_free_cstr(s: ?[*:0]u8) void {
    if (s) |ptr| {
        const slice = std.mem.sliceTo(ptr, 0);
        c_alloc.free(slice);
    }
}

export fn zyaml_error_message() ?[*:0]const u8 {
    return tl_error_msg;
}
