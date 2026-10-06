#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
BUILD_DIR="${PORTBAR_OUTPUT_DIR:-$PWD/dist}"
APP_PATH="$BUILD_DIR/PortBar.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
mkdir -p .build/arm64 .build/x86_64
for architecture in arm64 x86_64; do
  xcrun --sdk macosx swiftc PortBar.swift -o ".build/$architecture/PortBar" \
    -target "$architecture-apple-macos13.0" -sdk "$SDK_PATH" -O \
    -framework AppKit -framework SwiftUI -framework IOKit -framework ServiceManagement
done
xcrun lipo -create .build/arm64/PortBar .build/x86_64/PortBar -output "$APP_PATH/Contents/MacOS/PortBar"
cp Info.plist "$APP_PATH/Contents/Info.plist"
cp Assets/PortBar.icns "$APP_PATH/Contents/Resources/PortBar.icns"
codesign --force --sign - "$APP_PATH"
echo "Built universal PortBar.app: $APP_PATH"
