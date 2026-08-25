#!/bin/bash

DND_RENDER_PIDS=()
DND_SEG_DIR=""
DND_CHUNK_DIR=""
DND_TAILER_PID=""
DND_PROG_FILE=""

function dnd-detect-nvenc() {
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE '^\s*V[\.\w]*\s+h264_nvenc'
}

function dnd-render-from-plan() {
  local input="$1"
  local output="$2"
  local plan_json="$3"

  local keep_count
  keep_count=$(jq '[.timeline[] | select(.action=="keep")] | length' "$plan_json")

  if [[ "$keep_count" -eq 0 ]]; then
    dnd-warn "Nothing to keep -- entire timeline marked remove. Copying original as fallback."
    dnd-warn "If this was unintended, edit the timeline.json in the workspace and re-run with [t]."
    cp -p "$input" "$output"
    return 0
  fi

  local ws_dir
  ws_dir="$(dirname "$output")"
  local seg_dir="${DND_SEG_DIR:-$ws_dir/.segments}"
  local chunk_dir="$ws_dir/.chunks"
  mkdir -p "$seg_dir" "$chunk_dir"
  rm -f "$chunk_dir"/chunk_*.mp4 "$chunk_dir"/concat.txt 2>/dev/null
  DND_SEG_DIR="$seg_dir"
  DND_CHUNK_DIR="$chunk_dir"

  local use_gpu="off"
  if [[ "${DND_USE_GPU:-auto}" == "auto" ]]; then
    if dnd-detect-nvenc; then use_gpu="nvenc"; fi
  elif [[ "${DND_USE_GPU}" == "on" || "${DND_USE_GPU}" == "nvenc" ]]; then
    if dnd-detect-nvenc; then use_gpu="nvenc"; else dnd-warn "DND_USE_GPU=on but h264_nvenc not available; falling back to libx264"; fi
  fi

  local video_codec="libx264"
  local video_preset="veryfast"
  local quality_flag=(-crf "$DND_VIDEO_CRF")
  if [[ "$use_gpu" == "nvenc" ]]; then
    video_codec="h264_nvenc"
    video_preset="fast"
    quality_flag=(-cq "$DND_VIDEO_CRF" -b:v 0)
    dnd-log "GPU: NVENC detected, using h264_nvenc -preset fast -cq $DND_VIDEO_CRF"
  else
    dnd-log "GPU: none, using libx264 -preset veryfast -crf $DND_VIDEO_CRF"
  fi

  dnd-log "Re-encoding $keep_count keep-segments frame-accurately into $seg_dir ..."

  local nproc
  if [[ -n "$DND_RENDER_THREADS" ]]; then
    nproc="$DND_RENDER_THREADS"
  else
    nproc=$(nproc 2>/dev/null || echo 4)
  fi
  [[ $nproc -lt 1 ]] && nproc=1
  [[ $nproc -gt 16 ]] && nproc=16

  DND_RENDER_PIDS=()
  local i=0
  local start_ts
  start_ts=$(date +%s)
  local last_pct=-1
  local last_report_ts=0

  while IFS=$'\t' read -r start end; do
    i=$((i + 1))
    while [[ ${#DND_RENDER_PIDS[@]} -ge $nproc ]]; do
      wait "${DND_RENDER_PIDS[0]}" 2>/dev/null
      DND_RENDER_PIDS=("${DND_RENDER_PIDS[@]:1}")
    done

    local seg_file="$seg_dir/seg_$(printf '%05d' "$i").mp4"
    (
      ffmpeg -y -nostdin -loglevel error \
        -ss "$start" -to "$end" -i "$input" \
        -c:v "$video_codec" -preset "$video_preset" "${quality_flag[@]}" \
        -c:a aac -b:a "$DND_AUDIO_BITRATE" \
        -pix_fmt yuv420p \
        -movflags +faststart \
        "$seg_file" 2>/dev/null
    ) &
    DND_RENDER_PIDS+=($!)

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
      printf '\r[dnd] segmenting… %3d%% (%d/%d, %d parallel, ETA %s) ' "$pct" "$i" "$keep_count" "${#DND_RENDER_PIDS[@]}" "$eta" >&2
      last_pct=$pct
      last_report_ts=$now_ts
    fi
  done < <(jq -r '.timeline[] | select(.action=="keep") | "\(.start)\t\(.end)"' "$plan_json")

  for pid in "${DND_RENDER_PIDS[@]}"; do
    wait "$pid" 2>/dev/null
  done
  DND_RENDER_PIDS=()
  printf '\r[dnd] segmenting… 100%% (%d/%d)\n' "$i" "$keep_count" >&2

  local extracted=0
  for seg_file in "$seg_dir"/seg_*.mp4; do
    [[ -f "$seg_file" ]] && extracted=$((extracted + 1))
  done
  if [[ $extracted -eq 0 ]]; then
    dnd-warn "No segments produced; copying original as fallback to $output"
    cp -p "$input" "$output"
    dnd-render-cleanup
    return 1
  fi
  if [[ $extracted -lt $keep_count ]]; then
    dnd-warn "Only $extracted of $keep_count segments produced (some failures)"
  fi

  local crossfade_s
  crossfade_s=$(awk "BEGIN { printf \"%.3f\", $DND_CROSSFADE_MS / 1000 }")
  local chunk_size="$DND_CHUNK_SIZE"
  local total_chunks=$(( (extracted + chunk_size - 1) / chunk_size ))

  dnd-log "Stitching $extracted segments into $total_chunks chunks of up to $chunk_size (${DND_CROSSFADE_MS}ms audio crossfades)..."

  local chunk_idx=0
  for ((c_start=1; c_start<=extracted; c_start+=chunk_size)); do
    chunk_idx=$((chunk_idx + 1))
    local c_end=$((c_start + chunk_size - 1))
    [[ $c_end -gt $extracted ]] && c_end=$extracted

    local chunk_file="$chunk_dir/chunk_$(printf '%05d' "$chunk_idx").mp4"
    dnd-render-chunk "$seg_dir" "$c_start" "$c_end" "$chunk_file" "$crossfade_s" \
                      "$video_codec" "$video_preset" "${quality_flag[@]}"

    local pct=$(( chunk_idx * 100 / total_chunks ))
    printf '\r[dnd] stitching… %3d%% (%d/%d chunks)' "$pct" "$chunk_idx" "$total_chunks" >&2
  done
  printf '\r[dnd] stitching… 100%% (%d/%d chunks)\n' "$chunk_idx" "$total_chunks" >&2

  local concat_list="$chunk_dir/concat.txt"
  : > "$concat_list"
  local n_chunks=0
  for chunk_file in "$chunk_dir"/chunk_*.mp4; do
    [[ -f "$chunk_file" ]] || continue
    printf "file '%s'\n" "$(basename "$chunk_file")" >> "$concat_list"
    n_chunks=$((n_chunks + 1))
  done

  dnd-log "Concatenating $n_chunks chunks into final..."
  if ! ffmpeg -y -nostdin -loglevel error \
      -f concat -safe 0 -i "$concat_list" \
      -c copy -movflags +faststart \
      "$output"; then
    dnd-warn "Final concat failed; copying original as fallback to $output"
    cp -p "$input" "$output"
    dnd-render-cleanup
    return 1
  fi

  if [[ -z "${DND_KEEP_CHUNKS:-}" ]]; then
    rm -f "$chunk_dir"/chunk_*.mp4 "$chunk_dir"/concat.txt
  fi

  local elapsed=$(( $(date +%s) - start_ts ))
  dnd-log "Render complete in $(printf '%02d:%02d' $((elapsed/60)) $((elapsed%60))): $output"
  dnd-log "Segments kept at: $seg_dir"
  dnd-render-cleanup
}

function dnd-render-chunk() {
  local seg_dir="$1"
  local start_idx="$2"
  local end_idx="$3"
  local output="$4"
  local crossfade_s="$5"
  local video_codec="$6"
  local video_preset="$7"
  shift 7
  local quality_flag=("$@")

  local n=$(( end_idx - start_idx + 1 ))

  local fc_file
  fc_file=$(mktemp -t dnd-fc-XXXXXX.txt)

  local i
  for ((i=0; i<n; i++)); do
    printf "[%d:v]null[v%d];\n[%d:a]anull[a%d];\n" "$i" "$i" "$i" "$i" >> "$fc_file"
  done

  if [[ $n -gt 1 ]]; then
    printf "[a0][a1]acrossfade=d=%s:c1=tri:c2=tri[c0];\n" "$crossfade_s" >> "$fc_file"
    for ((i=2; i<n; i++)); do
      printf "[c%d][a%d]acrossfade=d=%s:c1=tri:c2=tri[c%d];\n" "$((i-2))" "$i" "$crossfade_s" "$((i-1))" >> "$fc_file"
    done
    local final_audio_label="c$((n-2))"
  else
    local final_audio_label="a0"
  fi

  local v_inputs=""
  for ((i=0; i<n; i++)); do
    v_inputs+="[v${i}]"
  done
  printf "%sconcat=n=%d:v=1:a=0[outv];\n" "$v_inputs" "$n" >> "$fc_file"
  printf "[%s]anull[aout]\n" "$final_audio_label" >> "$fc_file"

  local input_args=()
  for ((i=start_idx; i<=end_idx; i++)); do
    input_args+=(-i "$seg_dir/seg_$(printf '%05d' "$i").mp4")
  done

  ffmpeg -y -nostdin -loglevel error \
    "${input_args[@]}" \
    -filter_complex_script "$fc_file" \
    -map "[outv]" -map "[aout]" \
    -c:v "$video_codec" -preset "$video_preset" "${quality_flag[@]}" \
    -c:a aac -b:a "$DND_AUDIO_BITRATE" \
    -pix_fmt yuv420p \
    -movflags +faststart \
    "$output" 2>/dev/null

  rm -f "$fc_file"
}

function dnd-render-cleanup() {
  if [[ ${#DND_RENDER_PIDS[@]} -gt 0 ]]; then
    for pid in "${DND_RENDER_PIDS[@]}"; do
      kill "$pid" 2>/dev/null
    done
    DND_RENDER_PIDS=()
  fi
  DND_SEG_DIR=""
  DND_CHUNK_DIR=""
  DND_TAILER_PID=""
  DND_PROG_FILE=""
}
