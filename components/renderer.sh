#!/bin/bash

function dnd-detect-nvenc() {
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE '^[[:space:]]*V[\.a-zA-Z0-9]*[[:space:]]+h264_nvenc[[:space:]]'
}

function dnd-detect-vaapi() {
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE '^[[:space:]]*V[\.a-zA-Z0-9]*[[:space:]]+h264_vaapi[[:space:]]'
}

function dnd-can-encode() {
  local enc="$1"
  local w=256 h=256
  if [[ "$enc" == "h264_nvenc" || "$enc" == "h264_vaapi" ]]; then
    w=256 h=256
  fi
  if ffmpeg -y -nostdin -loglevel error \
        -f lavfi -i "color=c=black:s=${w}x${h}:d=1:r=30" \
        -c:v "$enc" -frames:v 1 -f null - >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

function dnd-pick-encoder() {
  if [[ -n "${DND_FORCE_CPU:-}" ]]; then
    echo "libx264"; return
  fi
  if dnd-detect-nvenc && dnd-can-encode h264_nvenc; then
    echo "h264_nvenc"; return
  fi
  if dnd-detect-vaapi && dnd-can-encode h264_vaapi; then
    echo "h264_vaapi"; return
  fi
  echo "libx264"
}

function dnd-render-from-plan() {
  local input="$1"
  local output="$2"
  local plan_json="$3"

  local keep_count
  keep_count=$(jq '[.timeline[] | select(.action=="keep")] | length' "$plan_json")

  if [[ "$keep_count" -eq 0 ]]; then
    dnd-err "Nothing to keep -- entire timeline marked remove. Aborting render."
    dnd-err "If this was unintended, edit the timeline.json in the workspace and re-run with [t]."
    return 1
  fi

  local ws_dir
  ws_dir="$(dirname "$output")"
  local piece_dir="$ws_dir/.pieces"
  mkdir -p "$piece_dir"
  rm -f "$piece_dir/concat.txt" 2>/dev/null

  local local_input="$input"
  local local_copy="$piece_dir/.source.mp4"
  if [[ ! -f "$local_copy" ]]; then
    dnd-log "Copying source to local working dir for fast I/O..."
    if cp -p "$input" "$local_copy" 2>/dev/null && [[ -s "$local_copy" ]]; then
      local_input="$local_copy"
      dnd-log "Source copied: $(du -h "$local_copy" | cut -f1)"
    else
      dnd-warn "Could not stage source locally; rendering directly from '$input'"
      rm -f "$local_copy"
    fi
  else
    local_input="$local_copy"
    dnd-log "Reusing staged source: $local_copy"
  fi

  local enc_args enc_name enc_choice
  enc_choice=$(dnd-pick-encoder)
  case "$enc_choice" in
    h264_nvenc)
      enc_args=(-c:v h264_nvenc -preset fast -cq "${DND_VIDEO_CRF:-18}" -b:v 0 -pix_fmt yuv420p)
      enc_name="h264_nvenc (GPU)"
      ;;
    h264_vaapi)
      enc_args=(-c:v h264_vaapi -qp "${DND_VIDEO_CRF:-18}" -pix_fmt yuv420p)
      enc_name="h264_vaapi (GPU)"
      ;;
    *)
      enc_args=(-c:v libx264 -preset ultrafast -crf "${DND_VIDEO_CRF:-18}" -pix_fmt yuv420p)
      enc_name="libx264 ultrafast (CPU)"
      ;;
  esac

  local is_gpu=0
  [[ "$enc_choice" != "libx264" ]] && is_gpu=1

  local nproc
  if [[ -n "${DND_RENDER_THREADS:-}" ]]; then nproc="$DND_RENDER_THREADS"
  else
    if [[ $is_gpu -eq 1 ]]; then
      nproc=$(nproc 2>/dev/null || echo 4)
      [[ "$nproc" -gt 4 ]] && nproc=4
    else
      nproc=$(nproc 2>/dev/null || echo 4)
      [[ "$nproc" -gt 8 ]] && nproc=8
    fi
  fi
  [[ "$nproc" -lt 1 ]] && nproc=1

  dnd-log "Stage 1/2: re-encoding $keep_count keep-segments with $enc_name, $nproc parallel..."

  local i=0
  local start_ts
  start_ts=$(date +%s)
  local last_pct=-1
  local last_report_ts=0

  while IFS=$'\t' read -r start end; do
    i=$((i + 1))
    local seg_file="$piece_dir/piece_$(printf '%05d' "$i").mp4"

    if [[ -s "$seg_file" ]]; then
      : # already extracted on a previous run — skip
    else
      while [[ $(jobs -rp 2>/dev/null | wc -l) -ge "$nproc" ]]; do
        wait -n 2>/dev/null || sleep 0.05
      done

      (
        ffmpeg -y -nostdin -loglevel error \
          -i "$local_input" \
          -ss "$start" -to "$end" \
          ${DND_PER_ENCODE_THREADS:+-threads "$DND_PER_ENCODE_THREADS"} \
          "${enc_args[@]}" \
          -c:a aac -b:a "${DND_AUDIO_BITRATE:-192k}" \
          "$seg_file" 2>/dev/null
      ) &
    fi

    local now_ts pct
    now_ts=$(date +%s)
    pct=$(( i * 100 / keep_count ))
    if [[ $((pct / 2)) -ne $((last_pct / 2)) ]] || (( now_ts - last_report_ts >= 5 )); then
      local elapsed=$(( now_ts - start_ts ))
      local eta="--:--"
      if [[ $i -gt 0 && $elapsed -gt 0 ]]; then
        local total_est=$(( elapsed * keep_count / i ))
        local remain=$(( total_est - elapsed ))
        (( remain < 0 )) && remain=0
        eta=$(printf '%02d:%02d' $((remain/60)) $((remain%60)))
      fi
      printf '\r[dnd] re-encoding… %3d%% (%d/%d, %d parallel, ETA %s) ' "$pct" "$i" "$keep_count" "$(jobs -rp 2>/dev/null | wc -l)" "$eta" >&2
      last_pct=$pct
      last_report_ts=$now_ts
    fi
  done < <(jq -r '.timeline[] | select(.action=="keep") | "\(.start)\t\(.end)"' "$plan_json")

  wait
  printf '\r[dnd] re-encoding… 100%% (%d/%d)\n' "$i" "$keep_count" >&2

  local extracted=0
  for seg_file in "$piece_dir"/piece_*.mp4; do
    [[ -f "$seg_file" ]] || continue
    [[ -s "$seg_file" ]] || continue
    extracted=$((extracted + 1))
  done
  if [[ "$extracted" -eq 0 ]]; then
    dnd-err "No pieces produced. Aborting render."
    return 1
  fi
  if [[ "$extracted" -lt "$keep_count" ]]; then
    dnd-warn "Only $extracted of $keep_count pieces produced (some failures)"
  fi

  local concat_list="$piece_dir/concat.txt"
  : > "$concat_list"
  for seg_file in "$piece_dir"/piece_*.mp4; do
    [[ -f "$seg_file" ]] || continue
    [[ -s "$seg_file" ]] || continue
    printf "file '%s'\n" "$(basename "$seg_file")" >> "$concat_list"
  done

  dnd-log "Stage 2/2: concatenating $extracted pieces into final (concat copy)..."
  local _log
  _log=$(mktemp -t dnd-concat-log-XXXXXX.txt)
  if ! ffmpeg -y -nostdin \
      -f concat -safe 0 -i "$concat_list" \
      -c copy -movflags +faststart \
      "$output" 2> "$_log"; then
    local _tail
    _tail=$(tail -30 "$_log" 2>/dev/null)
    rm -f "$_log" "$concat_list"
    dnd-err "Final concat failed. Aborting render."
    dnd-err "ffmpeg stderr (last lines):"
    while IFS= read -r line; do
      dnd-err "  $line"
    done <<< "$_tail"
    rm -f "$ws_dir/final.mp4" 2>/dev/null
    return 1
  fi
  rm -f "$_log" "$concat_list"

  if [[ -z "${DND_KEEP_PIECES:-}" ]]; then
    rm -rf "$piece_dir" 2>/dev/null
  else
    rm -f "$piece_dir/.source.mp4" 2>/dev/null
  fi

  local elapsed=$(( $(date +%s) - start_ts ))
  dnd-log "Render complete in $(printf '%02d:%02d' $((elapsed/60)) $((elapsed%60))): $output"
  if [[ -n "${DND_KEEP_PIECES:-}" ]]; then
    dnd-log "Pieces kept at: $piece_dir"
  fi
}

function dnd-render-cleanup() {
  jobs -rp 2>/dev/null | xargs -r kill 2>/dev/null
  wait 2>/dev/null
}
