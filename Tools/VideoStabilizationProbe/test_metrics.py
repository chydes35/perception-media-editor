import tempfile
import unittest
import json
import subprocess
from fractions import Fraction
from pathlib import Path
import run


class MetricChecks(unittest.TestCase):
    def test_native_encoder_preserves_exact_fractional_source_pts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            movie = root / "fractional.mov"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=size=64x64:rate=24000/1001",
                            "-frames:v", "4", "-c:v", "prores_ks", "-video_track_timescale", "24000", str(movie)], check=True)
            subprocess.run([str(run.PROBE), str(movie), str(root / "output"), "none", "0", "1", "64", "render"],
                           check=True, capture_output=True, timeout=30)
            report = json.loads((root / "output/motion.json").read_text())
            data = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                              "-show_entries", "stream=time_base:frame=pts", "-of", "json",
                              str(root / "output/diagnostic.mov")], text=True))
            base = Fraction(data["streams"][0]["time_base"])
            encoded = [int(f["pts"]) * base for f in data["frames"]]
            original = [Fraction(s["value"], s["timescale"]) for s in report["samples"]]
            self.assertEqual(encoded, [t-original[0] for t in original])

    def test_irregular_fixture_actually_contains_unequal_pts_intervals(self):
        with tempfile.TemporaryDirectory() as directory:
            movie = Path(directory) / "irregular.mov"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=size=64x64:rate=24",
                            "-vf", run.irregular_filter(), "-frames:v", "4", "-fps_mode", "vfr",
                            "-enc_time_base", "1:24000", "-video_track_timescale", "24000",
                            "-c:v", "prores_ks", str(movie)], check=True)
            data = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                              "-show_entries", "frame=pts_time", "-of", "json", str(movie)], text=True))
            times = [float(f["pts_time"]) for f in data["frames"]]
            self.assertAlmostEqual(times[1], 0.05, places=6)
            self.assertNotAlmostEqual(times[1]-times[0], times[2]-times[1], places=5)

    def test_reads_actual_darwin_time_peak_memory_label(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "time.log"
            log.write_text(" 46514176 maximum resident set size\n 27756416 peak memory footprint\n")
            result = run.process_memory(log)
            self.assertEqual(result["peakPhysicalFootprintMiB"], 27756416 / 1048576)
            self.assertEqual(result["peakRSSMiB"], 46514176 / 1048576)

    def test_time_linear_pan_has_zero_acceleration_with_irregular_pts(self):
        samples = [{"value": t, "timescale": 1000, "path": {"x": 0.03*t, "y": -0.01*t},
                    "valid": True, "segment": 0} for t in [0, 40, 103, 150, 229]]
        self.assertAlmostEqual(run.jitter({"samples": samples}), 0, places=8)

    def test_rejected_triplets_cannot_create_a_false_jitter_score(self):
        samples = [{"value": t, "timescale": 24, "path": {"x": t*1000, "y": 0},
                    "valid": t != 1, "segment": 0} for t in range(3)]
        self.assertIsNone(run.jitter({"samples": samples}))


if __name__ == "__main__":
    unittest.main()
