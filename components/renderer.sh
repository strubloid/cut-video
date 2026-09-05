#!/bin/bash

DND_RENDER_PIDS=()
DND_SEG_DIR=""

function dnd-detect-nvenc() {
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE '^\s*V[\.\w]*\s+h264_nvenc' || return 1
  ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=red:s=64x64:d=0.04 \
    -c:v h264_nvenc -f null - 2>/dev/null
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

  rm -rf "$seg_dir"
  mkdir -p "$seg_dir"
  DND_SEG_DIR="$seg_dir"

  local mode="${DND_RENDER_MODE:-auto}"
  local use_gpu="off"

  case "$mode" in
    reencode|force)
      if dnd-detect-nvenc; then use_gpu="nvenc"; else use_gpu="cpu"; fi
      ;;
    *)
      if dnd-detect-nvenc; then use_gpu="nvenc"; fi
      ;;
  esac

  if [[ "$use_gpu" == "off" ]]; then
    dnd-render-stream-copy "$input" "$output" "$plan_json" "$seg_dir" "$keep_count"
  else
    dnd-render-reencode "$input" "$output" "$plan_json" "$seg_dir" "$keep_count" "$use_gpu"
  fi
}

function dnd-render-stream-copy() {
  local input="$1"
  local output="$2"
  local plan_json="$3"
  local seg_dir="$4"
  local keep_count="$5"

  local kf_file="$seg_dir/keyframes.txt"
  if ! ffprobe -v error -select_streams v -skip_frame nokey \
      -show_entries frame=pts_time -of csv=p=0 "$input" > "$kf_file" 2>/dev/null; then
    dnd-warn "Failed to enumerate keyframes; falling back to re-encode"
    dnd-render-reencode "$input" "$output" "$plan_json" "$seg_dir" "$keep_count" "cpu"
    return $?
  fi
  local n_kf=0
  [[ -s "$kf_file" ]] && n_kf=$(wc -l < "$kf_file")
  dnd-log "Stream-copy (keyframe-snap forward): $n_kf keyframes; cuts snap forward up to ~1 GOP, no audio-only segments"

  local nproc
  if [[ -n "$DND_RENDER_THREADS" ]]; then
    nproc="$DND_RENDER_THREADS"
  else
    nproc=$(nproc 2>/dev/null || echo 4)
  fi
  [[ $nproc -lt 1 ]] && nproc=1
  [[ $nproc -gt 64 ]] && nproc=64

  dnd-log "Extracting $keep_count keep-segments into $seg_dir (up to $nproc parallel)..."

  DND_RENDER_PIDS=()
  local i=0
  local start_ts=$(date +%s)
  local last_pct=-1
  local last_report_ts=0
  local skipped=0

  while IFS=$'\t' read -r start end; do
    i=$((i + 1))
    while [[ ${#DND_RENDER_PIDS[@]} -ge $nproc ]]; do
      wait "${DND_RENDER_PIDS[0]}" 2>/dev/null
      DND_RENDER_PIDS=("${DND_RENDER_PIDS[@]:1}")
    done

    local actual_start="$start"
    if [[ $n_kf -gt 0 ]]; then
      local k
      k=$(awk -v t="$start" '$1+0 >= t+0 {print $1; exit}' "$kf_file")
      [[ -n "$k" ]] && actual_start="$k"
    fi

    if (( $(awk -v a="$actual_start" -v b="$end" 'BEGIN { print (b - a <= 0.05) ? 1 : 0 }') )); then
      skipped=$((skipped + 1))
      printf '\r[dnd] skipping seg %d (snap %s >= end %s)        ' "$i" "$actual_start" "$end" >&2
      continue
    fi

    local seg_file="$seg_dir/seg_$(printf '%05d' "$i").mp4"
    (
      ffmpeg -y -nostdin -loglevel error \
        -ss "$actual_start" -to "$end" -i "$input" \
        -c copy -avoid_negative_ts make_zero \
        "$seg_file" 2>/dev/null
    ) &
    DND_RENDER_PIDS+=($!)

    local now_ts pct
    now_ts=$(date +%s)
    pct=$(( i * 100 / keep_count ))
    if [[ $((pct / 5)) -ne $((last_pct / 5)) ]] || (( now_ts - last_report_ts >= 3 )); then
      local elapsed=$(( now_ts - start_ts ))
      local eta="--:--"
      if [[ $i -gt 0 && $elapsed -gt 0 ]]; then
        local total_est=$(( elapsed * keep_count / i ))
        local remain=$(( total_est - elapsed ))
        (( remain < 0 )) && remain=0
        eta=$(printf '%02d:%02d' $((remain/60)) $((remain%60)))
      fi
      printf '\r[dnd] extracting… %3d%% (%d/%d, %d parallel, ETA %s) ' "$pct" "$i" "$keep_count" "${#DND_RENDER_PIDS[@]}" "$eta" >&2
      last_pct=$pct
      last_report_ts=$now_ts
    fi
  done < <(jq -r '.timeline[] | select(.action=="keep") | "\(.start)\t\(.end)"' "$plan_json")

  for pid in "${DND_RENDER_PIDS[@]}"; do
    wait "$pid" 2>/dev/null
  done
  DND_RENDER_PIDS=()
  printf '\r[dnd] extracting… 100%% (%d/%d, %d skipped)\n' "$i" "$keep_count" "$skipped" >&2

  dnd-render-finalize "$input" "$output" "$seg_dir" "$start_ts" "$keep_count"
}

function dnd-render-reencode() {
  local input="$1"
  local output="$2"
  local plan_json="$3"
  local seg_dir="$4"
  local keep_count="$5"
  local use_gpu="$6"

  local video_codec="libx264"
  local video_preset="veryfast"
  local quality_flag=(-crf "$DND_VIDEO_CRF")
  if [[ "$use_gpu" == "nvenc" ]]; then
    video_codec="h264_nvenc"
    video_preset="fast"
    quality_flag=(-cq "$DND_VIDEO_CRF" -b:v 0)
    dnd-log "GPU: NVENC, using h264_nvenc -preset fast -cq $DND_VIDEO_CRF"
  else
    dnd-log "CPU: libx264 -preset veryfast -crf $DND_VIDEO_CRF"
  fi

  local nproc
  if [[ -n "$DND_RENDER_THREADS" ]]; then
    nproc="$DND_RENDER_THREADS"
  else
    nproc=$(nproc 2>/dev/null || echo 4)
  fi
  [[ $nproc -lt 1 ]] && nproc=1
  [[ $nproc -gt 64 ]] && nproc=64

  dnd-log "Re-encoding $keep_count keep-segments into $seg_dir using up to $nproc parallel jobs..."

  DND_RENDER_PIDS=()
  local i=0
  local start_ts=$(date +%s)
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
        -i "$input" -ss "$start" -to "$end" \
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
    if [[ $((pct / 5)) -ne $((last_pct / 5)) ]] || (( now_ts - last_report_ts >= 3 )); then
      local elapsed=$(( now_ts - start_ts ))
      local eta="--:--"
      if [[ $i -gt 0 && $elapsed -gt 0 ]]; then
        local total_est=$(( elapsed * keep_count / i ))
        local remain=$(( total_est - elapsed ))
        (( remain < 0 )) && remain=0
        eta=$(printf '%02d:%02d' $((remain/60)) $((remain%60)))
      fi
      printf '\r[dnd] encoding… %3d%% (%d/%d, %d parallel, ETA %s) ' "$pct" "$i" "$keep_count" "${#DND_RENDER_PIDS[@]}" "$eta" >&2
      last_pct=$pct
      last_report_ts=$now_ts
    fi
  done < <(jq -r '.timeline[] | select(.action=="keep") | "\(.start)\t\(.end)"' "$plan_json")

  for pid in "${DND_RENDER_PIDS[@]}"; do
    wait "$pid" 2>/dev/null
  done
  DND_RENDER_PIDS=()
  printf '\r[dnd] encoding… 100%% (%d/%d)\n' "$i" "$keep_count" >&2

  dnd-render-finalize "$input" "$output" "$seg_dir" "$start_ts" "$keep_count"
}

function dnd-render-finalize() {
  local input="$1"
  local output="$2"
  local seg_dir="$3"
  local start_ts="$4"
  local keep_count="$5"

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
    dnd-warn "Only $extracted of $keep_count segments produced (some skipped or failed)"
  fi

  local concat_list="$seg_dir/concat.txt"
  : > "$concat_list"
  local n_segs=0
  for seg_file in "$seg_dir"/seg_*.mp4; do
    [[ -f "$seg_file" ]] || continue
    printf "file '%s'\n" "$(basename "$seg_file")" >> "$concat_list"
    n_segs=$((n_segs + 1))
  done

  dnd-log "Concatenating $n_segs segments via concat demuxer (-c copy, +genpts)..."
  if ! ffmpeg -y -nostdin -loglevel error \
      -f concat -safe 0 -i "$concat_list" \
      -c copy -fflags +genpts -movflags +faststart \
      "$output"; then
    dnd-warn "Final concat failed; copying original as fallback to $output"
    cp -p "$input" "$output"
    dnd-render-cleanup
    return 1
  fi

  if [[ "${DND_KEEP_SEGMENTS:-1}" == "0" ]]; then
    rm -f "$seg_dir"/seg_*.mp4 "$seg_dir/concat.txt"
  fi

  local elapsed=$(( $(date +%s) - start_ts ))
  dnd-log "Render complete in $(printf '%02d:%02d' $((elapsed/60)) $((elapsed%60))): $output"
  if [[ "${DND_KEEP_SEGMENTS:-1}" != "0" ]]; then
    dnd-log "Segments kept at: $seg_dir  (set DND_KEEP_SEGMENTS=0 to clean up)"
  fi
  dnd-render-cleanup
}

function dnd-render-cleanup() {
  if [[ ${#DND_RENDER_PIDS[@]} -gt 0 ]]; then
    for pid in "${DND_RENDER_PIDS[@]}"; do
      kill "$pid" 2>/dev/null
    done
    DND_RENDER_PIDS=()
  fi
  DND_SEG_DIR=""
}