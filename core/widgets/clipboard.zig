//! Whether dvui's Paste can bring in the clipboard's text. Off the web the backend reads it
//! when asked; on the web only a secure page (or its worker) can read it, and then later, as a
//! text event (`WebBackend.clipboardText`).
const builtin = @import("builtin");

const is_wasm = builtin.target.cpu.arch == .wasm32;

const web = struct {
    extern "fizzy" fn fizzy_clipboard_can_read() bool;
};

/// True when a Paste can read the clipboard here: always off the web, and on the web while the
/// page is a secure context with a clipboard.
pub fn canPaste() bool {
    if (is_wasm) return web.fizzy_clipboard_can_read();
    return true;
}
