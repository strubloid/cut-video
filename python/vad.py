#!/usr/bin/env python3
"""WebRTC VAD over a mono 16 kHz wav -> speech-like regions as JSON."""
from __future__ import annotations

import argparse
import json
import sys

import numpy as np
import webrtcvad
from scipy.io import wavfile


def run(wav_path: str, out_path: str, min_speech_ms: int) -> int:
    sr, audio = wavfile.read(wav_path)
    if sr != 16000:
        print(f"[dnd-vad] expected 16000 Hz wav, got {sr}", file=sys.stderr)
        return 1
    if audio.ndim > 1:
        audio = audio.mean(axis=1).astype(np.int16)
    audio = np.ascontiguousarray(audio)

    vad = webrtcvad.Vad(2)

    frame_ms = 30
    frame_len = int(sr * frame_ms / 1000)
    n = len(audio) // frame_len

    regions: list[dict[str, float]] = []
    in_speech = False
    seg_start = 0.0
    for i in range(n):
        frame = audio[i * frame_len : (i + 1) * frame_len]
        if len(frame) < frame_len:
            break
        is_speech = vad.is_speech(frame.tobytes(), sr)
        t = i * frame_ms / 1000.0
        if is_speech and not in_speech:
            seg_start = t
            in_speech = True
        elif not is_speech and in_speech:
            regions.append({"start": round(seg_start, 3), "end": round(t, 3)})
            in_speech = False
    if in_speech:
        regions.append({
            "start": round(seg_start, 3),
            "end":   round(len(audio) / sr, 3),
        })

    min_dur = min_speech_ms / 1000.0
    regions = [r for r in regions if (r["end"] - r["start"]) >= min_dur]

    merged: list[dict[str, float]] = []
    for r in regions:
        if merged and (r["start"] - merged[-1]["end"]) < 0.2:
            merged[-1]["end"] = r["end"]
        else:
            merged.append(dict(r))

    with open(out_path, "w") as f:
        json.dump(merged, f, indent=2)

    print(f"[dnd-vad] {len(merged)} speech-like regions", file=sys.stderr)
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("wav", help="Input 16 kHz mono wav file")
    p.add_argument("output", help="Output JSON path")
    p.add_argument("--min-speech-ms", type=int, default=80,
                   help="Drop speech regions shorter than this (ms, min 50)")
    args = p.parse_args()

    if args.min_speech_ms < 50:
        args.min_speech_ms = 50
    return run(args.wav, args.output, args.min_speech_ms)


if __name__ == "__main__":
    sys.exit(main())