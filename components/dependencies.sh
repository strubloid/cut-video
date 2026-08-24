#!/bin/bash

function dnd-dependencies-check() {
  local missing=()
  local have_whisper=1
  local have_vad=1

  command -v ffmpeg  >/dev/null 2>&1 || missing+=("ffmpeg")
  command -v ffprobe >/dev/null 2>&1 || missing+=("ffprobe")
  command -v jq      >/dev/null 2>&1 || missing+=("jq")
  command -v python3 >/dev/null 2>&1 || missing+=("python3")

  if [[ ! -x "${BASH_ALIASES_VENV_BIN}/whisper" ]]; then
    have_whisper=0
    missing+=("whisper (expected at ${BASH_ALIASES_VENV_BIN}/whisper)")
  fi

  if ! "${BASH_ALIASES_VENV_BIN}/python" -c "import webrtcvad, scipy.io.wavfile, numpy" 2>/dev/null; then
    have_vad=0
    missing+=("webrtcvad / scipy.io.wavfile / numpy in the bash_aliases venv")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    dnd-err "Missing dependencies:"
    for dep in "${missing[@]}"; do
      dnd-err "  - $dep"
    done
    dnd-err "Install with: ${BASH_ALIASES_VENV_BIN}/pip install webrtcvad scipy numpy"
    return 1
  fi

  dnd-log "Dependencies OK  (whisper=$have_whisper vad=$have_vad)"
  return 0
}
