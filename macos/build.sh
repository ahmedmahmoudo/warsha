#!/bin/bash
# Builds Warsha.app from the Xcode project, signed with your Apple Development certificate when
# you have one (Xcode → Settings → Accounts → your Apple ID → Manage Certificates → +), so macOS
# keeps its Keychain and other permissions across rebuilds. build-swiftpm.sh is the fallback.
#
#   npm run app:build     build macos/build/Warsha.app
#   npm run app:install   build, copy to ~/Applications and open it
set -euo pipefail

MACOS="$(cd "$(dirname "$0")" && pwd)"
APP="$MACOS/build/Warsha.app"
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

# Warsha's built-in sign-in clients live in Secrets.xcconfig (git-ignored). Start it from the
# example when it's missing; the project lists it, so it has to exist.
SECRETS="$MACOS/Secrets.xcconfig"
if [ ! -f "$SECRETS" ]; then
  cp "$MACOS/Secrets.example.xcconfig" "$SECRETS"
  echo "note: made macos/Secrets.xcconfig from the example; fill in the sign-in clients there" >&2
fi

xcodegen generate --spec "$MACOS/project.yml" --quiet
xcodebuild -project "$MACOS/Warsha.xcodeproj" -scheme Warsha -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$MACOS/build/DerivedData" -allowProvisioningUpdates -quiet build

rm -rf "$APP"
cp -R "$MACOS/build/DerivedData/Build/Products/Release/Warsha.app" "$APP"
# awk reads to the end: stopping early would break codesign's pipe and, with pipefail, the script.
SIGNER="$(codesign -dv --verbose=2 "$APP" 2>&1 | awk -F= '/^Authority/ && !found { print $2; found = 1 }')"
if [ -n "$SIGNER" ]; then echo "Built $APP, signed by $SIGNER"; else echo "Built $APP, signed to run locally"; fi

if [ "${1:-}" = "install" ]; then
  osascript -e 'quit app id "com.warsha.app"' 2>/dev/null || true
  # Warsha was called Workbench: the old app goes, so only one of them runs (Warsha takes over its data).
  osascript -e 'quit app id "com.workbench.app"' 2>/dev/null || true
  rm -rf "$HOME/Applications/Workbench.app"
  rm -rf "$HOME/Applications/Warsha.app"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$HOME/Applications/Warsha.app"
  open "$HOME/Applications/Warsha.app"
  echo "Installed ~/Applications/Warsha.app"
fi
