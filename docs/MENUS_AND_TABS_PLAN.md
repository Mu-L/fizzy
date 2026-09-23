# Context menus and preview tabs

Two features that turn out to be one change, because they want the same thing: a menu
surface anyone can open, that plugins can add to, that looks the same everywhere, and that
a plugin can decline.

Agreed 2026-09-23. This is the plan; the code follows it in the stages at the bottom.

## What is wrong now

**Three menu surfaces that resemble each other.** `dvui.floatingMenu` (the file tree's row
menus, `DockingWidget`), `core.widgets.Popover` (the store's card flyout, the account list),
and fizzy's own copied menu chain in `core/widgets/menu/` (the menu bar). They have
different fills, different corners, different hover treatments, and three separate answers
to "what closes this". A fourth is one right-click away from being written.

**Nothing to right-click.** Tabs have no menu at all, so "keep this tab", "close the others"
and "close everything to the right" have nowhere to live. The text editor has no menu.
Store pages grew a bespoke "Keep Page Open" row in the store's own flyout because there was
no tab menu to put it in — the wrong place, and the reason this plan exists.

**No preview tabs.** Every open leaves a tab behind. Clicking down a list of files, or a
list of plugins, buries the thing you were doing under a row of tabs you did not ask for.
The store worked around it privately (its pages replace each other), which is the right
behaviour implemented in the wrong layer: it should be fizzy's, and it should apply to every
document.

## The shape

### 1. One surface: `core.widgets.ContextMenu`

One implementation of "a floating list of rows you can click", built on the surface
vocabulary already in `core.dialogs` (frost, `surface_corners`, `surfaceShadow`,
`rowHover`), which is what the command palette and every dialog use. Submenus, separators,
disabled rows, keybind hints on the right, and one rule for dismissal: a press outside every
level closes the chain.

Every menu in the app is then this: the file tree's, the tab strip's, the docking widget's,
the store's flyout, the account list, the text editor's. The menu *bar* keeps its own chain
(a menubar row is a different thing from a context-menu row) but draws its dropdown from the
same surface, as it does today.

### 2. A context menu is a menu with an id

Plugins already contribute to menus by id:

```zig
host.registerMenuSection(.{ .id = "drive.menu.file_section",
                            .parent_menu_id = "fizzy.menu.file", … });
```

Context menus reuse exactly that. Fizzy defines the ids and opens them:

| id | opened by |
|---|---|
| `fizzy.menu.tab` | right-click on a tab |
| `fizzy.menu.filetree.file` | right-click on a file row |
| `fizzy.menu.filetree.folder` | right-click on a folder row |
| `fizzy.menu.filetree.root` | right-click on the project row or blank space |
| `<plugin>.menu.document` | right-click inside a document, *if its owner names one* |

So a plugin adds "Reveal in Finder" to the file tree, or "Open Drive Folder" to the tab
menu, with the call it already knows, and fizzy's own items and the plugins' sit in one
menu rather than two competing ones.

**What the menu is about** is the missing half: a section drawing into
`fizzy.menu.filetree.file` needs to know *which* file. That is one new accessor, valid only
during a context-menu draw:

```zig
pub const MenuContext = struct {
    menu_id: []const u8,
    subject: Subject = .none,

    pub const Subject = union(enum) {
        none,
        path: []const u8,                                    // a tree row, the project root
        document: struct { id: u64, path: []const u8, grouping: u64 },  // a tab, a document pane
    };
    pub fn path(self: MenuContext) ?[]const u8;
};
pub fn menuContext(self: *Host) ?MenuContext;
pub fn drawMenuSections(self: *Host, ctx: MenuContext) void;
```

A union over the *subject*, not the fields: they are not exclusive (an open document always has
a path and a pane) but not independent either (a tree row has only a path), and a flat struct
with `0` / `""` for "absent" let a plugin check one sentinel and forget the other.

The context lives on the Host, set by `drawMenuSections` while contributed rows draw — not in the
app — because the workbench opens the tab and tree menus and is a plugin with no reach into app
globals.

### 3. A plugin can decline

Pixi uses right-click for the colour dropper; a context menu inside its canvas would be a
bug, not a feature. So fizzy never opens a menu inside a document on its own — it asks the
owner:

```zig
/// The context menu to open on a right-click inside this document, or null for none.
/// Null is the default: a plugin that says nothing keeps its right-click.
documentContextMenu: ?*const fn (state: *anyopaque, doc: DocHandle) ?[]const u8 = null,
```

The text plugin returns `"text.menu.document"` and registers its own sections into it
(Cut/Copy/Paste, Select All, …). Pixi implements nothing and keeps its dropper. Fizzy's
regions — the tab strip, the tree, the panel — are fizzy's own and always have one.

### 4. Preview tabs

A *preview* tab is VSCode's: opened by a single click, shown in italic, and replaced by the
next preview rather than accumulating. It becomes a real tab — "kept" — when the user edits
it, drags it, or chooses **Keep Open** from the tab menu.

*Not* by double-clicking it, which is where VSCode puts the gesture: fizzy uses double-click
nowhere else, so it would be a thing users have no reason to guess and no way to discover.
Editing covers the case that matters (a tab holding your typing is never replaced), and the
menu covers the deliberate one.

State lives with the app, which owns open documents: at most one preview per grouping, so a
split can hold a preview on each side. The tab strip reads it to draw italic; the document
loader sets it; `isDirty` promotes it.

```zig
/// How an open should land.
pub const OpenMode = enum { preview, keep };

pub const OpenOptions = struct {
    path: []const u8,
    /// 0 is the pane the user is in.
    grouping: u64 = 0,
    mode: OpenMode = .keep,
};
pub fn openFile(self: *Host, opts: OpenOptions) !bool;

pub fn documentIsPreview(self: *Host, doc_id: u64) bool;
/// Promote (or demote) a document. Editing promotes on its own; this is the explicit one.
pub fn setDocumentPreview(self: *Host, doc_id: u64, preview: bool) void;
```

`openFile` replaces `openFilePath` rather than joining it: two calls that open a file, one of
which cannot express half the question, is how the grouping bug in
`setDocumentGroupingOnBuffer` happened.

### 5. What moves

- The store's private "temporary page" logic is deleted: a page opens with `.mode = .preview`
  like anything else, and **Keep Page Open** leaves the store's flyout for the tab menu,
  where it is **Keep Open** and works for every document.
- The file tree opens with `.mode = .preview` on a single click.
- The workbench's tab strip gains its menu: Keep Open, Close, Close Others, Close to the
  Right, Close to the Left.

## The ABI bump

All of it is one `recorded_sdk_shape_fingerprint` move, so it goes in one release:
`MenuContext` + `menuContext()`, `OpenOptions`/`OpenMode` + `openFile()` (replacing
`openFilePath`), `documentIsPreview`/`setDocumentPreview`, and the `documentContextMenu`
vtable hook. SDK **0.2.1**, then repin and re-release drive, atlas, zig, ghostty and pixi.

Batched deliberately: every plugin pays for a fingerprint move, so the cost is worth paying
once for a considered surface rather than three times for whatever was urgent.

## Stages

1. **`core.widgets.ContextMenu`** — the one surface, and every existing caller moved onto it.
   No ABI, no behaviour change; the menus just stop disagreeing about what they look like.
2. **The SDK surface** — the additions above, the fingerprint bump, `sdk_version` to 0.2.1.
   Nothing uses them yet.
3. **Preview tabs** — app state, the loader, promote-on-edit, italic in the tab strip.
4. **Menus everywhere** — the tab menu (with Keep Open), the tree menus rebuilt on the
   contribution points, the text plugin's own.
5. **Release** — SDK 0.2.1, then repin and re-release the five plugins.

Stage 1 is worth doing whatever happens to the rest: it is the part that makes every menu in
the app read as one thing.
