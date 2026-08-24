#!/bin/bash

function dnd-render-from-plan() {
  local input="$1"
  local output="$2"
  local plan_json="$3"

  local keep_count
  keep_count=$(jq '[.timeline[] | select(.action=="keep")] | length' "$plan_json")

  if [[ "$keep_count" -eq 0 ]]; then
    dnd-warn "Nothing to keep -- entire timeline marked remove. Copying original as fallback."
    dnd-warn "If this was unintended, edit the decisions.json in the workspace and re-run with [t]."
    cp -p "$input" "$output"
    return 0
  fi

  local fc_file
  fc_file="$(dirname "$output")/.filter_complex_$$.txt"
  : > "$fc_file"

  local concat_inputs=""
  local i=0
  while IFS=$'\t' read -r start end; do
    printf '[0:v]trim=start=%s:end=%s,setpts=PTS-STARTPTS[v%d];\n' \
      "$start" "$end" "$i" >> "$fc_file"
    printf '[0:a]atrim=start=%s:end=%s,asetpts=PTS-STARTPTS[a%d];\n' \
      "$start" "$end" "$i" >> "$fc_file"
    concat_inputs+="[v$i][a$i]"
    i=$((i + 1))
  done < <(jq -r '.timeline[] | select(.action=="keep") | "\(.start)\t\(.end)"' "$plan_json")

  if [[ "$i" -eq 0 ]]; then
    dnd-warn "Plan produced no keep-segments."
    cp -p "$input" "$output"
    rm -f "$fc_file"
    return 0
  fi

  printf '%sconcat=n=%d:v=1:a=1[outv][outa]\n' \
    "$concat_inputs" "$i" >> "$fc_file"

  dnd-log "Rendering $keep_count keep-segments in a single sync-safe pass..."

  if ! ffmpeg -y -nostdin -loglevel error \
      -i "$input" \
      -filter_complex_script "$fc_file" \
      -map "[outv]" -map "[outa]" \
      -c:v libx264 -preset veryfast -crf 18 \
      -c:a aac -b:a 192k \
      -movflags +faststart \
      "$output"; then
    dnd-warn "Filter-based render failed; keeping filter_complex file for debugging: $fc_file"
    dnd-warn "Copying original as fallback to $output"
    cp -p "$input" "$output"
    return 1
  fi

  rm -f "$fc_file"
}
