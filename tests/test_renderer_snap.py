"""Regression tests for the segment-snap / overlap-clip fix.

The original renderer bug: backward keyframe snap could make adjacent
keep segments overlap in source range, causing the final video to play
the same audio/frame twice. These tests exercise the pure Python
helper that the renderer now uses.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))

from segment_snap import (  # noqa: E402
    assert_no_overlap,
    compute_segment_ranges,
    prev_keyframe_at_or_before,
)


class TestPrevKeyframe(unittest.TestCase):
    def test_keyframe_exact(self):
        self.assertEqual(prev_keyframe_at_or_before([1.0, 2.0, 3.0], 2.0), 2.0)

    def test_keyframe_between(self):
        self.assertEqual(prev_keyframe_at_or_before([1.0, 2.0, 3.0], 2.5), 2.0)

    def test_before_first_keyframe(self):
        self.assertEqual(prev_keyframe_at_or_before([5.0, 6.0], 3.0), 0.0)

    def test_after_last_keyframe(self):
        self.assertEqual(prev_keyframe_at_or_before([1.0, 2.0], 10.0), 2.0)

    def test_empty_keyframes(self):
        self.assertEqual(prev_keyframe_at_or_before([], 5.0), 0.0)


class TestOverlapClip(unittest.TestCase):
    """The original bug: with backward snap and keyframes at integer
    seconds, the keep ranges `(0.0, 0.4)` and `(0.4, 6.9)` both snap
    back to keyframe 0, producing two segments that overlap in source
    range. The fix must prevent that."""

    def test_short_pause_segments_no_overlap(self):
        keep = [(0.0, 0.4), (0.4, 6.9), (6.9, 8.0)]
        keyframes = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
        out = compute_segment_ranges(keep, keyframes,
                                     backward_snap=True,
                                     boundary_epsilon=0.04)
        # No two adjacent segments overlap.
        assert_no_overlap(out)
        # The first segment must still start at or before 0.0
        # (so no audio is missed from the original range).
        self.assertLessEqual(out[0][2], 0.0)
        # Total covered time is the union of orig ranges MINUS the
        # per-segment boundary epsilon (which is a deliberate trim to
        # avoid packet-boundary duplicates).
        orig_total = sum(e - s for s, e in keep)
        actual_total = sum(ae - asc for _, _, asc, ae in out)
        self.assertAlmostEqual(actual_total, orig_total - 3 * 0.04, places=2)

    def test_long_gap_removed_segments_no_overlap(self):
        # Two speech regions with a long gap in between (which would be
        # removed in the timeline, but here we just keep all ranges).
        keep = [(0.5, 5.0), (25.0, 30.0)]
        keyframes = [i + 0.0 for i in range(0, 31)]
        out = compute_segment_ranges(keep, keyframes,
                                     backward_snap=True,
                                     boundary_epsilon=0.04)
        assert_no_overlap(out)
        # Each segment keeps its speech intact.
        self.assertLessEqual(out[0][2], 0.5)
        self.assertGreaterEqual(out[0][3], 5.0 - 0.04)
        self.assertLessEqual(out[1][2], 25.0)
        self.assertGreaterEqual(out[1][3], 30.0 - 0.04)

    def test_consecutive_keep_ranges_clip_overlap(self):
        # Two consecutive keep ranges separated by exactly one keyframe.
        # Without clipping, both would snap to that keyframe.
        keep = [(1.0, 3.0), (3.0, 5.0)]
        keyframes = [0.0, 3.0, 6.0]  # keyframes at 0, 3, 6
        out = compute_segment_ranges(keep, keyframes,
                                     backward_snap=True,
                                     boundary_epsilon=0.0)
        assert_no_overlap(out)
        # First segment starts at 0 (prev kf of 1.0).
        self.assertEqual(out[0][2], 0.0)
        # First segment ends at or before 3.0 (next actual_start).
        self.assertLessEqual(out[0][3], 3.0 + 1e-9)
        # Second segment starts at 3.0 (prev kf of 3.0).
        self.assertEqual(out[1][2], 3.0)
        # Second segment ends at or before 5.0.
        self.assertLessEqual(out[1][3], 5.0 + 1e-9)

    def test_clipping_never_misses_audio_at_first_segment(self):
        # First keep range's leading audio must survive.
        keep = [(10.0, 20.0)]
        keyframes = [0.0, 5.0, 10.0, 15.0, 20.0]
        out = compute_segment_ranges(keep, keyframes,
                                     backward_snap=True,
                                     boundary_epsilon=0.04)
        # prev_kf of 10.0 is 10.0 itself (since 10.0 is a keyframe).
        self.assertEqual(out[0][2], 10.0)
        # End is orig_end=20.0, then minus epsilon.
        self.assertAlmostEqual(out[0][3], 19.96, places=2)

    def test_clipping_does_not_shrink_first_segment(self):
        # The very first segment has no previous neighbour to clip
        # against; it must extend back to the keyframe freely.
        keep = [(10.0, 20.0)]
        keyframes = [5.0, 10.0, 15.0, 20.0]
        out = compute_segment_ranges(keep, keyframes,
                                     backward_snap=True,
                                     boundary_epsilon=0.04)
        # prev_kf of 10.0 is 10.0 (10.0 is a keyframe).
        self.assertEqual(out[0][2], 10.0)
        self.assertAlmostEqual(out[0][3], 19.96, places=2)

    def test_overlap_invariant_holds_for_many_segments(self):
        # Random-ish long timeline; the invariant must always hold.
        keep = [(i * 10.0 + 5.0, i * 10.0 + 9.0) for i in range(50)]
        keyframes = [float(i) for i in range(0, 510)]
        out = compute_segment_ranges(keep, keyframes,
                                     backward_snap=True,
                                     boundary_epsilon=0.04)
        assert_no_overlap(out)
        # Every segment must start <= its orig_start (backward snap).
        for orig_s, _, actual_s, _ in out:
            self.assertLessEqual(actual_s, orig_s + 1e-9)
        # Every segment must end >= its orig_end - epsilon.
        for _, orig_e, _, actual_e in out:
            self.assertGreaterEqual(actual_e, orig_e - 0.04 - 1e-9)

    def test_backward_snap_never_shrinks_when_no_neighbour(self):
        # No neighbours; backward snap should always be honoured.
        keep = [(100.0, 200.0)]
        keyframes = [50.0, 100.0, 150.0, 200.0]
        out = compute_segment_ranges(keep, keyframes,
                                     backward_snap=True,
                                     boundary_epsilon=0.0)
        # prev_kf of 100.0 is 100.0 (it's in the list).
        self.assertEqual(out[0][2], 100.0)
        self.assertEqual(out[0][3], 200.0)

    def test_realistic_short_pause_scenario(self):
        # Mirrors what the timeline emits for the short-pause scenario.
        keep = [
            (0.0, 0.4),    # tiny leading gap (kept)
            (0.4, 6.9),    # speech region with padding
            (6.9, 8.0),    # trailing tiny gap
        ]
        # Realistic keyframe spacing: 1 GOP at 30 fps = every ~2.5 s.
        keyframes = [0.0, 2.5, 5.0, 7.5]
        out = compute_segment_ranges(keep, keyframes,
                                     backward_snap=True,
                                     boundary_epsilon=0.04)
        assert_no_overlap(out)
        # Verify there is no overlap numerically.
        for i in range(len(out) - 1):
            self.assertLessEqual(out[i][3], out[i + 1][2] + 1e-9,
                f"segments {i} and {i+1} overlap")

    def test_empty_keep_ranges(self):
        self.assertEqual(compute_segment_ranges([], [0, 1]), [])


class TestRendererKeyframeHandoff(unittest.TestCase):
    """The renderer now shells out to `render_ranges.py` to compute the
    TSV that the stream-copy / reencode paths read. Verify the TSV
    format and the invariant end-to-end through subprocess."""

    def test_render_ranges_tsv_format(self):
        import subprocess, tempfile, json as _json
        from pathlib import Path as _P
        from fixtures import write_json
        ROOT = Path(__file__).resolve().parent.parent
        render_ranges_py = ROOT / "python" / "render_ranges.py"
        with tempfile.TemporaryDirectory() as td:
            td = _P(td)
            plan = {
                "duration": 30.0,
                "timeline": [
                    {"id": 0, "start": 0.0, "end": 0.4, "action": "keep",
                     "classification": "gap",    "speech_confidence": 0.0,
                     "duration": 0.4, "review_required": False, "reason": ""},
                    {"id": 1, "start": 0.4, "end": 6.9, "action": "keep",
                     "classification": "speech", "speech_confidence": 1.0,
                     "duration": 6.5, "review_required": False, "reason": ""},
                    {"id": 2, "start": 6.9, "end": 8.0, "action": "keep",
                     "classification": "gap",    "speech_confidence": 0.0,
                     "duration": 1.1, "review_required": False, "reason": ""},
                ],
            }
            plan_p = td / "plan.json"
            kf_p = td / "kf.txt"
            out_p = td / "ranges.tsv"
            write_json(plan_p, plan)
            kf_p.write_text("0.0\n2.5\n5.0\n7.5\n10.0\n")
            cmd = ["python3", str(render_ranges_py),
                   "--plan", str(plan_p),
                   "--keyframes", str(kf_p),
                   "--out", str(out_p),
                   "--backward-snap", "1",
                   "--epsilon", "0.04"]
            r = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0,
                f"render_ranges.py failed: {r.stderr}")
            rows = [l.split("\t") for l in out_p.read_text().strip().splitlines()]
            self.assertEqual(len(rows), 3)
            # First row's actual_start is the prev keyframe of 0.0 (= 0.0)
            # (since 0.0 is in the keyframe list).
            self.assertAlmostEqual(float(rows[0][0]), 0.0, places=2)
            # No overlap between rows.
            for i in range(len(rows) - 1):
                self.assertLessEqual(float(rows[i][1]),
                                     float(rows[i + 1][0]) + 1e-9,
                    f"row {i} ends {rows[i][1]} but row {i+1} starts {rows[i+1][0]}")


if __name__ == "__main__":
    unittest.main(verbosity=2)