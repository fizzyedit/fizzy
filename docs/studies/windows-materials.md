# Windows window materials, and the fallback ladder

Status: study (L0). Task: fizzyedit/work#513, plans#104 step 6. Nothing in `core/` or `backend/`
changes. The probe is `tools/win_materials_probe.zig` (`zig run tools/win_materials_probe.zig`).

## What was measured, and where

The probe ran on Windows 11 build 26200 (`10.0.26200`), in **session 0 with no input desktop**,
as the worker's service account. Two consequences:

- **No screenshot was taken**, and none was retried. What a material looks like behind a
  transparent fizzy window is therefore taken from Microsoft's documentation and from what
  `backend/src/platform/win32_titlebar.zig` already does; it is marked *unverified* below.
- `DwmIsCompositionEnabled` reported `enabled=0` there, and `DwmExtendFrameIntoClientArea` and
  `DwmEnableBlurBehindWindow` failed with `0x80263001` (`DWM_E_COMPOSITIONDISABLED`). That is the
  session, not the OS: an interactive desktop on this build composes. It is also a finding in its
  own right: **a session without composition accepts the backdrop attribute and shows nothing**.

### Probe output

```
os: 10.0 build 26200
session id: 0; input desktop: none (no screenshot possible)
DwmIsCompositionEnabled: hr=0x00000000 enabled=0
Transparency effects setting: on

DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE = 38), then read back:
  0 DWMSBT_AUTO: set hr=0x00000000, get hr=0x00000000 value=0
  1 DWMSBT_NONE: set hr=0x00000000, get hr=0x00000000 value=1
  2 DWMSBT_MAINWINDOW (Mica): set hr=0x00000000, get hr=0x00000000 value=2
  3 DWMSBT_TRANSIENTWINDOW (Acrylic): set hr=0x00000000, get hr=0x00000000 value=3
  4 DWMSBT_TABBEDWINDOW (Mica Alt): set hr=0x00000000, get hr=0x00000000 value=4
  5 out of range (control): set hr=0x00000000, get hr=0x00000000 value=5

DwmSetWindowAttribute with a plausible value (hr only):
  17 DWMWA_USE_HOSTBACKDROPBRUSH: hr=0x00000000
  20 DWMWA_USE_IMMERSIVE_DARK_MODE: hr=0x00000000
  33 DWMWA_WINDOW_CORNER_PREFERENCE: hr=0x00000000
  34 DWMWA_BORDER_COLOR: hr=0x00000000
  35 DWMWA_CAPTION_COLOR: hr=0x00000000
  38 DWMWA_SYSTEMBACKDROP_TYPE: hr=0x00000000
  1029 undocumented MICA_EFFECT (pre-22621 Mica): hr=0x80070057

DwmExtendFrameIntoClientArea(-1 margins): hr=0x80263001
DwmEnableBlurBehindWindow(enable): hr=0x80263001

SetWindowCompositionAttribute (WCA_ACCENT_POLICY = 19):
  0 ACCENT_DISABLED: returned 1
  1 ACCENT_ENABLE_GRADIENT: returned 1
  2 ACCENT_ENABLE_TRANSPARENTGRADIENT: returned 1
  3 ACCENT_ENABLE_BLURBEHIND: returned 1
  4 ACCENT_ENABLE_ACRYLICBLURBEHIND: returned 1
  5 ACCENT_ENABLE_HOSTBACKDROP: returned 1
```

### What the output teaches

1. **Success proves nothing about support.** The out-of-range control (`5`) was accepted and read
   back, and every accent state returned success. DWM stores the number. A HRESULT cannot be the
   probe of "does this box do Acrylic"; the build number, the transparency setting and
   composition must be.
2. **The legacy Mica attribute (1029) is rejected on 26200** (`E_INVALIDARG`, `0x80070057`), as the
   documented attribute replaced it. Do not carry it into fizzy.
3. **Attribute 38 is accepted on build 26200**; its documented floor is 22621 (below).
4. **The accent policy still answers on 26200**, undocumented but present: it is the only
   material call that works below 22621.

## The materials

All backdrop calls take the top-level `HWND`. A material shows only where the window's pixels are
transparent: the client area must be alpha 0 (or the frame extended into it with
`DwmExtendFrameIntoClientArea` margins of -1, which fizzy's `win32_titlebar.zig` already does).
Rows marked *docs* come from Microsoft's documentation for the call; *unverified* means neither
the probe nor a screenshot confirmed it.

| Material | Call to request it | Minimum build | Behind a transparent fizzy window | When missing |
|---|---|---|---|---|
| Mica | `DwmSetWindowAttribute(hwnd, 38, &2, 4)` (`DWMSBT_MAINWINDOW`) | 22621 (Win11 22H2), docs | Opaque-ish wallpaper-tinted slab that does not blur what is under the window; falls to a solid fallback colour when the window is inactive or transparency is off (docs). Very quiet: fizzy's rim and light read on it. *Unverified here.* | Rung 4 (below): accent blur, or opaque fizzy body |
| Mica Alt (Tabbed) | `DwmSetWindowAttribute(hwnd, 38, &4, 4)` (`DWMSBT_TABBEDWINDOW`) | 22621, docs | Like Mica with a stronger tint, meant for a tab strip. *Unverified here.* | As Mica |
| Acrylic (transient) | `DwmSetWindowAttribute(hwnd, 38, &3, 4)` (`DWMSBT_TRANSIENTWINDOW`) | 22621, docs | Live blur of what is behind the window, with noise and tint. fizzy uses this today (`win32_titlebar.zig`). *Unverified here.* | Rung 2: accent acrylic |
| Auto / none | `38` with `0` / `1` | 22621, docs | `0` lets DWM choose; `1` removes the material, so the body is the window's own pixels. | n/a |
| Accent acrylic (legacy) | `SetWindowCompositionAttribute(hwnd, {19, ACCENT_POLICY{4, flags, ABGR tint, 0}})`, found with `GetProcAddress` on `user32` | 17134 (Win10 1803), community-documented | Blur plus tint. Known to lag while the window is dragged or resized on some Win10 builds (1903); *unverified here*. | Rung 3: accent blur |
| Accent blur-behind (legacy) | same call, state `3` (`ACCENT_ENABLE_BLURBEHIND`) | Win10 (10240), community-documented | Plain blur, no noise; tint comes from the client area. *Unverified here.* | Rung 5: opaque |
| Aero blur-behind | `DwmEnableBlurBehindWindow(hwnd, BlurBehind{.flags = 1, .enable = 1})` | Vista, docs | On Windows 8 and later it does not produce the old Aero glass; treat it as unavailable. *Unverified here.* | Rung 5 |
| Mica before 22621 | undocumented attribute `1029` | 22000 (Win11 21H2), community-documented | Rejected on 26200 by the probe. | Rung 5 |

Related attributes (all accepted by the probe on 26200): `DWMWA_USE_IMMERSIVE_DARK_MODE` (20)
picks the dark or light variant of the material; fizzy already drives it from the theme.
`DWMWA_WINDOW_CORNER_PREFERENCE` (33), `DWMWA_BORDER_COLOR` (34) and `DWMWA_CAPTION_COLOR` (35)
decide the OS rim and caption (build 22000 and later, docs).

## Keeping fizzy's rim and light over the OS body

The design in plans `design/materials.md` has the OS draw the *body* and fizzy draw the *rim and
light*. Constraints this study found:

- The OS body is behind the whole client area, so fizzy's own glass pieces (edge highlight,
  specular, shadow) stay in its renderer and draw over transparent pixels. Nothing needs the
  material to be anything but a backdrop.
- **The OS rim (`DWMWA_BORDER_COLOR`) should be turned off** (`DWMWA_COLOR_NONE`, which
  `win32_titlebar.zig` already uses on its borderless path) so two rims do not stack.
- The body **changes when the window loses focus** (Mica, and to a lesser degree Acrylic), so fizzy
  must not compute its light from the body's colour: derive it from the theme and re-apply the
  backdrop attribute on activate, as `win32MicaSubclassProc` already does.
- Without composition or with transparency effects off, DWM paints the fallback colour. Fizzy's
  rim and light still work over it; the window just looks flat.

## The fallback ladder

Pick the first rung whose test passes, and re-test when the user toggles transparency or the
session changes. Detect by **build number, `EnableTransparency` and composition**, never by the
return value of the call (finding 1).

| Rung | Test | Material |
|---|---|---|
| 1 | build >= 22621, composition on, transparency on | `DWMSBT` Acrylic (or Mica for quiet surfaces) |
| 2 | build >= 17134, composition on, transparency on | Accent acrylic (`state 4`) |
| 3 | build >= 10240, composition on | Accent blur-behind (`state 3`) |
| 4 | any build with composition on, no usable blur | Fizzy's own translucent tinted panel (no OS blur) |
| 5 | composition off, transparency off, battery saver, remote session | Opaque fizzy body in the theme colour |

Transparency effects are read from
`HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\EnableTransparency`
(the probe reads it: `on`). Registry change notification, or `WM_SETTINGCHANGE` with
`"ImmersiveColorSet"`, is the seam for re-testing; neither was exercised here.

## Unverified

- Every look in the table (nothing was rendered; no input desktop).
- Behaviour on builds other than 26200: the probe ran on one box. Minimum builds are from
  documentation and community sources, not from this study.
- Whether an out-of-range or unsupported `38` value errors on older builds (only 26200 ran; the
  `1029` rejection suggests unknown attributes error, which is an inference).
- Accent-policy lag while dragging or resizing, and whether it affects fizzy's frame loop.
- Whether the backdrop survives a DXGI flip-model swapchain with premultiplied alpha, and the
  cost of that path against the opaque one.
- Battery saver, RDP and High Contrast fallbacks.
- That `DwmExtendFrameIntoClientArea` and blur-behind succeed on an interactive desktop (they
  returned `DWM_E_COMPOSITIONDISABLED` here).

Next: re-run the probe on an interactive desktop and attach a screenshot per rung; plans#69
step 8 (work#214) puts the probe in the app.
