#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
APP_DIR="${1:-$SOURCE_DIR/.build.noindex/Finder高清助手.app}"
FINDER_CLEAR_ARCH="${FINDER_CLEAR_ARCH:-$(uname -m)}"
FINDER_CLEAR_MIN_OS="13.0"
case "$FINDER_CLEAR_ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $FINDER_CLEAR_ARCH" >&2; exit 1 ;; esac
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$SOURCE_DIR/.build.noindex/module-cache"
xcrun swiftc -swift-version 5 -O \
  -target "$FINDER_CLEAR_ARCH-apple-macos$FINDER_CLEAR_MIN_OS" \
  -module-cache-path "$SOURCE_DIR/.build.noindex/module-cache" \
  "$SOURCE_DIR/IconStore.swift" "$SOURCE_DIR/FinderBridge.swift" "$SOURCE_DIR/FinderSort.swift" \
  "$SOURCE_DIR/WheelPolicy.swift" "$SOURCE_DIR/FinderWheel.swift" "$SOURCE_DIR/main.swift" \
  -framework AppKit -framework SwiftUI -framework ImageIO -framework ServiceManagement \
  -o "$APP_DIR/Contents/MacOS/FinderClear"
cp "$SOURCE_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$SOURCE_DIR/Assets/FinderHDHelper.icns" "$APP_DIR/Contents/Resources/"
cp "$SOURCE_DIR/LinearMouse-LICENSE.txt" "$SOURCE_DIR/THIRD-PARTY-NOTICES.md" "$SOURCE_DIR/LICENSE" "$APP_DIR/Contents/Resources/"
codesign --force --sign - --identifier local.songjiaqi.FinderClear "$APP_DIR"
echo "Built: $APP_DIR ($FINDER_CLEAR_ARCH, macOS $FINDER_CLEAR_MIN_OS+)"
