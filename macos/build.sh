#!/bin/bash
# Builds Workbench.app, the native macOS app in macos/.
#
#   npm run app:build     build macos/build/Workbench.app
#   npm run app:install   build, copy to ~/Applications and open it
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACOS="$ROOT/macos"
APP="$MACOS/build/Workbench.app"
VERSION=0.1.0

swift build -c release --package-path "$MACOS"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$MACOS/.build/release/Workbench" "$APP/Contents/MacOS/Workbench"

# The Dock icon, from the web app's 512px icon.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ROOT/public/icon-512.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  [ $double -le 512 ] && sips -z $double $double "$ROOT/public/icon-512.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Workbench</string>
  <key>CFBundleDisplayName</key><string>Workbench</string>
  <key>CFBundleIdentifier</key><string>com.workbench.app</string>
  <key>CFBundleExecutable</key><string>Workbench</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signed for now, so each rebuild is a new app to macOS: the Keychain asks again before
# letting it read its credentials. A stable self-signed identity fixes that (and keeps
# Accessibility permission across rebuilds, which app tracking will need).
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
  osascript -e 'tell application "Workbench" to quit' 2>/dev/null || true
  rm -rf "$HOME/Applications/Workbench.app"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$HOME/Applications/Workbench.app"
  open "$HOME/Applications/Workbench.app"
  echo "Installed ~/Applications/Workbench.app"
fi
