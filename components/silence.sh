#!/bin/bash

function dnd-run-silence-detect() {
  local wav="$1"
  local out="$2"

  if [[ -f "$out" ]]; then
    dnd-log "Silence-detect already present, skipping."
    return 0
  fi

  local noise_db="${DND_SILENCEDETECT_NOISE_DB:--35}"
  local min_dur="${DND_SILENCEDETECT_MIN_DURATION:-0.5}"

  dnd-log "Running ffmpeg silencedetect (noise=${noise_db}dB, min_duration=${min_dur}s)..."

  "${BASH_ALIASES_VENV_BIN}/python" \
    "$CUT_VIDEO_ROOT/python/silence_detect.py" \
    --noise-db      "$noise_db" \
    --min-duration  "$min_dur" \
    --input-wav     "$wav" \
    --output-json   "$out"
}