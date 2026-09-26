#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="PerceptionEditor"
APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"
LOCAL_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" && -d "$LOCAL_SDK" ]]; then
    export SDKROOT="$LOCAL_SDK"
fi

export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/ManifestCache"

cd "$ROOT_DIR"
swift build --disable-sandbox --scratch-path "$ROOT_DIR/.build" -c release --product "$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ROOT_DIR/.build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
