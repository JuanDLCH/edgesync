#!/bin/sh
# Builds EdgeSync.app into ~/Applications and win-grid + send-key into ~/.local/bin.
# Signing: if a code-signing identity named "EdgeSync Local" exists (see README), it is used so the
# Accessibility grant survives rebuilds; otherwise the app is signed ad hoc and macOS drops the
# grant on every rebuild.
set -e
cd "$(dirname "$0")"
mkdir -p build ~/Applications ~/.local/bin

swiftc -O -o build/EdgeSync Sources/EdgeSync/main.swift
swiftc -O -o build/win-grid Sources/win-grid/main.swift
swiftc -O -o build/send-key Sources/send-key/main.swift

A=~/Applications/EdgeSync.app/Contents
rm -rf ~/Applications/EdgeSync.app && mkdir -p "$A/MacOS"
cp build/EdgeSync "$A/MacOS/"
cat > "$A/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.edgesync</string>
  <key>CFBundleName</key><string>EdgeSync</string>
  <key>CFBundleExecutable</key><string>EdgeSync</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
if security find-certificate -c "EdgeSync Local" >/dev/null 2>&1; then
  codesign --force --sign "EdgeSync Local" ~/Applications/EdgeSync.app
else
  codesign --force --sign - ~/Applications/EdgeSync.app
fi
cp build/win-grid build/send-key ~/.local/bin/
echo "Built ~/Applications/EdgeSync.app, ~/.local/bin/win-grid and ~/.local/bin/send-key"
