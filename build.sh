#!/bin/bash
# Builds "Android Share.app" in ./build
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Android Share.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AndroidShare "$APP/Contents/MacOS/AndroidShare"

# App icon
ICONSET="build/AppIcon.iconset"
SRC_ICON="assets/AppIcon.png"   # replace this file to change the icon
if [ ! -f build/AppIcon.icns ] || [ "$SRC_ICON" -nt build/AppIcon.icns ]; then
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  if [ -f "$SRC_ICON" ]; then cp "$SRC_ICON" build/icon_1024.png; else swift scripts/make_icon.swift build/icon_1024.png; fi
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Android Share</string>
  <key>CFBundleDisplayName</key><string>Android Share</string>
  <key>CFBundleIdentifier</key><string>com.htetmyat.androidshare</string>
  <key>CFBundleExecutable</key><string>AndroidShare</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M%S)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSBonjourServices</key><array><string>_FC9F5ED42C8A._tcp</string></array>
  <key>NSLocalNetworkUsageDescription</key><string>Android Share uses your local network so your phone can send and receive files over Wi-Fi.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"
echo "Install with:  cp -R \"$APP\" /Applications/"
