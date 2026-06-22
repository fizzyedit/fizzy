//! Monospace code editor: gutter line numbers + tree-sitter `textEntry`.
const std = @import("std");
const code = @import("../code.zig");
const dvui = code.dvui;
const wdvui = code.core.dvui;
const Document = code.Document;
const SyntaxHighlight = @import("SyntaxHighlight.zig");

const editor_padding = dvui.Rect.all(8);
const gutter_pad_x: f32 = 12;

/// Tree-sitter + per-token layout is O(file size) each frame without layout caching.
/// Above this size we still edit, but skip syntax highlighting.
const syntax_highlight_max_bytes: usize = 512 * 1024;

const chromeless = dvui.Options{
    .background = false,
    .margin = dvui.Rect{},
    .padding = null,
    // override() treats null as "unset", so use empty rects to clear TextEntry defaults.
    .border = dvui.Rect{},
    .corner_radius = dvui.Rect{},
    .ninepatch_fill = &dvui.Ninepatch.none,
    .ninepatch_hover = &dvui.Ninepatch.none,
    .ninepatch_press = &dvui.Ninepatch.none,
};

pub fn draw(doc: *Document, id_extra: u64, gpa: std.mem.Allocator) !bool {
    const font = dvui.Font.theme(.mono);
    const theme = SyntaxHighlight.default_theme;
    const gutter_w = gutterWidth(doc.line_count, font);
    const line_height = font.lineHeight();

    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, chromeless.override(.{
        .expand = .both,
    }));
    defer hbox.deinit();

    _ = dvui.spacer(@src(), .{
        .min_size_content = .{ .w = gutter_w },
        .expand = .vertical,
    });

    const use_syntax = doc.text.items.len <= syntax_highlight_max_bytes;

    var te = wdvui.textEntry(@src(), .{
        .multiline = true,
        .break_lines = false,
        // Limit layout + tree-sitter query work to the visible scroll range (see dvui Examples/text_entry.zig).
        .cache_layout = true,
        .scroll_horizontal = true,
        .show_focus_border = false,
        .text = .{ .array_list = .{ .backing = &doc.text, .allocator = gpa, .limit = max_text_bytes } },
        .tree_sitter = if (use_syntax) SyntaxHighlight.treeSitterOption(doc.path, theme) else null,
    }, chromeless.override(.{
        .expand = .both,
        .font = font,
        .padding = editor_padding,
        .color_text = theme.text,
        .id_extra = @intCast(id_extra),
    }));
    defer te.deinit();

    const te_rs = te.data().borderRectScale();
    const gutter_rs: dvui.RectScale = .{
        .r = .{
            .x = te_rs.r.x - gutter_w * te_rs.s,
            .y = te_rs.r.y,
            .w = gutter_w * te_rs.s,
            .h = te_rs.r.h,
        },
        .s = te_rs.s,
    };
    drawLineNumbers(gutter_rs, doc.line_count, te.scroll.si.viewport.y, font, line_height, theme.line_number);

    if (te.text_changed) doc.refreshLineCount();
    return te.text_changed;
}

const max_text_bytes: usize = 64 * 1024 * 1024;

fn gutterWidth(line_count: usize, font: dvui.Font) f32 {
    var buf: [16]u8 = undefined;
    const sample = std.fmt.bufPrint(&buf, "{d}", .{line_count}) catch "9999";
    return font.textSize(sample).w + gutter_pad_x * 2;
}

fn drawLineNumbers(
    rs: dvui.RectScale,
    line_count: usize,
    scroll_y: f32,
    font: dvui.Font,
    line_height: f32,
    number_color: dvui.Color,
) void {
    if (rs.r.empty()) return;

    const prev_clip = dvui.clip(rs.r);
    defer dvui.clipSet(prev_clip);

    const first_line: usize = @intCast(@max(0, @as(i64, @intFromFloat((scroll_y - editor_padding.y) / line_height))));

    var line: usize = first_line;
    var y: f32 = editor_padding.y + @as(f32, @floatFromInt(line)) * line_height - scroll_y;

    var num_buf: [32]u8 = undefined;

    while (line < line_count and y < rs.r.h + line_height) : ({
        line += 1;
        y += line_height;
    }) {
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line + 1}) catch continue;
        const text_size = font.textSize(num_str).scale(rs.s, dvui.Size.Physical);
        const x = rs.r.x + rs.r.w - editor_padding.w - text_size.w;
        const y_phys = rs.r.y + y * rs.s;

        dvui.renderText(.{
            .font = font,
            .text = num_str,
            .rs = .{ .r = .{ .x = x, .y = y_phys, .w = text_size.w, .h = text_size.h }, .s = rs.s },
            .color = number_color,
        }) catch |err| {
            dvui.log.err("line number text: {any}", .{err});
        };
    }
}
