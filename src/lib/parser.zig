const Parser = @This();
const Tokenizer = @import("tokenizer.zig");
const v = @import("vector.zig");
const std = @import("std");

data: []const u8,
allocator: std.mem.Allocator,
tokenizer: Tokenizer,
current: ?Tokenizer.Token,

nodes: std.ArrayListUnmanaged(Node),
fields: std.ArrayListUnmanaged(Node.Field),
items: std.ArrayListUnmanaged(NodeId),

pub const NodeId = u32;

pub const Node = union(enum(u8)) {
    pub const Field = struct {
        name: []const u8,
        value: NodeId,
    };

    object: struct { start: u32, len: u32 },
    array: struct { start: u32, len: u32 },
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    nil: void,
};

const Error =
    std.mem.Allocator.Error ||
    std.fmt.ParseFloatError ||
    std.fmt.ParseIntError ||
    error{Unexpected};

pub fn init(allocator: std.mem.Allocator, tokenizer: Tokenizer) Parser {
    const estimate: usize = tokenizer.data.len / 12;

    var self = Parser{
        .data = tokenizer.data,
        .allocator = allocator,
        .tokenizer = tokenizer,
        .current = null,
        .nodes = .empty,
        .fields = .empty,
        .items = .empty,
    };

    self.nodes.ensureTotalCapacity(allocator, estimate) catch {};
    self.fields.ensureTotalCapacity(allocator, estimate / 2) catch {};
    self.items.ensureTotalCapacity(allocator, estimate / 4) catch {};

    self.current = self.nextToken();
    return self;
}

pub fn deinit(self: *Parser) void {
    self.nodes.deinit(self.allocator);
    self.fields.deinit(self.allocator);
    self.items.deinit(self.allocator);
}

inline fn nextToken(self: *Parser) ?Tokenizer.Token {
    return self.tokenizer.next();
}

fn next(self: *Parser) Error!Tokenizer.Token {
    const tok = self.current orelse return Error.Unexpected;
    self.current = self.nextToken();
    return tok;
}

fn peek(self: *Parser) ?Tokenizer.Token {
    return self.current;
}

fn expect(self: *Parser, kind: Tokenizer.Token.Kind) Error!void {
    const tok = try self.next();
    if (tok.kind != kind) return Error.Unexpected;
}

pub fn parse(self: *Parser) Error!NodeId {
    const fields_start: u32 = @intCast(self.fields.items.len);
    var count: u32 = 0;

    while (true) {
        const tok = self.peek() orelse break;
        if (tok.kind != .ident) return Error.Unexpected;
        _ = try self.next();

        const name = self.data[tok.start..tok.end];
        try self.expect(.colon);
        const val = try self.value();
        try self.fields.append(self.allocator, .{ .name = name, .value = val });
        count += 1;
    }

    return self.addNode(.{ .object = .{ .start = fields_start, .len = count } });
}

fn addNode(self: *Parser, node: Node) Error!NodeId {
    const id: NodeId = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, node);
    return id;
}

fn value(self: *Parser) Error!NodeId {
    const tok = self.peek() orelse return Error.Unexpected;
    return switch (tok.kind) {
        .lbrace => self.object(),
        .lbracket => self.array(),
        .nil, .string, .integer, .float, .boolean => self.literal(),
        else => Error.Unexpected,
    };
}

fn literal(self: *Parser) Error!NodeId {
    const tok = try self.next();

    return self.addNode(switch (tok.kind) {
        .nil => .nil,
        .string => .{ .string = if (tok.escapes)
            try unescape(self.allocator, self.data[tok.start + 1 .. tok.end - 1])
        else
            self.data[tok.start + 1 .. tok.end - 1] },
        .integer => .{ .integer = fastParseInt(self.data[tok.start..tok.end]) orelse
            return Error.Unexpected },
        .float => .{ .float = fastParseFloat(self.data[tok.start..tok.end]) orelse
            try std.fmt.parseFloat(f64, self.data[tok.start..tok.end]) },
        .boolean => .{ .boolean = self.data[tok.start] == 't' },
        else => return Error.Unexpected,
    });
}

fn array(self: *Parser) Error!NodeId {
    _ = try self.next();
    const items_start: u32 = @intCast(self.items.items.len);
    var count: u32 = 0;

    while (true) {
        const tok = self.peek() orelse return Error.Unexpected;
        if (tok.kind == .rbracket) {
            _ = try self.next();
            break;
        }
        const val = try self.value();
        try self.items.append(self.allocator, val);
        count += 1;
        const after = self.peek() orelse return Error.Unexpected;
        if (after.kind == .rbracket) continue;
        try self.expect(.comma);
    }

    return self.addNode(.{ .array = .{ .start = items_start, .len = count } });
}

fn object(self: *Parser) Error!NodeId {
    _ = try self.next();
    const fields_start: u32 = @intCast(self.fields.items.len);
    var count: u32 = 0;

    while (true) {
        const tok = try self.next();
        if (tok.kind == .rbrace) break;
        if (tok.kind != .ident) return Error.Unexpected;

        const name = self.data[tok.start..tok.end];
        try self.expect(.colon);
        const val = try self.value();
        try self.fields.append(self.allocator, .{ .name = name, .value = val });
        count += 1;

        const after = self.peek() orelse return Error.Unexpected;
        if (after.kind == .rbrace) {
            _ = try self.next();
            break;
        }
    }

    return self.addNode(.{ .object = .{ .start = fields_start, .len = count } });
}

fn fastParseInt(s: []const u8) ?i64 {
    if (s.len == 0) return null;

    var i: usize = 0;
    const negative = s[0] == '-';
    if (negative) {
        i = 1;
        if (i >= s.len) return null;
    }

    var result: i64 = 0;
    while (i < s.len) : (i += 1) {
        const d = s[i] -% '0';
        if (d > 9) return null;
        result = result *% 10 +% d;
    }

    return if (negative) -%result else result;
}

fn fastParseFloat(s: []const u8) ?f64 {
    if (s.len == 0) return null;

    var i: usize = 0;
    const negative = s[0] == '-';
    if (negative) {
        i = 1;
        if (i >= s.len) return null;
    }

    var int_part: u64 = 0;
    while (i < s.len) : (i += 1) {
        const d = s[i] -% '0';
        if (d > 9) break;
        if (int_part > std.math.maxInt(u64) / 10) return null;
        int_part = int_part * 10 + d;
    }

    var result: f64 = @floatFromInt(int_part);

    if (i < s.len and s[i] == '.') {
        i += 1;
        var frac: f64 = 0;
        var divisor: f64 = 1;
        while (i < s.len) : (i += 1) {
            const d = s[i] -% '0';
            if (d > 9) break;
            frac = frac * 10 + @as(f64, @floatFromInt(d));
            divisor *= 10;
        }
        result += frac / divisor;
    }

    if (i < s.len) return null;

    return if (negative) -result else result;
}

fn unescape(allocator: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, raw.len);
    defer buf.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            const span_start = i;

            // SIMD scan for next backslash.
            i += 1;
            while (i + v.length <= raw.len) {
                const chunk: v.Value = raw[i..][0..v.length].*;
                const mask = @as(v.Bits, @bitCast(v.is(chunk, '\\')));
                if (mask != 0) {
                    i += @ctz(mask);
                    break;
                }
                i += v.length;
            } else {
                while (i < raw.len and raw[i] != '\\') : (i += 1) {}
            }

            try buf.appendSlice(allocator, raw[span_start..i]);
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
