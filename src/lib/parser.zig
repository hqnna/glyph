const Parser = @This();
const Tokenizer = @import("tokenizer.zig");
const std = @import("std");

data: []const u8,
allocator: std.mem.Allocator,
tokenizer: Tokenizer,
current: ?Tokenizer.Token,

pub const Node = union(enum(u8)) {
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

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .object => |fields| {
                for (fields) |field| field.value.deinit(allocator);
                allocator.free(fields);
            },
            .array => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
            else => {},
        }
        allocator.destroy(self);
    }
};

const Error =
    std.mem.Allocator.Error ||
    std.fmt.ParseFloatError ||
    std.fmt.ParseIntError ||
    error{Unexpected};

const Handler = *const fn (*Parser) Error!*Node;
const dispatch_size = std.enums.directEnumArrayLen(Tokenizer.Token.Kind, 0);

const dispatch: [dispatch_size]?Handler = blk: {
    var table: [dispatch_size]?Handler = .{null} ** dispatch_size;
    table[@intFromEnum(Tokenizer.Token.Kind.lbrace)] = object;
    table[@intFromEnum(Tokenizer.Token.Kind.lbracket)] = array;
    table[@intFromEnum(Tokenizer.Token.Kind.nil)] = literal;
    table[@intFromEnum(Tokenizer.Token.Kind.string)] = literal;
    table[@intFromEnum(Tokenizer.Token.Kind.integer)] = literal;
    table[@intFromEnum(Tokenizer.Token.Kind.float)] = literal;
    table[@intFromEnum(Tokenizer.Token.Kind.boolean)] = literal;
    break :blk table;
};

pub fn init(allocator: std.mem.Allocator, tokenizer: Tokenizer) Parser {
    var self = Parser{
        .data = tokenizer.data,
        .allocator = allocator,
        .tokenizer = tokenizer,
        .current = null,
    };
    self.current = self.nextRaw();
    return self;
}

fn nextRaw(self: *Parser) ?Tokenizer.Token {
    while (self.tokenizer.next()) |tok| {
        if (tok.kind == .whitespace or tok.kind == .comment) continue;
        return tok;
    }
    return null;
}

fn next(self: *Parser) Error!Tokenizer.Token {
    const tok = self.current orelse return Error.Unexpected;
    self.current = self.nextRaw();
    return tok;
}

fn peek(self: *Parser) ?Tokenizer.Token {
    return self.current;
}

fn expect(self: *Parser, kind: Tokenizer.Token.Kind) Error!void {
    const tok = try self.next();
    if (tok.kind != kind) return Error.Unexpected;
}

pub fn parse(self: *Parser) Error!*Node {
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);

    var fields = try std.ArrayList(Node.Field).initCapacity(self.allocator, 8);
    defer fields.deinit(self.allocator);

    while (true) {
        const tok = self.peek() orelse break;
        if (tok.kind != .ident) return Error.Unexpected;
        _ = try self.next();

        // Slice directly into the input buffer — no allocation.
        const name = self.data[tok.start..tok.end];
        try self.expect(.colon);
        try fields.append(self.allocator, .{ .name = name, .value = try self.value() });
    }

    node.* = .{ .object = try fields.toOwnedSlice(self.allocator) };
    return node;
}

fn literal(self: *Parser) Error!*Node {
    const tok = try self.next();
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);

    node.* = switch (tok.kind) {
        .nil => .nil,
        .string => blk: {
            const raw = self.data[tok.start + 1 .. tok.end - 1];
            break :blk .{ .string = if (tok.escapes)
                try unescape(self.allocator, raw)
            else
                raw };
        },
        .integer => .{ .integer = try std.fmt.parseInt(i64, self.data[tok.start..tok.end], 10) },
        .float => .{ .float = try std.fmt.parseFloat(f64, self.data[tok.start..tok.end]) },
        .boolean => .{ .boolean = self.data[tok.start] == 't' },
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
    _ = try self.next(); // consume lbracket
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);

    var values = try std.ArrayList(*Node).initCapacity(self.allocator, 8);
    defer values.deinit(self.allocator);

    while (true) {
        const tok = self.peek() orelse return Error.Unexpected;
        if (tok.kind == .rbracket) {
            _ = try self.next();
            break;
        }
        try values.append(self.allocator, try self.value());
        const after = self.peek() orelse return Error.Unexpected;
        if (after.kind == .rbracket) continue;
        try self.expect(.comma);
    }

    node.* = .{ .array = try values.toOwnedSlice(self.allocator) };
    return node;
}

fn object(self: *Parser) Error!*Node {
    _ = try self.next();
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);

    var fields = try std.ArrayList(Node.Field).initCapacity(self.allocator, 8);
    defer fields.deinit(self.allocator);

    while (true) {
        const tok = try self.next();
        if (tok.kind == .rbrace) break;
        if (tok.kind != .ident) return Error.Unexpected;

        const name = self.data[tok.start..tok.end];
        try self.expect(.colon);
        try fields.append(self.allocator, .{ .name = name, .value = try self.value() });

        const after = self.peek() orelse return Error.Unexpected;
        if (after.kind == .rbrace) {
            _ = try self.next();
            break;
        }
    }

    node.* = .{ .object = try fields.toOwnedSlice(self.allocator) };
    return node;
}

fn unescape(allocator: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, raw.len);
    defer buf.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            try buf.append(allocator, raw[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= raw.len) return Error.Unexpected;
        const escaped: u8 = switch (raw[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            else => return Error.Unexpected,
        };
        try buf.append(allocator, escaped);
        i += 1;
    }

    return buf.toOwnedSlice(allocator);
}
