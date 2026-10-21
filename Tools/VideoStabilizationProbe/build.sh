#!/bin/zsh
set -euo pipefail
probe_repo="${0:A:h:h:h}"
probe_scratch="$probe_repo/.build/video-stabilization-baseline"
probe_sdk="${PME_PROBE_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p "$probe_scratch"
cd "$probe_repo"
swiftc -swift-version 6 -sdk "$probe_sdk" -module-cache-path "$probe_scratch/modules" \
  -parse-as-library Tools/VideoStabilizationProbe/Motion.swift Tools/VideoStabilizationProbe/MotionChecks.swift \
  -o "$probe_scratch/motion-checks"
"$probe_scratch/motion-checks"
swiftc -O -swift-version 6 -target "$(uname -m)-apple-macos15.0" -sdk "$probe_sdk" \
  -module-cache-path "$probe_scratch/modules" -parse-as-library \
  Tools/VideoStabilizationProbe/Motion.swift Tools/VideoStabilizationProbe/Probe.swift -o "$probe_scratch/probe"

# Optional external reference; no network or global installation performed here.
if [[ -n "${PME_VIDSTAB_SOURCE:-}" ]]; then
  [[ "$(git -C "$PME_VIDSTAB_SOURCE" rev-parse HEAD)" == "90c76aca2cb06c3ff6f7476a7cd6851b39436656" ]] || {
    print -u2 "Expected pinned vid.stab v1.1.1 source revision"; exit 1
  }
  probe_sources=(frameinfo transformtype libvidstab transform transformfixedpoint motiondetect motiondetect_opt \
                 serialize localmotion2transform boxblur vsvector orc/motiondetectorc)
  probe_c_files=()
  for probe_file in $probe_sources; do probe_c_files+=("$PME_VIDSTAB_SOURCE/src/$probe_file.c"); done
  clang -O2 -DDISABLE_ORC -I "$PME_VIDSTAB_SOURCE/src" \
    Tools/VideoStabilizationProbe/VidstabReference.c $probe_c_files -lm -o "$probe_scratch/vidstab-reference"
fi
print "Standalone prototype built at $probe_scratch/probe"
