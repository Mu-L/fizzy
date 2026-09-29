# Splitting and moving views

What a user can do to the arrangement of an app's window at runtime, and the rules the
framework holds to while they do it. This is the contract: an app that declares regions gets
all of it without writing any of it, and a plugin that draws a surface never participates.

## Vocabulary

| Term | Meaning |
|---|---|
| **place** | A named area. Either declared by the shape (`Main`, `Panel`) or minted by a split (`Main/r1`). |
| **view** | The surface a place is currently showing. A place with tabs has one view and several surfaces. |
| **assignment** | The user's answer to "what goes here", per place. Overrides keyword matching. An empty assignment is an answer too: *nothing*, deliberately. |
| **origin** | The place that was split. Keeps its name, keywords and assignment. |
| **minted leaf** | The place a split creates. Empty, removable, and gone again when it collapses. |

Places, keywords and assignments are framework. `Main`, `Sidebar` and `Panel` are fizzy's own
shape (`src/editor/layout.zig`) and mean nothing here.

## The one rule

> **The edge you release on is where the dragged view ends up.**

Everything else follows from that sentence, including the case that is easy to get backwards.

| Release | Origin ends up | Minted leaf opens | The leaf holds |
|---|---|---|---|
| Middle of a *slot* (shows one) | the dest's view | — | the dragged view *(they trade)* |
| Middle of a *shelf* (shows many) | nothing back | — | the dragged view, added *(the rest stay)* |
| Middle of the *other half of its split*, carrying its last view | — | — | *(they join: one place, both views, as tabs)* |
| Edge of another place | untouched | that edge | the dragged view |
| Edge of its own place | that edge | the **opposite** edge | empty |
| Middle of its own place | — | — | *(nothing happens)* |

The join row is the undo of a split, reached the same way the split was: by carrying a view.
Only the two halves of one split join, and only when the view is the last one its place holds —
carried out of a place that keeps others it is just moving, and the middle means what it means
anywhere else. The split's origin is the half that stays, whichever way the drag went, since the
half a split minted is the one the tree can drop; it shows both views as tabs, because it now
holds two. Two places the shape declared are never a pair: neither may go.

The own-edge row is the one worth stating out loud. Dropping a view on its own right edge splits
that place and the view must finish on the right — so the *empty* leaf is what opens on the
left. Minting on the right instead would push the view to the left and the split would feel
mirrored.

A self-split also may not move the view onto the new leaf, even though that would put it on
the correct side. Remounting a surface into a fresh place tears down every widget inside it;
fizzy's Workspace would lose its open documents. The origin keeps the view, and the mint side
is what puts it under the pointer.

This table is `Drop.plan`, and it is about forty lines with no drawing and no state in it. The
drop zones and the release both read the same geometry (`Drop.kindAt` over
`core.widgets.DropZones`), which is the reason they cannot disagree.

## Feedback while dragging

A drag is a question ("where does this go?"). The answer is shown as the options, all at once,
and the view you are carrying — never as the view drawn in two places.

- **The app under a drag does not change.** The dragged surface is photographed once, at lift,
  from the draw its place was doing anyway (never a second `drawContents` in the same frame: that
  builds every widget under the place twice, and dvui reports a duplicate id for each of them),
  and a card of it rides the pointer. The place goes on drawing its view underneath: the drop
  zones are what changes, over a window that stays put.
- **The place under the pointer shows its drop zones.** All five of them — the middle and each
  edge — at once, and only there: moving to another place, its zones go as the new place's come
  in, so the one change on screen follows the pointer instead of covering the window in targets.
  They are the dialogs' frosted glass, the app's surface rounding, an even gap around each, and a
  faint icon saying what a drop there does: a pane opening on that side, or the middle's trade
  (one view), add (several) or join (the other half of a split). The one under the pointer
  lights. The middle of the place the view came from is bare glass: dropping
  there does nothing.
- **A join shows the place it leaves.** Aimed at, the two halves' zones step back and one lit
  pane of the same glass lies across both — the single place the drop will make, the divider
  between them gone under it.
- **Nothing is previewed in place.** No place poses the view as if it had landed, and none pulls
  back to make room: one copy of a view is easier to read than two, and the layout that answers
  the drop moves after it, with the easing every split and swap already has.
- **The zones are liquid glass.** An edge zone grows in out of its edge and the middle out of its
  centre, on a bounce, while the frost comes in ahead of the size; its icon arrives once the glass
  is mostly there. The glass is a mesh over one blur of the place, so it bends what it shows: a
  lens band at the rim, and a damped ripple running in from where the zone grew, and out from the
  pointer when a zone lights. Going, the same curve backwards, quicker. Never by opacity: a frost
  replaces what it covers, and a half-opaque one would show a see-through window's content
  through it.
- **A drag does not change the map it is read against.** The places, and where they are, are
  photographed at lift, exactly like the view is. A place can still move during a drag — a split
  easing shut, a window resized — and a hit-test read against the live layout would chase it.
  Frozen, it is a pure function of where the pointer is.

## Where the view goes when a place is split

Whoever already holds the view keeps it, and the *empty* place is what moves out of the way.
This holds for both entry points:

- **Picker → Split → Vertical / Horizontal.** The existing view stays; an empty leaf opens
  beside it. The names describe the divider, not the layout axis — "Vertical" is a vertical
  bar, so the two panes sit side by side.
- **Drag onto an edge.** As the table above.

The rule keeps a split feeling like a division of something that already exists, rather than
a replacement of it by two new things.

A split lands as even halves with the sash out of the middle, measured from the place as it
stood when the drag began — the place the user was shown.

## A place a split made shuts when its last view leaves

Carry the last view out of a minted leaf and the leaf slides shut, its neighbour taking the
room back. The shape's own places do not: Main with nothing in it is still where Main is, and
a user who empties one expects to put something back. A minted leaf is not furniture — it was
a container for the view that has just been carried out of it, and leaving a blank rectangle
behind makes the user tidy up after their own drag.

The leaf a split *mints* is the exception, and is not the same case: it is empty because it is
the room being made, not room left over.

A place closing for good reaches nothing, not nearly nothing. Its card's inset folds away with
the last of its extent and the sash beside it closes with it, so the frame the leaf is finally
dropped moves nothing at all. Left whole, the two of them are some twenty-odd points that a
smooth close hands back in one step at the very end — which is the only part of it anyone sees.
A place merely *shut* keeps its sash: that is the handle you drag it back out by.

## Edges and bands

Near an edge is 64pt, or 22% of that side, whichever is smaller (`DropZones.band`). The
fraction is what keeps a small pane usable: a fixed band on a 100pt place would leave no middle to aim at, and
swapping would be unreachable exactly where precision is hardest.

The place under the pointer is the *smallest* one containing it, so a document pane wins over
the main area it sits in. The one exception is the drag's own place: its edges outrank
anything nested inside, or a document filling it would make its edges unreachable.

A place only accepts what it can show. A shape place takes anything the user puts there; a
plugin's kind slot (a document pane) accepts only surfaces matching its keywords, so dropping
a log on the canvas lands on the main area instead of becoming a document tab.

## Removing a split

Carry the last view of one half onto the middle of the other (a join, above), carry it anywhere
else out of a minted half, or pick Remove. A minted leaf can be emptied and removed; a
shape-declared place can only be emptied. Removing
the last leaf collapses the branch and the origin becomes a whole place again, with its extent
and assignment untouched throughout — a split and its undo are symmetric.

## Where this lives

| File | Holds |
|---|---|
| `Drop.zig` | The rule. No drawing, no state, no allocator. |
| `ViewDrag.zig` | The gesture: drag state, hit-testing, the card, the drop zones over every place, and the assignment that lands. |
| `SplitTree.zig` | The tree: split, collapse, persistence links. Geometry-free. |
| `Region.zig` | Declaring a place and walking the tree to draw its leaves. |
| `Picker.zig` | The menu on a place: assign, clear, remove, split. |

## Settled, and not to be re-litigated

Each of these was built and removed. The reasoning is the expensive part.

- **A facing edge is not a swap.** Treating the edge two places share as a swap gave the same
  gesture two meanings depending on neighbours the user cannot see. Every edge splits.
- **No four create-handles.** Permanent handles on a place's edges are chrome for a gesture
  that is already available by dragging.
- **No `reuse_parent` / `initInParent`.** Packing the leftover's contents into the split's
  grouping box put the sash on the wrong side and made it drag the opposite pane.
- **A leftover origin does not re-qualify its keywords.** It sits inside a grouping box whose
  prefix is its own word; qualifying again produced `main.main`, the grouping box kept the
  exact claim, and both sides of a split drew empty.
- **The dragged snapshot is never the destination's only content.** A swap must lay out the
  real view; blitting the card into the destination looked right for one frame and was wrong
  the moment anything resized.
