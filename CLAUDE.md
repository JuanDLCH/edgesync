# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

EdgeSync gives macOS Hyprland-like window behaviour **without a tiling WM and without disabling SIP**.
Single-file Swift tools, no package manager, no tests. User-facing docs are in `README.md`;
code comments are in Spanish.

## Commands

```bash
./build.sh                                       # swiftc → ~/Applications/EdgeSync.app, ~/.local/bin/{win-grid,send-key,freeze-shot}
launchctl kickstart -k gui/$(id -u)/local.edgesync   # restart after building
./install.sh                                     # build + write/load the LaunchAgent (first install)
swiftc -O -o /tmp/es Sources/EdgeSync/main.swift # compile check only (doesn't touch the running app)
: > /tmp/edgesync.err.log; launchctl kickstart -k gui/$(id -u)/local.edgesync; sleep 2; cat /tmp/edgesync.err.log
                                                 # empty = has Accessibility; "necesita permiso" = no grant
```

**Signing matters.** `build.sh` signs with the local cert "EdgeSync Local" (`make-cert.sh`) when it
exists, so the Accessibility grant survives rebuilds. With an ad-hoc signature every rebuild silently
loses the grant: the user must remove EdgeSync with − in Accessibility and allow it again. Never
fall back to ad-hoc signing. If `build.sh` hangs in `codesign`, the login keychain is locked and a
prompt is waiting: ask the user to enter their password and click **Always Allow**.

## Testing without the user (debug channel)

`touch /tmp/edgesync.debug` → EdgeSync logs to `/tmp/edgesync.log` and reads `/tmp/edgesync.cmd`
(polled every ~240 ms, deleted after reading):

- `drag x1 y1 x2 y2` / `altdrag x1 y1 x2 y2` — synthetic left-button drag (screen coords, top-left
  origin), with ⌥ held for `altdrag`. Grab a title bar to move, a window edge (±1 px) to resize.
- `set <windowid> x y w h [pos|size|both|thorough]` — set a frame via AX and log AX/CG frames at
  0/0.1/0.5/1 s (to see how an app reacts). Several lines per file are allowed (e.g. to restore the
  user's layout after a test).

Listing frames from the terminal (CG, layer 0, skip `borders`):

```bash
swift -e 'import CoreGraphics
for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
where (w[kCGWindowLayer as String] as? Int) == 0 && (w[kCGWindowOwnerName as String] as? String) != "borders" {
  let b = w[kCGWindowBounds as String] as! [String: Double]
  print(w[kCGWindowNumber as String]!, w[kCGWindowOwnerName as String]!, Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!)) }'
```

Typical test: note the frames, `altdrag` a kitty title bar (kitty and Safari accept synthetic drags;
**Claude/Electron title bars don't**, use kitty/Safari as the moved window), list again, read the
log, then restore with `set`. Closing: `open -na kitty --args --title es-test`, `set` it into a
cell, `pkill -f 'kitty.*es-test'`. User-floating ids are in `/tmp/edgesync-floating`.

`win-grid -v` lists the windows it would arrange **without moving them**. Never run `win-grid` or
`win-grid max` without `-v` just to inspect: the Claude Code process has Accessibility, so it really
rearranges the user's screen. Same for the debug channel: it moves the user's mouse and windows; warn
them first. `rm /tmp/edgesync.debug` when done.

## Architecture

Four independent executables, each one `main.swift` compiled alone with `swiftc` (no shared module,
so helpers like `usable()`/margins are duplicated and must be kept in sync):

- **`Sources/EdgeSync`** — the daemon (`LSUIElement` app, LaunchAgent `local.edgesync`, runs an
  `NSApplication` with `.accessory` policy so it can show the snap preview window). A 40 ms timer
  (`tick`) polls the mouse button; while idle every 6th tick runs `watch()` (~240 ms).
- **`Sources/win-grid`** — CLI run by skhd (inherits skhd's Accessibility). Re-lays out the display
  under the mouse; `max` toggles the focused window to the full work area (state in `/tmp/win-grid-max`);
  `focus <dir>` focuses the nearest window in a direction across displays and warps the mouse to it;
  `-v` lists only. Activating another app from a background process must go through AX
  (`kAXFrontmostAttribute`): `NSRunningApplication.activate()` is silently ignored.
- **`Sources/freeze-shot`** — frozen-screen screenshot: `screencapture -x` one PNG per display (decode
  immediately with `kCGImageSourceShouldCacheImmediately`, the temp files are deleted right after),
  plus each window alone in parallel (`screencapture -x -o -l <id>`, so a window click captures only
  that window, not what covers it). Full-screen `.screenSaver` overlays per display with a crosshair
  cursor; click = window under the mouse (CGWindowList at freeze time), menu bar = whole display,
  drag = area, Esc = cancel. `finish()` copies to the clipboard, plays the shutter, saves to
  `~/Pictures/freeze-shot/` (pruned after a day; not under Caches, or Preview forces "keep a copy"
  dialogs) and shows a thumbnail bottom-left; clicking it runs `openInMarkup` (Preview + ⌘⇧A, then
  copies the file again whenever its mtime changes). Exits at once if the Screenshots toggle is off.
  Needs Screen Recording, which the Claude Code terminal doesn't have: only testable through skhd.
- **`Sources/send-key`** — CLI that posts a key combo with real modifier key presses (system shortcuts
  such as Ctrl+→ for Spaces ignore flag-only events). `send-key swipe left|right [speed]` posts a
  synthetic dock-swipe gesture (event types 29/30, field 110 = 23, phases 1/2/4, velocity fields
  129/130; default speed 5.25) so mouse buttons switch Spaces with the native animation, faster.

### EdgeSync flow (main.swift sections)

- **Window model**: `snapshot()` = CGWindowList, layer 0, regular-activation apps only (JankyBorders
  draws layer-0 windows and must be excluded), keyed by `CGWindowID`. AX elements are matched by id
  via private `_AXUIElementGetWindow`. Coordinates are top-left (CG); `NSScreen` frames are converted.
- **Drag** (`tick`): mouse-down takes a `baseline`. The first window whose *size* changes with one edge
  fixed per axis (`isEdgeResize`) is a resize → `findDividers` builds, per edge, the windows aligned on
  the same side and those touching from the other side (`divider`), and `apply` moves them live.
  Both edges of an axis moving = a move (`moving`); followers are restored. On release
  `resolveAfterResize` (0.35 s later) stops the divider at a neighbour's minimum size.
- **Snap** (`planAtMouse` → `dropPlan` → `feasiblePlan`): only when ⌥ is held at release;
  `showPreview(r, bad:)` draws the plan while dragging with ⌥ (purple, or red when it can't fit).
  Over a tiled window: middle 40 % = replace it, outer 30 % on its long axis = split it and take that
  half (only if the target is > 0.7 × a quarter: max 2 windows per quarter, a half can only be
  replaced). Near the screen edge/corner (`replaceZone` 70 px) = replace. Over empty space,
  `cellAtMouse` zones: side quarter of the width × top/middle/bottom third, centre-top = full.
  Replace: the displaced window goes to `vacated(moving.r)` (the mover's old cell clipped to the work
  area) if it came from a tile and `fits` there, else it floats; if it can't fit anywhere the plan is
  red and a drop puts the mover back. `verifySnap` (0.9 s later) undoes the whole operation if any
  window ended off-screen or on top of another tiled one.
- **`settle(id, old, snapped)`**: runs only within 2 s of a user drag (`lastDragEnd`). Not snapped
  and touching < 2 edges → user-floating (`/tmp/edgesync-floating`) + `regrid` of the display it left.
  Otherwise overlapped windows cede on the cheaper axis; same cell → split; if minimum sizes make
  sharing impossible → swap (or the displaced one floats where the dropped one came from); then
  `expandLone(vis, except: moved)` and small-gap filling.
- **`expandLone`**: every tiled window grows to the largest `standardCells` cell (full, columns,
  quarters; deliberately **no full-width rows**, layouts are column-based) that contains it and
  overlaps no other tiled window. The window the user just dropped is excluded so its neighbour fills
  the hole: the other half of a quarter takes the quarter back, the window above stretches down. `planAtMouse` only splits windows bigger than 0.7 × a quarter (max 2 per quarter).
- **Menu bar** (`MenuController`, `featureOn`/`setFeature`): toggles Autotiling / Autofocus /
  Screenshots via flag files in `~/Library/Application Support/EdgeSync/off/{tiling,focus,screenshots}`
  (persist across restarts, readable by other tools). Tiling off: `tick()` only syncs AutoRaise.
  Focus off: `applyFocusSetting` SIGSTOPs AutoRaise and creates `/tmp/edgesync-autoraise-paused` so
  the screenshot script doesn't resume it; `syncAutoRaise` does nothing. Screenshots off:
  `freeze-shot` exits at startup.
- **`watch()`**: debug commands, AutoRaise sync (SIGSTOP/SIGCONT AutoRaise while a user-floating window
  or a dialog is focused; flag file `/tmp/edgesync-autoraise-paused`), new dialogs/system prompts get
  focus + mouse (`checkDialogs`), new windows (id > `maxSeenId`) become floating centred on the mouse's
  display, closed tiled windows (`windowExists` false, not just off-Space) → `expandLone`, and `regrid` only
  if no neighbour now covers the hole; user
  moves are detected into `pending` → `settle`.
- **Layouts** (`regrid` and win-grid, keep identical): 1 full, 2 halves, 3 master-left + 2 rows,
  4 dwindle (left column, top-right, bottom-right split). Cells assigned by minimum total distance.
  `regrid` only takes windows that `looksTiled` (≥ 3 sides against a screen edge or another window).
- **Placement** (`place`): size→position→size, read back from CG (AX lags for Electron apps), retry,
  then `enforce` keeps re-applying for ~2 s because apps like Claude/Electron reassert their own size
  right after a user drag. Every new `place` cancels pending enforcement for that window. Our own
  moves are recorded in `ours` so `watch` ignores them.

### Gotchas (all hit in practice)

- Native tiling must be **off**: macOS keeps natively snapped windows in their half/quarter and undoes
  external AX changes. Never press "Window → Move & Resize → Return to Previous Size" programmatically.
- macOS may report no menu bar for a secondary display (`visibleFrame` top = 0): `usable()` uses the
  largest menu-bar height of all screens. Windows sit flush under the bar, `margin` 8 px elsewhere.
- Minimum sizes are learned (`learnMin` in `place`, only when the app kept the requested position but
  stayed bigger, and < 80 % of the screen) into `~/Library/Application Support/EdgeSync/min-sizes.json`;
  `feasiblePlan` uses them to colour the snap preview red and to bounce a drop back.
- Apps have minimum sizes (WhatsApp ~600 px tall, Spotify ~600 tall / wider with its queue panel);
  any placement must read back the real frame instead of trusting the requested one.
- Window ids only grow; a window appearing after a Space switch is old (lower id), not new.
- `regrid` ignores windows that don't `looksTiled` (e.g. half of a quarter touches only 2 sides), so
  hole filling must go through `expandLone`, not `regrid`.
- `log()` only writes when `/tmp/edgesync.debug` exists: to debug a bug the user reports, turn it on
  and ask them to reproduce it, then read `/tmp/edgesync.log`.

## Repo rules

Public repo: nothing personal or work-related (names, paths under the user's home, hostnames,
company). Commits use the GitHub noreply identity configured in this repo and **no Claude
attribution** (no Co-Authored-By/"Generated with" lines).
