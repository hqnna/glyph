const Tokenizer = @This();
const std = @import("std");
const v = @import("vector.zig");

cursor: usize,
data: []const u8,

pub const Token = struct {
    pub const Kind = enum(u8) { ident, number };

    kind: Kind,
    start: usize,
    end: usize,
};

pub fn init(data: []const u8) Tokenizer {
    return .{ .cursor = 0, .data = data };
}

fn identifier(self: *Tokenizer) ?Token {
    if (!std.ascii.isAlphabetic(self.data[self.cursor])) return null;

    const start = self.cursor;
    self.cursor += 1;

    while (self.cursor + v.length <= self.data.len) : (self.cursor += v.length) {
        const chunk: v.Value = self.data[self.cursor..][0..v.length].*;

        const is_alpha = v.isAlpha(chunk);
        const is_digit = v.isDigit(chunk);
        const is_under = chunk == @as(v.Value, @splat('_'));
        const valid = is_alpha | is_digit | is_under;
        const mask = @as(v.Bits, @bitCast(valid));

        if (mask != std.math.maxInt(v.Bits)) {
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
