//! Infobar metrics and the plugin contribution type.
//!
//! Fizzy draws the bar: its own items (logo/about, project folder) first, then each plugin
//! `Entry` as icon + text, in a horizontal strip that scrolls if the row overflows. Plugins
//! never draw into the bar — they return `Entry` values from `Plugin.VTable.infobarEntries`.
//!
//! Metrics derive from the current theme's body font, which fizzy's font-size setting drives
//! (`Settings.font_body_size`, clamped 6–20pt). The bar used to be a fixed 22pt, which fit the
//! default 9pt body font and clipped every larger setting — nothing in the bar may hard-code a
//! size.
const dvui = @import("dvui");

/// One plugin contribution. Fizzy draws it; `icon` is TVG bytes (entypo/lucide), empty = text
/// only. `text` and `icon` must remain valid until the next `infobarEntries` call (static or
/// `host.arena()`).
pub const Entry = struct {
    icon: []const u8 = &.{},
    text: []const u8 = &.{},
};

/// Breathing room above and below the tallest item, in natural units.
pub const vertical_padding: f32 = 4;

/// Gap between neighbouring items, whoever contributed them.
pub const item_spacing: f32 = 12;

/// Floor for `height()`, so the bar keeps its shape at the smallest font sizes rather than
/// collapsing to a sliver. This is what the bar measured before it scaled at all.
pub const min_height: f32 = 22;

/// The one font for every label in the bar: one step below body, so the infobar reads as
/// secondary chrome next to the document rather than competing with it.
pub fn font() dvui.Font {
    return dvui.Font.theme(.body).larger(-1.0);
}

/// Square side for icons and image glyphs: the bar's content band, i.e. its height less the
/// padding. Off `height()` rather than the font directly so a glyph fills the same band the
/// label sits in at large sizes *and* keeps its familiar size at small ones, where the bar is
/// held at `min_height` and the text no longer sets the height.
pub fn iconSide() f32 {
    return height() - 2 * vertical_padding;
}

/// Bar height: what the font needs plus padding. Recomputed every frame, so changing the font
/// size in settings resizes the bar on the next one.
pub fn height() f32 {
    return @max(min_height, @round(font().lineHeight() + 2 * vertical_padding));
}
