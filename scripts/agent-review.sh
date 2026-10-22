#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
MODE="${1:-all}"

cd "$ROOT_DIR"

# Generated sources (OCIOGeneratedShaders.swift) have lines hundreds of thousands of characters
# long. Whole matching lines of that size make CI logs unreadable and can truncate them, so
# every search shows a short preview instead.
RG_OPTS=(--max-columns 240 --max-columns-preview)

header() {
    print "## $1"
    print
}

workflow_review() {
    header "Workflow reviewer"
    print "Checks the photo workflow surface for the production features currently expected."
    print
    print "Photo workspace controls:"
    rg "${RG_OPTS[@]}" -n "Slider\(|Picker\(|HistogramView|PhotoComparisonView|ForEach\(store\.presets" Sources/PerceptionEditor/PhotoWorkspace.swift || true
    print
    print "Known workflow gaps:"
    rg "${RG_OPTS[@]}" -n "interactive crop|Batch|RAW|LUT|metadata|watermark|undo|redo|zoom|mask|curve" docs Sources README.md -i || true
}

renderer_review() {
    header "Renderer performance reviewer"
    print "Checks for synchronous preview work and the current render boundaries."
    print
    rg "${RG_OPTS[@]}" -n "renderer\.preview|renderer\.histogram|context\.render|createCGImage|cacheImmediately|useSoftwareRenderer" Sources/PerceptionEditor
    print
    print "Review focus: move repeated full-image preview and histogram work off the main interaction path, then add measured debounce/cancellation."
}

schema_review() {
    header "Project schema reviewer"
    print "Checks the non-destructive project model and migration guardrails."
    print
    rg "${RG_OPTS[@]}" -n "currentSchemaVersion|schemaVersion|CodingKeys|decodeIfPresent|ProjectDocumentError" Sources/PerceptionEditor/EditorModels.swift Sources/PerceptionEditor/ProjectDocument.swift Tests/PerceptionEditorTests
    print
    print "Review focus: every new adjustment or agent result that becomes persistent needs a schema revision and a backward-compatibility check."
}

compatibility_review() {
    header "Media compatibility reviewer"
    print "Checks imported media types, color assumptions, and video metadata coverage."
    print
    rg "${RG_OPTS[@]}" -n "allowedContentTypes|rawImage|movie|audio|sRGB|pixelWidth|pixelHeight|durationSeconds|preferredTransform" Sources/PerceptionEditor
    print
    print "Review focus: RAW camera matrix, HDR/wide-gamut color, mixed orientation, frame rate, audio layout, and long-form performance still need fixture coverage."
}

release_review() {
    header "Release QA reviewer"
    print "Checks repository hygiene and reports the verification commands that should run before release."
    print
    print "Unfinished markers:"
    rg "${RG_OPTS[@]}" -n "TODO|FIXME|planned|deferred|backlog" Sources docs README.md -i || true
    print
    print "Git diff check:"
    git diff --check
    print "PASS: git diff --check"
    print
    print "Recommended verification: ./scripts/test.sh"
}

case "$MODE" in
    workflow) workflow_review ;;
    renderer) renderer_review ;;
    schema) schema_review ;;
    compatibility) compatibility_review ;;
    release) release_review ;;
    all)
        workflow_review
        renderer_review
        schema_review
        compatibility_review
        release_review
        ;;
    *)
        print -u2 "Usage: $0 [all|workflow|renderer|schema|compatibility|release]"
        exit 2
        ;;
esac
