#!/bin/sh
# Builds, then installs EdgeSync as a per-user LaunchAgent (starts at login, restarts if it exits).
set -e
cd "$(dirname "$0")"
./build.sh
P=~/Library/LaunchAgents/local.edgesync.plist
mkdir -p ~/Library/LaunchAgents
cat > "$P" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.edgesync</string>
  <key>ProgramArguments</key>
  <array><string>$HOME/Applications/EdgeSync.app/Contents/MacOS/EdgeSync</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>/tmp/edgesync.err.log</string>
</dict>
</plist>
PL
launchctl bootout "gui/$(id -u)/local.edgesync" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$P"
echo "EdgeSync is running. Allow it in System Settings → Privacy & Security → Accessibility."
