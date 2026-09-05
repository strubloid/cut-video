#!/bin/bash

function dnd-build-timeline() {
  local ws="$1"
  local duration="$2"
  local vad_json="$ws/analysis/vad.json"
  local whisper_json="$ws/analysis/audio.json"
  local segments_json="$ws/analysis/segments.json"
  local timeline_json="$ws/analysis/timeline.json"

  dnd-log "Building classified timeline..."

  "${BASH_ALIASES_VENV_BIN}/python" \
    "$CUT_VIDEO_ROOT/python/timeline.py" \
    --duration         "$duration" \
    --min-speech       "$DND_MIN_SPEECH_DURATION" \
    --min-remove       "$DND_MIN_REMOVE_DURATION" \
    --min-keep-silence "$DND_MIN_KEEP_SILENCE_S" \
    --keep-threshold   "$DND_SPEECH_KEEP_THRESHOLD" \
    --review-threshold "$DND_SPEECH_REVIEW_THRESHOLD" \
    --pre-roll         "$DND_PRE_ROLL" \
    --post-roll        "$DND_POST_ROLL" \
    --preserve-intro   "$DND_PRESERVE_INTRO_S" \
    --preserve-end     "$DND_PRESERVE_END_S" \
    "$vad_json" "$whisper_json" "$segments_json" "$timeline_json"
}