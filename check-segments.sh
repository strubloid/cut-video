#!/bin/bash
# check-segments.sh -- diagnose .segments/ dir for audio-only / video-only files
# Usage:
#   check-segments.sh <workspace-dir>     # e.g. check-segments.sh ./AV26_sem_edicao.dnd-cut
#   check-segments.sh                    # auto-detect: look for .segments/ in cwd or parent
set -u

ws="${1:-}"

if [[ -z "$ws" ]]; then
  for cand in . ..; do
    if [[ -d "$cand/.segments" ]]; then ws="$cand"; break; fi
  done
fi

if [[ -z "$ws" ]]; then
  printf 'Usage: %s <workspace-dir>\n' "$0" >&2
  printf '  e.g. %s ./AV26_sem_edicao.dnd-cut\n' "$0" >&2
  exit 1
fi

seg_dir="$ws/.segments"
if [[ ! -d "$seg_dir" ]]; then
  printf 'No .segments directory at: %s\n' "$seg_dir" >&2
  exit 1
fi

seg_dir_abs=$(cd "$seg_dir" && pwd)
printf 'Scanning %s ...\n' "$seg_dir_abs"

segs=()
while IFS= read -r -d '' f; do
  segs+=("$f")
done < <(find "$seg_dir" -maxdepth 1 -name 'seg_*.mp4' -type f -print0 | sort -z)

total=${#segs[@]}
if [[ $total -eq 0 ]]; then
  printf 'No seg_*.mp4 files in %s\n' "$seg_dir_abs" >&2
  exit 0
fi

both=0
audio_only=0
video_only=0
empty=0
audio_only_list=()

for f in "${segs[@]}"; do
  types=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$f" 2>/dev/null)
  has_v=0; has_a=0
  while IFS= read -r t; do
    case "$t" in
      video) has_v=1 ;;
      audio) has_a=1 ;;
    esac
  done <<< "$types"

  if   [[ $has_v -eq 1 && $has_a -eq 1 ]]; then both=$((both + 1))
  elif [[ $has_v -eq 1 ]];                 then video_only=$((video_only + 1))
  elif [[ $has_a -eq 1 ]];                 then audio_only=$((audio_only + 1)); audio_only_list+=("$f")
  else                                          empty=$((empty + 1))
  fi
done

pct() { awk -v n="$1" -v t="$2" 'BEGIN { printf "%.1f%%", 100*n/t }'; }

printf '\n'
printf '%-15s %5d\n' "Total:"        "$total"
printf '%-15s %5d  (%s)\n' "Audio+Video:" "$both"     "$(pct "$both"     "$total")"
printf '%-15s %5d  (%s)\n' "Audio-only:"  "$audio_only" "$(pct "$audio_only" "$total")"
printf '%-15s %5d  (%s)\n' "Video-only:"  "$video_only" "$(pct "$video_only" "$total")"
printf '%-15s %5d  (%s)\n' "Empty:"       "$empty"    "$(pct "$empty"    "$total")"

if [[ $audio_only -gt 0 ]]; then
  printf '\nAudio-only segments:\n'
  for f in "${audio_only_list[@]}"; do
    dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null)
    printf '  %-22s  %.3fs\n' "$(basename "$f")" "${dur:-0}"
  done
fi

if [[ $video_only -gt 0 ]]; then
  printf '\nVideo-only segments: %d\n' "$video_only"
fi