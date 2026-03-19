const std = @import("std");

pub const Value = @Vector(length, u8);
pub const Condition = @Vector(length, bool);
pub const Bits = std.meta.Int(.unsigned, length);
pub const length = std.simd.suggestVectorLength(u8) orelse 16;

pub inline fn isAlpha(chunk: Value) Condition {
    const is_lower = (chunk >= @as(Value, @splat('a'))) & (chunk <= @as(Value, @splat('z')));
    const is_upper = (chunk >= @as(Value, @splat('A'))) & (chunk <= @as(Value, @splat('Z')));
    return is_lower | is_upper;
}

pub inline fn isDigit(chunk: Value) Condition {
    return (chunk >= @as(Value, @splat('0'))) & (chunk <= @as(Value, @splat('9')));
}
