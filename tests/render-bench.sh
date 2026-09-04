#!/bin/bash
# tests/render-bench.sh
# Micro-benchmark of the per-piece re-encoder used in components/renderer.sh.
# Runs N keep-segments from a real timeline under varying parallelism and
# encoder choice, then prints wall-clock throughput.
#
# Usage:
#   tests/render-bench.sh                          # default: 8 pieces, NVENC vs libx264
#   N=32 tests/render-bench.sh                     # 32 pieces per config
#   N=8 SRC=/path/to/source.mp4 WS=/path/to/ws tests/render-bench.sh
#
# Env:
#   N          pieces per config (default 8)
#   WS         workspace dir containing analysis/timeline.json and .pieces/.source.mp4
#              (default: /mnt/e/RPG RECORDS/AV26/AV26_sem_edicao.dnd-cut)
#   SRC        override source file
#   OUT        scratch dir for benchmark pieces (default /tmp/dnd-bench)
#   SKIP_NVENC=1   skip the NVENC run
#   SKIP_CPU=1     skip the libx264 run
#
# Notes:
#   * The renderer skips pieces that already exist on disk, so this benchmark
#     writes to /tmp, not into the real workspace.
#   * On WSL with a Windows E: drive the source IO dominates; expect
#     per-piece wall time around 3-6s regardless of encoder choice.

set -u

N="${N:-8}"
WS="${WS:-/mnt/e/RPG RECORDS/AV26/AV26_sem_edicao.dnd-cut}"
OUT="${OUT:-/tmp/dnd-bench}"
SRC="${SRC:-$WS/.pieces/.source.mp4}"
[[ ! -f "$SRC" ]] && SRC="/mnt/e/RPG RECORDS/AV26/AV26_sem_edicao.mp4"
[[ ! -f "$SRC" ]] && SRC="${WS%/}/$(basename "$WS" .dnd-cut).mp4"

CUT_VIDEO_ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/.." && pwd)"
source "$CUT_VIDEO_ROOT/components/config.sh"
source "$CUT_VIDEO_ROOT/components/logger.sh"
source "$CUT_VIDEO_ROOT/components/renderer.sh"

if [[ ! -f "$WS/analysis/timeline.json" ]]; then
  echo "no timeline.json at $WS/analysis/timeline.json" >&2
  exit 1
fi

echo "ws   = $WS"
echo "src  = $SRC"
echo "N    = $N pieces per config"
echo "enc  = $(dnd-pick-encoder) (picked by dnd-pick-encoder)"
echo ""

bench_one() {
  local label="$1"
  local parallel="$2"
  local enc_args="$3"
  local dir="$OUT/$label"
  rm -rf "$dir"
  mkdir -p "$dir"

  local i=0
  local t0 t1
  t0=$(date +%s)
  while IFS=$'\t' read -r start end; do
    i=$((i + 1))
    [[ $i -gt $N ]] && break
    local out="$dir/piece_$(printf '%05d' "$i").mp4"
    rm -f "$out"
    while [[ $(jobs -rp 2>/dev/null | wc -l) -ge "$parallel" ]]; do
      wait -n 2>/dev/null || sleep 0.05
    done
    (
      # shellcheck disable=SC2086
      ffmpeg -y -nostdin -loglevel error \
        -i "$SRC" -ss "$start" -to "$end" \
        $enc_args "$out" 2>/dev/null
    ) &
  done < <(jq -r '.timeline[] | select(.action=="keep") | "\(.start)\t\(.end)"' "$WS/analysis/timeline.json")
  wait
  t1=$(date +%s)

  local wall=$((t1 - t0))
  local total_src_s=0
  local total_out_b=0
  i=0
  while IFS=$'\t' read -r start end; do
    i=$((i + 1))
    [[ $i -gt $N ]] && break
    total_src_s=$(echo "$total_src_s + ($end - $start)" | bc)
    local f="$dir/piece_$(printf '%05d' "$i").mp4"
    [[ -f "$f" ]] && total_out_b=$((total_out_b + $(stat -c%s "$f")))
  done < <(jq -r '.timeline[] | select(.action=="keep") | "\(.start)\t\(.end)"' "$WS/analysis/timeline.json")

  local per_piece_ms=$(( wall * 1000 / N ))
  printf '  %-22s %2d-parallel  %3ds wall  (%4d ms/piece)  src=%.1fs  out=%s\n' \
    "$label" "$parallel" "$wall" "$per_piece_ms" "$total_src_s" \
    "$(numfmt --to=iec "$total_out_b" 2>/dev/null || echo "${total_out_b}B")"
}

echo "=== benchmark ==="
if [[ -z "${SKIP_NVENC:-}" ]]; then
  bench_one "nvenc-1"  1 "-c:v h264_nvenc -preset fast -cq 18 -b:v 0 -pix_fmt yuv420p -c:a aac -b:a 192k"
  bench_one "nvenc-4"  4 "-c:v h264_nvenc -preset fast -cq 18 -b:v 0 -pix_fmt yuv420p -c:a aac -b:a 192k"
fi
if [[ -z "${SKIP_CPU:-}" ]]; then
  bench_one "libx264-4" 4 "-c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k"
  bench_one "libx264-8" 8 "-c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k"
fi
echo ""
echo "=== full-render projection (1743 keep-segments) ==="
# Re-run the smallest/fastest measurement and project. Rough heuristic:
#  wall_time(pieces) ~= wall_time(N) / N * pieces / parallel
echo "  See measured per-piece ms above; project as (per_piece_ms * 1743 / parallel / 1000)s."
