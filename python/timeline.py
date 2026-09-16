#!/usr/bin/env python3
"""Build a conservative, segment-based edit list.

Design rules (in priority order):

  1. Preserve speech.
  2. Preserve complete words.
  3. Preserve conversations.
  4. Preserve natural conversational pauses.
  5. Remove genuinely long empty / background-only time.
  6. Reduce recording length.

This module is intentionally conservative: when in doubt, KEEP. A 10%
shorter video with all speech intact is better than a 30% shorter video
that requires recovering missing pieces from the original.

Pipeline (all in `build`):

  1. Treat every Whisper word (regardless of confidence) and every
     WebRTC-VAD region as a "potential speech" interval. Add ffmpeg's
     `silencedetect` regions as a complementary quiet-zone signal.

  2. Sort + merge intervals that touch or come within `merge_gap_s`
     seconds of each other into conversational segments.

  3. Pad every merged segment by `speech_start_padding` on the front
     and `speech_end_padding` on the back, clamped to 0..duration and
     to neighbouring segments so adjacent pads never overlap a cut.

  4. Treat the gap between two padded segments as a "candidate gap".
     A candidate gap is removed only if:
       a) its duration >= `min_remove_duration` seconds, AND
       b) it does not contain any Whisper word OR VAD activity
          (i.e. it is genuinely empty / background-only).
     Anything else is kept.

  5. Defensive word-boundary check: a cut is never placed within
     `word_boundary_safety_s` seconds of any Whisper word. This guards
     against the renderer snapping the boundary forward into the word.
"""
from __future__ import annotations

import argparse
import json
import sys
from typing import Iterable


Interval = tuple[float, float]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _merge_intervals(intervals: list[Interval], gap: float) -> list[Interval]:
    """Merge intervals whose gap is <= `gap` seconds.

    Returns intervals sorted by start, end-exclusive, then merged.
    Touching/overlapping intervals are merged as a single interval.
    """
    if not intervals:
        return []
    cleaned = sorted((max(0.0, s), e) for s, e in intervals if e > s)
    if not cleaned:
        return []
    out: list[Interval] = [cleaned[0]]
    for s, e in cleaned[1:]:
        ps, pe = out[-1]
        if s <= pe + gap:
            out[-1] = (ps, max(pe, e))
        else:
            out.append((s, e))
    return out


def _subtract_intervals(base: list[Interval], holes: list[Interval]) -> list[Interval]:
    """Return base minus holes (both lists of [start, end])."""
    if not base or not holes:
        return list(base)
    sorted_holes = sorted(holes)
    out: list[Interval] = []
    hi = 0
    for s, e in base:
        cur_s = s
        while hi < len(sorted_holes) and sorted_holes[hi][1] <= cur_s:
            hi += 1
        cur_e = e
        h = hi
        while h < len(sorted_holes) and sorted_holes[h][0] < cur_e:
            hs, he = sorted_holes[h]
            if hs > cur_s:
                out.append((cur_s, min(hs, cur_e)))
            cur_s = max(cur_s, he)
            if cur_s >= cur_e:
                break
            h += 1
        if cur_s < cur_e:
            out.append((cur_s, cur_e))
        hi = h
    return [(s, e) for s, e in out if e > s]


def _clamp_to(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def _contains_any_point(interval: Interval, points: list[float]) -> bool:
    s, e = interval
    return any(s < p < e for p in points)


# ---------------------------------------------------------------------------
# Word activity → intervals
# ---------------------------------------------------------------------------

def _words_to_intervals(words: list[dict], confidence_floor: float) -> tuple[list[Interval], list[tuple[float, float, str, float]]]:
    """Return (intervals, kept_words).

    Every Whisper word whose probability >= `confidence_floor` contributes
    its [start, end] as a candidate interval. Lowering the floor (e.g. 0.0)
    makes the algorithm strictly more conservative.
    """
    intervals: list[Interval] = []
    kept: list[tuple[float, float, str, float]] = []
    for w in words:
        prob = float(w.get("probability", 0.0) or 0.0)
        if prob < confidence_floor:
            continue
        s = float(w["start"])
        e = float(w["end"])
        if e <= s:
            continue
        intervals.append((s, e))
        kept.append((s, e, w.get("word", ""), prob))
    return intervals, kept


# ---------------------------------------------------------------------------
# Main build
# ---------------------------------------------------------------------------

def build(
    vad_path: str,
    whisper_path: str,
    silence_path: str,
    segments_out: str,
    timeline_out: str,
    *,
    duration: float,
    min_speech: float,
    min_remove: float,
    keep_threshold: float,
    pre_roll: float,
    post_roll: float,
    speech_start_padding: float,
    speech_end_padding: float,
    merge_gap_s: float,
    word_boundary_safety_s: float,
    preserve_intro_s: float,
    preserve_end_s: float,
) -> int:

    with open(vad_path) as f:
        vad = json.load(f)
    with open(whisper_path) as f:
        wh = json.load(f)

    silence_regions: list[dict] = []
    if silence_path:
        try:
            with open(silence_path) as f:
                silence_regions = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            silence_regions = []

    # ------------------------------------------------------------------
    # 1. Collect Whisper words and VAD regions.
    # ------------------------------------------------------------------
    raw_words: list[dict] = []
    for seg in wh.get("segments", []):
        no_speech_prob = float(seg.get("no_speech_prob", 0.0) or 0.0)
        if no_speech_prob > 0.6:
            continue
        for w in seg.get("words", []) or []:
            if "start" not in w or "end" not in w:
                continue
            txt = (w.get("word") or "").strip()
            if not txt:
                continue
            raw_words.append({
                "start": float(w["start"]),
                "end":   float(w["end"]),
                "probability": float(w.get("probability", 0.0) or 0.0),
                "word":  txt,
            })

    # All words, regardless of probability, become a candidate interval
    # once we drop the high-confidence floor. The user-facing threshold
    # `keep_threshold` still drives the *displayed* speech_confidence.
    word_intervals, _kept = _words_to_intervals(raw_words, confidence_floor=0.0)
    vad_intervals = [(float(r["start"]), float(r["end"])) for r in vad if r.get("end", 0) > r.get("start", 0)]

    # ------------------------------------------------------------------
    # 2. Union of all "possible speech" intervals.
    # ------------------------------------------------------------------
    possible_speech = sorted(word_intervals + vad_intervals)
    merged_activity = _merge_intervals(possible_speech, gap=merge_gap_s)

    # Drop micro-clusters (< min_speech seconds). Even here we keep the
    # word boundaries intact; this only removes truly tiny blips that
    # add nothing to the conversation.
    merged_activity = [(s, e) for s, e in merged_activity if (e - s) >= min_speech]

    # ------------------------------------------------------------------
    # 3. Pad each conversational segment.
    # ------------------------------------------------------------------
    padded: list[Interval] = []
    pad_pre  = max(pre_roll, speech_start_padding)
    pad_post = max(post_roll, speech_end_padding)
    for s, e in merged_activity:
        padded.append((_clamp_to(s - pad_pre, 0.0, duration),
                       _clamp_to(e + pad_post, 0.0, duration)))

    # ------------------------------------------------------------------
    # 4. Build the keep-list and the gap-list.
    # ------------------------------------------------------------------
    timeline: list[dict] = []
    seg_id = 0
    cursor = 0.0

    # Build a quick lookup of word timestamps for the boundary safety check.
    word_starts = [w["start"] for w in raw_words]
    word_ends   = [w["end"]   for w in raw_words]

    def _safe_extend_left(start: float, end: float) -> float:
        """Never let a left boundary land within word_boundary_safety_s of a word.

        If a Whisper word starts inside the keep region but too close to
        its left edge, push the edge LEFT (smaller value) so the cut sits
        at least `word_boundary_safety_s` BEFORE that word. Among all such
        words we take the one that requires the largest push.
        """
        new_start = start
        for ws in word_starts:
            if start <= ws <= end and ws - start < word_boundary_safety_s:
                new_start = min(new_start, ws - word_boundary_safety_s)
        return max(0.0, new_start)

    def _safe_extend_right(start: float, end: float) -> float:
        """Never let a right boundary land within word_boundary_safety_s of a word.

        If a Whisper word ends inside the keep region but too close to its
        right edge, push the edge RIGHT (larger value) so the cut sits at
        least `word_boundary_safety_s` AFTER the trailing word.
        """
        new_end = end
        for we in word_ends:
            if start <= we <= end and end - we < word_boundary_safety_s:
                new_end = max(new_end, we + word_boundary_safety_s)
        return min(duration, new_end)

    gap_was_kept = False
    for s, e in padded:
        if s > cursor:
            gap_d = s - cursor
            gap = (cursor, s)

            # 4a. Hard floor: never cut very short gaps.
            if gap_d < min_remove:
                # Kept gap: absorb it into the next keep so we never
                # emit two adjacent kept entries that would overlap in
                # source range (the gap and the keep's pre-roll).
                gap_was_kept = True
                # cursor already points to the gap's start; the next
                # keep will start there to cover the absorbed gap.
            # 4b. Long gaps are only cut if they contain NO potential speech.
            elif _contains_any_point(gap, word_starts):
                gap_was_kept = True
            elif _contains_any_point(gap, [s for s, _ in vad_intervals]):
                gap_was_kept = True
            elif any(gap[0] < ve < gap[1] for ve in word_ends):
                gap_was_kept = True
            else:
                decision = "remove"
                reason = ("Long quiet gap with no VAD/Whisper activity "
                          f"(>= {min_remove:.2f}s).")
                speech_conf = 0.0
                timeline.append({
                    "id": seg_id,
                    "start":  round(cursor, 3),
                    "end":    round(s, 3),
                    "duration": round(gap_d, 3),
                    "classification": "gap",
                    "speech_confidence": speech_conf,
                    "action":  decision,
                    "review_required": False,
                    "reason":  reason,
                })
                seg_id += 1

        # Emit the keep segment with word-boundary safety extension.
        # If the preceding gap was kept-and-absorbed, the keep must
        # START at `cursor` (= the gap's start) so the absorbed gap
        # is fully covered. Otherwise we apply normal pre-roll padding.
        ks = _safe_extend_left(s, e)
        ke = _safe_extend_right(s, e)
        if gap_was_kept:
            # The absorbed gap lies in [cursor, s]. To preserve it
            # entirely, the keep must begin no later than `cursor`.
            if ks > cursor:
                ks = cursor
        else:
            # No absorbed gap: keep must not START before `cursor`
            # (which equals the previous keep's end / removed gap's end).
            if ks < cursor:
                ks = cursor
        gap_was_kept = False
        timeline.append({
            "id": seg_id,
            "start":  round(ks, 3),
            "end":    round(ke, 3),
            "duration": round(ke - ks, 3),
            "classification": "speech",
            "speech_confidence": round(keep_threshold, 3),
            "action":  "keep",
            "review_required": False,
            "reason":  "Speech/activity region with safety padding",
        })
        seg_id += 1
        cursor = ke

    # Trailing tail
    if cursor < duration - 0.01:
        gap_d = duration - cursor
        if gap_d < min_remove:
            # Trailing kept gap: if the last emitted entry was a keep,
            # fold this trailing gap into it (extend its end).
            if timeline and timeline[-1].get("action") == "keep":
                prev = timeline[-1]
                prev["end"] = round(duration, 3)
                prev["duration"] = round(duration - prev["start"], 3)
                cursor = duration
            else:
                decision = "keep"
                reason = (f"Trailing gap shorter than MIN_REMOVE_DURATION ({min_remove:.2f}s); "
                          f"kept as natural pacing.")
                speech_conf = 0.0
                timeline.append({
                    "id": seg_id,
                    "start":  round(cursor, 3),
                    "end":    round(duration, 3),
                    "duration": round(gap_d, 3),
                    "classification": "gap",
                    "speech_confidence": speech_conf,
                    "action":  decision,
                    "review_required": False,
                    "reason":  reason,
                })
                seg_id += 1
        else:
            decision = "remove"
            reason = "Trailing quiet section."
            speech_conf = 0.0
            timeline.append({
                "id": seg_id,
                "start":  round(cursor, 3),
                "end":    round(duration, 3),
                "duration": round(gap_d, 3),
                "classification": "gap",
                "speech_confidence": speech_conf,
                "action":  decision,
                "review_required": False,
                "reason":  reason,
            })
            seg_id += 1

    # ------------------------------------------------------------------
    # 5. Intro / outro preservation (presenter greeting / end screen).
    # ------------------------------------------------------------------
    timeline = _apply_boundary_preservation(
        timeline, duration,
        preserve_intro_s=preserve_intro_s,
        preserve_end_s=preserve_end_s,
    )

    # ------------------------------------------------------------------
    # 6. Write outputs.
    # ------------------------------------------------------------------
    classified: list[dict] = []
    for r in timeline:
        classified.append({
            "id": r["id"],
            "start": r["start"],
            "end":   r["end"],
            "duration": r["duration"],
            "classification": r["classification"],
            "speech_confidence": r["speech_confidence"],
            "action": r["action"],
            "review_required": False,
            "reason": r["reason"],
        })

    keep_seconds   = round(sum(r["duration"] for r in timeline if r["action"] == "keep"), 3)
    remove_seconds = round(sum(r["duration"] for r in timeline if r["action"] == "remove"), 3)

    with open(segments_out, "w") as f:
        json.dump(classified, f, indent=2)

    with open(timeline_out, "w") as f:
        json.dump({
            "duration":    round(duration, 3),
            "timeline":    timeline,
            "words":       [{"start": s, "end": e, "word": w, "probability": p}
                            for s, e, w, p in _kept],
            "summary": {
                "keep_seconds":    keep_seconds,
                "remove_seconds":  remove_seconds,
                "remove_segments": sum(1 for r in timeline if r["action"] == "remove"),
                "keep_segments":   sum(1 for r in timeline if r["action"] == "keep"),
                "silence_inputs":  len(silence_regions),
                "vad_regions":     len(vad),
                "whisper_words":   len(raw_words),
            },
            "inputs": {
                "silence_regions": silence_regions,
            },
        }, f, indent=2)

    print(f"[timeline] keep={keep_seconds:.2f}s remove={remove_seconds:.2f}s "
          f"(keep segs={sum(1 for r in timeline if r['action']=='keep')}, "
          f"remove segs={sum(1 for r in timeline if r['action']=='remove')})",
          file=sys.stderr)
    return 0


def _apply_boundary_preservation(
    timeline: list[dict],
    duration: float,
    *,
    preserve_intro_s: float,
    preserve_end_s: float,
) -> list[dict]:
    """Force every region overlapping [0, intro] or [duration-end, duration] to be kept."""
    out: list[dict] = []
    for r in timeline:
        if preserve_intro_s > 0 and r["start"] < preserve_intro_s:
            split_at = min(preserve_intro_s, r["end"])
            before = dict(r)
            before["end"] = round(split_at, 3)
            before["duration"] = round(split_at - r["start"], 3)
            before["action"] = "keep"
            before["classification"] = "speech"
            before["reason"] = f"Preserved intro region (within first {preserve_intro_s}s)"
            out.append(before)
            if r["end"] > preserve_intro_s:
                after = dict(r)
                after["start"] = round(preserve_intro_s, 3)
                after["duration"] = round(r["end"] - preserve_intro_s, 3)
                out.append(after)
            continue
        if preserve_end_s > 0 and r["end"] > duration - preserve_end_s:
            start_split = max(0.0, duration - preserve_end_s)
            if r["start"] < start_split:
                before = dict(r)
                before["end"] = round(start_split, 3)
                before["duration"] = round(start_split - r["start"], 3)
                out.append(before)
            tail = dict(r)
            tail["start"] = round(max(start_split, r["start"]), 3)
            tail["end"]   = round(r["end"], 3)
            tail["duration"] = round(tail["end"] - tail["start"], 3)
            tail["action"] = "keep"
            tail["classification"] = "speech"
            tail["reason"] = f"Preserved outro region (within last {preserve_end_s}s)"
            out.append(tail)
            continue
        out.append(r)
    return out


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("vad_json")
    p.add_argument("whisper_json")
    p.add_argument("silence_json")
    p.add_argument("segments_out")
    p.add_argument("timeline_out")
    p.add_argument("--duration",                 type=float, required=True)
    p.add_argument("--min-speech",               type=float, default=0.25)
    p.add_argument("--min-remove",               type=float, default=4.0,
                   help="Minimum gap duration to be considered for removal (seconds).")
    p.add_argument("--keep-threshold",           type=float, default=0.40,
                   help="Whisper word confidence used for the displayed keep-region label.")
    p.add_argument("--pre-roll",                 type=float, default=0.6,
                   help="Backwards-compat alias for speech_start_padding.")
    p.add_argument("--post-roll",                type=float, default=0.7,
                   help="Backwards-compat alias for speech_end_padding.")
    p.add_argument("--speech-start-padding",     type=float, default=0.6,
                   help="Seconds of audio kept BEFORE each speech region.")
    p.add_argument("--speech-end-padding",       type=float, default=0.7,
                   help="Seconds of audio kept AFTER each speech region.")
    p.add_argument("--merge-gap",                type=float, default=1.5,
                   help="Intervals closer than this are merged into one conversational segment.")
    p.add_argument("--word-boundary-safety",     type=float, default=0.30,
                   help="Minimum seconds of audio to keep around any Whisper word before a cut.")
    p.add_argument("--preserve-intro",           type=float, default=0.0,
                   help="Force the first N seconds to be kept (presenter greeting).")
    p.add_argument("--preserve-end",             type=float, default=0.0,
                   help="Force the last N seconds to be kept (outro / end screen).")
    args = p.parse_args()

    return build(
        args.vad_json, args.whisper_json, args.silence_json,
        args.segments_out, args.timeline_out,
        duration=args.duration,
        min_speech=args.min_speech,
        min_remove=args.min_remove,
        keep_threshold=args.keep_threshold,
        pre_roll=args.pre_roll,
        post_roll=args.post_roll,
        speech_start_padding=args.speech_start_padding,
        speech_end_padding=args.speech_end_padding,
        merge_gap_s=args.merge_gap,
        word_boundary_safety_s=args.word_boundary_safety,
        preserve_intro_s=args.preserve_intro,
        preserve_end_s=args.preserve_end,
    )


if __name__ == "__main__":
    sys.exit(main())