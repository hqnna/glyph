const std = @import("std");
const Tokenizer = @import("tokenizer.zig");
const Parser = @import("parser.zig");
const ztracy = @import("ztracy");

/// The result of parsing a glyph document into a raw AST.
///
/// Uses contiguous storage for nodes, fields, and array items. All data is
/// allocated from the internal arena — freeing is a single O(1) operation
/// via `deinit`.
///
/// String values (non-escaped) are slices directly into the original input
/// buffer. The input must remain valid for the lifetime of the `Ast`.
pub const Ast = struct {
    root: Parser.NodeId,
    nodes: []const Parser.Node,
    fields: []const Parser.Node.Field,
    items: []const Parser.NodeId,
    arena: std.heap.ArenaAllocator,

    /// Free all memory associated with the AST.
    pub fn deinit(self: *Ast) void {
        self.arena.deinit();
    }

    pub fn getNode(self: *const Ast, id: Parser.NodeId) Parser.Node {
        return self.nodes[id];
    }

    pub fn getFields(self: *const Ast, node: Parser.Node) []const Parser.Node.Field {
        return self.fields[node.object.start..][0..node.object.len];
    }

    pub fn getItems(self: *const Ast, node: Parser.Node) []const Parser.NodeId {
        return self.items[node.array.start..][0..node.array.len];
    }
};

/// Parse glyph-formatted text into a Zig struct of type `T`.
///
/// Fields of `T` are matched by name against top-level keys in the glyph
/// document. Supports booleans, integers, floats, optional types, strings,
/// slices of strings, and nested structs.
///
/// The AST is built on an internal arena and freed immediately after
/// materialization — only the final struct lands in `allocator`. Peak RSS
/// is roughly: input size + one arena slab + output struct.
///
/// The caller owns the returned value and must free any allocated memory
/// through the provided allocator.
pub fn parse(T: type, allocator: std.mem.Allocator, data: []const u8) !T {
    const zone = ztracy.ZoneNC(@src(), "glyph.parse", 0x00_00_cc_ff);
    defer zone.End();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokenizer = Tokenizer.init(data);
    var parser = Parser.init(arena.allocator(), tokenizer);
    defer parser.deinit();
    const root = try parser.parse();

    return materialize(T, allocator, &parser, root);
}

/// Parse glyph-formatted text and return the raw AST root node.
///
/// Returns a pointer to the top-level `Parser.Node` (always an object for
/// valid glyph documents). The caller owns the tree and must call
/// `node.deinit(allocator)` when finished.
///
/// Note: `Node.string` and `Node.Field.name` are slices into `data`.
/// The input buffer must remain valid for the lifetime of the tree.
pub fn ast(allocator: std.mem.Allocator, data: []const u8) !Ast {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const tokenizer = Tokenizer.init(data);
    var parser = Parser.init(arena.allocator(), tokenizer);
    const root = try parser.parse();

    return .{
        .root = root,
        .nodes = parser.nodes.items,
        .fields = parser.fields.items,
        .items = parser.items.items,
        .arena = arena,
    };
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
    const zone = ztracy.ZoneNC(@src(), "glyph.dump", 0x00_cc_66_ff);
    defer zone.End();

    var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer buf.deinit(allocator);
    try serialize(T, &buf, allocator, value, 0);
    return buf.toOwnedSlice(allocator);
}

fn materialize(T: type, allocator: std.mem.Allocator, parser: *const Parser, id: Parser.NodeId) !T {
    const zone = ztracy.ZoneNC(@src(), "materialize", 0x00_40_ff_80);
    defer zone.End();

    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("parse target must be a struct");

    var result: T = undefined;
    const node = parser.nodes.items[id];
    const obj_fields = parser.fields.items[node.object.start..][0..node.object.len];

    inline for (info.@"struct".fields) |f| {
        const val = findField(obj_fields, f.name);
        @field(result, f.name) = try materializeField(f.type, allocator, parser, val);
    }

    return result;
}

fn materializeField(F: type, allocator: std.mem.Allocator, parser: *const Parser, node_id: ?Parser.NodeId) !F {
    const info = @typeInfo(F);

    if (info == .optional) {
        const nid = node_id orelse return null;
        const n = parser.nodes.items[nid];
        if (n == .nil) return null;
        return try materializeField(info.optional.child, allocator, parser, nid);
    }

    const nid = node_id orelse return error.Unexpected;
    const n = parser.nodes.items[nid];

    return switch (info) {
        .bool => if (n == .boolean) n.boolean else error.Unexpected,
        .int => if (n == .integer) @intCast(n.integer) else error.Unexpected,
        .float => if (n == .float) @floatCast(n.float) else error.Unexpected,
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                if (n == .string) break :blk try allocator.dupe(u8, n.string);
                return error.Unexpected;
            }
            if (ptr.size == .slice) {
                if (n != .array) return error.Unexpected;
                const arr_items = parser.items.items[n.array.start..][0..n.array.len];
                var list = try std.ArrayList(ptr.child).initCapacity(allocator, arr_items.len);
                defer list.deinit(allocator);
                for (arr_items) |item_id| {
                    try list.append(allocator, try materializeField(ptr.child, allocator, parser, item_id));
                }
                break :blk try list.toOwnedSlice(allocator);
            }
            @compileError("unsupported pointer type");
        },
        .@"struct" => materialize(F, allocator, parser, nid),
        else => @compileError("unsupported field type: " ++ @typeName(F)),
    };
}

fn findField(fields: []const Parser.Node.Field, name: []const u8) ?Parser.NodeId {
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
        if (value) |val| {
            try serializeValue(info.optional.child, buf, allocator, val, depth);
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
