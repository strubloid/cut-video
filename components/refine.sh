#!/bin/bash

function dnd-refine-cuts() {
  local ws="$1"
  local input="$2"
  local plan_json="$ws/analysis/timeline.json"
  local refined_json="$ws/analysis/timeline.refined.json"
  local audio_wav="$ws/analysis/audio.wav"
  local snap_window="${DND_SNAP_WINDOW_S:-0.5}"
  local audio_window="${DND_AUDIO_SNAP_WINDOW_S:-0.2}"

  dnd-log "Refining cut points (scene snap window=${snap_window}s, audio window=${audio_window}s)..."

  "${BASH_ALIASES_VENV_BIN}/python" \
    "$CUT_VIDEO_ROOT/python/refine.py" \
    --snap-window  "$snap_window" \
    --audio-window "$audio_window" \
    "$plan_json" "$refined_json" "$audio_wav" "$input"
}