#!/bin/bash

function dnd-refine-cuts() {
  local ws="$1"
  local input="$2"
  local plan_json="$ws/analysis/timeline.json"
  local refined_json="$ws/analysis/timeline.refined.json"
  local audio_wav="$ws/analysis/audio.wav"
  local word_safety="${DND_REFINE_WORD_SAFETY_S:-0.30}"
  local extend="${DND_REFINE_EXTEND_WINDOW_S:-0.25}"

  dnd-log "Refining cut points (word safety=${word_safety}s, outward extend=${extend}s, expand-only)..."

  "${BASH_ALIASES_VENV_BIN}/python" \
    "$CUT_VIDEO_ROOT/python/refine.py" \
    --word-boundary-safety "$word_safety" \
    --extend-window        "$extend" \
    "$plan_json" "$refined_json" "$audio_wav"
}