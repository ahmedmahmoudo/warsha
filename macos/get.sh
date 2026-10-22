#!/bin/bash
# Installs the latest Warsha release (or a given one) from GitHub into ~/Applications, for your
# other Macs. Uses the GitHub CLI, which can read the private repo and doesn't mark the download as
# quarantined, so it opens without Gatekeeper's prompt.
#
#   npm run app:get              the latest release
#   npm run app:get -- v0.1.1    a given one
set -euo pipefail

REPO="ahmedmahmoudo/warsha"
TAG="${1:-}"
command -v gh >/dev/null || { echo "error: needs the GitHub CLI (brew install gh), then gh auth login" >&2; exit 1; }

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
gh release download ${TAG:+"$TAG"} --repo "$REPO" --pattern 'Warsha-*.zip*' --dir "$DIR"
ZIP="$(ls "$DIR"/Warsha-*.zip)"
(cd "$DIR" && shasum -a 256 -c "$(basename "$ZIP").sha256" >/dev/null) || { echo "error: the download doesn't match its checksum" >&2; exit 1; }

osascript -e 'quit app id "com.warsha.app"' 2>/dev/null || true
# Warsha was called Workbench: the old app goes, so only one of them runs (Warsha takes over its data).
osascript -e 'quit app id "com.workbench.app"' 2>/dev/null || true
rm -rf "$HOME/Applications/Workbench.app"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Warsha.app"
ditto -x -k "$ZIP" "$HOME/Applications"
open "$HOME/Applications/Warsha.app"
echo "Installed $(basename "$ZIP" .zip) in ~/Applications"
