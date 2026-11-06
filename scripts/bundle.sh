#!/bin/bash
# Builds build/XMNative.app (release). Works with Xcode or the Command Line Tools.
#   UNIVERSAL=1  build arm64 + x86_64
#   VERSION=1.2.3  stamp the version into Info.plist
set -euo pipefail
cd "$(dirname "$0")/.."

build() { swift build --build-system native -c release "$@" 2>&1 | grep -v deprecated; }

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  build --triple arm64-apple-macosx26.0
  build --triple x86_64-apple-macosx26.0
  ARM="$(swift build --build-system native -c release --triple arm64-apple-macosx26.0 --show-bin-path 2>/dev/null)/XMNative"
  X86="$(swift build --build-system native -c release --triple x86_64-apple-macosx26.0 --show-bin-path 2>/dev/null)/XMNative"
  BIN="$(mktemp -d)/XMNative"
  lipo -create "$ARM" "$X86" -output "$BIN"
else
  build
  BIN="$(swift build --build-system native -c release --show-bin-path 2>/dev/null)/XMNative"
fi

APP=build/XMNative.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/XMNative"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$APP/Contents/Info.plist"
fi
codesign --force --sign - --options runtime --entitlements Resources/XMNative.entitlements "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/XMNative"))"
