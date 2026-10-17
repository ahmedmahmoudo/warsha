#!/bin/bash
# Builds Workbench.app from the Xcode project, signed with your Apple Development certificate when
# you have one (Xcode → Settings → Accounts → your Apple ID → Manage Certificates → +), so macOS
# keeps its Keychain and other permissions across rebuilds. build-swiftpm.sh is the fallback.
#
#   npm run app:build     build macos/build/Workbench.app
#   npm run app:install   build, copy to ~/Applications and open it
set -euo pipefail

MACOS="$(cd "$(dirname "$0")" && pwd)"
APP="$MACOS/build/Workbench.app"
LOCAL="$MACOS/Local.xcconfig"

# Sign with your certificate: write its team into Local.xcconfig (git-ignored) the first time.
if [ ! -f "$LOCAL" ] && security find-identity -v -p codesigning | grep -q "Apple Development"; then
  TEAM="$(security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject -nameopt multiline \
    | awk -F' = ' '/organizationalUnitName/ { print $2; exit }')"
  if [ -n "$TEAM" ]; then
    printf 'CODE_SIGN_IDENTITY = Apple Development\nDEVELOPMENT_TEAM = %s\n' "$TEAM" >"$LOCAL"
    echo "Signing with your Apple Development certificate (team $TEAM); see macos/Local.xcconfig"
  fi
fi
[ -f "$LOCAL" ] || echo "note: no Apple Development certificate, so this build is signed to run locally only" >&2

xcodegen generate --spec "$MACOS/project.yml" --quiet
xcodebuild -project "$MACOS/Workbench.xcodeproj" -scheme Workbench -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$MACOS/build/DerivedData" -allowProvisioningUpdates -quiet build

rm -rf "$APP"
cp -R "$MACOS/build/DerivedData/Build/Products/Release/Workbench.app" "$APP"
SIGNER="$(codesign -dv --verbose=2 "$APP" 2>&1 | awk -F= '/^Authority/ { print $2; exit }')"
echo "Built $APP, signed ${SIGNER:+by $SIGNER}${SIGNER:-to run locally}"

if [ "${1:-}" = "install" ]; then
  osascript -e 'quit app id "com.workbench.app"' 2>/dev/null || true
  rm -rf "$HOME/Applications/Workbench.app"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$HOME/Applications/Workbench.app"
  open "$HOME/Applications/Workbench.app"
  echo "Installed ~/Applications/Workbench.app"
fi
