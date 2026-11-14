#!/bin/bash
# Builds Millr.app into ./build
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/Millr"
APP="build/Millr.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Millr"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Millr</string>
  <key>CFBundleDisplayName</key><string>Millr</string>
  <key>CFBundleIdentifier</key><string>io.github.buuras.millr</string>
  <key>CFBundleExecutable</key><string>Millr</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSDesktopFolderUsageDescription</key><string>To show the files on your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>To show your Documents folder.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>To show your Downloads folder.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>To show external disks.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>To show network volumes.</string>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
echo "Built: $APP"
