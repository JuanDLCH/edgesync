# EdgeSync

Hyprland-style window behaviour for macOS **without a tiling window manager and without disabling
SIP**. You place windows yourself; EdgeSync keeps them together:

- **Shared edges**: drag the edge between two windows and every window on that divider follows
  (the ones aligned in the same column/row and the ones on the other side). Windows with a minimum
  size stop the divider instead of being overlapped.
- **Snap with ⌥**: drag a window holding ⌥ and a translucent preview shows where it will land; drop
  with ⌥ held to snap. Zones by mouse position: left/right quarter of the screen → top third =
  quarter, middle = full-height column, bottom third = quarter; centre touching the top = full
  screen. Without ⌥ (or outside the zones) the window just moves and becomes floating.
- **Make room**: windows covered by the dropped one shrink on the axis where they lose least;
  dropping onto an occupied cell splits it in two (the new window takes the half under the mouse).
- **Floating windows**: a window dropped outside the zones is remembered as floating; the tiled
  windows left behind are re-laid out. Closing a tiled window re-lays out its display too.
- **Focus helpers** (with [AutoRaise](https://github.com/sbmpost/AutoRaise)): while a floating window
  or a dialog has focus, AutoRaise is paused so hovering other windows doesn't cover it; new dialogs
  and system prompts get focus and the mouse.

`win-grid` (bind it to a hotkey, e.g. with skhd) re-lays out the display under the mouse:

| Windows | Layout |
|---|---|
| 1 | full screen |
| 2 | halves |
| 3 | left column + two rows on the right |
| 4 | dwindle: left column, top right, bottom right split in two |

Each window goes to the cell closest to where it is. Floating windows (app or user) are skipped.

`win-grid max` toggles the focused window between its own frame and the whole usable area of its
display (on top of the others, not macOS full screen); the previous frame is kept in
`/tmp/win-grid-max`.

It only reacts to what you do with the mouse: nothing happens when apps open windows or resize
themselves. Idle cost is about 0.3 % CPU (polling the mouse button and the window list).

## Requirements

- macOS 15 or later (tested on macOS 26), Xcode Command Line Tools (`swiftc`).
- Accessibility permission for EdgeSync. `win-grid` uses the permission of whatever runs it
  (e.g. skhd).
- **Turn off native tiling** (System Settings → Desktop & Dock → Windows: *Drag windows to screen
  edges to tile*, *Drag windows to menu bar to fill screen*, *Hold ⌥ key while dragging windows to
  tile*). macOS keeps natively tiled windows in their half/quarter and undoes any other change.

## Install

```bash
git clone https://github.com/JuanDLCH/edgesync && cd edgesync
./make-cert.sh   # optional, see below
./install.sh     # builds, installs ~/Applications/EdgeSync.app + ~/.local/bin/win-grid, starts it at login
```

Then allow **EdgeSync** in System Settings → Privacy & Security → Accessibility (it asks on first
start) and restart it: `launchctl kickstart -k gui/$(id -u)/local.edgesync`.

`send-key <mods> <key>` posts a key combination instantly (e.g. `send-key ctrl right` to switch
Spaces from a mouse button), much faster than `osascript` + System Events.

Hotkeys with skhd: `alt - g : ~/.local/bin/win-grid` and `alt - f : ~/.local/bin/win-grid max`.

### Why `make-cert.sh`

macOS ties the Accessibility grant to the app's code signature. An ad-hoc signature changes on every
build, so every rebuild needs removing EdgeSync from the list and allowing it again. `make-cert.sh`
creates a self-signed certificate *EdgeSync Local* in the login keychain (code signing only, not
trusted for anything else) and `build.sh` uses it when present, so the grant survives rebuilds.

## Settings

Constants at the top of the sections in `Sources/EdgeSync/main.swift`: `gap` (10 px between windows),
`margin` (8 px from the screen sides and bottom; windows sit flush under the menu bar), `maxGap`
(how far apart two windows still count as touching), `sideZone` (0.25 of the width for snapping),
`fillMax` (largest gap filled automatically) and the `floating` bundle IDs (apps that always float).

## Debugging

```bash
touch /tmp/edgesync.debug          # log to /tmp/edgesync.log
echo "drag 966 500 300 500" > /tmp/edgesync.cmd     # simulate a mouse drag (screen coordinates)
echo "set <window id> x y w h" > /tmp/edgesync.cmd  # move a window and log how it reacts
win-grid -v                        # list the windows win-grid would arrange (does not move them)
rm /tmp/edgesync.debug
```

Files: `/tmp/edgesync-floating` (window ids marked floating), `/tmp/edgesync-autoraise-paused`
(present while EdgeSync paused AutoRaise; a screenshot script can check it before resuming AutoRaise).

## Uninstall

```bash
launchctl bootout gui/$(id -u)/local.edgesync
rm -rf ~/Applications/EdgeSync.app ~/Library/LaunchAgents/local.edgesync.plist ~/.local/bin/win-grid
security delete-certificate -c "EdgeSync Local"   # if you created it
```

## License

MIT
