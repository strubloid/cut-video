#!/bin/bash

function dnd-extract-leftovers() {
  local ws="$1"
  local input="$2"
  local plan_json="$ws/analysis/timeline.json"

  local leftovers_dir="$ws/leftovers"
  rm -rf "$leftovers_dir"
  mkdir -p "$leftovers_dir"

  local qcount
  qcount=$(jq '.questionable | length' "$plan_json")

  if [[ "$qcount" -eq 0 ]]; then
    dnd-log "No questionable segments to review."
    jq -n '{segments: [], generated: now|todate}' > "$leftovers_dir/index.json"
    : > "$leftovers_dir/_concat.txt"
    return 0
  fi

  dnd-log "Extracting $qcount questionable leftovers..."

  local seg_data="$leftovers_dir/.seg_data.tsv"
  jq -r '.questionable[] | [.start, .end, .speech_confidence, .reason] | @tsv' "$plan_json" > "$seg_data"

  local fc_file="$leftovers_dir/.leftovers_filter_$$.txt"
  : > "$fc_file"

  local i=0
  while IFS=$'\t' read -r s e conf reason; do
    i=$((i + 1))
    printf '[0:v]trim=start=%s:end=%s,setpts=PTS-STARTPTS[v%d];\n' \
      "$s" "$e" "$i" >> "$fc_file"
    printf '[0:a]atrim=start=%s:end=%s,asetpts=PTS-STARTPTS[a%d];\n' \
      "$s" "$e" "$i" >> "$fc_file"
  done < "$seg_data"

  local -a ffmpeg_args
  ffmpeg_args=(-y -nostdin -loglevel error -i "$input"
               -filter_complex_script "$fc_file")
  i=0
  while IFS=$'\t' read -r s e conf reason; do
    i=$((i + 1))
    ffmpeg_args+=(-map "[v$i]" -map "[a$i]"
                  "$leftovers_dir/segment-$(printf '%03d' "$i").mp4")
  done < "$seg_data"

  dnd-log "Cutting $i segments in one ffmpeg pass..."
  if ! ffmpeg "${ffmpeg_args[@]}"; then
    dnd-warn "Multi-output cut failed; falling back to per-segment loop."
    i=0
    while IFS=$'\t' read -r s e conf reason; do
      i=$((i + 1))
      local dur
      dur=$(awk -v s="$s" -v e="$e" 'BEGIN { printf "%.3f", e - s }')
      ffmpeg -y -nostdin -loglevel error \
        -i "$input" -ss "$s" -t "$dur" \
        -c copy -avoid_negative_ts make_zero \
        "$leftovers_dir/segment-$(printf '%03d' "$i").mp4"
    done < "$seg_data"
  fi

  rm -f "$fc_file" "$seg_data"

  local idx_entries=()
  while IFS=$'\t' read -r s e conf reason; do
    local dur
    dur=$(awk -v s="$s" -v e="$e" 'BEGIN { printf "%.3f", e - s }')
    idx_entries+=("$(jq -n --argjson n "$((${#idx_entries[@]} + 1))" --argjson s "$s" --argjson e "$e" --argjson d "$dur" --argjson c "$conf" --arg r "$reason" \
      '{segment: $n, start: $s, end: $e, duration: $d, speech_confidence: $c, classification: "possible_speech", reason: $r, file: ("segment-" + (("000" + ($n|tostring)) | .[length-3:]) + ".mp4")}')")
  done < <(jq -r '.questionable[] | "\(.start)\t\(.end)\t\(.speech_confidence)\t\(.reason)"' "$plan_json")

  printf '%s\n' "${idx_entries[@]}" | jq -s '{generated: now|todate, segments: .}' > "$leftovers_dir/index.json"

  local list="$leftovers_dir/_concat.txt"
  : > "$list"
  for f in "$leftovers_dir"/segment-*.mp4; do
    [[ -f "$f" ]] && printf "file '%s'\n" "$f" >> "$list"
  done

  if [[ -s "$list" ]]; then
    dnd-log "Building leftovers.mp4..."
    ffmpeg -y -nostdin -loglevel error \
      -f concat -safe 0 -i "$list" \
      -c copy "$leftovers_dir/leftovers.mp4" \
      || dnd-warn "leftovers.mp4 concat failed; individual files still available."
  fi
}
