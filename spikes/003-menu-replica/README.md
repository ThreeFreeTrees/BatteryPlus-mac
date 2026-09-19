# Spike 003 — menu replica

## Question
Can an `NSMenu` reproduce the system Battery status menu closely enough to replace it?

## Verdict: VALIDATED — structure and styling match line for line

Verified by building the real menu, popping it open with `--demo-menu-at`, photographing it with an
external `screencapture` (`shots/replica_menu_final.png`) and comparing against a native capture of
the same menu.

| Native | Replica |
|---|---|
| `Battery` bold left, `67%` grey right-aligned, monospaced digits | same |
| `Power Source: Battery` grey secondary line | same |
| separator | same |
| `Energy Mode` grey section header | same |
| blue rounded-square battery icon + `Low Power` + neutral grey selection pill | same |
| `Using Significant Energy` + app rows | **omitted** — no public data source (see spike 004) |
| separator | same |
| `Battery Settings…` | same (opens System Settings → Battery) |

## What the iteration caught (things a mock-up would have shipped wrong)
- **One row, not two.** The first build listed `Low Power` *and* `Automatic` as separate rows. The
  native menu shows a **single toggle row** — "Low Power" — pill-highlighted only while it is active.
- **Wording.** The system writes `Power Source: Battery`, not `Battery Power`, and appends no
  time-remaining suffix in that line.
- **Highlight colour.** A selected row uses the *neutral* selection
  (`NSColor.unemphasizedSelectedContentBackgroundColor`), not the accent colour, and the row text
  stays regular weight.

## Implementation notes
- Custom view rows (`MenuRows.swift`) are needed for the two-column header, the grey section headers
  and the pill; everything else is a standard `NSMenuItem` so native hover, keyboard navigation and
  dismissal still work.
- Clicking the energy row calls the helper and **re-reads state**; a mismatch is surfaced in the menu
  rather than swallowed (the silent-success trap from spike 001).
- The icon is never tinted in either state — the menu carries the Low Power information instead.
  Proof: `shots/menubar_final.png` shows our item (white) next to the system item (yellow) with Low
  Power Mode on.

## Residual / not yet done
- Charging state (`battery.100percent.bolt`-style bolt overlay) is drawn but has not been compared
  against a native capture — it needs the charger plugged in.
- Launch-at-login and hiding the system's own battery item are still manual steps.
