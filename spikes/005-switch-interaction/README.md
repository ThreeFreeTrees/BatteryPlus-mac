# Spike 005 — the Low Power switch: why it did not animate, and what does

## Symptom

Clicking the switch toggled Low Power Mode correctly, but the knob teleported: no travel, no fade.

## Three separate causes, each invisible on its own

1. **The menu dismissed on click.** `mouseUp` called `cancelTracking()` immediately, so the menu was
   gone before any animation could play. Now it dismisses after the travel finishes.
2. **A timer in the default run-loop mode never fires during menu tracking.** Menu tracking runs the
   run loop in `.eventTracking`, so a `Timer` added to the default mode is never serviced. Register
   for `.common` (which includes event tracking) and `.eventTracking` explicitly.
   Related trap found while building the test: **`DispatchQueue.main.asyncAfter` also never fires
   while a menu is up** — the main queue is not drained in that mode. The test trigger had to become
   a timer as well.
3. **An open menu never repaints from a timer.** This is the one that actually killed the animation.
   The menu window is a static surface: it repaints when an *event* arrives — which is exactly why
   the row's hover highlight appeared and made the view look live — not when a view marks itself
   dirty. `displayIfNeeded()` on the view, `window.displayIfNeeded()`, and a forced full-window
   display all changed nothing. Measured: ten frames over 2.4 s during a 1.6 s travel, knob position
   constant at 0.69.

## What works

**Core Animation.** The switch is now two `CALayer`s (track + knob) instead of a `draw(_:)` view, and
the travel is a layer animation committed with `CATransaction.commit()` + `flush()`. The render
server composites it independently of the app's run loop, so it animates while the menu is tracking.

## Evidence

`--slow-toggle` stretches the travel to 1.6 s so a screenshot can catch it. Knob position as a
fraction of the track, sampled frame by frame through one toggle:

```
0.30  0.32  0.35  0.38  0.40  0.43  0.46  0.48  0.50  0.53  0.54  0.57
```

Monotonic travel, read from the pixels. (Same measurement before the layer rewrite: `0.69 0.69 0.69
0.69 0.69 0.69 0.69 0.69 0.69 0.69`.)

## Test harness built here

* `--demo-menu-for <seconds>` — keeps the demo menu open long enough to interact with.
* `--demo-toggle-after <seconds>` — drives the row's own `activate()` (the exact code path a click
  runs). A synthetic click cannot be delivered into a non-active app's menu window: `clicker.swift`
  posts one via CGEvent, the pointer *move* landed (the hover highlight appeared) but the button
  event never reached the row. `computer_use` cannot help on this machine either — its capture fails
  for lack of Screen Recording permission, and it requires a capture before it will click.
* `DemoLog` → `/tmp/batteryplus-demo.log`. A demo instance's stdout is invisible to the harness, and
  a silent no-op was precisely the failure being investigated — log to a file and read it back.
