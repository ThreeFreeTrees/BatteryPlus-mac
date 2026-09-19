# Spike 002 — glyph fidelity

## Question
Given the requirement "the same icon, white in Low Power Mode and out of it", can a third-party
menu bar item render a battery glyph indistinguishable from the native one?

## Verdict: VALIDATED — mean ink difference 1.2 %, median 0.18 %

Final measurement against a live 2x capture of the native icon (battery at 61 %):

```
native box       : 51x24 px  (aspect 2.125)      ours: 51x24 px  (aspect 2.125)   identical
fill boundary    : native 53.8%   ours 53.8%     of glyph width                   identical
ink diff         : mean 0.0117   median 0.0018   p95 0.0354
difference map   : only the nub's edge registers (0.10–0.25 coverage over ~6 px)
```

## What worked
- **Measuring instead of guessing.** A purpose-built probe (`glyph_probe`) plus an objective
  difference metric (`diff_glyphs`) turned "looks right" into numbers, and every parameter could
  then be calibrated by sweeping it and minimising the error.
- **Drawing the glyph ourselves** (`Sources/BatteryPlus/BatteryIcon.swift`). SF Symbols match the
  outer box but ship five discrete fill steps; the native icon fills continuously.
- **Template rendering** (`isTemplate = true`) gives "same colour in LPM and out of it" for free:
  macOS paints it white on a dark menu bar and black on a light one, and we never tint it.

## What didn't
- **SF Symbols' variable fill.** `NSImage(systemSymbolName:variableValue:accessibilityDescription:)`
  exists (macOS 13+) and looks like the perfect answer, but it is a **no-op in this rendering path**:
  the measured fill boundary stayed at 97 % for `variableValue` 0.05, 0.30, 0.50, 0.75 and 0.95.
  This is recorded here so it is not attempted again.
- **A first-guess geometry.** The initial constants (corner radius 2.0, empty alpha 0.50, nub 1.5x3.0)
  gave a mean diff of 0.034; calibration took it to 0.0117.

## Measured native geometry (2x capture, macOS 27, 24 pt menu bar)

| Element | Value | Notes |
|---|---|---|
| total glyph | 25.5 x 12.0 pt (51x24 px) | aspect 2.125 |
| body | 23.0 x 12.0 pt | corner radius **4.0 pt** (calibrated) |
| gap | 1.0 pt | body and nub are separate shapes |
| nub | 1.25 x 3.5 pt | vertically centred, ~capsule |
| charged part | full alpha, continuous | fill boundary = charge % of body width, verified exactly |
| remainder | same colour at **0.48** alpha | measured 0.61 over a 0.28 bar, full fill 0.96 |
| stroke | none | a vertical profile through the remainder is flat 0.61 with only edge antialiasing |

Calibration sweep (mean ink diff): radius 1.5→0.0374, 2.0→0.0343, 3.0→0.0258, **4.0→0.0135**,
4.5→0.0194, 5.0→0.0285 · emptyAlpha 0.44→0.0252, **0.48→0.0127**, 0.52→0.0199 ·
nub width 1.0→0.0276, **1.25→0.0117**, 1.5→0.0126.

## Surprises
- The nub is a **separate shape with a 1 pt gap**, not a bump fused to the body.
- The uncharged part has **no outline at all** — it is the same colour at ~48 % alpha. That is why
  an "outline + interior" model (the obvious guess) is wrong.
- SF Symbols sit *very* differently in the point-size space than expected: matching a 12 pt glyph
  needs `pointSize: 34, weight: .semibold`.

## Charging state (added after plugging in a charger)

Verified against live captures of the native charging icon — this is a *different* glyph, not the
plain pill with a bolt drawn inside it:

| Finding | Detail |
|---|---|
| The bolt **overflows the pill** | native glyph box while charging is **51x28 px (14 pt)**, against 51x24 for the plain pill. The canvas has to be taller than the body, with the pill centred in it — the first attempt clipped the bolt because the canvas was sized to the pill. |
| The bolt has a **transparent knockout ring** | ~1 pt gap around the silhouette, so the bolt reads over both the white fill and the grey remainder. In a template image the ring must be *transparent*, not a dark colour: the system recolours the icon and no second colour exists. |
| Bolt geometry | height ≈ 1.17 x the pill height, aspect 0.60, centred at 0.52 of the body width. |
| Measured silhouette | `bolt_outline` extracts the bolt's left profile row by row from the knockout ring (the bolt interior is white like the fill, so brightness alone cannot segment it): 0.34 → 0.24 → 0.38 of the pill width from top to bottom of the pill band. |

Result: **mean ink difference 8.7 %, median 1.8 %** for the charging glyph (against 1.2 % / 0.18 %
for the non-charging one). The box, fill, remainder and bolt *placement* match; the residual is the
bolt's exact vector silhouette, which is approximated by a six-point polygon rather than Apple's
path. At 12 pt tall this is a sub-pixel-scale difference, but it is not pixel-exact — recorded
honestly here rather than rounded up to "identical".

### Three bugs this caught, all of which failed *silently*
1. **Canvas too short** — the bolt was drawn outside the bitmap bounds and clipped away; the only
   symptom was an unexplained diff.
2. **`NSImage.lockFocus()` does not work for tinting in a command-line context** — the bolt
   rasterised blank. The CLI now has a `--selftest` that reports how many pixels a symbol actually
   produces, so this class of failure is caught immediately rather than inferred.
3. **The app squashed the charging glyph.** `AppDelegate.updateIcon` was overriding `image.size`
   with a fixed 12 pt box, so the 14 pt charging glyph was scaled down. Measured from a live capture
   of the menu bar: ours **50x23 px (aspect 2.174)** against the native's **51x28 px (1.821)** — the
   icon looked smaller *and* softer, because the bitmap no longer mapped 1:1 to screen pixels. The
   fix is to leave the image's own logical size alone; both items now measure **51x28 px (1.821)**.

   This is the failure mode to watch for with template images: a wrong `image.size` degrades quality
   without any error, and the CLI calibration harness cannot see it because it dumps the bitmap
   directly, bypassing the status item's layout.

## The nub (found by the user, measured afterwards)

The nub is **not a rectangle** — that was a visible error. Measured per column from a live capture:

| | column 1 | column 2 | column 3 |
|---|---|---|---|
| native | 8 px tall | 6 px | 4 px |
| ours (rectangle, before) | 6 px | 6 px | 6 px |
| ours (after fix) | 8 px | 6 px | 4 px |

It is a "D" shape: flat where it meets the body, rounded at the outer tip, 1.5 pt wide and 4 pt tall
(a rounded rect of 3.5 pt with a 0.75 pt radius rendered as a flat tab and was measurably smaller).
Drawn with two Bézier quarter-ellipses; `nubCornerRadius` is gone, the tip is always fully rounded.

Method worth reusing: **measure per column, not by bounding box.** A bounding box cannot distinguish
a rectangle from a rounded tab — the two had identical widths and the box metric called it a match.
`--col` profiles plus a per-column height read-out caught it immediately.

**Not reproduced:** a reported ~6 % height difference. In same-frame captures both items measure
51x24 px idle and 51x28 px charging, with the pill body 22 px tall in both; a hand-held photo across
the menu bar can differ by that much through perspective alone.

## Residual (accepted)
- Non-charging: the nub's antialiasing differs slightly (0.10–0.25 coverage over ~6 px at 8x zoom).
  At the real 1x size this is sub-pixel.
- Charging: the bolt silhouette, as above.

## Recommendation for the real build
Use `BatteryGlyph.image(fraction:charging:)` as the status item's template image, driven by
`isLowPowerModeEnabled` only for the *menu* content — never for tinting the icon.
