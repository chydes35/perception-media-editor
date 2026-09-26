#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
LOCAL_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" && -d "$LOCAL_SDK" ]]; then
    SDK_PATH="$LOCAL_SDK"
fi

mkdir -p "$ROOT_DIR/.build/ModelChecksCache"

swiftc \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx15.0 \
    -module-cache-path "$ROOT_DIR/.build/ModelChecksCache" \
    -parse-as-library \
    "$ROOT_DIR/Sources/PerceptionEditor/EditorModels.swift" \
    "$ROOT_DIR/Sources/PerceptionEditor/ProjectDocument.swift" \
    "$ROOT_DIR/Sources/PerceptionEditor/AgentModels.swift" \
    "$ROOT_DIR/Sources/PerceptionEditor/AgentEngine.swift" \
    "$ROOT_DIR/scripts/model-check.swift" \
    -o "$ROOT_DIR/.build/model-check"

"$ROOT_DIR/.build/model-check"

SDKROOT="$SDK_PATH" \
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/ManifestCache" \
swift build \
    --disable-sandbox \
    --scratch-path "$ROOT_DIR/.build" \
    --product PerceptionEditor

echo "Build check passed"
