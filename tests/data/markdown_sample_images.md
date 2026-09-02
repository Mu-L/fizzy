# Image-heavy preview fixture

This document exists for the markdown preview's stability tests. Every other sample in the suite
is a repo doc made of prose and tables, so until this file existed not one test had ever laid out
an image block. Images are the case most likely to move under a resize: nothing in the source says
how tall one is, the estimator has to guess a flat value for them, and the height they actually
occupy is a function of the pane width right up until the pane is wider than the image.

Keep the images pointing at files that really exist in the repo, and keep the document long enough
that it clears the length preconditions the shared stability tests apply to every sample.

## Sizing is a function of width

A square image is the cleanest way to see this. At any pane wider than the display ceiling the image lands at its ceiling height and stops changing. Narrow the pane past that point and the image scales down with it, losing height on every frame of the drag.

![The fizzy fox](../../assets/fox.png)

A square image is the cleanest way to see this. At any pane wider than the display ceiling the image lands at its ceiling height and stops changing. Narrow the pane past that point and the image scales down with it, losing height on every frame of the drag. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

## Why images are the hard case

A table's height is unstable because its cells re-wrap and because row culling makes it depend on where the reader is scrolled. An image has no such excuse: its height is a pure function of the width it is given and the natural size of the file behind it.

![The fizzy icon](../../assets/icon.png)

A table's height is unstable because its cells re-wrap and because row culling makes it depend on where the reader is scrolled. An image has no such excuse: its height is a pure function of the width it is given and the natural size of the file behind it. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

- A list item, because lists estimate differently from paragraphs.
- A second item, longer than the first, so that the block wraps at the narrow widths.
- A third item, with `inline code` in it.

## Estimates cannot help here

Nothing in the source of an image block says how tall it will be. The estimator has to fall back on a flat guess for the kind, which is right for no particular image and wrong for all of them until the block has actually been laid out once.

![The fox on a background](../../assets/fox_bg.png)

Nothing in the source of an image block says how tall it will be. The estimator has to fall back on a flat guess for the kind, which is right for no particular image and wrong for all of them until the block has actually been laid out once. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

## The block below is the one that moves

A block that changes height does not disturb itself; it disturbs everything after it. The reader parked three screens further down is the one who notices, which is why the anchor is keyed to source position rather than to a pixel offset.

![The fizzy fox](../../assets/fox.png)

A block that changes height does not disturb itself; it disturbs everything after it. The reader parked three screens further down is the one who notices, which is why the anchor is keyed to source position rather than to a pixel offset. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

> A block quote, for a block kind that is neither prose nor image.
> It runs to a second line so that it wraps like a real one.

## Loading is synchronous for local files

A file on disk is read and decoded during layout, so a local image has its real size from the first frame it is drawn. Only network images go through a placeholder, and the placeholder has a stable height of its own.

![The fizzy icon](../../assets/icon.png)

A file on disk is read and decoded during layout, so a local image has its real size from the first frame it is drawn. Only network images go through a placeholder, and the placeholder has a stable height of its own. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

## Ceilings and natural size

An image is drawn at its natural size until either the column or the display ceiling becomes the binding constraint. Which of the two binds first depends on the aspect ratio, so a tall image and a wide one respond differently to the same drag.

![The fox on a background](../../assets/fox_bg.png)

An image is drawn at its natural size until either the column or the display ceiling becomes the binding constraint. Which of the two binds first depends on the aspect ratio, so a tall image and a wide one respond differently to the same drag. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

- A list item, because lists estimate differently from paragraphs.
- A second item, longer than the first, so that the block wraps at the narrow widths.
- A third item, with `inline code` in it.

## Repetition is not an accident

Heights are cached by the hash of a block's source text, and two blocks with identical source hash to the same value. Documents repeat themselves constantly, so the disambiguation by nearest source line is load-bearing rather than defensive.

![The fizzy fox](../../assets/fox.png)

Heights are cached by the hash of a block's source text, and two blocks with identical source hash to the same value. Documents repeat themselves constantly, so the disambiguation by nearest source line is load-bearing rather than defensive. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

## Prose between the pictures

Enough ordinary text has to sit between the image blocks that the reader can park somewhere that is not itself an image, because that is where a reader usually is and it is the position most worth keeping still.

![The fizzy icon](../../assets/icon.png)

Enough ordinary text has to sit between the image blocks that the reader can park somewhere that is not itself an image, because that is where a reader usually is and it is the position most worth keeping still. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

> A block quote, for a block kind that is neither prose nor image.
> It runs to a second line so that it wraps like a real one.

## Re-measuring costs frames

Off-screen blocks are re-measured on a per-frame budget rather than all at once, so a document does not stall when its width changes. An image above the reader legitimately carries its old height for a few frames after a drag ends.

![The fox on a background](../../assets/fox_bg.png)

Off-screen blocks are re-measured on a per-frame budget rather than all at once, so a document does not stall when its width changes. An image above the reader legitimately carries its old height for a few frames after a drag ends. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

## What a settled document owes

Once nothing is asking to be measured, every height in the table has to be one that a real layout produced at the current width. A block still standing on a guess at that point is a block the scrollbar is lying about.

![The fizzy fox](../../assets/fox.png)

Once nothing is asking to be measured, every height in the table has to be one that a real layout produced at the current width. A block still standing on a guess at that point is a block the scrollbar is lying about. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

- A list item, because lists estimate differently from paragraphs.
- A second item, longer than the first, so that the block wraps at the narrow widths.
- A third item, with `inline code` in it.

## Aspect ratios that are not square

A wide image hits the column ceiling long before it hits the height ceiling, and a tall one does the opposite. Keeping both shapes in a fixture is what stops a change from being tuned to one of them.

![The fizzy icon](../../assets/icon.png)

A wide image hits the column ceiling long before it hits the height ceiling, and a tall one does the opposite. Keeping both shapes in a fixture is what stops a change from being tuned to one of them. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

## The scrollbar is a sum

Every position in the document is expressed against a total built from the height table, so any correction anywhere silently redefines what a saved offset points at. That is the whole reason the anchor exists.

![The fox on a background](../../assets/fox_bg.png)

Every position in the document is expressed against a total built from the height table, so any correction anywhere silently redefines what a saved offset points at. That is the whole reason the anchor exists. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

> A block quote, for a block kind that is neither prose nor image.
> It runs to a second line so that it wraps like a real one.

## Width changes invalidate

A width change demotes cached heights so they can be relearned, and a pin that outlived the change would hold a block at its pre-resize size for ever. A block that measures exactly its own pin agrees with itself and never reflows again.

![The fizzy fox](../../assets/fox.png)

A width change demotes cached heights so they can be relearned, and a pin that outlived the change would hold a block at its pre-resize size for ever. A block that measures exactly its own pin agrees with itself and never reflows again. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

## Reading order still matters

A fixture that is only stress cases stops resembling a document anyone would open. The ordinary paragraphs here are not filler; they are the material the reader is actually parked in when something jumps.

![The fizzy icon](../../assets/icon.png)

A fixture that is only stress cases stops resembling a document anyone would open. The ordinary paragraphs here are not filler; they are the material the reader is actually parked in when something jumps. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

- A list item, because lists estimate differently from paragraphs.
- A second item, longer than the first, so that the block wraps at the narrow widths.
- A third item, with `inline code` in it.

## Termination is a requirement

A block that keeps asking to be re-measured keeps the application awake. Convergence is not something to hope for, so the number of attempts is capped and a block that will never settle stops asking.

![The fox on a background](../../assets/fox_bg.png)

A block that keeps asking to be re-measured keeps the application awake. Convergence is not something to hope for, so the number of attempts is capped and a block that will never settle stops asking. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

## Closing the loop

What all of this protects is a single property: the thing the reader is looking at stays where it is, whatever the layout has to do behind it to arrive at the right answer.

![The fizzy fox](../../assets/fox.png)

What all of this protects is a single property: the thing the reader is looking at stays where it is, whatever the layout has to do behind it to arrive at the right answer. The point is repeated here in a second paragraph so the section has real length,
wraps at every width the tests exercise, and gives the anchor an ordinary block to hold
rather than only image blocks with dramatic heights.

> A block quote, for a block kind that is neither prose nor image.
> It runs to a second line so that it wraps like a real one.

## Sized images

An image can ask for a size in markup, and what it asks for is resolved against its own intrinsic
size rather than against the pane. That keeps a logo the same fraction of itself as the pane moves,
and it means a sized image should not track the column the way an unsized one does.

<img src="../../assets/fox.png" width="25%" alt="A quarter-size fox">

The two behaviours living side by side in one document is the point. If a resize ever moves a sized
image and an unsized one by the same proportion, something has started resolving the request
against the container again.

## A missing image

![This file is not there](../../assets/definitely-not-a-real-file.png)

A broken reference renders a placeholder, and a placeholder has a height of its own. It should be
stable — there is no file to load, so nothing about it can change after the first frame — which
makes it a useful control: if the broken image moves during a drag, the movement did not come from
image loading.

## Closing prose

The last block should be prose rather than an image, so that scrolling to the very bottom lands
somewhere with an ordinary height. Parking at the end of a document whose final block is still
resolving its size is a different test, and mixing the two would make a failure ambiguous.

One more paragraph so the ending is not abrupt, and so the final screen has something in it at
every width the tests exercise.
