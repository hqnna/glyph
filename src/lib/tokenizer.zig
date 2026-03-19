const Tokenizer = @This();
const std = @import("std");

cursor: usize,
data: []const u8,

const Chunk = @Vector(chunk_size, u8);
const chunk_size = std.simd.suggestVectorLength(u8) orelse 16;
const Mask = std.meta.Int(.unsigned, chunk_size);

pub const Token = struct {
    pub const Kind = enum(u8) {
        ident,
        boolean,
        number,
        string,
        object,
        array,
        nil,
    };

    kind: Kind,
    start: usize,
    end: ?usize,
};

pub fn init(data: []const u8) Tokenizer {
    return .{ .cursor = 0, .data = data };
}

fn identifier(self: *Tokenizer) ?Token {
    if (!std.ascii.isAlphabetic(self.data[self.cursor])) return null;

    const start = self.cursor;
    self.cursor += 1;

    while (self.cursor + chunk_size <= self.data.len) : (self.cursor += chunk_size) {
        const chunk: Chunk = self.data[self.cursor..][0..chunk_size].*;

        const is_lower = (chunk >= @as(Chunk, @splat('a'))) & (chunk <= @as(Chunk, @splat('z')));
        const is_upper = (chunk >= @as(Chunk, @splat('A'))) & (chunk <= @as(Chunk, @splat('Z')));
        const is_digit = (chunk >= @as(Chunk, @splat('0'))) & (chunk <= @as(Chunk, @splat('9')));
        const is_under = chunk == @as(Chunk, @splat('_'));

        const valid = is_lower | is_upper | is_digit | is_under;
        const mask = @as(Mask, @bitCast(valid));

        if (mask != std.math.maxInt(Mask)) {
            self.cursor += @ctz(~mask);
            return Token{ .kind = .ident, .start = start, .end = self.cursor };
        }
    }

    while (self.cursor < self.data.len) : (self.cursor += 1) {
        if (self.data[self.cursor] == '_') continue;
        if (!std.ascii.isAlphanumeric(self.data[self.cursor])) break;
    }

    return Token{ .kind = .ident, .start = start, .end = self.cursor };
}
