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

# Workbench's built-in Google client: Secrets.xcconfig (git-ignored), written from .env.local's
# GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET the first time.
SECRETS="$MACOS/Secrets.xcconfig"
ENV_FILE="$MACOS/../.env.local"
if [ ! -f "$SECRETS" ] && [ -f "$ENV_FILE" ]; then
  ID="$(sed -n 's/^GOOGLE_CLIENT_ID=//p' "$ENV_FILE" | tr -d '"' | head -1)"
  SECRET="$(sed -n 's/^GOOGLE_CLIENT_SECRET=//p' "$ENV_FILE" | tr -d '"' | head -1)"
  if [ -n "$ID" ] && [ -n "$SECRET" ]; then
    printf 'WORKBENCH_GOOGLE_CLIENT_ID = %s\nWORKBENCH_GOOGLE_CLIENT_SECRET = %s\n' "$ID" "$SECRET" >"$SECRETS"
    echo "Built-in Google client written to macos/Secrets.xcconfig from .env.local"
  fi
fi
[ -f "$SECRETS" ] || echo "note: no built-in Google client (macos/Secrets.xcconfig), so users enter their own in Settings" >&2

xcodegen generate --spec "$MACOS/project.yml" --quiet
xcodebuild -project "$MACOS/Workbench.xcodeproj" -scheme Workbench -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$MACOS/build/DerivedData" -allowProvisioningUpdates -quiet build

rm -rf "$APP"
cp -R "$MACOS/build/DerivedData/Build/Products/Release/Workbench.app" "$APP"
# awk reads to the end: stopping early would break codesign's pipe and, with pipefail, the script.
SIGNER="$(codesign -dv --verbose=2 "$APP" 2>&1 | awk -F= '/^Authority/ && !found { print $2; found = 1 }')"
if [ -n "$SIGNER" ]; then echo "Built $APP, signed by $SIGNER"; else echo "Built $APP, signed to run locally"; fi

if [ "${1:-}" = "install" ]; then
  osascript -e 'quit app id "com.workbench.app"' 2>/dev/null || true
  rm -rf "$HOME/Applications/Workbench.app"
  mkdir -p "$HOME/Applications"
  cp -R "$APP" "$HOME/Applications/Workbench.app"
  open "$HOME/Applications/Workbench.app"
  echo "Installed ~/Applications/Workbench.app"
fi
