# Windows resource assets

`fizzy.rc` is compiled by Zig's resource compiler and linked into `fizzy.exe`
for `*-windows-*` targets. It references `fizzy.ico` in this directory.

## fizzy.ico

A multi-resolution Windows icon. Include at least the 16, 32, 48, and 256 px
frames so Explorer / Taskbar / Alt-Tab pick the right size at every shell
density. PNG-compressed frames are fine.

The same `.ico` is passed to `vpk pack --icon` so the Velopack installer and
generated Start Menu shortcut use it too.

If you replace it, keep the filename — `fizzy.rc` and `build.zig` reference
this exact path.
