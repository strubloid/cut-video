# Adding render progress (percentage) to dnd-cut

## The problem

`components/renderer.sh` calls `ffmpeg … -loglevel error` and waits for it
to finish. For a short video that's fine, but for a 30- or 60-minute
recording on `preset veryfast` the single-pass `filter_complex` re-encode
can take a couple of minutes of pure silence — no log line, no progress
bar, no ETA. The user just sees:

```
[dnd] Rendering 142 keep-segments in a single sync-safe pass...
```

…and then either the summary or a fallback warning. There is no way to
tell whether ffmpeg is still working, hung, or 5% in.

## What ffmpeg already gives us

ffmpeg has a `-progress url` flag (also `-progress pipe:1` and
`-progress -` for stderr) that, after each chunk of work, writes
machine-parseable `key=value` lines like:

```
frame=1234
fps=58.4
bitrate=1832.5kbits/s
total_size=2834432
out_time_us=41234567
out_time_ms=41234567
out_time=00:00:41.234567
dup_frames=0
drop_frames=0
speed=1.87x
progress=continue
```

The two keys we care about are:

- **`out_time_us`** — microseconds of *output* already produced. This is
  the post-cut timeline position, not input time.
- **`progress=end`** — the last line ffmpeg writes when the encode is
  actually done (ffmpeg reuses the same file with `progress=continue` for
  every intermediate update).

We don't have a clean `out_time_us` for the *output duration* — that
depends on the filter graph, not the input. So we compute it ourselves:
sum the `end - start` of every `keep` segment in the plan. That's exactly
what the render is producing.

## The fix: a small progress tailer

The idea is to launch ffmpeg with `-progress` writing to a temp file, and
in the background poll that file, parse `out_time_us`, and print a single
rewriting percentage line on stderr. When ffmpeg exits, the tailer is
killed, the file is removed, and the final 100% is shown.

### Where the change goes

Everything happens inside `dnd-render-from-plan` in
`components/renderer.sh`. The function already knows the plan JSON and
the output path, so it can compute both the total output duration and
where to put the temp progress file.

### Step-by-step

#### 1. Compute the total output duration

Right after `keep_count` is read, also compute `total_us` (the total
microseconds of the cut output) by summing the keep segments. Easiest is
to do it in the same jq call:

```bash
local total_us
total_us=$(jq -r '
  [.timeline[] | select(.action=="keep") | ((.end - .start) * 1000000)]
  | add // 0
' "$plan_json" | awk '{ printf "%d", $1 }')
```

If `total_us` is 0, skip the progress display (the `cp -p "$input"
"$output"` fallback handles it, and it's instant anyway).

#### 2. Create a temp progress file

```bash
local prog_file
prog_file="$(mktemp --tmpdir="$(dirname "$output")"
                   dnd-progress.XXXXXX)"
```

Putting it next to the output means cleanup is automatic if the workspace
is wiped, and we don't litter `/tmp`.

#### 3. Start a background tailer

Spawn it *before* ffmpeg so we never miss the first update:

```bash
(
  last_pct=-1
  while :; do
    [[ -f "$prog_file" ]] || sleep 0.2
    # ffmpeg rewrites the file in place; read the latest out_time_us
    cur_us=$(awk -F= '/^out_time_us=/{v=$2} END{print v+0}' "$prog_file" 2>/dev/null)
    end=$(awk -F= '/^progress=end$/{print "1"; exit} END{print ""}' "$prog_file" 2>/dev/null)

    if [[ -n "$cur_us" && "$total_us" -gt 0 ]]; then
      pct=$(( cur_us * 100 / total_us ))
      [[ $pct -gt 100 ]] && pct=100
      if [[ "$pct" -ne "$last_pct" ]]; then
        # \r overwrites the line; pad to keep the trailing chars in place
        printf '\r[dnd] rendering… %3d%%' "$pct" >&2
        last_pct=$pct
      fi
    fi
    [[ -n "$end" ]] && break
    sleep 0.5
  done
  printf '\r[dnd] rendering… 100%%\n' >&2
) &
local tailer_pid=$!
```

Notes:
- `awk` over the whole file on each iteration is fine — ffmpeg's progress
  file is tiny (a few hundred bytes).
- The `[[ -n "$end" ]] && break` watches for the literal `progress=end`
  line, which is the canonical "ffmpeg is finished" signal.
- We use `\r` (carriage return, not newline) so the percentage line
  overwrites itself in place instead of scrolling.
- `sleep 0.5` keeps the loop at ~2 Hz, which is fast enough to feel live
  but light enough not to compete with ffmpeg for CPU.

#### 4. Run ffmpeg with `-progress`

Add `-progress "$prog_file"` to the existing ffmpeg invocation:

```bash
if ! ffmpeg -y -nostdin -loglevel error \
    -progress "$prog_file" \
    -i "$input" \
    -filter_complex_script "$fc_file" \
    -map "[outv]" -map "[outa]" \
    -c:v libx264 -preset veryfast -crf 18 \
    -c:a aac -b:a 192k \
    -movflags +faststart \
    "$output"; then
  …
fi
```

`-nostdin` is still important — we don't want ffmpeg reading from the
user's keyboard or the process-substitution stdin.

#### 5. Reap the tailer and clean up

Right after the ffmpeg `if` block (both branches: success and fallback):

```bash
wait "$tailer_pid" 2>/dev/null
rm -f "$prog_file"
```

`wait` blocks until the tailer has seen `progress=end` (success) or
returns immediately if ffmpeg failed and the tailer is still polling —
either way, after `wait` we own the temp file and can remove it.

#### 6. Don't break the fallback

The existing fallback path (`cp -p "$input" "$output"`) is instant. We
should *not* show a progress bar for it, because the percentage would
jump from whatever-it-was to 100% in one frame and confuse the user. The
cleanest way is to gate the whole tailer on `total_us > 0` (already done
in step 3) and let the existing warning speak for itself when the
fallback fires.

#### 7. Respect `-loglevel error` and the existing `dnd-log` style

The progress line goes straight to `>&2` with `[dnd]` prefix to match
`dnd-log`. We do **not** route it through `dnd-log` because `dnd-log`
appends to `$DND_LOG_FILE` — and a 60-line rendering progress log is
just noise.

## Putting it together

The final `dnd-render-from-plan` body, in order:

1. Read `keep_count` and `total_us` from the plan.
2. If `keep_count == 0`, fall through to the existing copy fallback and
   return.
3. Build the filter graph (`fc_file`).
4. If no keep segments were emitted, fall through to the existing copy
   fallback and return.
5. **NEW:** If `total_us > 0`, spawn the background tailer from step 3.
6. Run ffmpeg with `-progress "$prog_file"` (step 4).
7. On failure: warn, copy original, `wait` the tailer, `rm` the progress
   file, return 1 — same as today.
8. On success: `rm -f "$fc_file"`, `wait` the tailer, `rm` the progress
   file, return 0 — same as today.

The user-visible difference is exactly one new line per render:

```
[dnd] Rendering 142 keep-segments in a single sync-safe pass...
[dnd] rendering…   7%
[dnd] rendering…  23%
[dnd] rendering…  41%
…
[dnd] rendering…  99%
[dnd] rendering… 100%
============================================================
  DND video cut summary
============================================================
  …
```

## Edge cases to think about

- **ffmpeg writes `progress=end` once, then ffmpeg exits.** The tailer
  breaks on the `end` marker *or* when its `wait` is reaped — both
  work, and either path leads to a clean `rm`.
- **`-nostdin` is preserved**, so the tailer's `</dev/tty` in the review
  loop (if it ever comes back) is unaffected — this change is in
  `renderer.sh`, not `review.sh`.
- **CI / non-tty runs.** The progress line is written to `>&2` and uses
  `\r`; in a non-tty log capture it will appear as repeated `[dnd]
  rendering…  N%` lines (because `\r` is not interpreted by most log
  collectors). That's verbose but not broken. If you want a one-liner
  per render in CI, gate the tailer on `-t 2` (stderr is a tty).
- **Very fast renders.** If ffmpeg finishes before the first `sleep 0.5`
  in the tailer, the user sees just the final 100% line. That's
  acceptable — better than nothing, and the `dnd-log` line above already
  told them rendering started.
- **The `awk` parsing is forgiving.** A line that doesn't match
  `^out_time_us=` is silently skipped, so if ffmpeg ever changes its
  progress format, the tailer degrades to "no percentage" rather than
  crashing.

## What this does *not* do

- It does not add a per-segment progress (you can't tell from `out_time`
  which `keep` segment ffmpeg is currently on — you'd need to parse
  ffmpeg's verbose log for that, which `-loglevel error` suppresses).
- It does not give an ETA. ETA needs either `speed=` combined with
  history (a Kalman filter on the percentage curve) or ffmpeg's
  own ETA, which it doesn't emit. Adding a coarse "≈ N min remaining"
  line is a natural follow-up if you want it.
- It does not persist progress to the log file. The run log
  (`logs/dnd-*.log`) only gets a single `Rendering N keep-segments…`
  line at start and nothing else from the render, by design.
