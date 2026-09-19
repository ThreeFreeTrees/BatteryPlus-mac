# spike 008 — stale row highlights in the menu (fixed)

## The report

> "when moving the cursor fastly, some rows get highlighted, but the cursor is not on the row and it is
> still highlighted"

The screenshot showed **two** switch rows lit at once (the cursor was over neither of them).

## Reproduction

The menu is a popup owned by an app that may not be active, so synthetic clicks are unreliable here —
but **cursor warps are not**, and they are enough to reproduce this. `cursorsweep` moves the real cursor
through a list of points (6 ms apart, no dwell):

```sh
# menu placed with: BatteryPlus --demo-menu --demo-plugged --demo-menu-at 900,560 --demo-menu-for 20
cursorsweep 920,430 1000,455 1080,470 … 1090,640     # sweep through the rows
cursorsweep 200,200                                  # park far outside
screencapture -x /tmp/after_sweep.png
```

Before the fix that capture shows `Low Power Mode` **and** `Open at Login` still carrying their hover
pills with the pointer 700 pt away.

**Coordinate trap that cost two false results:** `cursorsweep` and `screencapture` work in the same
space (points at 2× backing scale), but a *crop* passed to a vision tool is in **original pixels**, i.e.
2× the point coordinates the cursor uses. Sweeping at half the right x/y never touched the menu, and
"no stale highlight" then means nothing. Check a sweep landed by sampling a pixel inside the menu, not
by assuming.

## What failed, and why it matters

First attempt: recompute the hover from the pointer on every `mouseMoved`, and switch the tracking areas
to `.inVisibleRect` with `rect: .zero` (to eliminate stale rects). Result: **hover highlighting
disappeared completely** — no row and no chip lit, ever. Inside a popup menu's own view hierarchy that
combination stops delivering events at all. Revert to `rect: bounds` with `.activeAlways`.

Second discovery: `mouseMoved:` is not a dependable source in a popup menu owned by a non-active app —
which is also why the chip row's per-chip hover (its only hover path) had never worked.

## The fix

The event that goes missing is the **exit**, not the enter: re-entering a row is reliable, leaving one is
not. So:

* `mouseEntered` sets the highlight (as before) and starts a 50 ms timer registered for `.common` *and*
  `.eventTracking` (a menu's tracking loop drains neither the default mode nor the main queue);
* the timer asks **the pointer** — `NSEvent.mouseLocation`, a global position needing no permissions and
  no event delivery — whether it is still inside the row's screen frame, and reports the exit itself;
* `mouseExited` **never clears on its own**: a spurious exit arrives readily (a tracking area replaced
  mid-move is enough), so it just triggers the same verification.

Rows with sub-areas (the five chips) re-derive the sub-area from the pointer on every tick, so they get
the same self-correction.

## Verification (measured, not eyeballed)

* sweep + park outside → **no row highlighted** (capture)
* rest on a row → **only that row** highlighted (capture)
* rest on a chip → that chip highlighted: state log holds `chip=1` on every tick, and the pixels differ —
  hovered chip `rgb(234,234,234)` vs idle `rgb(190,190,190)` (sampled with `sample`)

`--hover-log` writes the hover decisions to `/tmp/batteryplus-demo.log` while a demo instance runs, which
is how the chip case was settled: the state was right and only the *visibility* was in question, and the
pixel sample is what answered it.

## Harness in this folder

* `cursorsweep.swift` — move the real cursor through points, fast (`swiftc -O -o cursorsweep cursorsweep.swift`)
* `sample.swift` — print the colour at pixel positions of a PNG, in original coordinates
