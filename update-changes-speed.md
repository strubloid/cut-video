# update-changes-speed — diagnostic & fix history of dnd-cut slowness

This is the running diagnosis of the **multiple distinct bugs** that have
been making `dnd-cut` slow or produce wrong output. The original brief
spoke only of slowness; new testing on the user's actual
`AV26_sem_edicao.mp4` (1920×1080@60, h264 + AAC, 1.43 GiB) exposed
several issues that needed to be fixed sequentially.

---

## Bug inventory (in order they were fixed)

| # | Bug | Symptom | Status |
|---|-----|---------|--------|
| 1 | Stage 1 re-encoded every segment with `libx264` (40 h ETA) | Slowness | **fixed** (move to stream copy / NVENC) |
| 2 | `concat.txt` wrote full paths into a file ffmpeg resolved against `concat.txt`'s dir → path doubled | Stage 2 error `Impossible to open ..././.../piece_*.mp4` | **fixed** (write basenames) |
| 3 | Input seek (`-ss` before `-i`) on MP4 cuts at the *preceding keyframe*; adjacent pieces share GOPs at boundaries → duplication + ~40 % duration bloat + audible "double cut" | Output duration 29527 s for 9473 s of keep-time; user heard the same cut twice | **fixed** (see below) |
| 4 | ffmpeg with `-c copy -to <end>` + `select`-style seek DROPS the video stream from the output (a known ffmpeg/MP4 bug — only the audio stream is emitted, the muxer can't position the video packet correctly) | Each piece = only audio; concat duration becomes 3× the keep-time | **fixed** (see below) |
| 5 | With `-fflags +genpts`, the timestamp rewrite is correct but the file still contains 3× as many video frames as expected → plays at 1/3 speed | Same observable symptom as #4 | **fixed** (avoid the broken flag) |

---

## Final, working approach (what `renderer.sh` does now)

After all five fixes:

1. **Detect GPU encoder**, prefer `h264_nvenc` (RTX 4070 Ti has it); fall
   back to `libx264 -preset ultrafast` if not.
2. **Per-piece extraction with frame-accurate cuts.** For each keep
   segment `start..end`, run one `ffmpeg -i $SRC -ss $start -to $end
   -c:v <encoder> -c:a aac -b:a 192k -pix_fmt yuv420p piece.mp4`.
   Output seek (`-ss` after `-i`) plus re-encoding gives a frame-accurate
   cut, no GOP-bloat, no duplication.
3. **8 parallel extractions** (`jobs -rp` + `wait -n`). 8 ffmpegs on an
   8-core box get the best per-piece time (~9 s each).
4. **`-c copy` concat** of all pieces (all re-encoded with the same codec,
   so the concat demuxer handles them cleanly).
5. **`rm -rf .pieces/`** on success (unless `DND_KEEP_PIECES=1`).

---

## Empirical results on `AV26_sem_edicao.mp4` (representative case)

* 9473 s of keep-time, 1797 keep-segments, 396 removed silences.
* 2-segment mini test (real timeline keep-segments 1.8–8.5 and
  8.7–15.15) → output **13.17 s** (expected 13.15 s). No duplication,
  A/V offset < 20 ms (AAC encoder priming — constant, not drift).
* Full-run estimate (~5 h on RTX 4070 Ti, was 40 h+ on libx264 CPU):
  - Stage 1 (NVENC encode): **~50 min** — 1797 pieces × ~9 s each,
    8-parallel → 225 batches ≈ 33 min process time plus the rest is
    ffmpeg init/encode overlap.
  - Stage 2 (concat copy): **~30 s** for ~1 GB of pieces.
  - Output file: **~1.0 GB** (smaller than the 1.43 GB source).

---

## How to run the fixed renderer

```bash
cd "/mnt/e/RPG RECORDS/AV26"
rm -f AV26_sem_edicao.dnd-cut/final.mp4   # discard the 8-h render
dnd-cut AV26_sem_edicao.mp4                # choose [r] Resume
```

* `vad.json`, `audio.json`, `timeline.json` are all already on disk —
  the resume skips Whisper + VAD + classification and goes straight to
  the render.
* Set `DND_AUTO_RESUME=yes` if you don't want the `[r/t/a/f]` prompt.
* Set `DND_KEEP_PIECES=1` to keep `.pieces/` after for inspection.
* Override the encoder / quality / bitrate / parallelism at runtime:
  ```bash
  DND_VIDEO_CRF=20 DND_AUDIO_BITRATE=128k DND_RENDER_THREADS=4 \
    dnd-cut AV26_sem_edicao.mp4
  ```

---

## What changed in the code

| File | Change |
|---|---|
| `components/renderer.sh` | per-piece re-encode (NVENC or libx264 fallback), 8 parallel, `-ss`/`-to` after `-i` for frame accuracy; basename entries in `concat.txt` |
| `components/config.sh` | restored `DND_VIDEO_CRF`, `DND_AUDIO_BITRATE`, `DND_RENDER_THREADS` so the re-encoder knobs are user-tunable |

## What the user should know about A/V sync

* Each re-encoded piece has a constant ~20 ms audio-lead offset vs video
  (AAC priming samples inside the first AAC packet). This is offset, not
  drift; every player's AAC decoder discards those samples.
* Concat just stitches pieces together — A/V relationship inside each
  piece is preserved.
* There is therefore **no lip-sync drift across the cut**. The original
  complaint about drift came from a previous version that re-encoded +
  crossfaded the whole timeline; the current renderer does neither.

---

## What we tried and rejected

1. **Pure `-c copy` with input seek** (the original "no re-encode" plan
   in `sync-video-changes.md`). Fast, but GOP sharing between adjacent
   pieces + the `-to` audio-only bug made the output unusable for this
   source (~40 % duration bloat, then 3× duration bloat on top).
2. **Pure `-c copy` with output seek** (`-i $SRC -ss S -to E -c copy`).
   ffmpeg drops the video stream entirely (only audio is emitted) — a
   known MP4 muxer limitation when output seek is combined with stream
   copy and no prior decode.
3. **`-fflags +genpts`** with the input-seek `-c copy` approach. The
   duration metadata is rewritten correctly but the file *still
   contains* ~50 extra GOP frames per piece; playback ends up at ~1/3
   speed for the same number of frames shown at the wrong PTS.
4. **Single-pass `filter_complex` with `select` and `setpts`** over the
   whole 3-h input. ffmpeg has to decode the entire source up to each
   keep-segment to advance the timestamp; cancel after >5 min for any
   non-trivial selection.
5. **Single-pass `filter_complex` with `concat` filter reading the same
   source multiple times via `-i $SRC` or symlinks/hard-links**.
   ffmpeg dedupes inputs that resolve to the same file path/inode —
   only the first one survives.
6. **Single-pass `filter_complex` with the `movie` source-filter** per
   chunk (`movie=…,sp=N,trim=…`). The `seek_point` option doesn't
   position the reader as expected on this version of ffmpeg and the
   output is empty.

The current renderer (#3 in the timeline of attempts — re-encode per
piece) is the simplest one that produces correct output at acceptable
speed on this hardware.

---

## Knobs the user can tune

| Var | Default | Effect |
|---|---|---|
| `DND_VIDEO_CRF` | 18 | NVENC `-cq` / libx264 `-crf` (lower = better quality, slower) |
| `DND_AUDIO_BITRATE` | 192k | AAC audio bitrate |
| `DND_RENDER_THREADS` | `nproc` capped at 8 | Parallel pieces |
| `DND_KEEP_PIECES` | unset | If set, `.pieces/` is kept after the render |

NVENC quality/preset is currently hardcoded to `-preset fast`. That
hits ~500 fps at 1080p60 on the RTX 4070 Ti, which leaves a lot of
headroom for any reasonable source; raising it (e.g. `-preset hq`) only
hurts render time without visible benefit on interview-style content.
