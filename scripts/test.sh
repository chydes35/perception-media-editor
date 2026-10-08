#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

SWIFT_FLAGS=(--disable-sandbox --scratch-path "$ROOT_DIR/.build")

# With only Command Line Tools installed, point SwiftPM at the CLT copy of Swift Testing.
# Full Xcode finds it on its own, so these flags are skipped there.
if [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" ]]; then


    CLT_DEVELOPER="/Library/Developer/CommandLineTools/Library/Developer"
    SWIFT_FLAGS+=(
        -Xswiftc -F -Xswiftc "$CLT_DEVELOPER/Frameworks"
        -Xlinker -rpath -Xlinker "$CLT_DEVELOPER/Frameworks"
        -Xlinker -rpath -Xlinker "$CLT_DEVELOPER/usr/lib"
    )
    export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
    export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/ManifestCache"
fi

swift test "${SWIFT_FLAGS[@]}" "$@"
swift build "${SWIFT_FLAGS[@]}" --product PerceptionEditor

echo "Tests and build passed"
