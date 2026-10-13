#!/usr/bin/env bash
# Builds the installers customers download: build/SpaceKit-<version>.pkg (the macOS Installer, which also
# puts the `spacekit` CLI on PATH) and build/SpaceKit-<version>.dmg (drag to Applications). The app is
# universal (Apple silicon and Intel) by default.
#
#   scripts/build-installer.sh                      → unsigned installers, for testing on this Mac only
#
#   APP_SIGN_IDENTITY="Developer ID Application: AppRise Ventures Oy (XW75F94L2B)" \
#   INSTALLER_SIGN_IDENTITY="Developer ID Installer: AppRise Ventures Oy (XW75F94L2B)" \
#   NOTARY_PROFILE=spacekit-notary \
#   scripts/build-installer.sh                      → signed, notarized and stapled: ready to sell
#
# FORMATS="pkg" or "dmg" builds just one. One-time setup for signing and notarization: docs/RELEASING.md.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="${VERSION:-$(grep -m1 'static let version' Sources/SpaceKitCLI/SpaceKitCommand.swift | sed -E 's/.*"(.*)".*/\1/')}"
export VERSION
ARCHS="${ARCHS:-arm64 x86_64}"
FORMATS="${FORMATS:-pkg dmg}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APP="$ROOT/build/SpaceKit.app"
PKG="$ROOT/build/SpaceKit-$VERSION.pkg"
DMG="$ROOT/build/SpaceKit-$VERSION.dmg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "✗ $*" >&2
  exit 1
}

if [ -n "$NOTARY_PROFILE" ]; then
  [ -n "$APP_SIGN_IDENTITY" ] || fail "NOTARY_PROFILE needs APP_SIGN_IDENTITY (a Developer ID Application certificate)"
  if [[ " $FORMATS " == *" pkg "* ]] && [ -z "$INSTALLER_SIGN_IDENTITY" ]; then
    fail "NOTARY_PROFILE needs INSTALLER_SIGN_IDENTITY (a Developer ID Installer certificate) to notarize the .pkg"
  fi
fi

# Submits a file to Apple's notary service, waits for the verdict and staples the ticket to the file.
notarize() {
  local file="$1"
  echo "→ Notarizing $(basename "$file") (usually a few minutes)"
  local result
  result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
  local status id
  status="$(plutil -extract status raw - <<<"$result" 2>/dev/null || echo unknown)"
  id="$(plutil -extract id raw - <<<"$result" 2>/dev/null || echo unknown)"
  if [ "$status" != "Accepted" ]; then
    echo "$result" >&2
    fail "notarization of $(basename "$file") ended with status $status. Details: xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE"
  fi
  xcrun stapler staple "$file"
  xcrun stapler validate "$file"
}

SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}" ARCHS="$ARCHS" scripts/build-app.sh
HOST_ARCHS="$(lipo -archs "$APP/Contents/MacOS/SpaceKit" | tr ' ' ',')"

if [[ " $FORMATS " == *" pkg "* ]]; then
  echo "→ Building $(basename "$PKG") ($HOST_ARCHS)"
  mkdir -p "$WORK/root" "$WORK/resources"
  ditto --norsrc --noextattr --noqtn --noacl "$APP" "$WORK/root/SpaceKit.app"

  # Install exactly to /Applications. Left relocatable, Installer would "upgrade" whatever copy of the
  # bundle id it finds first, such as a build/SpaceKit.app in someone's checkout.
  pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
  plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"

  pkgbuild \
    --root "$WORK/root" \
    --component-plist "$WORK/component.plist" \
    --identifier dev.spacekit.app \
    --version "$VERSION" \
    --install-location /Applications \
    --scripts "$ROOT/installer/scripts" \
    "$WORK/SpaceKit-component.pkg" >/dev/null

  cp "$ROOT/installer/resources/"*.html "$WORK/resources/"
  cp "$ROOT/LICENSE" "$WORK/resources/LICENSE.txt"
  sed -e "s/@VERSION@/$VERSION/g" -e "s/@HOST_ARCHS@/$HOST_ARCHS/g" \
    "$ROOT/installer/Distribution.xml" >"$WORK/Distribution.xml"

  PRODUCT_SIGN=()
  if [ -n "$INSTALLER_SIGN_IDENTITY" ]; then
    PRODUCT_SIGN=(--sign "$INSTALLER_SIGN_IDENTITY" --timestamp)
  fi
  rm -f "$PKG"
  productbuild \
    --distribution "$WORK/Distribution.xml" \
    --resources "$WORK/resources" \
    --package-path "$WORK" \
    ${PRODUCT_SIGN[@]+"${PRODUCT_SIGN[@]}"} \
    "$PKG" >/dev/null

  if [ -n "$NOTARY_PROFILE" ]; then
    notarize "$PKG"
  fi
fi

if [[ " $FORMATS " == *" dmg "* ]]; then
  echo "→ Building $(basename "$DMG")"
  mkdir -p "$WORK/dmg"
  ditto --norsrc --noextattr --noqtn --noacl "$APP" "$WORK/dmg/SpaceKit.app"
  ln -s /Applications "$WORK/dmg/Applications"
  rm -f "$DMG"
  hdiutil create -volname "SpaceKit $VERSION" -srcfolder "$WORK/dmg" -fs APFS -format ULFO -ov "$DMG" >/dev/null
  if [ -n "$APP_SIGN_IDENTITY" ]; then
    codesign --force --timestamp --sign "$APP_SIGN_IDENTITY" "$DMG"
  fi
  if [ -n "$NOTARY_PROFILE" ]; then
    notarize "$DMG"
  fi
fi

echo
for format in $FORMATS; do
  file="$ROOT/build/SpaceKit-$VERSION.$format"
  echo "✓ $file ($(du -h "$file" | cut -f1 | tr -d ' '))"
  echo "  sha256 $(shasum -a 256 "$file" | cut -d' ' -f1)"
done
if [ -z "$NOTARY_PROFILE" ]; then
  echo
  echo "  Not notarized: other Macs will refuse to open these. To sell them, sign and notarize (docs/RELEASING.md)."
fi
