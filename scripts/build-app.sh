#!/usr/bin/env bash
# Builds Skrinsut.app (release) into ./build and ad-hoc signs it.
# Usage: scripts/build-app.sh [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

# SwiftUI macros need the full Xcode toolchain, not just Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" || { ARCHS=(); swift build -c release; }
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Skrinsut"

APP=build/Skrinsut.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Skrinsut"
# App icon (regenerate with: swift scripts/make-icon.swift)
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

VERSION="${VERSION:-0.1.0}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.skrinsut.app</string>
  <key>CFBundleName</key><string>Skrinsut</string>
  <key>CFBundleDisplayName</key><string>Skrinsut</string>
  <key>CFBundleExecutable</key><string>Skrinsut</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.skrinsut.app.deeplink</string>
      <key>CFBundleURLSchemes</key><array><string>skrinsut</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.png</string><string>public.jpeg</string><string>com.compuserve.gif</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x Skrinsut 2>/dev/null || true
  open "$APP"
fi
