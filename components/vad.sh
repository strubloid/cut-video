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

  "${BASH_ALIASES_VENV_BIN}/python" \
    "$CUT_VIDEO_ROOT/python/vad.py" \
    --min-speech-ms "$min_speech_ms" \
    "$wav" "$out"
}