#!/bin/zsh
# Gate G3 reference: one frame of a V-Log clip through a .cube LUT by ffmpeg, as raw planar float
# RGB (gbrpf32le: G, B, R planes, top row first). Reads the clip and LUT only.
#   ffmpeg-lut-reference.sh <clip.MOV> <lut.cube> <output.raw> [frame]
set -euo pipefail
clip=$1; lut=$2; out=$3; frame=${4:-0}
# Full-range BT.709 Y'CbCr to R'G'B' (no range change), then the LUT with tetrahedral interpolation.
# Chroma is taken as the file says (left-sited) and not interpolated, so on even columns the decode is
# the exact sample, like the app's. With swscale's default chroma interpolation the two decoders
# differed by up to 34 of 1023 levels on saturated edges, which is not what this gate measures.
ffmpeg -v error -y -i "$clip" -vf "select=eq(n\,$frame),scale=in_range=full:out_range=full:in_color_matrix=bt709:in_chroma_loc=left:flags=neighbor+full_chroma_int+accurate_rnd+bitexact,format=gbrpf32le,lut3d=file='$lut':interp=tetrahedral" \
  -frames:v 1 -f rawvideo -pix_fmt gbrpf32le "$out"
# And the same frame without the LUT, to compare the two decoders.
ffmpeg -v error -y -i "$clip" -vf "select=eq(n\,$frame),scale=in_range=full:out_range=full:in_color_matrix=bt709:in_chroma_loc=left:flags=neighbor+full_chroma_int+accurate_rnd+bitexact,format=gbrpf32le" \
  -frames:v 1 -f rawvideo -pix_fmt gbrpf32le "${out%.raw}-decoded.raw"
ls -l "$out" "${out%.raw}-decoded.raw"
