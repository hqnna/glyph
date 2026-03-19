const Tokenizer = @This();
const std = @import("std");
const v = @import("vector.zig");

cursor: usize,
data: []const u8,

const Scan = enum { cont, end, fail };

pub const Token = struct {
    pub const Kind = enum(u8) {
        ident,
        whitespace,
        boolean,
        lbracket,
        rbracket,
        comment,
        string,
        integer,
        float,
        lbrace,
        rbrace,
        colon,
        comma,
        nil,
    };

    kind: Kind,
    start: usize,
    end: usize,
};

pub fn init(data: []const u8) Tokenizer {
    return .{ .cursor = 0, .data = data };
}

pub fn next(self: *Tokenizer) ?Token {
    if (self.cursor >= self.data.len) return null;
    return self.whitespace() orelse
        self.comment() orelse
        self.symbol() orelse
        self.string() orelse
        self.number() orelse
        self.boolean() orelse
        self.nil() orelse
        self.identifier();
}

fn identifier(self: *Tokenizer) ?Token {
    if (self.cursor >= self.data.len) return null;
    if (!std.ascii.isAlphabetic(self.data[self.cursor])) return null;

    const start = self.cursor;
    self.cursor += 1;

    while (self.cursor + v.length <= self.data.len) : (self.cursor += v.length) {
        const chunk: v.Value = self.data[self.cursor..][0..v.length].*;

        const is_alpha = v.isAlpha(chunk);
        const is_digit = v.isDigit(chunk);
        const is_under = v.is(chunk, '_');
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

fn whitespace(self: *Tokenizer) ?Token {
    if (self.cursor >= self.data.len) return null;
    if (!std.ascii.isWhitespace(self.data[self.cursor])) return null;

    const start = self.cursor;
    self.cursor += 1;

    while (self.cursor + v.length <= self.data.len) : (self.cursor += v.length) {
        const chunk: v.Value = self.data[self.cursor..][0..v.length].*;

        const is_space = v.is(chunk, ' ');
        const is_return = v.is(chunk, '\r');
        const is_newline = v.is(chunk, '\n');
        const is_tab = v.is(chunk, '\t');

        const valid = is_space | is_tab | is_return | is_newline;
        const mask = @as(v.Bits, @bitCast(valid));

        if (mask != std.math.maxInt(v.Bits)) {
            self.cursor += @ctz(~mask);
            return Token{ .kind = .whitespace, .start = start, .end = self.cursor };
        }
    }

    while (self.cursor < self.data.len) : (self.cursor += 1) {
        if (!std.ascii.isWhitespace(self.data[self.cursor])) break;
    }

    return Token{ .kind = .whitespace, .start = start, .end = self.cursor };
}

fn comment(self: *Tokenizer) ?Token {
    if (self.cursor >= self.data.len) return null;
    if (self.data[self.cursor] != '#') return null;

    const start = self.cursor;
    self.cursor += 1;

    while (self.cursor + v.length <= self.data.len) : (self.cursor += v.length) {
        const chunk: v.Value = self.data[self.cursor..][0..v.length].*;
        const mask = @as(v.Bits, @bitCast(v.is(chunk, '\n')));

        if (mask != 0) {
            self.cursor += @ctz(mask);
            return Token{ .kind = .comment, .start = start, .end = self.cursor };
        }
    }

    while (self.cursor < self.data.len) : (self.cursor += 1) {
        if (self.data[self.cursor] == '\n') break;
    }

    return Token{ .kind = .comment, .start = start, .end = self.cursor };
}

fn string(self: *Tokenizer) ?Token {
    if (self.cursor >= self.data.len) return null;
    if (self.data[self.cursor] != '"') return null;

    const start = self.cursor;
    self.cursor += 1;

    while (self.cursor + v.length <= self.data.len) {
        const chunk: v.Value = self.data[self.cursor..][0..v.length].*;

        const is_quote = v.is(chunk, '"');
        const is_escape = v.is(chunk, '\\');
        const is_newline = v.is(chunk, '\n');
        const mask = @as(v.Bits, @bitCast(is_quote | is_escape | is_newline));

        if (mask != 0) {
            self.cursor += @ctz(mask);
            switch (self.stringStop()) {
                .end => return Token{ .kind = .string, .start = start, .end = self.cursor },
                .cont => continue,
                .fail => return null,
            }
        }

        self.cursor += v.length;
    }

    while (self.cursor < self.data.len) {
        switch (self.data[self.cursor]) {
            '"', '\\', '\n' => switch (self.stringStop()) {
                .end => return Token{ .kind = .string, .start = start, .end = self.cursor },
                .fail => return null,
                .cont => {},
            },
            else => self.cursor += 1,
        }
    }

    return null;
}

fn number(self: *Tokenizer) ?Token {
    if (self.cursor >= self.data.len) return null;
    if (!std.ascii.isDigit(self.data[self.cursor])) return null;

    const start = self.cursor;
    var exponent = false;
    var decimal = false;
    self.cursor += 1;

    while (self.cursor + v.length <= self.data.len) {
        const chunk: v.Value = self.data[self.cursor..][0..v.length].*;

        const is_digit = v.isDigit(chunk);
        const mask = @as(v.Bits, @bitCast(~is_digit));

        if (mask != 0) {
            self.cursor += @ctz(mask);
            switch (self.numberStop(&decimal, &exponent)) {
                .cont => continue,
                .end => {
                    const kind: Token.Kind = if (decimal or exponent) .float else .integer;
                    return Token{ .kind = kind, .start = start, .end = self.cursor };
                },
                .fail => return null,
            }
        }

        self.cursor += v.length;
    }

    while (self.cursor < self.data.len) : (self.cursor += 1) {
        if (!std.ascii.isDigit(self.data[self.cursor])) {
            switch (self.numberStop(&decimal, &exponent)) {
                .cont => {},
                .end => {
                    const kind: Token.Kind = if (decimal or exponent) .float else .integer;
                    return Token{ .kind = kind, .start = start, .end = self.cursor };
                },
                .fail => return null,
            }
        }
    }

    const kind: Token.Kind = if (decimal or exponent) .float else .integer;
    return Token{ .kind = kind, .start = start, .end = self.cursor };
}

fn symbol(self: *Tokenizer) ?Token {
    if (self.cursor >= self.data.len) return null;

    const kind: Token.Kind = switch (self.data[self.cursor]) {
        '{' => .lbrace,
        '}' => .rbrace,
        '[' => .lbracket,
        ']' => .rbracket,
        ':' => .colon,
        ',' => .comma,
        else => return null,
    };

    const start = self.cursor;
    self.cursor += 1;

    return Token{ .kind = kind, .start = start, .end = self.cursor };
}

fn boolean(self: *Tokenizer) ?Token {
    if (self.cursor >= self.data.len) return null;

    const start = self.cursor;

    if (std.mem.startsWith(u8, self.data[self.cursor..], "true")) {
        const end = self.cursor + 4;
        if (end < self.data.len) {
            if (std.ascii.isAlphanumeric(self.data[end])) return null;
            if (self.data[end] == '_') return null;
        }
        self.cursor = end;
        return Token{ .kind = .boolean, .start = start, .end = self.cursor };
    }

    if (std.mem.startsWith(u8, self.data[self.cursor..], "false")) {
        const end = self.cursor + 5;
        if (end < self.data.len) {
            if (std.ascii.isAlphanumeric(self.data[end])) return null;
            if (self.data[end] == '_') return null;
        }
        self.cursor = end;
        return Token{ .kind = .boolean, .start = start, .end = self.cursor };
    }

    return null;
}

fn nil(self: *Tokenizer) ?Token {
    if (self.cursor >= self.data.len) return null;
    if (!std.mem.startsWith(u8, self.data[self.cursor..], "nil")) return null;

    const start = self.cursor;
    const end = self.cursor + 3;

    if (end < self.data.len) {
        if (std.ascii.isAlphanumeric(self.data[end])) return null;
        if (self.data[end] == '_') return null;
    }

    self.cursor = end;
    return Token{ .kind = .nil, .start = start, .end = self.cursor };
}

inline fn stringStop(self: *Tokenizer) Scan {
    switch (self.data[self.cursor]) {
        '"' => {
            self.cursor += 1;
            return .end;
        },
        '\\' => {
            if (self.cursor + 1 >= self.data.len) return .fail;
            self.cursor += 2;
            return .cont;
        },
        '\n' => return .fail,
        else => unreachable,
    }
}

inline fn numberStop(self: *Tokenizer, decimal: *bool, exponent: *bool) Scan {
    switch (self.data[self.cursor]) {
        '.' => {
            if (decimal.* or exponent.*) return .fail;
            if (self.cursor + 1 >= self.data.len) return .fail;
            if (!std.ascii.isDigit(self.data[self.cursor + 1])) return .fail;

            self.cursor += 1;
            decimal.* = true;
            return .cont;
        },
        'e', 'E' => {
            if (decimal.* or exponent.*) return .fail;

            self.cursor += 1;
            if (self.cursor >= self.data.len) return .fail;

            var char = self.data[self.cursor];
            if (char == '+' or char == '-') {
                self.cursor += 1;
                if (self.cursor >= self.data.len) return .fail;
                char = self.data[self.cursor];
            }

            if (!std.ascii.isDigit(char)) return .fail;
            exponent.* = true;
            return .cont;
        },
        else => return .end,
    }
}
