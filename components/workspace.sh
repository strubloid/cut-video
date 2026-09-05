#!/bin/bash

function dnd-workspace-path() {
  local input="$1"
  local dir
  local base
  dir="$(dirname "$input")"
  base="$(basename "${input%.*}")"
  printf '%s/%s.dnd-cut\n' "$dir" "$base"
}

function dnd-workspace-init() {
  local ws="$1"
  mkdir -p "$ws/analysis" "$ws/logs"
}

function dnd-has-state() {
  local ws="$1"
  [[ -f "$ws/analysis/audio.json" || -f "$ws/analysis/timeline.json" ]]
}

function dnd-resume-prompt() {
  local ws="$1"
  local choice

  if [[ "$DND_AUTO_RESUME" == "yes" ]]; then choice="r"; fi

  if [[ -z "${choice:-}" ]]; then
    dnd-log "Existing workspace detected: $ws"
    printf '\n' >&2
    dnd-log "  r  Resume           (reuse analysis + timeline, just re-render)"
    dnd-log "  t  Rebuild timeline (keep audio/VAD/Whisper, rebuild timeline + render)"
    dnd-log "  a  Re-analyze       (keep workspace, redo audio/VAD/Whisper + timeline + render)"
    dnd-log "  f  Fresh start      (wipe workspace)"
    printf '\n' >&2
    while true; do
      local ans
      printf '[dnd] Enter choice [r/t/a/f]: ' >&2
      read -r -n 1 ans
      printf '\n' >&2
      case "$ans" in
        r|t|a|f) choice="$ans"; break ;;
        *) dnd-warn "Please press r, t, a or f." ;;
      esac
    done
  fi

  case "$choice" in
    r) dnd-log "Resuming."; printf 'resume\n'; return 0 ;;
    t) rm -f "$ws/final.mp4" "$ws/analysis/timeline.json"
       dnd-log "Rebuilding timeline from existing analysis."; printf 'rebuild-timeline\n'; return 0 ;;
    a) rm -f "$ws/final.mp4" "$ws/analysis/timeline.json" \
          "$ws/analysis/audio.wav" "$ws/analysis/vad.json" "$ws/analysis/audio.json"
       dnd-log "Re-running analysis."; printf 'reanalyze\n'; return 0 ;;
    f) dnd-log "Wiping workspace."; rm -rf "$ws"; dnd-workspace-init "$ws"
       printf 'fresh\n'; return 0 ;;
  esac
}