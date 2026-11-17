---
name: mac-cu
description: Drive this Mac's GUI, click, type, drag, scroll, read screens, for any agent in a shell session. Use whenever a task needs keyboard or mouse control of a macOS app, reading an app's UI tree, clicking a button by name, or verifying what an app shows. More reliable than hand-rolled CGEvent/osascript code; always prefer it over writing new synthetic-input code.
---

# mac-cu, computer use for agents on this Mac

Binary: `~/.local/bin/mac-cu` (sources: `mac-cu.swift` and `JsonText.swift`; rebuild
with `swiftc -O -target arm64-apple-macosx14.0 mac-cu.swift JsonText.swift -o mac-cu`).

Every command prints JSON with `"ok":true|false`. Requires the calling terminal to
have Accessibility permission. Check it with `mac-cu pos` or `mac-cu apps` before use.

## Rules that prevent the known failures

1. **Element indices over pixel coordinates.** Run `elements` first, click by
   `--element`. Coordinates are the fallback, not the default.
2. **Verify after acting.** After a click or key, read state with `elements` or
   `get`. Never assert success from the action's exit code alone.
3. **Do not hand-roll `osascript` AX reads.** `entire contents` and `first text
   area of window 1` silently return wrong or empty results on nested AppKit
   views. `mac-cu elements` and `mac-cu get` walk the tree correctly.
4. **Do not write new CGEvent code.** mac-cu already solves shared event source,
   hover-arming before clicks, and inter-event timing. Hand-rolled events drop
   mouse-ups and fail to arm gesture recognizers.

## Commands

```
mac-cu apps                          # apps with on-screen windows (name, pid)
mac-cu windows <app>                 # window ids, titles, frames
mac-cu elements <app> [filter] [--json]  # numbered AX tree; --json for machine parsing
mac-cu get <app> <N> [attribute]     # read element N's value (or named attribute)
mac-cu set <app> <N> <text>          # write element N's value (no focus needed)
mac-cu click <x> <y>                 # hover-armed click at coordinates
mac-cu click --element <N> --app <A> [--method ax|coords]
mac-cu doubleclick|rightclick …      # same argument forms as click
mac-cu move <x> <y>
mac-cu drag <x1> <y1> <x2> <y2>
mac-cu scroll <ticks> [x y]           # negative = down; optional point targets the view under it
mac-cu type <text>                   # unicode text into the focused field (dangerous patterns blocked)
mac-cu key <return|tab|esc|delete|space|left|right|down|up|…>
mac-cu hotkey <cmd+shift+c>          # lock-screen and log-out chords are hard-blocked
mac-cu wait <seconds>                # bounded sleep (max 60)
mac-cu wait <app> --text "needle" [--timeout 15]   # poll the AX tree until a label appears
mac-cu capture [path]                # full screen (needs Screen Recording permission)
mac-cu capture [path] --app <A>      # crop to the app's frontmost window
mac-cu capture [path] --app <A> --som  # + numbered overlays matching `elements` indices
mac-cu pos                           # cursor position (top-left origin)
```

`<app>` matches exact name, bundle id, substring, or pid (e.g. `Safari`,
`com.apple.Safari`, `Preview`, `16038`).

## Standard loop

```
mac-cu elements "Notes"                 # find the composer and Send button
mac-cu click 2567 1156                    # or click --element 9 --app "Notes"
mac-cu type "status report please"
mac-cu key return
mac-cu get "Notes" 8                     # read the transcript, verify the reply
```

Disabled controls ignore both AXPress and synthetic clicks. Enablement follows app
state: `mac-cu type` fires the app's delegate callbacks; `mac-cu set` does not.

## Vision loop (set of mark)

```
mac-cu capture /tmp/shot.png --app "Notes" --som   # numbered overlay image
mac-cu elements "Notes"                  # the matching #N index with roles/labels
mac-cu click --element 13 --app "Notes" # numbers match between the two
```

## Hard safety rules

- `type` refuses dangerous shell patterns (`rm -rf /`, `curl | sh`, `dd if=`,
  shutdown/reboot, and similar). `hotkey` refuses lock-screen and log-out chords.
  Do not work around these blocks; they are load-bearing.
- Never click permission dialogs, password prompts, payment UI, or 2FA surfaces
  unless the user explicitly named that action.

Known limits: full-screen `capture` grabs the display under the pointer (ScreenCaptureKit,
single display at 2x); hidden app menus need `click --element`
on the AXMenuButton first, then a fresh `elements` of the menu window. SoM indices
come from the moment of capture, re-capture after any UI change before clicking.
