#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="PerceptionEditor"
APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"
BUILD_DIR="${PERCEPTION_BUILD_DIR:-$ROOT_DIR/.build}"
MODEL_DIR="${PERCEPTION_SKY_MODEL_DIR:-$BUILD_DIR/models}"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/ManifestCache"

cd "$ROOT_DIR"
swift build --disable-sandbox --scratch-path "$BUILD_DIR" -c release --product "$APP_NAME"
zsh "$ROOT_DIR/scripts/prepare-sky-model.sh" "$MODEL_DIR"

if ps -axo comm= | rg --fixed-strings --quiet "$APP_BUNDLE/Contents/MacOS/$APP_NAME"; then
    print -u2 "Quit PerceptionEditor before replacing its app bundle."
    exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
mkdir -p "$APP_BUNDLE/Contents/Resources/Models"
cp -R "$MODEL_DIR/SkySegmentation.mlmodelc" "$APP_BUNDLE/Contents/Resources/Models/"
cp -R "$ROOT_DIR/Resources/ModelNotices" "$APP_BUNDLE/Contents/Resources/"
cp -R "$ROOT_DIR/Resources/ThirdPartyNotices" "$APP_BUNDLE/Contents/Resources/"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
