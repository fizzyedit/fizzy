# Linux desktop-integration assets

`com.foxnne.fizzy.desktop` and `com.foxnne.fizzy.xml` are **not** wired into
the automated AppImage build yet. `vpk pack` (Velopack) generates its own
minimal `.desktop` entry inside the AppImage from `--packTitle`/`--icon`/
`--categories` (see `build/package.zig`'s Linux branch), but the `vpk pack`
CLI has no flag for `MimeType=` or custom mime-info, so that generated entry
never declares any file associations — there is currently no way to make
fizzy a MIME-registered "Open With" candidate purely through the release
pipeline.

These two files exist so a user (or a future packaging step) can wire up
real file-association support manually:

- `com.foxnne.fizzy.desktop` — a proper desktop entry with `MimeType=`
  covering plain text / generic binary / images, plus fizzy's own
  `application/x-fizzy` / `application/x-pixi` types.
- `com.foxnne.fizzy.xml` — a [shared-mime-info](https://gitlab.freedesktop.org/xdg/shared-mime-info)
  package declaring `*.fiz` / `*.pixi` globs for those two custom types
  (without this, `.fiz`/`.pixi` files — which are zip archives on disk —
  get sniffed as `application/zip` and offered to archive managers instead
  of fizzy).

## Manual install (per-user, no root)

```sh
xdg-mime install --mode user assets/linux/com.foxnne.fizzy.xml
desktop-file-install --dir="$HOME/.local/share/applications" assets/linux/com.foxnne.fizzy.desktop
update-desktop-database "$HOME/.local/share/applications"
update-mime-database "$HOME/.local/share/mime"
```

After that, fizzy appears in the "Open With" list for any file (via the
broad `text/plain` / `application/octet-stream` `MimeType=` entries) in
GNOME Files, Dolphin, Thunar, etc., and the user can pick "Set as default"
per file type themselves — no in-app action needed. To set a default
non-interactively instead: `xdg-mime default com.foxnne.fizzy.desktop <mimetype>`
(find a file's mimetype with `xdg-mime query filetype <path>`).

## Follow-up (not done here)

Bundling these into the AppImage itself — so this works out of the box
without a manual step — needs a post-`vpk pack` build step that patches the
AppImage's embedded `.desktop` (or repacks it) since `vpk` doesn't expose
the hooks directly. That's a real Linux-toolchain change (mksquashfs
extraction/repack) that needs testing on an actual Linux runner, so it's
left as follow-up rather than guessed at here.
