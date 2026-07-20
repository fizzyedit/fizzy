//! Evaluate standard tree-sitter query text predicates (#eq?, #match?, #lua-match?, #any-of?).
const std = @import("std");
const dvui = @import("dvui");

const c = dvui.c;

const Step = c.TSQueryPredicateStep;
const step_done = c.TSQueryPredicateStepTypeDone;
const step_capture = c.TSQueryPredicateStepTypeCapture;
const step_string = c.TSQueryPredicateStepTypeString;

fn captureText(source: []const u8, node: c.TSNode) []const u8 {
    const start: usize = @intCast(c.ts_node_start_byte(node));
    const end: usize = @intCast(c.ts_node_end_byte(node));
    return source[start..end];
}

fn textForCaptureId(match: c.TSQueryMatch, source: []const u8, capture_id: u32) ?[]const u8 {
    var i: u16 = 0;
    while (i < match.capture_count) : (i += 1) {
        const cap = match.captures[i];
        if (cap.index == capture_id) return captureText(source, cap.node);
    }
    return null;
}

fn queryString(query: *const c.TSQuery, id: u32) []const u8 {
    var len: u32 = undefined;
    const ptr = c.ts_query_string_value_for_id(query, id, &len);
    return ptr[0..len];
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn isPascalTypeName(text: []const u8) bool {
    if (text.len == 0) return false;
    const c0 = text[0];
    if (c0 != '_' and (c0 < 'A' or c0 > 'Z')) return false;
    for (text[1..]) |ch| if (!isIdentChar(ch)) return false;
    return true;
}

fn isCamelFunctionName(text: []const u8) bool {
    if (text.len == 0) return false;
    const c0 = text[0];
    if (c0 != '_' and (c0 < 'a' or c0 > 'z')) return false;
    for (text[1..]) |ch| if (!isIdentChar(ch)) return false;
    return true;
}

fn isScreamingConstant(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[0] < 'A' or text[0] > 'Z') return false;
    for (text) |ch| {
        if (ch >= 'A' and ch <= 'Z') continue;
        if (ch >= '0' and ch <= '9') continue;
        if (ch == '_') continue;
        return false;
    }
    return true;
}

fn regexMatch(text: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, pattern, "^[A-Z_][a-zA-Z0-9_]*")) return isPascalTypeName(text);
    if (std.mem.eql(u8, pattern, "^[A-Z][A-Z_0-9]+$")) return isScreamingConstant(text);
    if (std.mem.eql(u8, pattern, "^[a-z_][a-zA-Z0-9_]*$")) return isCamelFunctionName(text);
    if (std.mem.eql(u8, pattern, "^//!")) return std.mem.startsWith(u8, text, "//!");
    if (std.mem.startsWith(u8, pattern, "^") and std.mem.endsWith(u8, pattern, "$")) {
        return std.mem.eql(u8, text, pattern[1 .. pattern.len - 1]);
    }
    if (std.mem.startsWith(u8, pattern, "^")) {
        return std.mem.startsWith(u8, text, pattern[1..]);
    }
    return std.mem.eql(u8, text, pattern);
}

fn evalPredicate(
    query: *const c.TSQuery,
    match: c.TSQueryMatch,
    source: []const u8,
    steps: []const Step,
) bool {
    if (steps.len == 0) return true;
    if (steps[0].type != step_string) return true;

    const op = queryString(query, steps[0].value_id);

    if (std.mem.eql(u8, op, "set!")) return true;

    if (std.mem.eql(u8, op, "eq?") or std.mem.eql(u8, op, "not-eq?")) {
        if (steps.len != 3 or steps[1].type != step_capture) return true;
        const positive = std.mem.eql(u8, op, "eq?");
        const cap_text = textForCaptureId(match, source, steps[1].value_id) orelse return !positive;
        const expected = if (steps[2].type == step_string)
            queryString(query, steps[2].value_id)
        else
            textForCaptureId(match, source, steps[2].value_id) orelse return !positive;
        const matched = std.mem.eql(u8, cap_text, expected);
        return if (positive) matched else !matched;
    }

    if (std.mem.eql(u8, op, "match?") or std.mem.eql(u8, op, "not-match?") or
        std.mem.eql(u8, op, "lua-match?") or std.mem.eql(u8, op, "not-lua-match?"))
    {
        if (steps.len != 3 or steps[1].type != step_capture or steps[2].type != step_string) return true;
        const positive = std.mem.eql(u8, op, "match?") or std.mem.eql(u8, op, "lua-match?");
        const cap_text = textForCaptureId(match, source, steps[1].value_id) orelse return !positive;
        const pattern = queryString(query, steps[2].value_id);
        const matched = regexMatch(cap_text, pattern);
        return if (positive) matched else !matched;
    }

    if (std.mem.eql(u8, op, "any-of?") or std.mem.eql(u8, op, "not-any-of?")) {
        if (steps.len < 3 or steps[1].type != step_capture) return true;
        const positive = std.mem.eql(u8, op, "any-of?");
        const cap_text = textForCaptureId(match, source, steps[1].value_id) orelse return !positive;
        var i: usize = 2;
        while (i < steps.len) : (i += 1) {
            if (steps[i].type != step_string) continue;
            if (std.mem.eql(u8, cap_text, queryString(query, steps[i].value_id))) {
                return positive;
            }
        }
        return !positive;
    }

    return true;
}

pub fn matchApplies(query: *const c.TSQuery, match: c.TSQueryMatch, source: []const u8) bool {
    var step_count: u32 = undefined;
    const steps = c.ts_query_predicates_for_pattern(query, match.pattern_index, &step_count);
    if (step_count == 0) return true;

    var i: u32 = 0;
    while (i < step_count) {
        const start = i;
        while (i < step_count and steps[i].type != step_done) : (i += 1) {}
        const pred = steps[start..i];
        if (pred.len > 0 and !evalPredicate(query, match, source, pred)) return false;
        i += 1;
    }
    return true;
}
