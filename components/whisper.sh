#!/bin/bash

function dnd-run-whisper() {
  local wav="$1"
  local out_dir="$2"

  if [[ -f "$out_dir/$(basename "${wav%.*}").json" ]]; then
    dnd-log "Whisper output already present, skipping."
    return 0
  fi

  dnd-log "Running Whisper  (model=$DND_WHISPER_MODEL  device=$DND_WHISPER_DEVICE)..."

  "${BASH_ALIASES_VENV_BIN}/whisper" "$wav" \
    --model "$DND_WHISPER_MODEL" \
    --language "$DND_WHISPER_LANGUAGE" \
    --device "$DND_WHISPER_DEVICE" \
    --output_format json \
    --word_timestamps True \
    --output_dir "$out_dir" \
    --verbose False \
    > /dev/null
}
