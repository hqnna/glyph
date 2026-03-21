const Tokenizer = @This();
const std = @import("std");
const v = @import("vector.zig");

cursor: u32,
data: []const u8,

pub const Token = struct {
    pub const Kind = enum(u8) {
        ident,
        boolean,
        lbracket,
        rbracket,
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
    escapes: bool,
    start: u32,
    end: u32,
};

const CharClass = enum(u8) {
    ws,
    comment,
    alpha,
    digit,
    quote,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    colon,
    comma,
    minus,
    other,
};

const class_table: [256]CharClass = blk: {
    var table: [256]CharClass = .{.other} ** 256;
    table[' '] = .ws;
    table['\t'] = .ws;
    table['\r'] = .ws;
    table['\n'] = .ws;
    table['#'] = .comment;
    table['"'] = .quote;
    table['{'] = .lbrace;
    table['}'] = .rbrace;
    table['['] = .lbracket;
    table[']'] = .rbracket;
    table[':'] = .colon;
    table[','] = .comma;
    table['-'] = .minus;
    for ('a'..('z' + 1)) |c| table[c] = .alpha;
    for ('A'..('Z' + 1)) |c| table[c] = .alpha;
    table['_'] = .alpha;
    for ('0'..('9' + 1)) |c| table[c] = .digit;
    break :blk table;
};

pub fn init(data: []const u8) Tokenizer {
    return .{ .cursor = 0, .data = data };
}

pub fn next(self: *Tokenizer) ?Token {
    while (self.cursor < self.data.len) {
        switch (class_table[self.data[self.cursor]]) {
            .ws => self.skipWhitespace(),
            .comment => self.skipComment(),
            .alpha => return self.scanWord(),
            .digit, .minus => return self.scanNumber(),
            .quote => return self.scanString(),
            .lbrace => return self.scanSymbol(.lbrace),
            .rbrace => return self.scanSymbol(.rbrace),
            .lbracket => return self.scanSymbol(.lbracket),
            .rbracket => return self.scanSymbol(.rbracket),
            .colon => return self.scanSymbol(.colon),
            .comma => return self.scanSymbol(.comma),
            .other => return null,
        }
    }
    return null;
}

inline fn scanSymbol(self: *Tokenizer, kind: Token.Kind) Token {
    const start = self.cursor;
    self.cursor += 1;
    return .{ .kind = kind, .escapes = false, .start = start, .end = self.cursor };
}

fn skipWhitespace(self: *Tokenizer) void {
    self.cursor += 1;

    while (self.cursor + v.length <= self.data.len) : (self.cursor += v.length) {
        const chunk: v.Value = self.data[self.cursor..][0..v.length].*;
        const mask = @as(v.Bits, @bitCast(v.isWhitespace(chunk)));

        if (mask != std.math.maxInt(v.Bits)) {
            self.cursor += @ctz(~mask);
            return;
        }
    }

    while (self.cursor < self.data.len and std.ascii.isWhitespace(self.data[self.cursor]))
        self.cursor += 1;
}

fn skipComment(self: *Tokenizer) void {
    self.cursor += 1;

    while (self.cursor + v.length <= self.data.len) : (self.cursor += v.length) {
        const chunk: v.Value = self.data[self.cursor..][0..v.length].*;
        const mask = @as(v.Bits, @bitCast(v.is(chunk, '\n')));

        if (mask != 0) {
            self.cursor += @ctz(mask);
            return;
        }
    }

    while (self.cursor < self.data.len and self.data[self.cursor] != '\n')
        self.cursor += 1;
}

fn scanWord(self: *Tokenizer) Token {
    const start = self.cursor;
    self.cursor += 1;

    while (self.cursor + v.length <= self.data.len) : (self.cursor += v.length) {
        const chunk: v.Value = self.data[self.cursor..][0..v.length].*;
        const valid = v.isAlpha(chunk) | v.isDigit(chunk) | v.is(chunk, '_');
        const mask = @as(v.Bits, @bitCast(valid));

        if (mask != std.math.maxInt(v.Bits)) {
            self.cursor += @ctz(~mask);
            return self.classifyWord(start);
        }
    }

    while (self.cursor < self.data.len) : (self.cursor += 1) {
        const c = self.data[self.cursor];
        if (c == '_') continue;
        if (!std.ascii.isAlphanumeric(c)) break;
    }

    return self.classifyWord(start);
}

inline fn classifyWord(self: *const Tokenizer, start: u32) Token {
    const len = self.cursor - start;
    const word = self.data[start..self.cursor];

    const kind: Token.Kind = switch (len) {
        3 => if (word[0] == 'n' and word[1] == 'i' and word[2] == 'l') .nil else .ident,
        4 => if (word[0] == 't' and word[1] == 'r' and word[2] == 'u' and word[3] == 'e') .boolean else .ident,
        5 => if (word[0] == 'f' and word[1] == 'a' and word[2] == 'l' and word[3] == 's' and word[4] == 'e') .boolean else .ident,
        else => .ident,
    };

    return .{ .kind = kind, .escapes = false, .start = start, .end = self.cursor };
}

fn scanString(self: *Tokenizer) ?Token {
    const start = self.cursor;
    self.cursor += 1;
    var has_escapes = false;

    while (self.cursor + v.length <= self.data.len) {
        const chunk: v.Value = self.data[self.cursor..][0..v.length].*;
        const mask = @as(v.Bits, @bitCast(v.is(chunk, '"') | v.is(chunk, '\\') | v.is(chunk, '\n')));

        if (mask != 0) {
            self.cursor += @ctz(mask);
            switch (self.data[self.cursor]) {
                '"' => {
                    self.cursor += 1;
                    return .{ .kind = .string, .escapes = has_escapes, .start = start, .end = self.cursor };
                },
                '\\' => {
                    if (self.cursor + 1 >= self.data.len) return null;
                    has_escapes = true;
                    self.cursor += 2;
                },
                '\n' => return null,
                else => unreachable,
            }
        } else {
            self.cursor += v.length;
        }
    }

    while (self.cursor < self.data.len) {
        switch (self.data[self.cursor]) {
            '"' => {
                self.cursor += 1;
                return .{ .kind = .string, .escapes = has_escapes, .start = start, .end = self.cursor };
            },
            '\\' => {
                if (self.cursor + 1 >= self.data.len) return null;
                has_escapes = true;
                self.cursor += 2;
            },
            '\n' => return null,
            else => self.cursor += 1,
        }
    }

    return null;
}

fn scanNumber(self: *Tokenizer) ?Token {
    const start = self.cursor;
    var decimal = false;
    var exponent = false;

    if (self.data[self.cursor] == '-') {
        self.cursor += 1;
        if (self.cursor >= self.data.len or !std.ascii.isDigit(self.data[self.cursor])) {
            self.cursor = start;
            return null;
        }
    }

    self.cursor += 1;

    while (self.cursor + v.length <= self.data.len) {
        const chunk: v.Value = self.data[self.cursor..][0..v.length].*;
        const mask = @as(v.Bits, @bitCast(~v.isDigit(chunk)));

        if (mask != 0) {
            self.cursor += @ctz(mask);
            switch (self.numberStop(&decimal, &exponent)) {
                .cont => continue,
                .end => return .{
                    .kind = if (decimal or exponent) .float else .integer,
                    .escapes = false,
                    .start = start,
                    .end = self.cursor,
                },
                .fail => return null,
            }
        } else {
            self.cursor += v.length;
        }
    }

    while (self.cursor < self.data.len) : (self.cursor += 1) {
        if (!std.ascii.isDigit(self.data[self.cursor])) {
            switch (self.numberStop(&decimal, &exponent)) {
                .cont => {},
                .end => return .{
                    .kind = if (decimal or exponent) .float else .integer,
                    .escapes = false,
                    .start = start,
                    .end = self.cursor,
                },
                .fail => return null,
            }
        }
    }

    return .{
        .kind = if (decimal or exponent) .float else .integer,
        .escapes = false,
        .start = start,
        .end = self.cursor,
    };
}

const Scan = enum { cont, end, fail };

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
            if (exponent.*) return .fail;

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
