#!/bin/zsh
# Builds BrightnessKeys.app and installs it to ~/Applications.
set -euo pipefail
cd "${0:A:h}"

APP=build/BrightnessKeys.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/BrightnessKeys" Sources/main.swift \
  -framework AppKit -framework IOKit -framework ServiceManagement

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.local.BrightnessKeys</string>
  <key>CFBundleName</key><string>BrightnessKeys</string>
  <key>CFBundleExecutable</key><string>BrightnessKeys</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF

codesign --force --sign - "$APP"

mkdir -p ~/Applications
pkill -x BrightnessKeys 2>/dev/null || true
rm -rf ~/Applications/BrightnessKeys.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/BrightnessKeys.app"
