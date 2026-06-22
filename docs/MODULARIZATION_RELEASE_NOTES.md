# **Fizzy** - a modular editor

> I haven't ever really written much about the design of `fizzy`, which started as `pixi`, solely focused on being a fun pixel art editor. Over time, my goals for `fizzy` as a project have evolved. I have always enjoyed making tools, especially tools that allow one to make games easier. I also always wanted what I'm crafting to be of some use to someone else, extendable and customizeable and transformable into whatever tool could benefit someone trying to quickly make something creative, while remaining fun to use and polished.

## Motivation
----

`fizzy` started out with a much smaller scope, providing tools for myself to use to create pixel art for small games for my children and for myself. As the project has continued, I began to ask myself, how can this editor become something beneficial for a *developer*? a *writer*? an *artist*? a *designer*? a *musician*?

I think the answer is to decentralize the editor. To make it a generic shell that anything can fill, and then begin providing filling.

When I set out to begin redesiging the editor to be based upon plugins, I decided that there would be 3 main requirements:

1. I wanted plugins to be able to be written in `Zig` using `DVUI` directly, just like fizzy itself.
2. I wanted plugins to be able to be loaded and unloaded at runtime.
3. I wanted plugins to be able to work together.

To accomplish this, I decided I needed to develop several plugins that exercised these requirements and made sure the library would be able to accomplish these goals.
The three plugins I chose are:

- [pixi](https://github.com/fizzyedit/pixi): all the original pixi functionality: drawing and grid arrangement, sprite packing, and animation management.
    - Adds menu options, multiple explorer views, a bottom panel view with custom rendering, etc.
- [zig](https://github.com/fizzyedit/zig): adds syntax highlighting and ZLS (autocomplete, hover/goTo) to the built-in `text` plugin
    - Example of using builtin LSP client, as well as adding part-functionality alongside another plugin
- [ghostty](https://github.com/fizzyedit/ghostty): adds a `ghostty_vt` driven terminal to the bottom pane
    - Example of providing only a bottom panel, and waking the app reliably from a plugin

These plugins are all fully external to the fizzy project and in their own repositories.

## Design
----

The plugin design in detail, along with a guide to creating a simple plugin, is located in `docs/PLUGINS.md`, which will continue to evolve with fizzy.

To give a general overview:

- Plugins import `fizzy` using the zig package manager (`.zon`) and have a general structure shared amongst plugins. `fizzy` provides helper build functions for quickly setting up `build.zig` for a plugin to produce a compiled `.dll/dynlib/so` that fizzy can load at runtime. 
- These plugins use a `proxy backend` to avoid linking in the SDL3 backend and causing conflicts during linking, and to ensure that the SDL3 context our plugins are sending commands to is the single instance we have in `fizzy`.
- Plugins supply a `vtable` of optional hooks provided by fizzy and/or builtin plugins. Examples of this are document-level hooks provided by the `workbench` builtin plugin (which provides the file explorer, tabs/splits etc), or editor-level hooks like a center provider for the main window pane of the editor. Plugins may choose either, or even just be a utility that claims no files and just adds menu options. 

`fizzy` also is set-up to provide a decentralized "store" for providing these plugins to existing `fizzy` installs.

- [plugins](https://github.com/fizzyedit/plugins)

This is a repository with a small zig project that simply compiles and looks at its catalog, grabs releases of those plugins listed in the repository, and stores them in a SQLite database.
The action that aggregates these releases runs every 6 hours currently, or when a manifest is added.

Plugins themselves are repositories, and the store within fizzy expects each project to have a `README.md` and `ICON.png`, which are loaded from the store tab to display information about the plugin to the user. The store itself expects releases to contain artifacts that match a naming scheme, and we provide a [Github Action](https://github.com/fizzyedit/plugin-build-action) that can handle this automatically for you, or there is an example manifest for what your release needs to contain to be compatible with the store.

When using the action, or building one yourself, the plugin will have to be built for the current 6 targets fizzy supports: macOS, Linux and Windows - both x86_64 and arm64. 

This allows the store to choose the correct plugin build for the current build of fizzy that is running.

#### Note: plugins must be compiled in the same optimize mode as fizzy. fizzy builds and releases in ReleaseFast, so the store expects ReleaseFast. During testing, you can build and use `zig build install` to automatically build and install the plugin to the plugins location. This allows you to build both the editor and plugins in Debug mode during testing.

Once everything is setup for a plugin, releasing a new version can be as simple as updating the version in the projects `.zon` and tagging a release, where the store will then pick it up next time it aggregates.

## A note about the author and a small thanks

I started this project years ago, when I was first learning how to code. Over time, its become something that has taught me a great deal. I have learned so much through the excitement of working on this project, and the design opportunities it has given me, as well as building something that I myself can use to continue to be creative.

I struggle greatly with my mental health, and it is a journey I also began years ago alongside this one, working through diagnoses and medications, therapy and hardships, and all throughout this project has been something that I have returned to. An outlet for creativity and imagination. A place to exercise that incredible feeling of turning idea into code into something useable. 

If you even look at my github activity, you can begin to see cycles of activity and inactivity, points within the year at which my creativity fades, and my ability to focus becomes slim, and things feel altogether much harder to accomplish. Times of depression or severe anxiety, or great fear, become obstacles that prevent the wonderful feeling of creating, the satisfaction of making something.

I make use of Claude/Cursor on this project, increasingly so as of late. This tool has allowed me to express myself creatively, and continue to make, when my mind doesn't allow for it. Especially when my mental health requires more of me.

Thank you to all that have supported my work and fizzy over the years, as I've been able to share it. Thank you to all that have offered help and guidance. Hope it assists your creativity the way it has mine.













