#!/usr/bin/env bash
# Uploads the installer to the website's downloads volume, where buyers download it from. The site serves
# the newest .pkg there, so publishing a new version is just uploading it.
#
#   DEPLOY_TARGET=root@my-server:/var/lib/docker/volumes/<volume>/_data/downloads scripts/publish-installer.sh [file]
#
# Uploads build/SpaceKit-<version>.pkg, or the .dmg when there's no .pkg, or the file you name, and the
# release notes in docs/releases/<version>.md if they exist. A .dmg is also signed for Sparkle (with the
# key generate_keys put in this Mac's keychain), so SpaceKit can install it as an in-app update. The site
# serves the highest version, to new buyers and as an update.
#
# Build and notarize it first (scripts/build-installer.sh). Setup: web/README.md.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
VERSION="${VERSION:-$(grep -m1 'static let version' Sources/SpaceKitCLI/SpaceKitCommand.swift | sed -E 's/.*"(.*)".*/\1/')}"
PKG="${1:-build/SpaceKit-$VERSION.pkg}"
if [ -z "${1:-}" ] && [ ! -f "$PKG" ]; then
  PKG="build/SpaceKit-$VERSION.dmg"
fi
: "${DEPLOY_TARGET:?Set DEPLOY_TARGET=user@host:/path/to/downloads (see web/README.md)}"

[ -f "$PKG" ] || { echo "✗ $PKG doesn't exist. Run scripts/build-installer.sh first." >&2; exit 1; }
if ! xcrun stapler validate "$PKG" >/dev/null 2>&1; then
  echo "✗ $PKG isn't notarized, so buyers' Macs would refuse to open it. Build it with signing and notarization (docs/RELEASING.md)." >&2
  [ "${ALLOW_UNNOTARIZED:-}" = 1 ] || exit 1
fi

SIGNATURE=""
if [[ "$PKG" == *.dmg ]]; then
  SIGN_UPDATE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
  [ -x "$SIGN_UPDATE" ] || swift package resolve >/dev/null
  echo "→ Signing $(basename "$PKG") for Sparkle"
  SIGNATURE="$("$SIGN_UPDATE" --account spacekit "$PKG")" || {
    echo "✗ sign_update failed: is the Sparkle key in this Mac's keychain? (docs/RELEASING.md)" >&2
    exit 1
  }
fi

HOST="${DEPLOY_TARGET%%:*}"
DIR="${DEPLOY_TARGET#*:}"
echo "→ Uploading $(basename "$PKG") to $DEPLOY_TARGET"
ssh "$HOST" "mkdir -p '$DIR'"
# Upload under a temporary name and rename, so nobody downloads a half-copied file.
scp "$PKG" "$HOST:$DIR/.upload-$(basename "$PKG")"
NOTES="docs/releases/$VERSION.md"
if [ -z "${1:-}" ] && [ -f "$NOTES" ]; then
  echo "→ Uploading release notes ($NOTES)"
  scp "$NOTES" "$HOST:$DIR/.upload-SpaceKit-$VERSION.notes.md"
  ssh "$HOST" "chmod 644 '$DIR/.upload-SpaceKit-$VERSION.notes.md' && mv '$DIR/.upload-SpaceKit-$VERSION.notes.md' '$DIR/SpaceKit-$VERSION.notes.md'"
fi
# Notes and signature first: the moment the installer appears, the appcast offers it, complete.
if [ -n "$SIGNATURE" ]; then
  printf '%s\n' "$SIGNATURE" | ssh "$HOST" "cat > '$DIR/.upload-$(basename "$PKG").sig' && chmod 644 '$DIR/.upload-$(basename "$PKG").sig' && mv '$DIR/.upload-$(basename "$PKG").sig' '$DIR/$(basename "$PKG").sig'"
fi
ssh "$HOST" "chmod 644 '$DIR/.upload-$(basename "$PKG")' && mv '$DIR/.upload-$(basename "$PKG")' '$DIR/$(basename "$PKG")'"
echo "✓ Published. https://<your-domain>/appcast.xml now offers $VERSION as an update."
