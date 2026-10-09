#!/usr/bin/env bash
# Prints the macOS SDK to build SpaceKit with, or nothing when the default SDK works.
#
# The macOS 27 SDK declares SwiftUI's @State as a macro whose compiler plugin (SwiftUIMacros) ships only
# with Xcode, so with just the Command Line Tools the app target fails to compile. This compiles a small
# @State view against the default SDK and, if that fails, against every other installed SDK (newest
# first), and prints the first one that compiles it.
#
#   SDKROOT="$(scripts/swift-sdk.sh)" swift build
set -euo pipefail

# Xcode carries the plugin, so only a Command Line Tools developer directory needs the probe.
case "$(xcode-select -p)" in
  */CommandLineTools*) ;;
  *) exit 0 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/Probe.swift" <<'SWIFT'
import SwiftUI

struct Probe: View {
    @State private var on = false
    var body: some View { Toggle("", isOn: $on) }
}
SWIFT

compiles() {
  xcrun swiftc -typecheck -sdk "$1" -target "$(uname -m)-apple-macos15.0" "$WORK/Probe.swift" >/dev/null 2>&1
}

DEFAULT_SDK="$(xcrun --sdk macosx --show-sdk-path)"
if compiles "$DEFAULT_SDK"; then
  exit 0
fi

# Real SDK folders only: MacOSX.sdk and MacOSX27.sdk are links to the versioned ones.
for sdk in $(find "$(dirname "$DEFAULT_SDK")" -maxdepth 1 -type d -name 'MacOSX*.sdk' | sort -rV); do
  if compiles "$sdk"; then
    echo "$sdk"
    exit 0
  fi
done

echo "No installed macOS SDK compiles SwiftUI's @State without Xcode. Install Xcode to build the app." >&2
