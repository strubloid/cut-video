"""Compute the actual source-range a renderer will extract for each segment.

Given the timeline's keep ranges and the input video's keyframe times, this
module returns per-segment `(actual_start, actual_end)` pairs that
**never overlap** between adjacent segments. This is the property that
prevents the final cut from showing the same audio/frame twice.

Two operations are performed:

  1. **Backward keyframe snap** (default) — each segment's `actual_start`
     is the latest keyframe at or before the timeline's `start`. This
     can only ADD audio to a segment (because the keyframe is earlier
     than the cut point) so it never chops a word.

  2. **Overlap clip** — after step 1, each segment's `actual_start` is
     clipped forward to be at least the previous segment's
     `actual_end`, and each segment's `actual_end` is clipped backward
     to be at most the next segment's `actual_start`. The result is
     that adjacent segments touch at their boundaries but never overlap.

The function is pure and side-effect-free so it can be unit-tested
without ffmpeg.
"""
from __future__ import annotations

from typing import Iterable


def prev_keyframe_at_or_before(keyframes: list[float], t: float) -> float:
    """Return the latest keyframe timestamp <= t.

    Returns 0.0 if `t` is before the first keyframe.
    """
    best = 0.0
    for k in keyframes:
        if k <= t:
            best = k
        else:
            break
    return best


def compute_segment_ranges(
    keep_ranges: list[tuple[float, float]],
    keyframes: list[float],
    *,
    backward_snap: bool = True,
    boundary_epsilon: float = 0.0,
) -> list[tuple[float, float, float, float]]:
    """Return [(orig_start, orig_end, actual_start, actual_end), ...].

    The output preserves the order of `keep_ranges`. `orig_*` is the
    timeline's keep range, `actual_*` is the source range the renderer
    should extract (`-ss actual_start -to actual_end`).

    Invariant: for every i < j, the actual ranges do not overlap.

    `boundary_epsilon` (seconds) trims each segment's end by this much
    to avoid sharing a packet at the cut boundary in stream-copy mode.
    A value of 0.04 (~1 frame at 25 fps) is safe for typical MP4s.
    """
    if not keep_ranges:
        return []

    sorted_kf = sorted(keyframes)

    # Step 1: compute raw actual_starts.
    raw: list[tuple[float, float, float]] = []
    for orig_s, orig_e in keep_ranges:
        if backward_snap:
            actual_s = prev_keyframe_at_or_before(sorted_kf, orig_s)
        else:
            # Forward snap to the next keyframe (legacy / unsafe).
            nxt = None
            for k in sorted_kf:
                if k >= orig_s:
                    nxt = k
                    break
            actual_s = nxt if nxt is not None else orig_s
        raw.append((orig_s, orig_e, actual_s))

    # Step 2: clip actual_starts to be >= previous segment's orig_end.
    clipped: list[tuple[float, float, float]] = []
    prev_end = 0.0
    for orig_s, orig_e, actual_s in raw:
        if actual_s < prev_end:
            actual_s = prev_end
        clipped.append((orig_s, orig_e, actual_s))
        prev_end = orig_e

    # Step 3: compute actual_ends = min(orig_end, next_actual_start).
    out: list[tuple[float, float, float, float]] = []
    for i, (orig_s, orig_e, actual_s) in enumerate(clipped):
        actual_e = orig_e
        if i + 1 < len(clipped):
            next_actual_s = clipped[i + 1][2]
            if next_actual_s < actual_e:
                actual_e = next_actual_s
        if actual_e - boundary_epsilon > actual_s:
            actual_e -= boundary_epsilon
        else:
            # Pathological: would invert the segment. Fall back to orig_end.
            actual_e = orig_e
        out.append((orig_s, orig_e, actual_s, actual_e))

    return out


def assert_no_overlap(ranges: list[tuple[float, float, float, float]]) -> None:
    """Raise AssertionError if any two adjacent actual ranges overlap."""
    for i in range(len(ranges) - 1):
        _, _, _, actual_e = ranges[i]
        _, _, next_actual_s, _ = ranges[i + 1]
        if actual_e > next_actual_s + 1e-9:
            raise AssertionError(
                f"segments {i} and {i+1} overlap in source range: "
                f"segment {i} ends at {actual_e}, segment {i+1} starts at {next_actual_s}"
            )