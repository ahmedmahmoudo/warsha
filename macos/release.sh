#!/bin/bash
# Publishes a Warsha release on GitHub: bumps the version, builds the signed app with build.sh,
# zips it (signature intact), writes notes from the commits since the last release, tags it and
# uploads it. Built here rather than on GitHub's runners, because the signing certificate and the
# sign-in clients (Secrets.xcconfig) live on this Mac. Only the tag is pushed, not main.
#
#   npm run app:release                 next patch version (0.1.0 → 0.1.1)
#   npm run app:release -- 0.2.0        a given version
#   npm run app:release -- --dry-run    build and package, show the notes, change nothing
#
# On another Mac: npm run app:get (or the gh one-liner in macos/README.md, "Releases").
set -euo pipefail

MACOS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$MACOS")"
SPEC="$MACOS/project.yml"
OUT="$MACOS/build/release"

DRY=false
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=true ;;
    *) VERSION="$arg" ;;
  esac
done

command -v gh >/dev/null || { echo "error: needs the GitHub CLI (brew install gh), signed in" >&2; exit 1; }
cd "$ROOT"

# The release is built from what's committed: anything uncommitted in the app would ship unrecorded.
if [ -n "$(git status --porcelain -- macos package.json package-lock.json)" ]; then
  echo "error: macos/ or package.json has uncommitted changes; commit or stash them first" >&2
  git status --short -- macos package.json package-lock.json >&2
  exit 1
fi

CURRENT="$(awk '/MARKETING_VERSION:/ { print $2; exit }' "$SPEC")"
BUILD="$(awk '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$SPEC")"
LAST_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
# The first release ships 0.1.0 as it is; after that the patch number goes up unless one is given.
if [ -z "$VERSION" ]; then
  if [ -z "$LAST_TAG" ]; then VERSION="$CURRENT"; else VERSION="$(echo "$CURRENT" | awk -F. '{ printf "%d.%d.%d", $1, $2, $3 + 1 }')"; fi
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like 1.2.3, not $VERSION" >&2; exit 1; }
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || gh release view "$TAG" >/dev/null 2>&1; then
  echo "error: $TAG already exists" >&2
  exit 1
fi

# Notes: the app's features and fixes since the last release, newest first.
NOTES="$(mktemp)"
RANGE="${LAST_TAG:+$LAST_TAG..}HEAD"
{
  echo "## What's new"
  echo
  git log "$RANGE" --no-merges --pretty='%s' -- macos | grep -E '^(feat|fix|perf)' \
    | sed -E 's/^(feat|fix|perf)(\([^)]*\))?!?: /- /' | head -60 || true
  echo
  echo "## Install"
  echo
  echo '```bash'
  echo "gh release download $TAG --repo $(gh repo view --json nameWithOwner -q .nameWithOwner) --pattern 'Warsha-*.zip' --dir /tmp/warsha --clobber \\"
  echo "  && rm -rf ~/Applications/Warsha.app && ditto -x -k /tmp/warsha/Warsha-$VERSION.zip ~/Applications \\"
  echo "  && open ~/Applications/Warsha.app"
  echo '```'
  echo
  echo "Downloaded with a browser instead, macOS asks once: System Settings → Privacy & Security → Open Anyway."
} >"$NOTES"

if ! $DRY; then
  # The version goes into the app and the history before it's built.
  sed -i '' -E "s/^( *MARKETING_VERSION: ).*/\\1$VERSION/; s/^( *CURRENT_PROJECT_VERSION: ).*/\\1$((BUILD + 1))/" "$SPEC"
  # package.json (and its lockfile) carry the same version, so the repo has one.
  npm version "$VERSION" --no-git-tag-version --allow-same-version >/dev/null
  git add "$SPEC" package.json package-lock.json
  git commit -q -m "chore(macos): release $TAG"
fi

"$MACOS/build.sh"
APP="$MACOS/build/Warsha.app"
SHIPPED="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
$DRY || [ "$SHIPPED" = "$VERSION" ] || { echo "error: built $SHIPPED, expected $VERSION" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

rm -rf "$OUT" && mkdir -p "$OUT"
ZIP="$OUT/Warsha-$VERSION.zip"
# ditto keeps the bundle's signature, extended attributes and symlinks, which zip doesn't.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" >"$(basename "$ZIP").sha256")

if $DRY; then
  echo
  echo "Dry run: built $SHIPPED, packaged $ZIP ($(du -h "$ZIP" | cut -f1)). Would release $TAG with these notes:"
  echo
  cat "$NOTES"
  rm -f "$NOTES"
  exit 0
fi

git tag -a "$TAG" -m "Warsha $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" "$ZIP.sha256" --verify-tag --title "Warsha $VERSION" --notes-file "$NOTES"
rm -f "$NOTES"
echo "Released $TAG: $(gh release view "$TAG" --json url -q .url)"
echo "The version bump is committed on $(git branch --show-current) but not pushed; push it when you're ready."
