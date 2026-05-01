const std = @import("std");
const Parser = @import("parser/parser.zig").Parser;
const Value = @import("ast/value.zig").Value;

pub const YamlValue = Value;
pub const YamlParser = Parser;
pub const YamlError = @import("error.zig").YamlError;

pub const ast = @import("ast/mod.zig");
pub const parser = @import("parser/mod.zig");
pub const encode = @import("encode/mod.zig");
pub const decode = @import("decode/mod.zig");

pub const Emitter = @import("encode/emitter.zig").Emitter;
pub const EmitOptions = @import("encode/emitter.zig").EmitOptions;
pub const FlowStyle = @import("encode/emitter.zig").FlowStyle;
pub const Composer = @import("decode/composer.zig").Composer;

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Value {
    var p = Parser.init(allocator, source);
    defer p.deinit();
    return p.parse();
}

pub fn stringify(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return @import("encode/emitter.zig").stringify(allocator, value, .{});
}

pub fn stringifyWithOptions(allocator: std.mem.Allocator, value: Value, options: EmitOptions) ![]const u8 {
    return @import("encode/emitter.zig").stringify(allocator, value, options);
}

pub fn compose(allocator: std.mem.Allocator, source: []const u8) !Value {
    return @import("decode/composer.zig").compose(allocator, source);
}

test "root module - parse and stringify roundtrip" {
    const allocator = std.testing.allocator;
    var doc = try parse(allocator, "key: value");
    defer doc.deinit(allocator);
    const output = try stringify(allocator, doc);
    defer allocator.free(output);
    try std.testing.expect(output.len > 0);
}

test "root module - compose value" {
    const allocator = std.testing.allocator;
    var doc = try compose(allocator, "hello");
    defer doc.deinit(allocator);
    try std.testing.expect(doc == .string);
    try std.testing.expectEqualStrings("hello", doc.string);
}
