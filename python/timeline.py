#!/usr/bin/env python3
"""Build a classified edit list from VAD regions + Whisper word timestamps."""
from __future__ import annotations

import argparse
import json
import sys
from typing import Iterable


def expand_speech(seg: dict, pre_roll: float, post_roll: float, duration: float) -> dict:
    return {
        "start": max(0.0, seg["start"] - pre_roll),
        "end":   min(duration, seg["end"] + post_roll),
        "classification": "speech",
    }


def inside_keep(start: float, end: float, keep_ranges: list[tuple[float, float]]) -> bool:
    for ks, ke in keep_ranges:
        if start >= ks and end <= ke:
            return True
    return False


def apply_intro_preservation(classified: list[dict], preserve_intro_s: float, keep_threshold: float) -> list[dict]:
    """Force every region overlapping [0, preserve_intro_s] to be kept as speech.

    The presenter greeting at the top of a YouTube video usually has VAD
    activity but no useful Whisper transcription (it gets flagged as
    'vad_only' and removed by default). Treating the whole intro window as
    'speech/keep' preserves that greeting without changing anything past the
    window.
    """
    if preserve_intro_s <= 0:
        return classified
    new: list[dict] = []
    for r in classified:
        if r["start"] >= preserve_intro_s:
            new.append(r)
            continue
        if r["end"] <= preserve_intro_s:
            new.append(_force_keep(r, keep_threshold,
                                   f"Preserved intro region (within first {preserve_intro_s}s)"))
        else:
            intro_part = dict(r)
            intro_part["end"] = preserve_intro_s
            intro_part["duration"] = round(preserve_intro_s - r["start"], 3)
            new.append(_force_keep(intro_part, keep_threshold,
                                   f"Preserved intro region (within first {preserve_intro_s}s)"))
            after = dict(r)
            after["start"] = preserve_intro_s
            after["duration"] = round(r["end"] - preserve_intro_s, 3)
            new.append(after)
    return new


def apply_end_preservation(classified: list[dict], duration: float, preserve_end_s: float, keep_threshold: float) -> list[dict]:
    """Force every region overlapping [duration - preserve_end_s, duration] to be kept as speech.

    Mirror of apply_intro_preservation for the outro: the presenter's goodbye,
    call-to-action, and end screen all live in the last few minutes and would
    otherwise be cut by the silence-detection rules.
    """
    if preserve_end_s <= 0:
        return classified
    end_start = max(0.0, duration - preserve_end_s)
    reason = f"Preserved outro region (within last {preserve_end_s}s)"
    new: list[dict] = []
    for r in classified:
        if r["end"] <= end_start:
            new.append(r)
            continue
        if r["start"] >= end_start:
            new.append(_force_keep(r, keep_threshold, reason))
        else:
            before = dict(r)
            before["end"] = end_start
            before["duration"] = round(end_start - r["start"], 3)
            new.append(before)
            end = dict(r)
            end["start"] = end_start
            end["duration"] = round(r["end"] - end_start, 3)
            new.append(_force_keep(end, keep_threshold, reason))
    return new


def _force_keep(r: dict, keep_threshold: float, reason: str) -> dict:
    kept = dict(r)
    kept["classification"] = "speech"
    kept["action"] = "keep"
    kept["review_required"] = False
    kept["speech_confidence"] = round(keep_threshold, 3)
    kept["reason"] = reason
    return kept


def build(
    vad_path: str,
    whisper_path: str,
    segments_out: str,
    timeline_out: str,
    *,
    duration: float,
    min_speech: float,
    min_remove: float,
    keep_threshold: float,
    review_threshold: float,
    pre_roll: float,
    post_roll: float,
    preserve_intro_s: float,
    preserve_end_s: float,
) -> int:

    with open(vad_path) as f:
        vad = json.load(f)
    with open(whisper_path) as f:
        wh = json.load(f)

    words: list[dict] = []
    for seg in wh.get("segments", []):
        no_speech_prob = float(seg.get("no_speech_prob", 0.0) or 0.0)
        if no_speech_prob > 0.6:
            continue
        for w in seg.get("words", []) or []:
            if "start" not in w or "end" not in w:
                continue
            prob = float(w.get("probability", 0.0) or 0.0)
            txt = (w.get("word") or "").strip()
            if not txt:
                continue
            words.append({
                "start": float(w["start"]),
                "end":   float(w["end"]),
                "probability": prob,
                "word":  txt,
            })

    RES = 0.05
    n = int(duration / RES) + 2
    labels = ["silence"] * n

    for w in words:
        if w["probability"] < keep_threshold:
            continue
        s = max(0, int(w["start"] / RES))
        e = min(n - 1, int(w["end"] / RES))
        for i in range(s, e + 1):
            labels[i] = "speech"

    for r in vad:
        s = max(0, int(r["start"] / RES))
        e = min(n - 1, int(r["end"] / RES))
        for i in range(s, e + 1):
            if labels[i] == "silence":
                labels[i] = "vad_only"

    regions: list[tuple[str, float, float]] = []
    cur = labels[0]
    cs = 0
    for i in range(1, n):
        if labels[i] != cur:
            regions.append((cur, cs * RES, i * RES))
            cur = labels[i]
            cs = i
    regions.append((cur, cs * RES, n * RES))

    classified: list[dict] = []
    idx = 0
    for state, s, e in regions:
        d = e - s
        rec = {
            "id": idx,
            "start": round(s, 3),
            "end":   round(e, 3),
            "duration": round(d, 3),
            "classification": state,
            "speech_confidence": 0.0,
            "action": "keep",
            "review_required": False,
            "reason": "",
        }
        if state == "speech":
            rec["action"] = "keep"
            rec["reason"] = "Whisper transcribed words in this range"
            rec["speech_confidence"] = 1.0
        elif state == "vad_only":
            rec["action"] = "remove"
            rec["review_required"] = True
            rec["reason"] = "Speech-like audio without transcribed text"
            rec["speech_confidence"] = round(review_threshold, 3)
        else:
            if d < min_remove:
                rec["action"] = "keep"
                rec["reason"] = f"Silence shorter than MIN_REMOVE_DURATION ({min_remove}s)"
                rec["speech_confidence"] = 0.0
            else:
                rec["action"] = "remove"
                rec["review_required"] = False
                rec["reason"] = "No speech-like audio detected"
                rec["speech_confidence"] = 0.0
        classified.append(rec)
        idx += 1

    classified = [
        r for r in classified
        if not (r["classification"] == "speech" and r["duration"] < min_speech)
    ]

    classified = apply_intro_preservation(classified, preserve_intro_s, keep_threshold)
    classified = apply_end_preservation(classified, duration, preserve_end_s, keep_threshold)

    expanded = [expand_speech(r, pre_roll, post_roll, duration)
                for r in classified if r["classification"] == "speech"]
    expanded.sort(key=lambda x: x["start"])

    merged: list[dict] = []
    for r in expanded:
        if merged and r["start"] <= merged[-1]["end"]:
            merged[-1]["end"] = max(merged[-1]["end"], r["end"])
        else:
            merged.append(dict(r))

    timeline: list[dict] = []
    seg_id = 0
    cursor = 0.0
    for m in merged:
        if m["start"] > cursor:
            gap_d = m["start"] - cursor
            if gap_d >= min_remove:
                timeline.append({
                    "id": seg_id,
                    "start":  round(cursor, 3),
                    "end":    round(m["start"], 3),
                    "duration": round(gap_d, 3),
                    "classification": "gap",
                    "speech_confidence": 0.0,
                    "action": "remove",
                    "review_required": False,
                    "reason": "Non-speech gap between kept speech regions",
                })
                seg_id += 1
        timeline.append({
            "id": seg_id,
            "start":  round(m["start"], 3),
            "end":    round(m["end"], 3),
            "duration": round(m["end"] - m["start"], 3),
            "classification": "speech",
            "speech_confidence": 1.0,
            "action": "keep",
            "review_required": False,
            "reason": "Confirmed speech (Whisper) with padding",
        })
        seg_id += 1
        cursor = m["end"]

    if cursor < duration - 0.01:
        gap_d = duration - cursor
        if gap_d >= min_remove:
            timeline.append({
                "id": seg_id,
                "start":  round(cursor, 3),
                "end":    round(duration, 3),
                "duration": round(gap_d, 3),
                "classification": "gap",
                "speech_confidence": 0.0,
                "action": "remove",
                "review_required": False,
                "reason": "Trailing non-speech section",
            })
            seg_id += 1

    keep_ranges = [(t["start"], t["end"]) for t in timeline if t["action"] == "keep"]
    questionable: list[dict] = []
    for r in classified:
        if r["classification"] != "vad_only":
            continue
        if r["duration"] < min_speech:
            continue
        if inside_keep(r["start"], r["end"], keep_ranges):
            continue
        questionable.append({
            "id":              r["id"],
            "start":           r["start"],
            "end":             r["end"],
            "duration":        r["duration"],
            "classification":  "possible_speech",
            "speech_confidence": r["speech_confidence"],
            "action":          "remove",
            "review_required": True,
            "reason":          r["reason"],
        })

    with open(segments_out, "w") as f:
        json.dump(classified, f, indent=2)

    with open(timeline_out, "w") as f:
        json.dump({
            "duration":    round(duration, 3),
            "timeline":    timeline,
            "questionable": questionable,
            "summary": {
                "keep_seconds":    round(sum(t["duration"] for t in timeline if t["action"] == "keep"), 3),
                "remove_seconds":  round(sum(t["duration"] for t in timeline if t["action"] == "remove"), 3),
                "review_segments": len(questionable),
                "remove_segments": sum(1 for t in timeline if t["action"] == "remove"),
                "keep_segments":   sum(1 for t in timeline if t["action"] == "keep"),
            },
        }, f, indent=2)

    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("vad_json")
    p.add_argument("whisper_json")
    p.add_argument("segments_out")
    p.add_argument("timeline_out")
    p.add_argument("--duration",          type=float, required=True)
    p.add_argument("--min-speech",        type=float, required=True)
    p.add_argument("--min-remove",        type=float, required=True)
    p.add_argument("--keep-threshold",    type=float, required=True)
    p.add_argument("--review-threshold",  type=float, required=True)
    p.add_argument("--pre-roll",          type=float, required=True)
    p.add_argument("--post-roll",         type=float, required=True)
    p.add_argument("--preserve-intro",    type=float, default=0.0,
                   help="Force the first N seconds to be kept (presenter greeting).")
    p.add_argument("--preserve-end",      type=float, default=0.0,
                   help="Force the last N seconds to be kept (outro / end screen).")
    args = p.parse_args()

    return build(
        args.vad_json, args.whisper_json,
        args.segments_out, args.timeline_out,
        duration=args.duration,
        min_speech=args.min_speech,
        min_remove=args.min_remove,
        keep_threshold=args.keep_threshold,
        review_threshold=args.review_threshold,
        pre_roll=args.pre_roll,
        post_roll=args.post_roll,
        preserve_intro_s=args.preserve_intro,
        preserve_end_s=args.preserve_end,
    )


if __name__ == "__main__":
    sys.exit(main())