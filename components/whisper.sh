#!/bin/bash

function dnd-run-whisper() {
  local wav="$1"
  local out_dir="$2"

  local out_json="$out_dir/$(basename "${wav%.*}").json"

  if [[ -f "$out_json" ]]; then
    dnd-log "Whisper output already present, skipping."
    return 0
  fi

  local lang_label="${DND_WHISPER_LANGUAGE:-auto}"
  dnd-log "Running Whisper  (model=$DND_WHISPER_MODEL  device=$DND_WHISPER_DEVICE  language=$lang_label)..."

  local whisper_args=(
    "$wav"
    --model "$DND_WHISPER_MODEL"
    --device "$DND_WHISPER_DEVICE"
    --output_format json
    --word_timestamps True
    --output_dir "$out_dir"
    --verbose False
  )

  if [[ -n "$DND_WHISPER_LANGUAGE" ]]; then
    whisper_args+=(--language "$DND_WHISPER_LANGUAGE")
  fi

  "${BASH_ALIASES_VENV_BIN}/whisper" "${whisper_args[@]}" > /dev/null

  if [[ -f "$out_json" ]]; then
    local detected
    detected=$(jq -r '.language // empty' "$out_json" 2>/dev/null)
    if [[ -n "$detected" ]]; then
      dnd-log "Whisper detected language: $detected"
    fi
  fi
}
