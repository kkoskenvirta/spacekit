#!/usr/bin/env bash
# Builds SpaceKit.app: the SwiftUI app and the `spacekit` CLI (used by the background agent). Both have the
# built-in rules from rules/ compiled in, so the bundle carries no rule files.
#
#   scripts/build-app.sh            → build/SpaceKit.app (release, ad-hoc signed)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="${VERSION:-$(grep -m1 'static let version' Sources/SpaceKitCLI/SpaceKitCommand.swift | sed -E 's/.*"(.*)".*/\1/')}"
CONFIGURATION="${CONFIGURATION:-release}"
APP="$ROOT/build/SpaceKit.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "→ Building SpaceKit $VERSION ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product SpaceKitApp
swift build -c "$CONFIGURATION" --product spacekit
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/SpaceKitApp" "$APP/Contents/MacOS/SpaceKit"
# Helpers/, not MacOS/: on a case-insensitive volume "spacekit" would overwrite "SpaceKit".
cp "$BIN/spacekit" "$APP/Contents/Helpers/spacekit"

# App icon from assets/icon.svg (Quick Look renders SVG; iconutil builds the .icns).
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
RENDER_DIR="$(mktemp -d)"
if qlmanage -t -s 1024 -o "$RENDER_DIR" "$ROOT/assets/icon.svg" >/dev/null 2>&1 && [ -f "$RENDER_DIR/icon.svg.png" ]; then
  for size in 16 32 128 256 512; do
    sips -z $size $size "$RENDER_DIR/icon.svg.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$RENDER_DIR/icon.svg.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
  echo "  (icon rendering unavailable; continuing without an icon)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.spacekit.app</string>
  <key>CFBundleName</key><string>SpaceKit</string>
  <key>CFBundleDisplayName</key><string>SpaceKit</string>
  <key>CFBundleExecutable</key><string>SpaceKit</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Open source under the MIT License.</string>
</dict>
</plist>
PLIST

echo "→ Signing ($SIGN_IDENTITY)"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/spacekit"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"

echo "✓ $APP"
echo "  Open it:            open \"$APP\""
echo "  Install it:         cp -R \"$APP\" /Applications/"
echo "  CLI inside the app:  ln -s /Applications/SpaceKit.app/Contents/Helpers/spacekit ~/.local/bin/spacekit"
echo "  Grant Full Disk Access to SpaceKit (and to the bundled spacekit tool, for the background agent)."
