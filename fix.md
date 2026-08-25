# Fix: orphaned tailer + hang on ffmpeg failure

## Bugs

Three problems in the new render-progress code in `components/renderer.sh`,
introduced (uncommitted) on top of the staged diff in `git diff --staged`:

1. `wait "$tailer_pid"` blocks forever when ffmpeg fails, because the
   tailer only exits on the `progress=end` line and ffmpeg does not write
   that line on failure.
2. The tailer is never killed on `Ctrl+C` / `SIGTERM`. The parent trap
   `dnd-on-interrupt` just calls `exit 130` and leaves the subshell
   polling forever.
3. The `dnd-progress.XXXXXX` file is leaked on interrupt for the same
   reason.

On WSL this is what "WSL broken at the end" looks like: every interrupted
run leaves another `bash` subshell spinning `sleep 0.5` + `awk` against a
deleted file, and WSL's init is not always fast at reaping them.

## Fix

### 1. `components/renderer.sh`

```diff
@@ top of the function, after locals @@
   local keep_count
   keep_count=$(jq '[.timeline[] | select(.action=="keep")] | length' "$plan_json")

   local total_us
   total_us=$(jq -r '
     [.timeline[] | select(.action=="keep") | ((.end - .start) * 1000000)]
     | add // 0
   ' "$plan_json" | awk '{ printf "%d", $1 }')

+  # Publish the tailer's identity to the global namespace so the parent
+  # EXIT trap (set in dnd-cut) can reach in and clean up on Ctrl+C.
+  DND_TAILER_PID=""
+  DND_PROG_FILE=""
@@ in the tailer block @@
   if [[ "$total_us" -gt 0 ]]; then
     prog_file="$(mktemp --tmpdir="$(dirname "$output")" dnd-progress.XXXXXX)"
+    DND_PROG_FILE="$prog_file"
     (
+      # Make the subshell actually die when the parent kills it; without
+      # this, SIGTERM/SIGINT go to the foreground command (sleep / awk)
+      # and the loop keeps going.
+      trap 'exit 0' TERM INT
       last_pct=-1
       while :; do
         [[ -f "$prog_file" ]] || sleep 0.2
         cur_us=$(awk -F= '/^out_time_us=/{v=$2} END{print v+0}' "$prog_file" 2>/dev/null)
         end=$(awk -F= '/^progress=end$/{print "1"; exit} END{print ""}' "$prog_file" 2>/dev/null)

         if [[ -n "$cur_us" && "$total_us" -gt 0 ]]; then
           pct=$(( cur_us * 100 / total_us ))
           [[ $pct -gt 100 ]] && pct=100
           if [[ "$pct" -ne "$last_pct" ]]; then
             printf '\r[dnd] rendering… %3d%%' "$pct" >&2
             last_pct="$pct"
           fi
         fi
         [[ -n "$end" ]] && break
         sleep 0.5
       done
       printf '\r[dnd] rendering… 100%%\n' >&2
     ) &
     tailer_pid=$!
+    DND_TAILER_PID="$tailer_pid"
   fi

@@ ffmpeg failure branch @@
   if ! ffmpeg -y -nostdin -loglevel error \
       ${prog_file:+-progress "$prog_file"} \
       -i "$input" \
       -filter_complex_script "$fc_file" \
       -map "[outv]" -map "[outa]" \
       -c:v libx264 -preset veryfast -crf 18 \
       -c:a aac -b:a 192k \
       -movflags +faststart \
       "$output"; then
     dnd-warn "Filter-based render failed; keeping filter_complex file for debugging: $fc_file"
     dnd-warn "Copying original as fallback to $output"
     cp -p "$input" "$output"
+    # ffmpeg failed -> no progress=end -> tailer is still polling.
+    # Kill it before wait or we hang forever.
     if [[ -n "$tailer_pid" ]]; then
+      kill "$tailer_pid" 2>/dev/null
       wait "$tailer_pid" 2>/dev/null
     fi
-    rm -f "$prog_file"
+    dnd-render-cleanup
     return 1
   fi

   rm -f "$fc_file"
+  # Success path: ffmpeg wrote progress=end, the tailer should have
+  # already exited. wait is bounded by the tailer's polling interval.
   if [[ -n "$tailer_pid" ]]; then
     wait "$tailer_pid" 2>/dev/null
   fi
-  rm -f "$prog_file"
+  dnd-render-cleanup
 }

+function dnd-render-cleanup() {
+  # Idempotent. Safe to call from the EXIT trap even when the renderer
+  # never ran (DND_TAILER_PID is ""), and safe to call twice.
+  if [[ -n "${DND_TAILER_PID:-}" ]] && kill -0 "$DND_TAILER_PID" 2>/dev/null; then
+    kill "$DND_TAILER_PID" 2>/dev/null
+    wait "$DND_TAILER_PID" 2>/dev/null
+  fi
+  if [[ -n "${DND_PROG_FILE:-}" ]]; then
+    rm -f "$DND_PROG_FILE"
+  fi
+  DND_TAILER_PID=""
+  DND_PROG_FILE=""
+}
```

### 2. `dnd-cut.sh`

```diff
   function dnd-cut() {
-    trap 'dnd-pause-on-exit' EXIT
+    # Run renderer-cleanup first so a SIGINT/SIGTERM during ffmpeg
+    # (which fires dnd-on-interrupt -> exit 130 -> EXIT) still kills
+    # the tailer and removes dnd-progress.XXXXXX before we pause.
+    trap 'dnd-render-cleanup; dnd-pause-on-exit' EXIT
```

## Why each piece is needed

- **`trap 'exit 0' TERM INT` in the subshell.** Without it, `kill
  <tailer_pid>` sends SIGTERM to the foreground command in the subshell
  (`sleep 0.5` or `awk`). `sleep` honors SIGTERM but the *subshell* keeps
  going into the next loop iteration, which calls `sleep` again, which
  re-races with the next SIGTERM. On a busy box or under WSL the loop can
  survive multiple SIGTERMs. Setting the trap inside the subshell makes
  SIGTERM exit the subshell outright.

- **`kill` before `wait` in the failure branch.** The whole point. If
  ffmpeg never wrote `progress=end`, the tailer is alive and `wait`
  blocks forever. `kill` is async-safe and bounded; the subsequent
  `wait` reaps it.

- **`DND_TAILER_PID` / `DND_PROG_FILE` as globals + `dnd-render-cleanup`.**
  The renderer's local `tailer_pid` / `prog_file` are not visible from
  the parent's `EXIT` trap. Publishing them through module-level vars
  lets the parent trap reach in on Ctrl+C, kill the tailer, and `rm` the
  progress file. The function is idempotent (empty-var guards, resets
  state) so it's safe to call from any path and safe to call twice.

- **EXIT trap ordering: `dnd-render-cleanup; dnd-pause-on-exit`.** On
  Ctrl+C during ffmpeg: INT trap -> `dnd-on-interrupt` -> `exit 130` ->
  EXIT trap fires -> cleanup runs (tailer dies, temp file gone) ->
  `dnd-pause-on-exit` reads `/dev/tty` *after* the workspace is clean.
  This is the path that was previously leaving the tailer alive and the
  progress file behind.

## Verification

After the fix, all three of these should be true:

```bash
# 1. Failure path no longer hangs
DND_AUTO_RESUME=yes dnd-cut /tmp/short.mp4   # with a deliberately broken plan
# Expect: immediate "Filter-based render failed" + copy fallback + exit 0
# (not: 30s of "rendering…  N%" then a hang)

# 2. No orphan after Ctrl+C
# Run, hit Ctrl+C during the render, then:
ps -ef | grep dnd-progress      # expect: empty
ls <ws>/dnd-progress.* 2>/dev/null  # expect: empty

# 3. Success path still prints 0%..100%
# Normal run on a real video -- the percentage line should advance to 100%
```

## What this does *not* fix

- The `read -rp "..." </dev/tty` in `dnd-pause-on-exit` is left alone.
  On WSL it can still be flaky in some terminal emulators; setting
  `DND_NO_PAUSE=1` is the documented workaround. A more robust version
  would `[[ -r /dev/tty ]]` before the `read`, but that's a separate
  change and not what's leaving processes around.
- The progress file is still created in the workspace directory (not
  `mktemp`'s default). That was an intentional choice in
  `rendering-time.md` (workspace-wipe cleans it up automatically) and
  is preserved.
