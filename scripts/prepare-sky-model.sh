#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
MODEL_DIR="${1:-$ROOT_DIR/.build/models}"
REVISION=7c771f8867a479d1441ac5fb0a8de31feea76bb6
PACKAGE=DETRResnet50SemanticSegmentationF16.mlpackage
BASE_URL="https://huggingface.co/apple/coreml-detr-semantic-segmentation/resolve/$REVISION/$PACKAGE"
mkdir -p "$MODEL_DIR"

fetch() {
    local relative="$1" expected="$2" target="$MODEL_DIR/$PACKAGE/$1"
    mkdir -p "${target:h}"
    if [[ -f "$target" && "$(shasum -a 256 "$target" | cut -d ' ' -f 1)" == "$expected" ]]; then
        return
    fi
    curl --fail --location --retry 3 --output "$target.download" "$BASE_URL/$relative"
    [[ "$(shasum -a 256 "$target.download" | cut -d ' ' -f 1)" == "$expected" ]] || {
        print -u2 "Sky model integrity check failed: $relative"
        return 1
    }
    mv "$target.download" "$target"
}

fetch Manifest.json 0749549c6b11139e11a40aaab82add4843a9977010337e596cce3dbb35c98512
fetch Data/com.apple.CoreML/model.mlmodel 61e05678150bcae26deac589b998dffe13c2977a9ba6f802938a9f3a60bfdcce
fetch Data/com.apple.CoreML/weights/weight.bin 2f4de3dfed1aeced35ad7096d7c8721fcfb59571110a9e9138d73a7e56480408
swift "$ROOT_DIR/scripts/compile-sky-model.swift" "$MODEL_DIR/$PACKAGE" "$MODEL_DIR/SkySegmentation.mlmodelc"
