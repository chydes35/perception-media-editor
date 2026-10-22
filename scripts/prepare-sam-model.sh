#!/bin/zsh
# Fetches Apple's Core ML conversion of SAM 2.1 Small at a pinned revision, checks every file's SHA-256,
# and compiles the three packages to .mlmodelc for the app bundle. Files already present with the right
# hash are not downloaded again. Same pattern as prepare-sky-model.sh.
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
MODEL_DIR="${1:-$ROOT_DIR/.build/models}"
REVISION=883f5787eb0be35ce6965907a8bc1f5320a5a02e
BASE_URL="https://huggingface.co/apple/coreml-sam2.1-small/resolve/$REVISION"
mkdir -p "$MODEL_DIR"

fetch() {
    local relative="$1" expected="$2" target="$MODEL_DIR/$1"
    mkdir -p "${target:h}"
    if [[ -f "$target" && "$(shasum -a 256 "$target" | cut -d ' ' -f 1)" == "$expected" ]]; then
        return
    fi
    curl --fail --location --retry 3 --output "$target.download" "$BASE_URL/$relative"
    [[ "$(shasum -a 256 "$target.download" | cut -d ' ' -f 1)" == "$expected" ]] || {
        rm -f "$target.download"
        print -u2 "SAM model integrity check failed: $relative"
        return 1
    }
    mv "$target.download" "$target"
}

# Large files carry the SHA-256 Hugging Face publishes for them; the three 617-byte manifests are not
# in LFS, so their hashes were computed from the verified download of this revision.
ENCODER=SAM2_1SmallImageEncoderFLOAT16.mlpackage
fetch $ENCODER/Manifest.json 442f9102d1a37c2699fce89b1f5257d35ebd0a7096f1773501cb0aba94fe95b6
fetch $ENCODER/Data/com.apple.CoreML/model.mlmodel 736602a3130875072f843df123ce3ceff41ec2f917a867da56f7c2264d81a567
fetch $ENCODER/Data/com.apple.CoreML/weights/weight.bin 6128a58f10cbcb7797bd12a7ec1e05ab4e9f8c80bd14ed05bbc43a9c9935a9c3

DECODER=SAM2_1SmallMaskDecoderFLOAT16.mlpackage
fetch $DECODER/Manifest.json d95d732931f590dbf6a08ea1fe58a6659ced8971c5b2a671d79091be1a63b9e1
fetch $DECODER/Data/com.apple.CoreML/model.mlmodel 3536b71674dc706381f42833b55627fd3d1f2c1b68a365b49255284b4f7b55c7
fetch $DECODER/Data/com.apple.CoreML/weights/weight.bin dbc4910c434fee657ed9f001da7abcb467d2a37ac235099c6aa47628b122ec4e

PROMPT=SAM2_1SmallPromptEncoderFLOAT16.mlpackage
fetch $PROMPT/Manifest.json b368a8e831599464347890a79c054df143c163d9928e3e0a2ab6ef7c00a425d4
fetch $PROMPT/Data/com.apple.CoreML/model.mlmodel 3a83c167d8bd63e80f86349a78c2ab0527ce97eca1f848a4ce57fe5351241fa3
fetch $PROMPT/Data/com.apple.CoreML/weights/weight.bin e29c6c65ef7754f8f6ed26155ca39ea703de3a7f576be5a7d3b8e29545059f31

swift "$ROOT_DIR/scripts/compile-coreml-package.swift" "$MODEL_DIR/$ENCODER" "$MODEL_DIR/SAM2ImageEncoder.mlmodelc"
swift "$ROOT_DIR/scripts/compile-coreml-package.swift" "$MODEL_DIR/$PROMPT" "$MODEL_DIR/SAM2PromptEncoder.mlmodelc"
swift "$ROOT_DIR/scripts/compile-coreml-package.swift" "$MODEL_DIR/$DECODER" "$MODEL_DIR/SAM2MaskDecoder.mlmodelc"
