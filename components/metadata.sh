#!/bin/bash

function dnd-extract-metadata() {
  local input="$1"
  local ws="$2"
  local out="$ws/analysis/metadata.json"

  ffprobe -v error \
    -show_entries stream=index,codec_type,codec_name,width,height,r_frame_rate,sample_rate,channels,bit_rate \
    -show_entries format=duration,bit_rate,size,format_name \
    -of json "$input" > "$out"

  jq -r '.format.duration // empty' "$out"
}
