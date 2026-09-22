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
  dnd-log "Stream-copy (backward keyframe snap + overlap clip + reset_timestamps + audio frame count cap)"

  # Probe audio: get sample rate so we can compute exact audio-frame
  # counts per segment. The audio re-encoder's `-frames:a N` cap is the
  # only way to control where the audio track of each segment ENDS.
  # We pick N such that audio duration is at most the segment duration,
  # so audio never spills over into the next segment's video at the
  # concat boundary — which is what causes the cumulative lip-sync
  # drift the user reported. (`+1.5` would round UP and let audio
  # extend past video; we round DOWN so audio ends at or before the
  # last video frame.)
  local audio_sr=48000
  local audio_framesize=1024
  local probe_out
  probe_out=$(ffprobe -v error -select_streams a:0 \
              -show_entries stream=sample_rate -of csv=p=0 "$input" 2>/dev/null | head -1)
  [[ "$probe_out" =~ ^[0-9]+$ ]] && audio_sr="$probe_out"

  local nproc
  if [[ -n "$DND_RENDER_THREADS" ]]; then
    nproc="$DND_RENDER_THREADS"
  else
    nproc=$(nproc 2>/dev/null || echo 4)
  fi
  [[ $nproc -lt 1 ]] && nproc=1
  [[ $nproc -gt 64 ]] && nproc=64

  # ---------------------------------------------------------------------
  # Pass 1: compute (actual_start, actual_end) for every keep range,
  # guaranteeing adjacent segments never overlap in source range.
  # Also compute exact audio frame counts (see note above).
  # ---------------------------------------------------------------------
  local ranges_file="$seg_dir/ranges.tsv"
  local backward_snap=1
  [[ "${DND_RENDER_BACKWARD_KEYFRAME_SNAP:-1}" == "0" ]] && backward_snap=0
  local epsilon="${DND_RENDER_BOUNDARY_EPSILON_S:-0.04}"

  "${BASH_ALIASES_VENV_BIN}/python" \
    "$CUT_VIDEO_ROOT/python/render_ranges.py" \
    --plan         "$plan_json" \
    --keyframes    "$kf_file" \
    --backward-snap "$backward_snap" \
    --epsilon       "$epsilon" \
    --out           "$ranges_file"

  local total
  total=$(wc -l < "$ranges_file")
  dnd-log "Computed $total non-overlapping segment ranges; extracting (up to $nproc parallel)..."

  DND_RENDER_PIDS=()
  local i=0
  local start_ts=$(date +%s)
  local last_pct=-1
  local last_report_ts=0
  local skipped=0

  while IFS=$'\t' read -r actual_start actual_end; do
    i=$((i + 1))
    while [[ ${#DND_RENDER_PIDS[@]} -ge $nproc ]]; do
      wait "${DND_RENDER_PIDS[0]}" 2>/dev/null
      DND_RENDER_PIDS=("${DND_RENDER_PIDS[@]:1}")
    done

    if (( $(awk -v a="$actual_start" -v b="$actual_end" 'BEGIN { print (b - a <= 0.05) ? 1 : 0 }') )); then
      skipped=$((skipped + 1))
      printf '\r[dnd] skipping seg %d (range [%s, %s] too short)  ' "$i" "$actual_start" "$actual_end" >&2
      continue
    fi

    # Compute exact audio frame count for this segment. We use FLOOR
    # (not the previous `+1.5` rounding-up fudge) so the audio track
    # is guaranteed to end at or before the last video frame. Any
    # audio that extended past the last video frame would be heard
    # over the next segment's video at the concat boundary — the
    # source of the user's lip-sync drift.
    local n_frames
    n_frames=$(awk -v s="$actual_start" -v e="$actual_end" \
                     -v sr="$audio_sr" -v fs="$audio_framesize" \
                     'BEGIN { printf("%d\n", int((e - s) * sr / fs)) }')

    local seg_file="$seg_dir/seg_$(printf '%05d' "$i").mp4"
    (
      # Video stream-copy; audio re-encode with frame-count cap.
      #
      # `-reset_timestamps 1` makes both A and V start at PTS=0 in
      # every segment file. This is the key fix for the lip-sync
      # drift: without it, V starts at the previous keyframe's PTS
      # (after backward snap) which is typically 1-3 seconds before
      # A's start. When concat'd, that pre-roll is preserved and the
      # user perceives it as A and V drifting apart over time.
      #
      # `-frames:a N` (with the floor-rounded N computed above) caps
      # the re-encoded audio so it never extends past the last video
      # frame in the segment. The audio encoder would otherwise
      # produce a few extra samples (~21 ms = one AAC frame at 48 kHz)
      # past the segment boundary because AAC frames are atomic.
      #
      # Do NOT pass `-avoid_negative_ts make_zero`: with MP4 +
      # B-frames + stream-copy, that flag causes ffmpeg to include
      # ~50 extra audio packets past the requested `-to` boundary,
      # which then plays back as duplicated audio. The concat
      # demuxer's `-fflags +genpts` handles per-segment PTS
      # correctly without it.
      ffmpeg -y -nostdin -loglevel error \
        -ss "$actual_start" -to "$actual_end" -i "$input" \
        -c:v copy -c:a aac -b:a "$DND_AUDIO_BITRATE" \
        -frames:a "$n_frames" \
        -reset_timestamps 1 \
        "$seg_file" 2>/dev/null
    ) &
    DND_RENDER_PIDS+=($!)

    local now_ts pct
    now_ts=$(date +%s)
    pct=$(( i * 100 / total ))
    if [[ $((pct / 5)) -ne $((last_pct / 5)) ]] || (( now_ts - last_report_ts >= 3 )); then
      local elapsed=$(( now_ts - start_ts ))
      local eta="--:--"
      if [[ $i -gt 0 && $elapsed -gt 0 ]]; then
        local total_est=$(( elapsed * total / i ))
        local remain=$(( total_est - elapsed ))
        (( remain < 0 )) && remain=0
        eta=$(printf '%02d:%02d' $((remain/60)) $((remain%60)))
      fi
      printf '\r[dnd] extracting… %3d%% (%d/%d, %d parallel, ETA %s) ' "$pct" "$i" "$total" "${#DND_RENDER_PIDS[@]}" "$eta" >&2
      last_pct=$pct
      last_report_ts=$now_ts
    fi
  done < "$ranges_file"

  for pid in "${DND_RENDER_PIDS[@]}"; do
    wait "$pid" 2>/dev/null
  done
  DND_RENDER_PIDS=()
  printf '\r[dnd] extracting… 100%% (%d/%d, %d skipped)\n' "$i" "$total" "$skipped" >&2

  dnd-render-finalize "$input" "$output" "$seg_dir" "$start_ts" "$total"
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

  # Probe audio for frame count calculations.
  local audio_sr=48000
  local audio_framesize=1024
  local probe_out
  probe_out=$(ffprobe -v error -select_streams a:0 \
              -show_entries stream=sample_rate -of csv=p=0 "$input" 2>/dev/null | head -1)
  [[ "$probe_out" =~ ^[0-9]+$ ]] && audio_sr="$probe_out"

  local nproc
  if [[ -n "$DND_RENDER_THREADS" ]]; then
    nproc="$DND_RENDER_THREADS"
  else
    nproc=$(nproc 2>/dev/null || echo 4)
  fi
  [[ $nproc -lt 1 ]] && nproc=1
  [[ $nproc -gt 64 ]] && nproc=64

  dnd-log "Re-encoding $keep_count keep-segments into $seg_dir using up to $nproc parallel jobs..."

  # Same 2-pass strategy for the re-encode path: compute non-overlapping
  # ranges first, then extract in parallel.
  local kf_file="$seg_dir/keyframes.txt"
  if ffprobe -v error -select_streams v -skip_frame nokey \
      -show_entries frame=pts_time -of csv=p=0 "$input" > "$kf_file" 2>/dev/null; then
    : # ok
  else
    : > "$kf_file"
  fi
  local ranges_file="$seg_dir/ranges.tsv"
  local backward_snap=1
  [[ "${DND_RENDER_BACKWARD_KEYFRAME_SNAP:-1}" == "0" ]] && backward_snap=0
  local epsilon="${DND_RENDER_BOUNDARY_EPSILON_S:-0.04}"

  "${BASH_ALIASES_VENV_BIN}/python" \
    "$CUT_VIDEO_ROOT/python/render_ranges.py" \
    --plan         "$plan_json" \
    --keyframes    "$kf_file" \
    --backward-snap "$backward_snap" \
    --epsilon       "$epsilon" \
    --out           "$ranges_file"

  DND_RENDER_PIDS=()
  local i=0
  local start_ts=$(date +%s)
  local last_pct=-1
  local last_report_ts=0

  while IFS=$'\t' read -r actual_start actual_end; do
    i=$((i + 1))
    while [[ ${#DND_RENDER_PIDS[@]} -ge $nproc ]]; do
      wait "${DND_RENDER_PIDS[0]}" 2>/dev/null
      DND_RENDER_PIDS=("${DND_RENDER_PIDS[@]:1}")
    done

    # Compute exact audio frame count for this segment. See the note
    # in dnd-render-stream-copy for why we FLOOR (no `+1.5` fudge):
    # we want audio duration ≤ video duration so audio never spills
    # over into the next segment's video at the concat boundary.
    local n_frames
    n_frames=$(awk -v s="$actual_start" -v e="$actual_end" \
                     -v sr="$audio_sr" -v fs="$audio_framesize" \
                     'BEGIN { printf("%d\n", int((e - s) * sr / fs)) }')

    local seg_file="$seg_dir/seg_$(printf '%05d' "$i").mp4"
    (
      # Re-encode video + audio with frame-count cap on audio.
      #
      # `-reset_timestamps 1` is the key fix for lip-sync drift: it
      # makes both A and V start at PTS=0 in every segment so the
      # concat demuxer's `-fflags +genpts` produces a clean output.
      # Without it, V starts at the previous keyframe's PTS (after
      # backward snap) which is typically 1-3 s before A's start,
      # and the user perceives it as cumulative A/V drift.
      #
      # `-frames:a N` (with the floor-rounded N computed above) caps
      # the re-encoded audio so it never extends past the last video
      # frame in the segment. The audio encoder would otherwise
      # produce ~21 ms of extra audio past the boundary.
      ffmpeg -y -nostdin -loglevel error \
        -i "$input" -ss "$actual_start" -to "$actual_end" \
        -c:v "$video_codec" -preset "$video_preset" "${quality_flag[@]}" \
        -c:a aac -b:a "$DND_AUDIO_BITRATE" -frames:a "$n_frames" \
        -reset_timestamps 1 \
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
  done < "$ranges_file"

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