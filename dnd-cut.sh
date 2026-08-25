#!/bin/bash

set -u
set -o pipefail

CUT_VIDEO_ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

source "$CUT_VIDEO_ROOT/components/config.sh"
source "$CUT_VIDEO_ROOT/components/logger.sh"
source "$CUT_VIDEO_ROOT/components/dependencies.sh"
source "$CUT_VIDEO_ROOT/components/workspace.sh"
source "$CUT_VIDEO_ROOT/components/metadata.sh"
source "$CUT_VIDEO_ROOT/components/audio.sh"
source "$CUT_VIDEO_ROOT/components/vad.sh"
source "$CUT_VIDEO_ROOT/components/whisper.sh"
source "$CUT_VIDEO_ROOT/components/timeline.sh"
source "$CUT_VIDEO_ROOT/components/refine.sh"
source "$CUT_VIDEO_ROOT/components/renderer.sh"
source "$CUT_VIDEO_ROOT/components/finalize.sh"

function dnd-cut() {
  trap 'dnd-render-cleanup; dnd-pause-on-exit' EXIT

  if [[ $# -lt 1 ]]; then
    dnd-err "Usage: dnd-cut <video-file>"
    return 1
  fi

  local input="$1"
  if [[ ! -f "$input" ]]; then
    dnd-err "Input file not found: $input"
    return 1
  fi

  dnd-dependencies-check || return 1

  local ws
  ws=$(dnd-workspace-path "$input")
  dnd-workspace-init "$ws"

  local run_ts
  run_ts="$(date +%Y-%m-%dT%H-%M-%S)"
  export DND_LOG_FILE="$ws/logs/dnd-${run_ts}.log"
  export DND_ERROR_LOG="$ws/logs/error.log"
  : > "$DND_LOG_FILE"

  trap 'dnd-on-interrupt $?' INT TERM

  dnd-log "=== dnd-cut run start ==="
  dnd-log "Workspace: $ws"
  dnd-log "Log file:   $DND_LOG_FILE"
  dnd-log "Error log:  $DND_ERROR_LOG"
  dnd-log "Input:      $input"

  local mode="fresh"
  if dnd-has-state "$ws"; then
    mode=$(dnd-resume-prompt "$ws")
  fi

  local duration
  duration=$(dnd-extract-metadata "$input" "$ws")
  dnd-log "Video duration: ${duration}s"

  local wav="$ws/analysis/audio.wav"
  dnd-extract-audio "$input" "$wav"

  if [[ "$mode" == "fresh" || "$mode" == "reanalyze" ]]; then
    dnd-run-vad      "$wav" "$ws/analysis/vad.json"
    dnd-run-whisper  "$wav" "$ws/analysis"
  else
    if ! dnd-valid-json "$ws/analysis/vad.json"; then
      rm -f "$ws/analysis/vad.json"
      dnd-run-vad "$wav" "$ws/analysis/vad.json"
    fi
    if ! dnd-valid-json "$ws/analysis/audio.json"; then
      rm -f "$ws/analysis/audio.json"
      dnd-run-whisper "$wav" "$ws/analysis"
    fi
  fi

  if [[ "$mode" != "resume" ]] || ! dnd-valid-json "$ws/analysis/timeline.json"; then
    dnd-build-timeline "$ws" "$duration"
  fi

  local plan_json="$ws/analysis/timeline.refined.json"
  if [[ "$mode" == "resume" ]] && dnd-valid-json "$plan_json"; then
    dnd-log "Reusing existing refined timeline."
  else
    dnd-refine-cuts "$ws" "$input"
  fi

  dnd-render-from-plan "$input" "$ws/final.mp4" "$plan_json"

  dnd-print-summary "$ws" "$input"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  dnd-cut "$@"
fi
