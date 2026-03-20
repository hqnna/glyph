const std = @import("std");
const Tokenizer = @import("tokenizer.zig");
const Parser = @import("parser.zig");

pub const Node = Parser.Node;

/// Parse glyph-formatted text into a Zig struct of type `T`.
///
/// Fields of `T` are matched by name against top-level keys in the glyph
/// document. Supports booleans, integers, floats, optional types, strings,
/// slices of strings, and nested structs.
///
/// The caller owns the returned value and must free any allocated memory
/// through the provided allocator.
pub fn parse(T: type, allocator: std.mem.Allocator, data: []const u8) !T {
    var root = try ast(allocator, data);
    defer root.deinit(allocator);
    return materialize(T, allocator, root);
}

/// Parse glyph-formatted text and return the raw AST root node.
///
/// Returns a pointer to the top-level `Node` (always an object for valid
/// glyph documents). The caller owns the tree and must call
/// `node.deinit(allocator)` when finished.
pub fn ast(allocator: std.mem.Allocator, data: []const u8) !*Node {
    var tokenizer = Tokenizer.init(data);
    var parser = try Parser.init(allocator, &tokenizer);
    defer parser.deinit();
    return parser.parse();
}

/// Serialize a Zig struct of type `T` into glyph-formatted text.
///
/// Produces a human-readable glyph document from the struct's fields.
/// Supports booleans, integers, floats, optional types, strings, slices of
/// strings, and nested structs.
///
/// The caller owns the returned slice and must free it with the provided
/// allocator.
pub fn dump(T: type, allocator: std.mem.Allocator, value: T) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer buf.deinit(allocator);
    try serialize(T, &buf, allocator, value, 0);
    return buf.toOwnedSlice(allocator);
}

fn materialize(T: type, allocator: std.mem.Allocator, node: *Node) !T {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("parse target must be a struct");

    var result: T = undefined;
    const fields = node.object;

    inline for (info.@"struct".fields) |f| {
        const val = findField(fields, f.name);
        @field(result, f.name) = try materializeField(f.type, allocator, val);
    }

    return result;
}

fn materializeField(F: type, allocator: std.mem.Allocator, node: ?*Node) !F {
    const info = @typeInfo(F);

    if (info == .optional) {
        const n = node orelse return null;
        if (n.* == .nil) return null;
        return try materializeField(info.optional.child, allocator, n);
    }

    const n = node orelse return error.Unexpected;

    return switch (info) {
        .bool => if (n.* == .boolean) n.boolean else error.Unexpected,
        .int => if (n.* == .integer) @intCast(n.integer) else error.Unexpected,
        .float => if (n.* == .float) @floatCast(n.float) else error.Unexpected,
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                if (n.* == .string) break :blk try allocator.dupe(u8, n.string);
                return error.Unexpected;
            }
            if (ptr.size == .slice) {
                if (n.* != .array) return error.Unexpected;
                var list = try std.ArrayList(ptr.child).initCapacity(allocator, n.array.len);
                defer list.deinit(allocator);
                for (n.array) |item| {
                    try list.append(allocator, try materializeField(ptr.child, allocator, item));
                }
                break :blk try list.toOwnedSlice(allocator);
            }
            @compileError("unsupported pointer type");
        },
        .@"struct" => materialize(F, allocator, n),
        else => @compileError("unsupported field type: " ++ @typeName(F)),
    };
}

fn findField(fields: []const Node.Field, name: []const u8) ?*Node {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.value;
    }
    return null;
}

fn serialize(
    T: type,
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: T,
    depth: usize,
) !void {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("dump target must be a struct");

    const fields = info.@"struct".fields;
    inline for (fields, 0..) |f, i| {
        try indent(buf, allocator, depth);
        try buf.appendSlice(allocator, f.name);
        try buf.appendSlice(allocator, ": ");
        try serializeValue(f.type, buf, allocator, @field(value, f.name), depth);
        if (depth > 0 or i < fields.len - 1)
            try buf.append(allocator, '\n');
    }
}

fn serializeValue(
    F: type,
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: F,
    depth: usize,
) !void {
    const info = @typeInfo(F);

    if (info == .optional) {
        if (value) |v| {
            try serializeValue(info.optional.child, buf, allocator, v, depth);
        } else {
            try buf.appendSlice(allocator, "nil");
        }
        return;
    }

    switch (info) {
        .bool => try buf.appendSlice(allocator, if (value) "true" else "false"),
        .int => {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .float => {
            var tmp: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
            try buf.appendSlice(allocator, s);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, value);
                try buf.append(allocator, '"');
            } else if (ptr.size == .slice) {
                try buf.appendSlice(allocator, "[\n");
                for (value) |item| {
                    try indent(buf, allocator, depth + 1);
                    try serializeValue(ptr.child, buf, allocator, item, depth + 1);
                    try buf.append(allocator, '\n');
                }
                try indent(buf, allocator, depth);
                try buf.append(allocator, ']');
            } else {
                @compileError("unsupported pointer type");
            }
        },
        .@"struct" => {
            try buf.appendSlice(allocator, "{\n");
            try serialize(F, buf, allocator, value, depth + 1);
            try indent(buf, allocator, depth);
            try buf.append(allocator, '}');
        },
        else => @compileError("unsupported field type: " ++ @typeName(F)),
    }
}

fn indent(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, depth: usize) !void {
    for (0..depth) |_| try buf.appendSlice(allocator, "  ");
}
