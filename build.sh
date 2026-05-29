#!/bin/bash
# Build DisplayFixer.app (menu-bar agent). Ad-hoc signed; not sandboxed (needs IOKit USB + SkyLight).
set -euo pipefail
cd "$(dirname "$0")"

APP="DisplayFixer.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MACOS_DIR="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS_DIR"
cp Info.plist "$APP/Contents/Info.plist"

clang -fobjc-arc -Wno-deprecated-declarations -O2 \
  -F"$SDK/System/Library/PrivateFrameworks" \
  -framework Cocoa -framework CoreGraphics -framework IOKit \
  -framework SkyLight -framework ServiceManagement \
  src/main.m src/AppDelegate.m src/DisplayFixCore.m \
  -o "$MACOS_DIR/DisplayFixer"

# Ad-hoc code signature (required for SMAppService login-item registration to be stable).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed (login-item may be flaky)"

echo "Built $APP"
