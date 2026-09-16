#!/usr/bin/env python3
"""Compute non-overlapping source ranges for every keep segment.

Reads:
  - a timeline.json (with action=="keep" entries)
  - a keyframes file (one timestamp per line)

Writes:
  - a TSV file `actual_start<TAB>actual_end` per row

The guarantee: NO two adjacent rows overlap in source range, so when
the renderer concatenates the resulting per-segment MP4s, the final
video never plays the same audio/frame twice.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from segment_snap import assert_no_overlap, compute_segment_ranges  # noqa: E402


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--plan",         required=True, help="timeline.json path")
    p.add_argument("--keyframes",    required=True, help="keyframes.txt (one PTS per line)")
    p.add_argument("--out",          required=True, help="output TSV path")
    p.add_argument("--backward-snap", type=int,   default=1,
                   help="1 = snap each segment start to the previous keyframe "
                        "(safe); 0 = snap forward to the next keyframe (legacy).")
    p.add_argument("--epsilon",       type=float, default=0.04,
                   help="Trim each segment's end by this many seconds to avoid "
                        "sharing a packet at the cut boundary in stream-copy mode.")
    args = p.parse_args()

    with open(args.plan) as f:
        plan = json.load(f)

    keep_ranges: list[tuple[float, float]] = []
    for entry in plan.get("timeline", []):
        if entry.get("action") != "keep":
            continue
        keep_ranges.append((float(entry["start"]), float(entry["end"])))

    keyframes: list[float] = []
    kf_path = Path(args.keyframes)
    if kf_path.exists() and kf_path.stat().st_size > 0:
        for line in kf_path.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                keyframes.append(float(line))
            except ValueError:
                continue

    ranges = compute_segment_ranges(
        keep_ranges,
        keyframes,
        backward_snap=bool(args.backward_snap),
        boundary_epsilon=float(args.epsilon),
    )

    # Final safety net — should be impossible to trigger given the
    # algorithm, but we want to fail loudly if a future change ever
    # introduces overlap.
    assert_no_overlap(ranges)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w") as f:
        for _orig_s, _orig_e, actual_s, actual_e in ranges:
            f.write(f"{actual_s:.3f}\t{actual_e:.3f}\n")

    print(
        f"[render-ranges] {len(ranges)} non-overlapping ranges, "
        f"{'backward' if args.backward_snap else 'forward'} snap, "
        f"epsilon={args.epsilon}s",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())