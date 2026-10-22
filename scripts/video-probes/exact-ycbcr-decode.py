"""Exact Y'CbCr to R'G'B' for LUT references (gate G11).

ffmpeg's own limited-range float decode differs from the BT.2020 equations by up to 3.4/1023, which a
log-to-709 LUT magnifies past the gate's limit. This decodes 10-bit 4:2:2 codes exactly instead, so
the reference measures only ffmpeg's `lut3d`. Chroma is the left-sited sample, not interpolated,
like the app on even columns.

    python -I exact-ycbcr-decode.py <in.yuv422p10le> <out.gbrpf32le> <width> <height> <limited|full> <bt709|bt2020>

Needs numpy (the pinned venv from scripts/ocio/requirements.txt has it).
"""

import sys

import numpy as np

source, destination, width, height, value_range, matrix = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
kr, kb = {"bt709": (0.2126, 0.0722), "bt2020": (0.2627, 0.0593)}[matrix]
codes = np.fromfile(source, dtype="<u2").astype(np.float64)
luma = codes[: width * height].reshape(height, width)
cb = codes[width * height : width * height * 3 // 2].reshape(height, width // 2).repeat(2, axis=1)
cr = codes[width * height * 3 // 2 :].reshape(height, width // 2).repeat(2, axis=1)
if value_range == "limited":
    y, u, v = (luma - 64) / 876, (cb - 512) / 896, (cr - 512) / 896
else:
    y, u, v = luma / 1023, (cb - 512) / 1023, (cr - 512) / 1023
r = y + 2 * (1 - kr) * v
b = y + 2 * (1 - kb) * u
g = (y - kr * r - kb * b) / (1 - kr - kb)
# gbrpf32le: G, B, R planes.
np.concatenate([g.ravel(), b.ravel(), r.ravel()]).astype("<f4").tofile(destination)
