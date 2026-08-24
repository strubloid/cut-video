#!/bin/bash

function dnd-print-summary() {
  local ws="$1"
  local input="$2"
  local plan_json="$ws/analysis/timeline.json"

  local orig_dur final_dur keep_dur removed_dur removed_segments kept_segments
  orig_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input")
  final_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$ws/final.mp4" 2>/dev/null || echo "n/a")
  keep_dur=$(jq '[.timeline[] | select(.action=="keep")] | map(.duration) | add // 0' "$plan_json")
  removed_dur=$(jq '[.timeline[] | select(.action=="remove")] | map(.duration) | add // 0' "$plan_json")
  kept_segments=$(jq '[.timeline[] | select(.action=="keep")] | length' "$plan_json")
  removed_segments=$(jq '[.timeline[] | select(.action=="remove")] | length' "$plan_json")

  cat <<EOF
============================================================
  DND video cut summary
============================================================
  Original duration : ${orig_dur}s
  Kept duration     : ${keep_dur}s  (${kept_segments} segments)
  Removed duration  : ${removed_dur}s  (${removed_segments} segments)
  Final duration    : ${final_dur}s
  Final output      : $ws/final.mp4
============================================================
EOF
}
