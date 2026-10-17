#!/bin/zsh
# Gates G3 and G11 reference: one frame of a log clip through a .cube LUT by ffmpeg, as raw planar
# float RGB (gbrpf32le: G, B, R planes, top row first). Reads the clip and LUT only.
#   ffmpeg-lut-reference.sh <clip.MOV> <lut.cube> <output.raw> [frame] [range] [matrix]
# range is the file's: full (Lumix V-Log, the default) or limited (iPhone Apple Log); matrix is
# bt709 (the default) or bt2020 (Apple Log). For limited range, set PME_AVF_CODES to the frame's codes
# from avf-codes.swift to start from AVFoundation's decode, as the app does.
set -euo pipefail
clip=$1; lut=$2; out=$3; frame=${4:-0}; range=${5:-full}; matrix=${6:-bt709}
# Y'CbCr to R'G'B' in the file's range and matrix, scaled to 0…1, then the LUT with tetrahedral interpolation.
# Chroma is taken as the file says (left-sited) and not interpolated, so on even columns the decode is
# the exact sample, like the app's. With swscale's default chroma interpolation the two decoders
# differed by up to 34 of 1023 levels on saturated edges, which is not what this gate measures.
if [[ $range == limited ]]; then
  # ffmpeg's limited-range float decode is up to 3.4/1023 off the equations, which a log LUT
  # magnifies; decode the codes exactly instead (PME_PYTHON: a python with numpy, such as the
  # pinned OCIO venv), and let ffmpeg apply only the LUT.
  size=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$clip")
  codes="${out%.raw}-codes.yuv"
  if [[ -n ${PME_AVF_CODES:-} ]]; then
    # The app's own input: AVFoundation's decode, written by avf-codes.swift. ffmpeg's ProRes decoder
    # rounds up to 1 code differently, which the LUT magnifies.
    cp "$PME_AVF_CODES" "$codes"
  else
    ffmpeg -v error -y -i "$clip" -vf "select=eq(n\,$frame)" -frames:v 1 -f rawvideo -pix_fmt yuv422p10le "$codes"
  fi
  "${PME_PYTHON:-python3}" -I "$(dirname "$0")/exact-ycbcr-decode.py" "$codes" "${out%.raw}-decoded.raw" ${size%x*} ${size#*x} limited "$matrix"
  ffmpeg -v error -y -f rawvideo -pix_fmt gbrpf32le -s "$size" -i "${out%.raw}-decoded.raw" \
    -vf "lut3d=file='$lut':interp=tetrahedral" -frames:v 1 -f rawvideo -pix_fmt gbrpf32le "$out"
  rm -f "$codes"
  ls -l "$out" "${out%.raw}-decoded.raw"
  exit 0
fi
ffmpeg -v error -y -i "$clip" -vf "select=eq(n\,$frame),scale=in_range=$range:out_range=full:in_color_matrix=$matrix:in_chroma_loc=left:flags=neighbor+full_chroma_int+accurate_rnd+bitexact,format=gbrpf32le,lut3d=file='$lut':interp=tetrahedral" \
  -frames:v 1 -f rawvideo -pix_fmt gbrpf32le "$out"
# And the same frame without the LUT, to compare the two decoders.
ffmpeg -v error -y -i "$clip" -vf "select=eq(n\,$frame),scale=in_range=$range:out_range=full:in_color_matrix=$matrix:in_chroma_loc=left:flags=neighbor+full_chroma_int+accurate_rnd+bitexact,format=gbrpf32le" \
  -frames:v 1 -f rawvideo -pix_fmt gbrpf32le "${out%.raw}-decoded.raw"
ls -l "$out" "${out%.raw}-decoded.raw"
