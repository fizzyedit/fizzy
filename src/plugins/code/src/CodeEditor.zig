//! Monospace code editor: line numbers + local `TextEntryWidget` with tree-sitter highlighting.
const std = @import("std");
const code = @import("../code.zig");
const dvui = code.dvui;
const Document = code.Document;
const SyntaxHighlight = @import("SyntaxHighlight.zig");
const TextEntryWidget = @import("widgets/TextEntryWidget.zig");

const editor_pad_y: f32 = 8;
const editor_pad_right: f32 = 8;
const line_number_pad_left: f32 = 4;
const code_gap_after_numbers: f32 = 12;

const text_color = dvui.Color{ .r = 0xdd, .g = 0xdc, .b = 0xd3, .a = 255 };
const line_number_color = dvui.Color{ .r = 0x58, .g = 0x58, .b = 0x5f, .a = 255 };

/// Tree-sitter + per-token layout is O(file size) each frame without layout caching.
const syntax_highlight_max_bytes: usize = 512 * 1024;

const chromeless = dvui.Options{
    .background = false,
    .margin = dvui.Rect{},
    .padding = null,
    .border = dvui.Rect{},
    .corner_radius = dvui.Rect{},
    .ninepatch_fill = &dvui.Ninepatch.none,
    .ninepatch_hover = &dvui.Ninepatch.none,
    .ninepatch_press = &dvui.Ninepatch.none,
};

pub fn draw(doc: *Document, id_extra: u64, gpa: std.mem.Allocator) !bool {
    const font = dvui.Font.theme(.mono);
    const line_height = font.lineHeight();
    const line_num_col = lineNumberColumnWidth(doc.line_count, font);

    var te = TextEntryWidget.textEntry(@src(), .{
        .multiline = true,
        .break_lines = false,
        .cache_layout = true,
        .scroll_horizontal = true,
        .focus_border = false,
        .text = .{ .array_list = .{ .backing = &doc.text, .allocator = gpa, .limit = max_text_bytes } },
        .tree_sitter = if (doc.text.items.len <= syntax_highlight_max_bytes)
            SyntaxHighlight.treeSitterOption(doc.path)
        else
            null,
    }, chromeless.override(.{
        .expand = .both,
        .font = font,
        .padding = .{
            .x = line_num_col,
            .y = editor_pad_y,
            .w = editor_pad_right,
            .h = editor_pad_y,
        },
        .color_text = text_color,
        .id_extra = @intCast(id_extra),
    }));
    defer te.deinit();

    drawLineNumbers(
        te.data().borderRectScale(),
        doc.line_count,
        te.scroll.si.viewport.y,
        font,
        line_height,
    );

    if (te.text_changed) doc.refreshLineCount();
    return te.text_changed;
}

const max_text_bytes: usize = 64 * 1024 * 1024;

fn lineNumberColumnWidth(line_count: usize, font: dvui.Font) f32 {
    var buf: [16]u8 = undefined;
    const sample = std.fmt.bufPrint(&buf, "{d}", .{line_count}) catch "9999";
    return line_number_pad_left + font.textSize(sample).w + code_gap_after_numbers;
}

fn drawLineNumbers(
    rs: dvui.RectScale,
    line_count: usize,
    scroll_y: f32,
    font: dvui.Font,
    line_height: f32,
) void {
    if (rs.r.empty()) return;

    const prev_clip = dvui.clip(rs.r);
    defer dvui.clipSet(prev_clip);

    const first_line: usize = @intCast(@max(0, @as(i64, @intFromFloat((scroll_y - editor_pad_y) / line_height))));

    var line: usize = first_line;
    var y: f32 = editor_pad_y + @as(f32, @floatFromInt(line)) * line_height - scroll_y;

    var num_buf: [32]u8 = undefined;

    while (line < line_count and y < rs.r.h + line_height) : ({
        line += 1;
        y += line_height;
    }) {
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line + 1}) catch continue;
        const text_size = font.textSize(num_str).scale(rs.s, dvui.Size.Physical);
        const x = rs.r.x + line_number_pad_left * rs.s;
        const y_phys = rs.r.y + y * rs.s;

        dvui.renderText(.{
            .font = font,
            .text = num_str,
            .rs = .{ .r = .{ .x = x, .y = y_phys, .w = text_size.w, .h = text_size.h }, .s = rs.s },
            .color = line_number_color,
        }) catch |err| {
            dvui.log.err("line number text: {any}", .{err});
        };
    }
}
