# Workbench

Built-in [Fizzy](../../../readme.md) plugin. Workbench is the frame every other plugin's content sits inside: it owns the **Files**
sidebar (browsing and opening files from the current folder) and the **workspace** center, the
tabbed/paned area where open documents (from Workbench itself or from any other plugin, like
Pixi) are laid out and switched between.

Workbench has no document type of its own to edit; it contributes navigation and layout so
editor plugins can focus purely on their own document.

| Features | Description |
|---|---|
| Files | a tree view of the open folder for browsing and opening files |
| Workspaces | the tab strip + pane-splitting surface that hosts open documents from any plugin. |
  
