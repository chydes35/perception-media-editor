#!/bin/zsh
# Gate G7 for timeline export: runs RealVideoExportTests.uhdExportThroughput (60 s of UHD V-Log,
# V-Log input LUT, ProRes 422 HQ at UHD) in release and samples, twice a second, the physical
# footprint of the test process plus every VTDecoderXPCService that was not running before (video
# decoding happens out of process). Prints the idle baseline, the peak and the peak over idle, and
# the swap-outs during the run.
#
# Usage: PME_VIDEO_SAMPLE=/Volumes/ExSSD1/Pictures/110_PANA/P1107157.MOV \
#        PME_VLOG_LUT='/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT/Panasonic/V-Log to V-709.cube' \
#        scripts/profile-video.sh
# Optional: PME_EXPORT_PRESET=hevc, PME_EXPORT_DIR=<folder on a disk with ~6 GB free>.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${PME_VIDEO_SAMPLE:?set PME_VIDEO_SAMPLE}"
: "${PME_VLOG_LUT:?set PME_VLOG_LUT}"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
[[ -d $SDK ]] && export SDKROOT=$SDK
TEST_ARGS=(-c release --no-parallel -Xswiftc -plugin-path -Xswiftc $PLUGINS --filter RealVideoExportTests/uhdExportThroughput)

footprint_of() { # pid -> bytes (0 when gone)
  footprint --noCategories -f bytes -p "$1" 2>/dev/null | awk '/Footprint:/ { for (i = 1; i <= NF; i++) if ($i == "Footprint:") print $(i + 1); exit }' || true
}
swapouts() { vm_stat | awk '/Swapouts/ { gsub("\\.", "", $2); print $2 }'; }

typeset -A preexisting
for pid in $(pgrep -x VTDecoderXPCService || true); do preexisting[$pid]=1; done
swap_before=$(swapouts)
log=$(mktemp -t pme-profile-video)
swift test "${TEST_ARGS[@]}" >"$log" 2>&1 &
runner=$!

helper=""
# `swift test` builds first (several minutes in release); sampling starts once the test process runs.
for _ in {1..2400}; do
  helper=$(pgrep -f "swiftpm-testing-helper.*uhdExportThroughput" | head -1 || true)
  [[ -n $helper ]] && break
  sleep 0.5
done
[[ -z $helper ]] && { echo "The test process did not start; see $log"; wait $runner || true; exit 1; }

baseline="" peak=0 peak_app=0 peak_decoder=0
while kill -0 $helper 2>/dev/null; do
  app=$(footprint_of $helper); app=${app:-0}
  decoder=0
  for pid in $(pgrep -x VTDecoderXPCService || true); do
    [[ -n ${preexisting[$pid]:-} ]] && continue
    d=$(footprint_of $pid); decoder=$(( decoder + ${d:-0} ))
  done
  total=$(( app + decoder ))
  [[ -z $baseline ]] && baseline=$total
  (( total > peak )) && peak=$total
  (( app > peak_app )) && peak_app=$app
  (( decoder > peak_decoder )) && peak_decoder=$decoder
  sleep 0.5
done
wait $runner && rc=0 || rc=$?
swap_after=$(swapouts)

grep -E "EXPORT G1|✘|Test run with" "$log" || true
mb() { echo $(( $1 / 1048576 )); }
echo "G7 export: idle $(mb $baseline) MB, peak $(mb $peak) MB (app peak $(mb $peak_app) MB, decoder peak $(mb $peak_decoder) MB), over idle $(mb $(( peak - baseline ))) MB (limit 600)"
echo "Swap-outs during the run: $(( swap_after - swap_before )) pages"
echo "Full test log: $log"
exit $rc
