#!/usr/bin/env python3
"""Snap cut points *outward* from speech so the renderer never lands on a word.

SAFETY CONTRACT (the previous version violated this):

  The refine stage MUST NOT shrink a keep region. It must only expand it
  or leave it alone. In particular:

    * `start` may only move EARLIER (smaller value). Moving it later
      would chop the front of the first word.
    * `end` may only move LATER (larger value). Moving it earlier
      would chop the tail of the last word.

  Beyond that, any "snap to scene change" / "snap to zero crossing"
  heuristics are removed: they're the exact mechanism that pulls cuts
  INTO words.

The new refine step therefore does only ONE thing: ensure every cut
sits at least `word_boundary_safety_s` outside any Whisper word, and
optionally extend a keep region outward into a longer silent zone so
the renderer has somewhere to place a clean keyframe.
"""
from __future__ import annotations

import argparse
import json
import sys

import numpy as np
from scipy.io import wavfile


def _find_last_word_end(start: float, end: float, word_ends: list[float]) -> float | None:
    inside = [we for we in word_ends if start <= we <= end]
    return max(inside) if inside else None


def _find_first_word_start(start: float, end: float, word_starts: list[float]) -> float | None:
    inside = [ws for ws in word_starts if start <= ws <= end]
    return min(inside) if inside else None


def _find_quietest_extension(
    data: np.ndarray, rate: int, edge: float, direction: int, max_s: float
) -> float:
    """Return a `direction=+1` -> extend right to the quietest 20 ms within
    [edge, edge + max_s]. `direction=-1` -> extend left within [edge - max_s, edge].

    Used only as an EXTENSION helper, never to pull a cut inward.
    """
    n = len(data)
    win_size = max(1, int(0.020 * rate))
    if direction >= 0:
        s0 = max(0, int(edge * rate))
        s1 = min(n, int((edge + max_s) * rate))
    else:
        s0 = max(0, int((edge - max_s) * rate))
        s1 = min(n, int(edge * rate))
    if s1 - s0 < win_size * 2:
        return edge

    seg = data[s0:s1].astype(np.float64)
    rms = []
    for i in range(0, len(seg) - win_size, win_size):
        w = seg[i:i + win_size]
        rms.append(float(np.sqrt(np.mean(w * w)) + 1e-12))
    if not rms:
        return edge
    k = int(np.argmin(rms))
    if direction >= 0:
        return (s0 + k * win_size) / rate + win_size / rate
    return (s0 + (k + 1) * win_size) / rate


def refine(
    plan_path: str,
    ref_path: str,
    wav_path: str,
    *,
    word_boundary_safety_s: float,
    extend_window_s: float,
) -> int:

    with open(plan_path) as f:
        plan = json.load(f)

    rate, data = wavfile.read(wav_path)
    if data.ndim > 1:
        data = data[:, 0]
    data = data.astype(np.float64)
    n_samples = len(data)
    duration = n_samples / rate

    timeline = list(plan["timeline"])

    word_starts = [float(w["start"]) for w in plan.get("words", [])]
    word_ends   = [float(w["end"])   for w in plan.get("words", [])]

    refined: list[dict] = []
    n_padded_left = 0
    n_padded_right = 0
    n_word_guard = 0

    for seg in timeline:
        if seg.get("action") != "keep":
            refined.append(seg)
            continue

        orig_s, orig_e = seg["start"], seg["end"]
        new_s, new_e = orig_s, orig_e

        # Word-boundary guard: ensure at least `word_boundary_safety_s`
        # of audio on each side of any word in the segment.
        first_ws = _find_first_word_start(orig_s, orig_e, word_starts)
        if first_ws is not None and (first_ws - new_s) < word_boundary_safety_s:
            new_s = max(0.0, first_ws - word_boundary_safety_s)
            n_word_guard += 1
        last_we = _find_last_word_end(orig_s, orig_e, word_ends)
        if last_we is not None and (new_e - last_we) < word_boundary_safety_s:
            new_e = min(duration, last_we + word_boundary_safety_s)
            n_word_guard += 1

        # Outward-only extension into the surrounding silence, capped by
        # the next/previous gap boundary.
        if extend_window_s > 0:
            new_s = min(new_s, _find_quietest_extension(data, rate, new_s, -1, extend_window_s))
            new_e = max(new_e, _find_quietest_extension(data, rate, new_e, +1, extend_window_s))
            if new_s < orig_s:
                n_padded_left += 1
            if new_e > orig_e:
                n_padded_right += 1

        # NEVER shrink the keep region.
        new_s = min(new_s, orig_s)
        new_e = max(new_e, orig_e)

        new_seg = dict(seg)
        new_seg["start"]   = round(new_s, 3)
        new_seg["end"]     = round(new_e, 3)
        new_seg["duration"] = round(new_e - new_s, 3)
        new_seg["original_start"] = orig_s
        new_seg["original_end"]   = orig_e
        refined.append(new_seg)

    # Re-clip adjacent keep regions so they don't overlap each other.
    refined.sort(key=lambda r: (r.get("start", 0.0), 0 if r.get("action") == "gap" else 1))
    for i in range(len(refined) - 1):
        if refined[i].get("action") == "keep" and refined[i + 1].get("action") == "keep":
            if refined[i]["end"] > refined[i + 1]["start"]:
                mid = (refined[i]["end"] + refined[i + 1]["start"]) / 2
                refined[i]["end"] = round(mid, 3)
                refined[i + 1]["start"] = round(mid, 3)

    with open(ref_path, "w") as f:
        json.dump({
            "duration": plan["duration"],
            "timeline": refined,
            "summary": plan.get("summary", {}),
            "refinement": {
                "word_boundary_safety_s": word_boundary_safety_s,
                "extend_window_s": extend_window_s,
                "kept_count":          sum(1 for s in refined if s.get("action") == "keep"),
                "removed_count":       sum(1 for s in refined if s.get("action") == "remove"),
                "word_boundary_guards": n_word_guard,
                "outward_extensions_left":  n_padded_left,
                "outward_extensions_right": n_padded_right,
                "mode": "expand-only",
            },
        }, f, indent=2)

    print(f"[refine] word-boundary guards={n_word_guard}, "
          f"outward-extend left={n_padded_left} right={n_padded_right}, "
          f"mode=expand-only",
          file=sys.stderr)
    print(f"[refine] wrote {ref_path}", file=sys.stderr)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("plan_json")
    p.add_argument("refined_json")
    p.add_argument("audio_wav")
    p.add_argument("--word-boundary-safety", type=float, default=0.30,
                   help="Minimum seconds to keep around any Whisper word (default 0.30).")
    p.add_argument("--extend-window",        type=float, default=0.25,
                   help="How far outward (in seconds) to extend cuts into adjacent silence (default 0.25).")
    args = p.parse_args()

    return refine(
        args.plan_json, args.refined_json, args.audio_wav,
        word_boundary_safety_s=args.word_boundary_safety,
        extend_window_s=args.extend_window,
    )


if __name__ == "__main__":
    sys.exit(main())