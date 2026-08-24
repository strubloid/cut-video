#!/bin/bash

function dnd-play-segment() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    dnd-warn "Cannot play: $file not found."
    return 1
  fi
  $DND_AUDIO_PLAYER "$file" >/dev/null 2>&1 &
  local pid=$!
  wait "$pid" 2>/dev/null
}

function dnd-interactive-review() {
  local ws="$1"
  local plan_json="$ws/analysis/timeline.json"
  local decisions="$ws/decisions.json"
  local review_log="$ws/review/review.log"

  if [[ ! -f "$decisions" ]]; then
    echo '{"updated": "", "items": []}' > "$decisions"
  fi

  local total
  total=$(jq '.questionable | length' "$plan_json")
  if [[ "$total" -eq 0 ]]; then
    dnd-log "No segments require manual review. Skipping."
    return 0
  fi

  dnd-log "Manual review starts: $total segment(s) require attention."

  if [[ ! -t 0 ]] && ! { : < /dev/tty; } 2>/dev/null; then
    dnd-warn "No interactive terminal detected; auto-marking all $total questionable segment(s) as 'remove'."
    local segid
    while IFS=$'\t' read -r segid _s _e _c _reason; do
      [[ "$segid" =~ ^[0-9]+$ ]] || continue
      dnd-decisions-append "$ws" "$segid" "remove"
      printf '%s segment=%d decision=remove (auto: no tty)\n' \
        "$(date -Iseconds)" "$segid" >> "$review_log"
    done < <(jq -r '.questionable[] | "\(.id)\t\(.start)\t\(.end)\t\(.speech_confidence)\t\(.reason)"' "$plan_json")
    return 0
  fi

  local i=0
  while IFS=$'\t' read -r segid s e conf reason; do
    i=$((i + 1))

    if ! [[ "$segid" =~ ^[0-9]+$ ]]; then
      dnd-warn "[$i/$total] Skipping malformed entry (id='$segid')."
      continue
    fi

    local segfile
    segfile=$(printf 'segment-%03d.mp4' "$((segid + 1))")

    local current
    current=$(dnd-decision-for "$decisions" "$segid")
    if [[ "$current" == "restore" || "$current" == "remove" ]]; then
      dnd-log "  [$i/$total] decision already set: $current (skipping)"
      continue
    fi

    local ts_start ts_end
    ts_start=$(dnd-format-ts "${s:-0}")
    ts_end=$(dnd-format-ts "${e:-0}")

    printf '\n'
    dnd-log "[$i/$total]  segment=$segid  $ts_start -> $ts_end  ($(awk -v s="${s:-0}" -v e="${e:-0}" 'BEGIN{printf "%.2f", e-s}')s, conf=$conf)"
    dnd-log "         reason: $reason"
    dnd-log "         file:   leftovers/$segfile"

    if [[ -f "$ws/leftovers/$segfile" ]]; then
      dnd-play-segment "$ws/leftovers/$segfile" || true
    else
      dnd-warn "Leftover file missing: leftovers/$segfile -- auto-skipping (no audio to review)"
      dnd-decisions-append "$ws" "$segid" "remove"
      printf '%s segment=%d decision=remove (auto: file missing)\n' \
        "$(date -Iseconds)" "$segid" >> "$review_log"
      dnd-log "  -> auto-removed (no playable file); continuing"
      continue
    fi

    while true; do
      if ! read -r -n 1 -p "[dnd] [r]estore  [k]eep removed  [p]lay again  [s]kip  [q]uit? " choice < /dev/tty; then
        dnd-warn "Input closed; treating as 'skip' for this segment."
        printf '%s segment=%d decision=skip (auto: input closed)\n' \
          "$(date -Iseconds)" "$segid" >> "$review_log"
        break
      fi
      echo
      case "$choice" in
        r) dnd-decisions-append "$ws" "$segid" "restore"
           printf '%s segment=%d decision=restore\n' "$(date -Iseconds)" "$segid" >> "$review_log"
           dnd-log "  -> marked RESTORE"; break ;;
        k) dnd-decisions-append "$ws" "$segid" "remove"
           printf '%s segment=%d decision=remove\n'  "$(date -Iseconds)" "$segid" >> "$review_log"
           dnd-log "  -> marked REMOVE";  break ;;
        p) dnd-play-segment "$ws/leftovers/$segfile" || true; continue ;;
        s) dnd-log "  -> deferred"; break ;;
        q) dnd-log "  -> quitting (resumable)"; DND_QUIT_REQUESTED=1; return 0 ;;
        *) dnd-warn "Please press r, k, p, s or q." ;;
      esac
    done
  done < <(jq -r '.questionable[] | "\(.id)\t\(.start)\t\(.end)\t\(.speech_confidence)\t\(.reason)"' "$plan_json")

  dnd-log "Review complete. See $review_log"
}
