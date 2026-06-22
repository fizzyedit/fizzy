
<p align="center">
  <img width="20%" src="assets/icon.png" alt="Fizzy logo">
</p>

![buildworkflow](https://github.com/fizzyedit/fizzy/actions/workflows/ci.yml/badge.svg)

# 
**Fizzy** is a cross-platform open-source modular general editor written in [Zig](https://github.com/ziglang/zig).

### Try it in your browser [here](https://fizzyed.it/app/)

### Downloads are available [here](https://fizzyed.it)

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/R5R4LL2PJ)

Fizzy is an empty modular editor shell, which dynamically loads and unloads compiled plugins to provide editor functionality. It includes a store where plugins can be published as well as a store tab to browse and install these plugins.

Fizzy offers a SDK for developing plugins and several plugins already exist that can be installed, which are part of the fizzyedit org. These plugins will always be primary to the development of fizzy and used to exercise the plugin SDK and abilities of the editor.

- [pixi](https://github.com/fizzyedit/pixi) - Pixel art editor. Provides a grid structure for editing and creating animation frames, making use of Lospec palettes, and packing sprites into an atlas. This plugin uses its own workflow, and draws its cursors using its atlas. 
- [zig](https://github.com/fizzyedit/zig) - Zig language plugin, providing syntax highlighting and ZLS functionality (if compatible ZLS is in PATH) (hover/goto definition/signature help). The builtin `text` plugin is what this works alongside
- [ghostty](https://github.com/fizzyedit/ghostty) - Plugin adding only a bottom panel, which uses `ghostty_vt` to provide a cross-platform terminal.

By default, when you install fizzy, only builtin plugins are included. This gives you the ability to edit markdown and regular text files. Markdown is included only to render plugin README.md files in the store, though it can be used generally. 

## User Interface
- The user interface is driven by [DVUI](https://github.com/david-vanderson/dvui).
- The general layout takes many ideas from VSCode or IDE's, as well as general project setup using folders.

## Compilation
- [Linux] Ensure `gtk+3-devel` or similar is installed (for native file dialogs).
- Install zig 0.16.0.
- Clone fizzy.
- Build.
    - ```git clone https://github.com/fizzyedit/fizzy.git```
    - ```cd fizzy```
    - ```zig build run```

## Credits
- [David Vanderson](https://github.com/david-vanderson) for all the help and [DVUI](https://github.com/david-vanderson/dvui).
- [emidoots](https://github.com/emidoots) for all the help and [mach](https://github.com/hexops/mach).
- [michal-z](https://github.com/michal-z) for all the help and [zig-gamedev](https://github.com/michal-z/zig-gamedev).
- [prime31](https://github.com/prime31) for all the help.
- Any and all contributors


     
