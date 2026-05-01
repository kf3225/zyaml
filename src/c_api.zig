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

fn fromValue(v: Value, arena: *std.heap.ArenaAllocator) *YamlValueOpaque {
    const box = c_alloc.create(BoxedValue) catch @panic("out of memory");
    box.* = .{ .value = v, .arena = arena };
    return @ptrCast(@alignCast(box));
}

const BoxedValue = struct {
    value: Value,
    arena: ?*std.heap.ArenaAllocator,
};

fn toBoxedValue(ptr: ?*YamlValueOpaque) ?*BoxedValue {
    if (ptr) |p| {
        return @ptrCast(@alignCast(p));
    }
    return null;
}

fn toValue(ptr: ?*YamlValueOpaque) ?*Value {
    if (toBoxedValue(ptr)) |b| {
        return &b.value;
    }
    return null;
}

fn boxValue(v: Value) ?*YamlValueOpaque {
    const box = c_alloc.create(BoxedValue) catch return null;
    box.* = .{ .value = v, .arena = null };
    return @ptrCast(@alignCast(box));
}

fn allocDupZ(s: []const u8) ?[*:0]const u8 {
    const duped = c_alloc.dupeZ(u8, s) catch return null;
    return duped.ptr;
}

fn parseWithArena(source: []const u8, error_context: ?[]const u8) ?*YamlValueOpaque {
    const arena_ptr = c_alloc.create(std.heap.ArenaAllocator) catch @panic("out of memory");
    arena_ptr.* = std.heap.ArenaAllocator.init(c_alloc);
    const arena_alloc = arena_ptr.allocator();

    var parser = Parser.init(arena_alloc, source);
    const value = parser.parse() catch |err| {
        parser.deinit();
        arena_ptr.deinit();
        c_alloc.destroy(arena_ptr);
        if (error_context) |ctx| {
            setError("parse error in '{s}': {}", .{ ctx, err });
        } else {
            setError("parse error: {}", .{err});
        }
        return null;
    };
    parser.deinit();
    return fromValue(value, arena_ptr);
}

export fn zyaml_parse(input: [*]const u8, len: usize) ?*YamlValueOpaque {
    clearError();
    return parseWithArena(input[0..len], null);
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
    return parseWithArena(source, path_slice);
}

export fn zyaml_free(value: ?*YamlValueOpaque) void {
    if (toBoxedValue(value)) |b| {
        if (b.arena) |arena| {
            arena.deinit();
            c_alloc.destroy(arena);
        } else {
            b.value.deinit(c_alloc);
            c_alloc.destroy(b);
        }
    }
}

export fn zyaml_type(value: ?*YamlValueOpaque) YamlType {
    if (toValue(value)) |v| {
        return switch (v.*) {
            inline else => |_, tag| @field(YamlType, @tagName(tag)),
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
    freeNullTerminated(s);
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
                const cloned = v.sequence.items[index].deepClone(c_alloc) catch return null;
                return boxValue(cloned);
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
                const cloned = found.deepClone(c_alloc) catch return null;
                return boxValue(cloned);
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
            const entries = v.mapping.unmanaged.entries;
            if (index < entries.len) {
                const key = entries.items(.key)[index];
                out_len.* = key.len;
                return key.ptr;
            }
        }
    }
    return null;
}

export fn zyaml_mapping_get_value_borrow(value: ?*YamlValueOpaque, index: usize) ?*YamlValueOpaque {
    if (toValue(value)) |v| {
        if (v.* == .mapping) {
            const entries = v.mapping.unmanaged.entries;
            if (index < entries.len) {
                return @ptrCast(@alignCast(&entries.items(.value)[index]));
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
        var buffer = std.ArrayList(u8).init(c_alloc);
        errdefer buffer.deinit();
        var emitter = zyaml.Emitter.init(c_alloc, buffer.writer(), .{});
        emitter.emitValue(v.*) catch {
            buffer.deinit();
            return null;
        };
        const terminated = buffer.toOwnedSliceSentinel(0) catch {
            buffer.deinit();
            return null;
        };
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

const json_escape_map = blk: {
    var table: [256]?[]const u8 = @splat(null);
    table['"'] = "\\\"";
    table['\\'] = "\\\\";
    table['\n'] = "\\n";
    table['\r'] = "\\r";
    table['\t'] = "\\t";
    break :blk table;
};

fn writeJsonEscapedChar(buf: *std.ArrayList(u8), ch: u8) JsonWriteError!void {
    if (json_escape_map[ch]) |escaped| {
        try buf.appendSlice(escaped);
        return;
    }
    if (ch < 0x20) {
        try buf.appendSlice("\\u00");
        const hex = "0123456789abcdef";
        try buf.append(hex[ch >> 4]);
        try buf.append(hex[ch & 0xf]);
    } else {
        try buf.append(ch);
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
    freeNullTerminated(s);
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
    freeNullTerminated(s);
}

export fn zyaml_value_null() ?*YamlValueOpaque {
    return boxValue(.null);
}

export fn zyaml_value_bool(b: bool) ?*YamlValueOpaque {
    return boxValue(.{ .boolean = b });
}

export fn zyaml_value_int(i: i64) ?*YamlValueOpaque {
    return boxValue(.{ .integer = i });
}

export fn zyaml_value_float(f: f64) ?*YamlValueOpaque {
    return boxValue(.{ .float = f });
}

export fn zyaml_value_string(s: [*]const u8, len: usize) ?*YamlValueOpaque {
    const duped = c_alloc.dupeZ(u8, s[0..len]) catch return null;
    return boxValue(.{ .string = duped[0..len :0] });
}

export fn zyaml_value_sequence() ?*YamlValueOpaque {
    return boxValue(.{ .sequence = Value.Sequence.init(c_alloc) });
}

export fn zyaml_value_sequence_append(seq: ?*YamlValueOpaque, val: ?*YamlValueOpaque) bool {
    if (toBoxedValue(seq)) |s| {
        if (s.value == .sequence) {
            if (toBoxedValue(val)) |v| {
                s.value.sequence.append(v.value) catch return false;
                c_alloc.destroy(v);
                return true;
            }
        }
    }
    return false;
}

export fn zyaml_value_mapping() ?*YamlValueOpaque {
    return boxValue(.{ .mapping = Value.Mapping.init(c_alloc) });
}

export fn zyaml_value_mapping_put(map: ?*YamlValueOpaque, key: [*]const u8, key_len: usize, val: ?*YamlValueOpaque) bool {
    if (toBoxedValue(map)) |m| {
        if (m.value == .mapping) {
            if (toBoxedValue(val)) |v| {
                const duped_key = c_alloc.dupeZ(u8, key[0..key_len]) catch return false;
                m.value.mapping.put(duped_key[0..key_len :0], v.value) catch {
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
    freeNullTerminated(s);
}

export fn zyaml_error_message() ?[*:0]const u8 {
    return tl_error_msg;
}
