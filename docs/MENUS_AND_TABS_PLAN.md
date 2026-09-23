# Context menus and preview tabs

Two features that are one change, because they want the same thing: a menu anyone can open,
that plugins can add to, that looks the same everywhere, and that a plugin can decline.

Stages 1–4 are in; stage 5 (the release) is what remains. The contract for plugin authors is
in `docs/PLUGINS.md` §3.4.1–3.4.2; this file is the design and its reasons.

## 1. One menu row, one menu surface

Every menu in the app is fizzy's menu chain (`core/widgets/menu/`) drawing
`core.widgets.menuRow` rows:

- `core.widgets.contextMenu(src, at, opts)` — a floating menu at a point, on the surface
  vocabulary in `core.dialogs` (frost, `surface_corners`, `surfaceShadow`), with the `.popup`
  dismissal every floating menu shares: a press outside every level closes the chain.
- `core.widgets.menuRow(src, label, opts)` — the macOS row: an icon column, the label, and the
  shortcut right-aligned in its own column (`draw.labelWithKeybind`, drawn by `core.keycaps`).
  `.submenu = true` adds the chevron. The menu bar, the tree, the tab strip, plugin sections
  (`Host.drawMenuItem`) and the account flyout all draw this row.
- `core.widgets.textEntryMenu(te)` — Copy/Paste on any text field.

## 2. A context menu is a menu with an id

Plugins contribute to menus by id with `host.registerMenuSection`. Context menus reuse exactly
that; fizzy defines the ids and opens them:

| id | opened by |
|---|---|
| `fizzy.menu.tab` | right-click on a tab |
| `fizzy.menu.filetree.file` | right-click on a file row |
| `fizzy.menu.filetree.folder` | right-click on a folder row |
| `fizzy.menu.filetree.root` | right-click on the project row or blank space |
| `<plugin>.menu.document` | right-click inside a document, *if its owner names one* |

A section needs to know what the menu is about:

```zig
pub const MenuContext = struct {
    menu_id: []const u8,
    subject: Subject = .none,

    pub const Subject = union(enum) {
        none,
        path: []const u8,                                   // a tree row, the project root
        document: Document,                                 // a tab, a document pane
        pub const Document = struct { id: u64, path: []const u8, grouping: u64 };
    };
    pub fn path(self: MenuContext) ?[]const u8;
};
pub fn menuContext(self: *Host) ?MenuContext;
pub fn drawMenuSections(self: *Host, ctx: MenuContext, after_rows: bool) void;
```

A union over the *subject*: an open document always has a path and a pane, a tree row has only
a path, and a flat struct with `0` / `""` for "absent" lets a plugin check one sentinel and
forget the other.

The context lives on the Host, set by `drawMenuSections` while contributed rows draw, because
the workbench opens the tab and tree menus and is a plugin with no reach into app globals.

## 3. A plugin can decline

Pixi uses right-click for the colour dropper, so fizzy never opens a menu inside a document on
its own — it asks the owner (`Plugin.VTable.documentContextMenu`, default null = no menu). The
text plugin returns `"text.menu.document"` and fills it with its own sections.

## 4. Preview tabs

A preview tab is opened by a single click, shown in italic, and replaced by the next preview in
its pane. It is kept when the user edits it, drags it, or chooses **Keep Open** from the tab
menu. Not by double-click: fizzy uses double-click nowhere else, so users would have no reason
to guess it.

State lives with the app, which owns open documents: at most one preview per grouping.

```zig
pub const OpenMode = enum { keep, preview };
pub const OpenOptions = struct { path: []const u8, grouping: u64 = 0, mode: OpenMode = .keep };
pub fn openFile(self: *Host, opts: OpenOptions) !bool;
pub fn documentIsPreview(self: *Host, doc_id: u64) bool;
pub fn setDocumentPreview(self: *Host, doc_id: u64, preview: bool) void;
```

Store pages are documents (`app/store/PluginPage.zig`, mount `store://pages`) and open as
previews like any file; their tab title comes from `Plugin.VTable.documentTitle`.

## The ABI bump

One `recorded_sdk_shape_fingerprint` move, SDK **0.2.1**:

- `EditorAPI`: `OpenMode`/`OpenOptions` + `openFile` (replacing `openFilePath`),
  `documentIsPreview`/`setDocumentPreview`, `MenuContext`, `isRemotePath`
- `Host`: `menuContext()`, `drawMenuSections(ctx, after_rows)`
- `Plugin`: `internal`, `VTable.documentTitle`, `VTable.documentContextMenu`
- `Surface.scrolls_itself`; `core.vfs.Fs.remote`

## Stages

1. ~~One menu surface~~ — done.
2. ~~The SDK surface~~ — done.
3. ~~Preview tabs~~ — done.
4. ~~Menus everywhere~~ — done: the tab menu, the tree menus on the contribution points, the
   text plugin's own, Copy/Paste on text fields, keycaps for every shortcut.
5. **Release** — tag `sdk-v0.2.1`, then repin and re-release drive, atlas (switch its scheme
   check to `host.isRemotePath`), zig, ghostty and pixi.
