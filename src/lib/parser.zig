const Parser = @This();
const Tokenizer = @import("tokenizer.zig");
const std = @import("std");

cursor: usize,
data: []const u8,
tokens: []const Tokenizer.Token,
allocator: std.mem.Allocator,

const Node = union(enum(u8)) {
    pub const Field = struct {
        name: []const u8,
        value: *Node,
    };

    object: []const Field,
    array: []const *Node,
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    nil: void,
};

const Error = std.mem.Allocator.Error || error{Unexpected};

pub fn init(a: std.mem.Allocator, t: *Tokenizer) Error!Parser {
    var tokens = try std.ArrayList(Tokenizer.Token).initCapacity(a, 64);
    defer tokens.deinit(a);

    while (t.next()) |tok| {
        if (tok.kind == .whitespace or tok.kind == .comment) continue;
        try tokens.append(a, tok);
    }

    return .{
        .cursor = 0,
        .data = t.data,
        .tokens = try tokens.toOwnedSlice(a),
        .allocator = a,
    };
}

pub fn deinit(self: Parser) void {
    self.allocator.free(self.tokens);
}

pub fn parse(self: *Parser) Error!*Node {
    return self.object(true);
}

const Handler = *const fn (*Parser) Error!*Node;
const dispatch_size = std.enums.directEnumArrayLen(Tokenizer.Token.Kind, 0);

const dispatch: [dispatch_size]?Handler = blk: {
    var table: [dispatch_size]?Handler = .{null} ** dispatch_size;
    table[@intFromEnum(Tokenizer.Token.Kind.lbrace)] = objectValue;
    table[@intFromEnum(Tokenizer.Token.Kind.lbracket)] = array;
    table[@intFromEnum(Tokenizer.Token.Kind.nil)] = literal;
    table[@intFromEnum(Tokenizer.Token.Kind.string)] = literal;
    table[@intFromEnum(Tokenizer.Token.Kind.integer)] = literal;
    table[@intFromEnum(Tokenizer.Token.Kind.float)] = literal;
    table[@intFromEnum(Tokenizer.Token.Kind.boolean)] = literal;
    break :blk table;
};

fn objectValue(self: *Parser) Error!*Node {
    return self.object(false);
}

fn literal(self: *Parser) Error!*Node {
    const tok = self.tokens[self.cursor];
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);
    self.cursor += 1;

    node.* = switch (tok.kind) {
        .nil => Node.nil,
        .string => .{ .string = self.data[tok.start + 1 .. tok.end - 1] },
        .integer => .{ .integer = try std.fmt.parseInt(i64, self.data[tok.start..tok.end], 10) },
        .float => .{ .float = try std.fmt.parseFloat(f64, self.data[tok.start..tok.end]) },
        .boolean => .{ .boolean = std.mem.eql(u8, "true", self.data[tok.start..tok.end]) },
        else => return Error.Unexpected,
    };

    return node;
}

fn value(self: *Parser) Error!*Node {
    const tok = self.peek() orelse return Error.Unexpected;
    const handler = dispatch[@intFromEnum(tok.kind)] orelse return Error.Unexpected;
    return handler(self);
}

fn array(self: *Parser) Error!*Node {
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);
    self.cursor += 1;

    var values = try std.ArrayList(*Node).initCapacity(self.allocator, 64);
    defer values.deinit(self.allocator);

    while (true) {
        const tok = try self.next();
        if (tok.kind == .rbracket) break;
        try values.append(self.allocator, try self.value());
        const after = try self.next();
        if (after.kind == .comma) continue;
        if (after.kind == .rbracket) break;
        return Error.Unexpected;
    }

    node.* = .{ .array = try values.toOwnedSlice(self.allocator) };
    return node;
}

fn object(self: *Parser, root: bool) Error!*Node {
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);
    if (!root) self.cursor += 1;

    var fields = try std.ArrayList(Node.Field).initCapacity(self.allocator, 64);
    defer fields.deinit(self.allocator);

    while (true) {
        const tok = try self.next();
        if (!root and tok.kind == .rbrace) break;
        if (tok.kind != .ident) return Error.Unexpected;
        const name = self.data[tok.start..tok.end];
        try self.expect(.colon);
        const field = Node.Field{ .name = name, .value = try self.value() };
        try fields.append(self.allocator, field);
        const after = self.peek() orelse if (root) break else return Error.Unexpected;
        if (!root and after.kind == .rbrace) {
            self.cursor += 1;
            break;
        }
    }

    node.* = .{ .object = try fields.toOwnedSlice(self.allocator) };
    return node;
}

fn next(self: *Parser) Error!Tokenizer.Token {
    if (self.cursor >= self.tokens.len) return Error.Unexpected;
    const token = self.tokens[self.cursor];
    self.cursor += 1;
    return token;
}

fn peek(self: Parser) ?Tokenizer.Token {
    if (self.cursor >= self.tokens.len) return null;
    return self.tokens[self.cursor];
}

fn expect(self: *Parser, kind: Tokenizer.Token.Kind) Error!void {
    if (self.cursor >= self.tokens.len) return Error.Unexpected;
    if (self.tokens[self.cursor].kind != kind) return Error.Unexpected;
    self.cursor += 1;
}
