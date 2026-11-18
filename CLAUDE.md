# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

EdgeSync gives macOS Hyprland-like window behaviour **without a tiling WM and without disabling SIP**.
Single-file Swift tools, no package manager, no tests. User-facing docs are in `README.md`;
code comments are in Spanish.

## Commands

```bash
./build.sh                                       # swiftc → ~/Applications/EdgeSync.app, ~/.local/bin/{win-grid,send-key}
launchctl kickstart -k gui/$(id -u)/local.edgesync   # restart after building
./install.sh                                     # build + write/load the LaunchAgent (first install)
swiftc -O -o /tmp/es Sources/EdgeSync/main.swift # compile check only (doesn't touch the running app)
: > /tmp/edgesync.err.log; launchctl kickstart -k gui/$(id -u)/local.edgesync; sleep 2; cat /tmp/edgesync.err.log
                                                 # empty = has Accessibility; "necesita permiso" = no grant
```

**Signing matters.** `build.sh` signs with the local cert "EdgeSync Local" (`make-cert.sh`) when it
exists, so the Accessibility grant survives rebuilds. With an ad-hoc signature every rebuild silently
loses the grant: the user must remove EdgeSync with − in Accessibility and allow it again.

## Testing without the user (debug channel)

`touch /tmp/edgesync.debug` → EdgeSync logs to `/tmp/edgesync.log` and reads `/tmp/edgesync.cmd`
(polled every ~240 ms, deleted after reading):

- `drag x1 y1 x2 y2` / `altdrag x1 y1 x2 y2` — synthetic left-button drag (screen coords, top-left
  origin), with ⌥ held for `altdrag`. Grab a title bar to move, a window edge (±1 px) to resize.
- `set <windowid> x y w h [pos|size|both|thorough]` — set a frame via AX and log AX/CG frames at
  0/0.1/0.5/1 s (to see how an app reacts).

`win-grid -v` lists the windows it would arrange **without moving them**. Never run `win-grid` or
`win-grid max` without `-v` just to inspect: the Claude Code process has Accessibility, so it really
rearranges the user's screen. Same for the debug channel: it moves the user's mouse and windows; warn
them first. `rm /tmp/edgesync.debug` when done.

## Architecture

Three independent executables, each one `main.swift` compiled alone with `swiftc` (no shared module,
so helpers like `usable()`/margins are duplicated and must be kept in sync):

- **`Sources/EdgeSync`** — the daemon (`LSUIElement` app, LaunchAgent `local.edgesync`, runs an
  `NSApplication` with `.accessory` policy so it can show the snap preview window). A 40 ms timer
  (`tick`) polls the mouse button; while idle every 6th tick runs `watch()` (~240 ms).
- **`Sources/win-grid`** — CLI run by skhd (inherits skhd's Accessibility). Re-lays out the display
  under the mouse; `max` toggles the focused window to the full work area (state in `/tmp/win-grid-max`);
  `-v` lists only.
- **`Sources/send-key`** — CLI that posts a key combo with real modifier key presses (system shortcuts
  such as Ctrl+→ for Spaces ignore flag-only events).

### EdgeSync flow (main.swift sections)

- **Window model**: `snapshot()` = CGWindowList, layer 0, regular-activation apps only (JankyBorders
  draws layer-0 windows and must be excluded), keyed by `CGWindowID`. AX elements are matched by id
  via private `_AXUIElementGetWindow`. Coordinates are top-left (CG); `NSScreen` frames are converted.
- **Drag** (`tick`): mouse-down takes a `baseline`. The first window whose *size* changes with one edge
  fixed per axis (`isEdgeResize`) is a resize → `findDividers` builds, per edge, the windows aligned on
  the same side and those touching from the other side (`divider`), and `apply` moves them live.
  Both edges of an axis moving = a move (`moving`); followers are restored. On release
  `resolveAfterResize` (0.35 s later) stops the divider at a neighbour's minimum size.
- **Snap** (`cellAtMouse`/`snapTarget`): only when ⌥ is held at release; `showPreview` draws the cell
  while dragging with ⌥. Zones: side quarter of the width × top/middle/bottom third, centre-top = full.
  A window bigger than the cell (minimum size) is anchored to the chosen corner.
- **`settle(id, old, snapped)`**: runs only within 2 s of a user drag (`lastDragEnd`). Not snapped
  and touching < 2 edges → user-floating (`/tmp/edgesync-floating`) + `regrid` of the display it left.
  Otherwise overlapped windows cede on the cheaper axis; same cell → split; if minimum sizes make
  sharing impossible → swap (or the displaced one floats where the dropped one came from); then
  `fillHole` for the vacated cell and small-gap filling.
- **`watch()`**: debug commands, AutoRaise sync (SIGSTOP/SIGCONT AutoRaise while a user-floating window
  or a dialog is focused; flag file `/tmp/edgesync-autoraise-paused`), new dialogs/system prompts get
  focus + mouse (`checkDialogs`), new windows (id > `maxSeenId`) become floating centred on the mouse's
  display, closed tiled windows (`windowExists` false, not just off-Space) trigger `regrid`, and user
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
- Apps have minimum sizes (WhatsApp ~600 px tall, Spotify ~600 tall / wider with its queue panel);
  any placement must read back the real frame instead of trusting the requested one.
- Window ids only grow; a window appearing after a Space switch is old (lower id), not new.

## Repo rules

Public repo: nothing personal or work-related (names, paths under the user's home, hostnames,
company). Commits use the GitHub noreply identity configured in this repo and **no Claude
attribution** (no Co-Authored-By/"Generated with" lines).
