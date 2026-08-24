#!/bin/bash

function dnd-run-vad() {
  local wav="$1"
  local out="$2"

  if [[ -f "$out" ]]; then
    dnd-log "VAD already present, skipping."
    return 0
  fi

  dnd-log "Running WebRTC VAD..."

  local min_speech_ms
  min_speech_ms=$(awk -v d="$DND_MIN_SPEECH_DURATION" 'BEGIN { printf "%d", d * 1000 }')
  [[ "$min_speech_ms" -lt 50 ]] && min_speech_ms=50

  local pybin="${BASH_ALIASES_VENV_BIN}/python"
  "$pybin" - "$wav" "$out" "$min_speech_ms" <<'PYEOF'
import sys, json, os
import numpy as np
from scipy.io import wavfile

wav_path, out_path, min_speech_ms = sys.argv[1], sys.argv[2], int(sys.argv[3])

sr, audio = wavfile.read(wav_path)
if sr != 16000:
    raise SystemExit(f"expected 16000 Hz wav, got {sr}")
if audio.ndim > 1:
    audio = audio.mean(axis=1).astype(np.int16)
audio = np.ascontiguousarray(audio)

import webrtcvad
vad = webrtcvad.Vad(2)

frame_ms = 30
frame_len = int(sr * frame_ms / 1000)
n = len(audio) // frame_len
regions = []
in_speech = False
seg_start = 0
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
        regions.append({"start": round(seg_start, 3),
                        "end":   round(t, 3)})
        in_speech = False
if in_speech:
    regions.append({"start": round(seg_start, 3),
                    "end":   round(len(audio) / sr, 3)})

min_dur = min_speech_ms / 1000.0
regions = [r for r in regions if (r["end"] - r["start"]) >= min_dur]

merged = []
for r in regions:
    if merged and (r["start"] - merged[-1]["end"]) < 0.2:
        merged[-1]["end"] = r["end"]
    else:
        merged.append(dict(r))

with open(out_path, "w") as f:
    json.dump(merged, f, indent=2)

print(f"[dnd-vad] {len(merged)} speech-like regions")
PYEOF
}
