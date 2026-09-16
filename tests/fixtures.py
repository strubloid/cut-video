"""Test fixtures: synthetic Whisper / VAD / silence inputs.

The pipeline is tested at the JSON-interface level rather than on real
audio. That means each test:

  1. Generates a synthetic `vad.json`, `audio.json`, and `silence.json`.
  2. Calls `python/timeline.py` via subprocess and inspects the
     `timeline.json` and `segments.json` it produces.
  3. Asserts on the keep/remove decisions, gap boundaries, and the
     exact audio that survives into the final cut.

For tests that need audio (e.g. the refine step), a synthetic 16 kHz
mono wav is generated with `numpy` (already a hard dep of the project).
"""
from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np


REPO_ROOT = Path(__file__).resolve().parent.parent
TIMELINE_PY = REPO_ROOT / "python" / "timeline.py"
REFINE_PY   = REPO_ROOT / "python" / "refine.py"
SILENCE_PY  = REPO_ROOT / "python" / "silence_detect.py"
VAD_PY      = REPO_ROOT / "python" / "vad.py"


def make_word(start: float, end: float, text: str, prob: float = 0.95) -> dict:
    return {"start": start, "end": end, "word": text, "probability": prob}


def make_vad(intervals: list[tuple[float, float]]) -> list[dict]:
    return [{"start": s, "end": e} for s, e in intervals]


def make_silence(intervals: list[tuple[float, float]]) -> list[dict]:
    return [{"start": s, "end": e, "duration": round(e - s, 3)} for s, e in intervals]


def write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)


def whisper_blob(words: list[dict], segments: list[dict] | None = None) -> dict:
    if segments is None:
        segments = []
        if words:
            segments.append({
                "id": 0, "start": words[0]["start"], "end": words[-1]["end"],
                "text": " ".join(w["word"] for w in words),
                "no_speech_prob": 0.01, "words": words,
            })
    return {"language": "en", "segments": segments}


def run_timeline(
    vad: list[dict],
    whisper: dict,
    silence: list[dict],
    duration: float,
    *,
    min_remove: float = 4.0,
    min_speech: float = 0.25,
    keep_threshold: float = 0.40,
    speech_start_padding: float = 0.60,
    speech_end_padding: float = 0.70,
    merge_gap: float = 1.50,
    word_boundary_safety: float = 0.30,
    preserve_intro: float = 0.0,
    preserve_end: float = 0.0,
) -> dict:
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        vad_p        = td / "vad.json"
        whisper_p    = td / "whisper.json"
        silence_p    = td / "silence.json"
        segments_p   = td / "segments.json"
        timeline_p   = td / "timeline.json"
        write_json(vad_p, vad)
        write_json(whisper_p, whisper)
        write_json(silence_p, silence)
        cmd = [
            sys.executable, str(TIMELINE_PY),
            str(vad_p), str(whisper_p), str(silence_p),
            str(segments_p), str(timeline_p),
            "--duration", str(duration),
            "--min-speech", str(min_speech),
            "--min-remove", str(min_remove),
            "--keep-threshold", str(keep_threshold),
            "--speech-start-padding", str(speech_start_padding),
            "--speech-end-padding", str(speech_end_padding),
            "--merge-gap", str(merge_gap),
            "--word-boundary-safety", str(word_boundary_safety),
            "--preserve-intro", str(preserve_intro),
            "--preserve-end", str(preserve_end),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise AssertionError(
                f"timeline.py failed (rc={result.returncode}):\n"
                f"STDOUT: {result.stdout}\nSTDERR: {result.stderr}"
            )
        with open(timeline_p) as f:
            return json.load(f)


# ---------------------------------------------------------------------------
# Audio synthesis (used by refine tests).
# ---------------------------------------------------------------------------

def synth_wav(path: Path, *, duration_s: float, sr: int = 16000,
              speech_segments: list[tuple[float, float, float]] | None = None,
              background_amp: float = 0.001) -> None:
    """Write a 16-bit mono PCM wav at `sr` Hz.

    `speech_segments` is a list of (start_s, end_s, amplitude). Outside
    those ranges the signal is just background noise (very low amplitude).
    """
    n = int(duration_s * sr)
    rng = np.random.default_rng(seed=0)
    samples = rng.normal(0, background_amp, size=n).astype(np.float32)
    if speech_segments:
        for s, e, amp in speech_segments:
            s_i = int(s * sr); e_i = int(e * sr)
            t = np.arange(e_i - s_i, dtype=np.float32) / sr
            tone = np.sin(2 * np.pi * 220.0 * t) * amp
            samples[s_i:e_i] += tone.astype(np.float32)
    samples = np.clip(samples, -1.0, 1.0)
    samples_i16 = (samples * 32767.0).astype(np.int16)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        wf.writeframes(samples_i16.tobytes())


def run_refine(
    plan: dict,
    wav_path: Path,
    *,
    word_boundary_safety: float = 0.30,
    extend_window: float = 0.25,
) -> dict:
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        plan_p   = td / "plan.json"
        refined_p = td / "refined.json"
        with open(plan_p, "w") as f:
            json.dump(plan, f)
        cmd = [
            sys.executable, str(REFINE_PY),
            str(plan_p), str(refined_p), str(wav_path),
            "--word-boundary-safety", str(word_boundary_safety),
            "--extend-window", str(extend_window),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise AssertionError(
                f"refine.py failed (rc={result.returncode}):\n"
                f"STDOUT: {result.stdout}\nSTDERR: {result.stderr}"
            )
        with open(refined_p) as f:
            return json.load(f)


# ---------------------------------------------------------------------------
# Convenience helpers for assertions.
# ---------------------------------------------------------------------------

def keep_ranges(timeline_obj: dict) -> list[tuple[float, float]]:
    return [(s["start"], s["end"]) for s in timeline_obj["timeline"] if s["action"] == "keep"]


def speech_keep_ranges(timeline_obj: dict) -> list[tuple[float, float]]:
    return [(s["start"], s["end"]) for s in timeline_obj["timeline"]
            if s["action"] == "keep" and s.get("classification") == "speech"]


def remove_ranges(timeline_obj: dict) -> list[tuple[float, float]]:
    return [(s["start"], s["end"]) for s in timeline_obj["timeline"] if s["action"] == "remove"]


def covered(intervals: list[tuple[float, float]], start: float, end: float) -> bool:
    """Return True iff [start, end] is fully covered by the union of `intervals`."""
    ivs = sorted(intervals)
    cur = start
    for s, e in ivs:
        if s > cur:
            return False
        cur = max(cur, e)
        if cur >= end:
            return True
    return cur >= end


def assert_range_preserved(timeline_obj: dict, lo: float, hi: float, *, msg: str = "") -> None:
    """Assert that the original audio in [lo, hi] survives into the final cut."""
    if not covered(keep_ranges(timeline_obj), lo, hi):
        keep = keep_ranges(timeline_obj)
        raise AssertionError(
            f"{msg or 'range not preserved'}: [{lo}, {hi}] not fully covered "
            f"by keep ranges {keep}"
        )


def assert_range_removed(timeline_obj: dict, lo: float, hi: float, *, msg: str = "") -> None:
    """Assert that the original audio in [lo, hi] is cut out."""
    if covered(keep_ranges(timeline_obj), lo, hi):
        raise AssertionError(
            f"{msg or 'range not removed'}: [{lo}, {hi}] still in keep "
            f"ranges {keep_ranges(timeline_obj)}"
        )