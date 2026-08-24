#!/bin/bash

function dnd-extract-audio() {
  local input="$1"
  local wav="$2"

  if [[ -f "$wav" ]]; then return 0; fi

  dnd-log "Extracting audio -> $wav"
  ffmpeg -y -nostdin -loglevel error -i "$input" \
    -vn -ac 1 -ar 16000 -c:a pcm_s16le "$wav"
}
