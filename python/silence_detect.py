#!/usr/bin/env python3
"""Run ffmpeg silencedetect over a 16 kHz mono wav and emit JSON regions.

Output schema:
    [
        {"start": 12.34, "end": 14.56, "duration": 2.22}, ...
    ]

silencedetect is treated as ONE signal among several — never as a
hard cut signal. The Python wrapper just parses the stderr stream
ffmpeg produces.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys


_START_RE = re.compile(r"silence_start:\s*(-?\d+(?:\.\d+)?)")
_END_RE = re.compile(r"silence_end:\s*(-?\d+(?:\.\d+)?)")


def parse_silence(stderr: str) -> list[dict[str, float]]:
    """Parse silencedetect stderr output into [{start,end,duration}, ...].

    Handles both complete intervals (`silence_start` followed by `silence_end`)
    and trailing intervals that run to the end of the stream
    (`silence_start` with no following `silence_end`).
    """
    intervals: list[tuple[float, float | None]] = []
    last_start: float | None = None
    for line in stderr.splitlines():
        m_s = _START_RE.search(line)
        if m_s:
            last_start = float(m_s.group(1))
            continue
        m_e = _END_RE.search(line)
        if m_e and last_start is not None:
            intervals.append((last_start, float(m_e.group(1))))
            last_start = None

    if last_start is not None:
        intervals.append((last_start, None))

    out: list[dict[str, float]] = []
    for s, e in intervals:
        if e is None:
            e = s
        dur = e - s
        if dur < 0:
            continue
        out.append({"start": round(s, 3), "end": round(e, 3), "duration": round(dur, 3)})
    return out


def run(wav_path: str, out_path: str, noise_db: float, min_duration: float) -> int:
    cmd = [
        "ffmpeg", "-hide_banner", "-nostats", "-i", wav_path,
        "-af", f"silencedetect=noise={noise_db}dB:duration={min_duration}",
        "-f", "null", "-",
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
    except subprocess.TimeoutExpired:
        print("[silence-detect] ffmpeg timed out", file=sys.stderr)
        return 1
    if proc.returncode not in (0, None):
        print(f"[silence-detect] ffmpeg exit={proc.returncode}", file=sys.stderr)

    regions = parse_silence(proc.stderr)

    with open(out_path, "w") as f:
        json.dump(regions, f, indent=2)

    print(f"[silence-detect] noise={noise_db}dB min={min_duration}s -> "
          f"{len(regions)} silence intervals ({sum(r['duration'] for r in regions):.2f}s total)",
          file=sys.stderr)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--input-wav",    required=True)
    p.add_argument("--output-json",  required=True)
    p.add_argument("--noise-db",     type=float, default=-35.0,
                   help="dBFS threshold below which audio counts as silence (default -35)")
    p.add_argument("--min-duration", type=float, default=0.5,
                   help="Minimum silence duration to report (seconds, default 0.5)")
    args = p.parse_args()
    return run(args.input_wav, args.output_json, args.noise_db, args.min_duration)


if __name__ == "__main__":
    sys.exit(main())