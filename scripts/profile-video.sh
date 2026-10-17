#!/bin/zsh
# Gate G7. Runs one real-footage test in release and samples, twice a second, the physical
# footprint of the test process plus every VTDecoderXPCService that was not running before (video
# decoding happens out of process). Prints the idle baseline, the peak and the peak over idle, and
# the swap-outs during the run.
#
# PME_PROFILE=export (the default): RealVideoExportTests.uhdExportThroughput, 60 s of UHD V-Log
#   through the V-Log input LUT into ProRes 422 HQ at UHD. Limit +600 MB. Needs PME_VLOG_LUT.
#   Optional: PME_EXPORT_PRESET=hevc, PME_EXPORT_DIR=<folder on a disk with ~6 GB free>.
# PME_PROFILE=playback: RealVideoPlaybackTests, a 1080p proxy of 60 s of V-Log, golden grade,
#   source color (PME_VLOG_LUT if set, ACES otherwise) and scopes, played in real time 10 times.
#   Limit +350 MB, measured from when playback starts (the test's trim and proxy generation come
#   before and are not counted); the test itself checks growth across runs (20 MB), drops and GPU time (G1).
#   Optional: PME_PLAYBACK_SECONDS, PME_PLAYBACK_REPEATS.
#
# Usage: PME_VIDEO_SAMPLE=/Volumes/ExSSD1/Pictures/110_PANA/P1107157.MOV \
#        PME_VLOG_LUT='/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT/Panasonic/V-Log to V-709.cube' \
#        scripts/profile-video.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${PME_VIDEO_SAMPLE:?set PME_VIDEO_SAMPLE}"
: "${PME_PROFILE:=export}"
case $PME_PROFILE in
  export)
    : "${PME_VLOG_LUT:?set PME_VLOG_LUT}"
    FILTER=RealVideoExportTests/uhdExportThroughput HELPER_MATCH=uhdExportThroughput LIMIT=600 REPORT="EXPORT G1" ;;
  playback)
    FILTER=RealVideoPlaybackTests HELPER_MATCH=RealVideoPlaybackTests LIMIT=350 REPORT="PLAYBACK" ;;
  *) echo "PME_PROFILE must be export or playback"; exit 2 ;;
esac
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
[[ -d $SDK ]] && export SDKROOT=$SDK
TEST_ARGS=(-c release -Xswiftc -enable-testing --no-parallel -Xswiftc -plugin-path -Xswiftc $PLUGINS --filter $FILTER)

footprint_of() { # pid -> bytes (0 when gone)
  footprint --noCategories -f bytes -p "$1" 2>/dev/null | awk '/Footprint:/ { for (i = 1; i <= NF; i++) if ($i == "Footprint:") print $(i + 1); exit }' || true
}
swapouts() { vm_stat | awk '/Swapouts/ { gsub("\\.", "", $2); print $2 }'; }

# Playback measures from a marker the test creates once its setup is done; export from the start.
marker=""
if [[ $PME_PROFILE == playback ]]; then
  marker=$(mktemp -u -t pme-profile-marker)
  export PME_PROFILE_MARKER=$marker
fi

typeset -A preexisting
for pid in $(pgrep -x VTDecoderXPCService || true); do preexisting[$pid]=1; done
swap_before=$(swapouts)
log=$(mktemp -t pme-profile-video)
swift test "${TEST_ARGS[@]}" >"$log" 2>&1 &
runner=$!

helper=""
# `swift test` builds first (several minutes in release); sampling starts once the test process runs.
for _ in {1..2400}; do
  helper=$(pgrep -f "swiftpm-testing-helper.*$HELPER_MATCH" | head -1 || true)
  [[ -n $helper ]] && break
  sleep 0.5
done
[[ -z $helper ]] && { echo "The test process did not start; see $log"; wait $runner || true; exit 1; }

baseline="" peak=0 peak_app=0 peak_decoder=0
while kill -0 $helper 2>/dev/null; do
  if [[ -n $marker && ! -e $marker ]]; then sleep 0.5; continue; fi
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
[[ -n $marker ]] && rm -f "$marker"
swap_after=$(swapouts)

grep -E "$REPORT|✘|Test run with" "$log" || true
mb() { echo $(( $1 / 1048576 )); }
start_label=$([[ -n $marker ]] && echo "start of playback" || echo "idle")
echo "G7 $PME_PROFILE: $start_label $(mb $baseline) MB, peak $(mb $peak) MB (app peak $(mb $peak_app) MB, decoder peak $(mb $peak_decoder) MB), over $start_label $(mb $(( peak - baseline ))) MB (limit $LIMIT)"
echo "Swap-outs during the run: $(( swap_after - swap_before )) pages"
echo "Full test log: $log"
exit $rc
