#!/bin/bash
# Builds Workbench.app with SwiftPM alone, no Xcode project: the fallback for build.sh. It's
# always ad-hoc signed, so the Keychain asks again after every rebuild.
#
#   macos/build-swiftpm.sh            build macos/build/Workbench.app
#   macos/build-swiftpm.sh install    build, copy to ~/Applications and open it
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACOS="$ROOT/macos"
APP="$MACOS/build/Workbench.app"
VERSION=0.1.0

swift build -c release --package-path "$MACOS"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$MACOS/.build/release/Workbench" "$APP/Contents/MacOS/Workbench"
# SwiftPM records the deployment target as the SDK version, and AppKit picks the design from that:
# an app that says it was built against an older SDK keeps the old look. Record the real SDK.
xcrun vtool -set-build-version macos 26.0 "$(xcrun --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/Workbench" "$APP/Contents/MacOS/Workbench"

# The Dock icon, from the web app's 512px icon.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ROOT/public/icon-512.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  [ $double -le 512 ] && sips -z $double $double "$ROOT/public/icon-512.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# The asset catalog. AccentColor is the web version's primary; Resources/README.md explains dark mode.
# actool needs Xcode's first-launch setup; without it the app still applies the accent in code.
ACCENT_KEY=""
xcrun actool "$MACOS/Resources/Assets.xcassets" --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --accent-color AccentColor \
  --output-partial-info-plist "$(mktemp -d)/assets.plist" >/dev/null 2>&1 || true
if [ -f "$APP/Contents/Resources/Assets.car" ]; then
  ACCENT_KEY="<key>NSAccentColorName</key><string>AccentColor</string>"
else
  echo "warning: couldn't compile the asset catalog (run 'xcodebuild -runFirstLaunch' once); list selection keeps the system accent" >&2
fi

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
  $ACCENT_KEY
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signed, so each rebuild is a new app to macOS: the Keychain asks again before letting it
# read its credentials. build.sh signs with your Apple Development certificate instead.
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
  osascript -e 'quit app id "com.workbench.app"' 2>/dev/null || true
  rm -rf "$HOME/Applications/Workbench.app"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$HOME/Applications/Workbench.app"
  open "$HOME/Applications/Workbench.app"
  echo "Installed ~/Applications/Workbench.app"
fi
