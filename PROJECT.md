# dnd-cut

A "drag-and-drop" style bash pipeline that automatically removes silence and
non-speech gaps from long-form videos (interviews, talks, podcasts) using
**WebRTC VAD** + **OpenAI Whisper**. Single command in, single cut video out —
no interactive review, no manual decisions.

The whole thing is plain bash orchestrating real Python files + ffmpeg/jq —
no frameworks, no daemons, no compiled code, no embedded heredocs.

```
dnd-cut interview.mp4  →  dnd-cut  →  interview.dnd-cut/final.mp4
```

---

## Table of contents

- [What it does](#what-it-does)
- [Repository layout](#repository-layout)
- [Installation](#installation)
- [Usage](#usage)
- [The pipeline](#the-pipeline)
- [Configuration](#configuration)
- [Workspace layout](#workspace-layout)
- [Resume modes](#resume-modes)
- [Render strategy](#render-strategy)
- [Signals & terminal handling](#signals--terminal-handling)
- [Dependencies](#dependencies)
- [Limitations & known caveats](#limitations--known-caveats)

---

## What it does

Given a single video file, `dnd-cut` runs the pipeline fully automatically and
writes a single output: `<input-dir>/<basename>.dnd-cut/final.mp4`. There is
no interactive review step.

Under the hood:

1. Extracts its mono 16 kHz audio.
2. Runs **WebRTC VAD** (frame-level voice activity detection) to flag every
   speech-like region.
3. Runs **Whisper** with word-level timestamps to get a transcript and
   per-word probabilities.
4. Classifies the timeline into three categories:
   - **`speech`** — Whisper transcribed real words here → `keep`
   - **`vad_only`** — VAD heard voice but Whisper heard nothing → `remove`
     (this is the change: `vad_only` segments are now treated as silence and
     cut automatically, no questions asked)
   - **`silence`** — no speech-like audio at all
     - short silences (< `DND_MIN_REMOVE_DURATION`) are kept (cheaper than
       a splice)
     - long silences are removed automatically
5. Builds a clean edit list: keep every speech region (padded by
   `DND_PRE_ROLL` / `DND_POST_ROLL`), splice them together, and render
   `final.mp4` in a single ffmpeg pass.

Everything is idempotent — re-running picks up where it left off.

---

## Repository layout

```
cut-video/
├── dnd-cut.sh               # entry point: sources components, defines dnd-cut()
├── install.sh               # creates /usr/local/bin/dnd-cut symlink, checks deps
├── PROJECT.md               # this file
├── python/                  # standalone Python scripts (called from shell)
│   ├── vad.py               # WebRTC VAD
│   ├── timeline.py          # classify + build edit list
│   └── refine.py            # snap to scene changes / audio zero crossings
└── components/
    ├── config.sh            # tunables (exported env vars with defaults)
    ├── logger.sh            # dnd-log / dnd-warn / dnd-err + EXIT/INT traps
    ├── dependencies.sh      # dnd-dependencies-check
    ├── workspace.sh         # workspace dir, resume prompt
    ├── metadata.sh          # ffprobe wrapper
    ├── audio.sh             # ffmpeg → 16 kHz mono wav
    ├── vad.sh               # shells out to python/vad.py
    ├── whisper.sh           # whisper CLI wrapper
    ├── timeline.sh          # shells out to python/timeline.py
    ├── refine.sh            # shells out to python/refine.py
    ├── renderer.sh          # stream-copy segments + concat demuxer
    └── finalize.sh          # print summary
```

The shell components are thin orchestrators — they call the Python files in
`python/` via the venv interpreter (`$BASH_ALIASES_VENV_BIN/python`). No
Python lives inside shell heredocs anymore.

Each component file is independently sourceable and exports a small set of
`dnd-*` functions. `dnd-cut.sh` just sources them in order and orchestrates.

> **No review components.** Earlier versions of this tool had
> `components/leftovers.sh`, `decisions.sh`, and `review.sh` for an
> interactive per-segment review. They were removed when the review step
> was dropped — the pipeline is now fully automatic.

---

## Installation

```bash
./install.sh                # symlinks dnd-cut.sh → /usr/local/bin/dnd-cut
./install.sh uninstall      # removes the symlink
INSTALL_DIR=~/.local/bin ./install.sh   # custom location
BASH_ALIASES_VENV_BIN=/opt/venv/bin ./install.sh   # custom venv
```

The installer:
- makes the scripts executable,
- drops (or replaces) a symlink at `$INSTALL_DIR/dnd-cut` (default
  `/usr/local/bin`; uses `sudo` if it isn't writable),
- runs a dependency check and reports which pieces are missing.

The Python venv is expected at
`${BASH_ALIASES_VENV_BIN:-$HOME/.bash_aliases_scripts/.venv/bin}` and must
provide `python`, `whisper`, and the `webrtcvad` / `scipy` / `numpy` packages.

---

## Usage

```bash
dnd-cut <video-file>
```

That's it. On first run the full pipeline executes; on subsequent runs the
script detects the existing workspace and asks which resume mode to use.

Useful environment variables (all optional):

| Var | Default | Effect |
|---|---|---|
| `DND_AUTO_RESUME` | `ask` | `ask` prompts on resume; `yes` silently resumes |
| `DND_NO_PAUSE`    | `0`    | if `1`, skip the "Press enter to exit…" prompt |
| `DND_PRE_ROLL`    | `0.30` | seconds of padding kept before each speech region |
| `DND_POST_ROLL`   | `0.40` | seconds of padding kept after each speech region |
| `DND_MIN_REMOVE_DURATION`  | `0.80` | silences shorter than this are NOT removed |
| `DND_MIN_SPEECH_DURATION`  | `0.25` | speech regions shorter than this are dropped |
| `DND_SPEECH_KEEP_THRESHOLD` | `0.40` | Whisper word probability required to mark `speech` |
| `DND_PRESERVE_INTRO_S`     | `90`   | seconds at the start of the video to always keep (presenter greeting). Set to `0` to disable. |
| `DND_PRESERVE_END_S`       | `300`  | seconds at the end of the video to always keep (outro / end screen). Set to `0` to disable. |
| `DND_WHISPER_MODEL`     | `small` | whisper model size |
| `DND_WHISPER_LANGUAGE`  | *(auto)* | language hint (e.g. `en`, `pt`, `es`); empty = Whisper auto-detects from the audio |
| `DND_WHISPER_DEVICE`    | `cuda`  | `cuda` / `cpu` |
| `BASH_ALIASES_VENV_BIN` | `~/.bash_aliases_scripts/.venv/bin` | path to the Python venv |

### Cut every silence, no matter how short

By default `DND_MIN_REMOVE_DURATION=0.80` means silences under 0.8 s are
preserved (a 200 ms breath isn't worth a splice). To literally cut every
gap:

```bash
DND_MIN_REMOVE_DURATION=0 dnd-cut talk.mp4
```

`DND_MIN_SPEECH_DURATION=0` will likewise stop dropping tiny speech
regions.

---

## The pipeline

`dnd-cut.sh:20` (`dnd-cut()`) runs the stages in order. The very first
line of the function sets `trap 'dnd-pause-on-exit' EXIT` so even early
validation errors get a clean prompt before the script exits.

| # | Stage | Component | Output |
|---|---|---|---|
| 1 | Validate input, check deps | `dependencies.sh` | — |
| 2 | Create workspace | `workspace.sh` | `<input-dir>/<basename>.dnd-cut/` |
| 3 | ffprobe metadata | `metadata.sh` | `analysis/metadata.json` |
| 4 | Extract mono 16 kHz wav | `audio.sh` | `analysis/audio.wav` |
| 5 | WebRTC VAD | `vad.sh` | `analysis/vad.json` |
| 6 | Whisper word-timestamp transcription | `whisper.sh` | `analysis/audio.json` |
| 7 | Classify timeline, build edit list | `timeline.sh` → `python/timeline.py` | `analysis/timeline.json` + `analysis/segments.json` |
| 8 | Render final cut | `renderer.sh` | `final.mp4` |
| 9 | Print summary | `finalize.sh` | stdout |

---

## Configuration

All knobs live in `components/config.sh` and can be overridden at invocation
time, e.g. `DND_PRE_ROLL=0.5 dnd-cut talk.mp4`. The defaults are tuned for
"natural-paced interview/talk" content.

- **Pre/post roll** adds a small cushion of audio around every kept speech
  region so cuts don't chop breaths or trailing consonants.
- **`MIN_REMOVE_DURATION`** is the silence floor — cutting a 200 ms pause
  is rarely worth the splice artifact, so it stays. Set to `0` to cut
  everything.
- **`MIN_SPEECH_DURATION`** drops speech regions shorter than this
  (Whisper occasionally hallucinates a one-word blip).
- **`SPEECH_KEEP_THRESHOLD`** filters out low-confidence Whisper words
  (hallucinated "thanks for watching" type artifacts). Lower it to keep
  more; raise it to be more aggressive about ignoring Whisper noise.

---

## Workspace layout

```
<dir>/<basename>.dnd-cut/
├── analysis/
│   ├── metadata.json          # ffprobe dump
│   ├── audio.wav              # 16 kHz mono PCM, used by VAD + Whisper
│   ├── vad.json               # WebRTC VAD regions  [{start,end}, ...]
│   ├── audio.json             # Whisper word-timestamp output
│   ├── segments.json          # every classified region in the video
│   └── timeline.json          # edit list (timeline[]) + questionable list
│                              # + summary; this IS the final plan
├── final.mp4                  # the cut output
└── logs/
    ├── dnd-YYYY-MM-DDTHH-MM-SS.log
    └── error.log
```

`dnd-workspace-init` creates the skeleton; `dnd-workspace-path` derives the
path as `<dir-of-input>/<basename-without-ext>.dnd-cut`, so each input has
exactly one workspace sibling.

The `timeline.json` schema is:

```jsonc
{
  "duration": 600.123,
  "timeline": [
    { "id": 0, "start": 0.5,  "end": 12.7,  "duration": 12.2,
      "classification": "speech", "speech_confidence": 1.0,
      "action": "keep", "review_required": false,
      "reason": "Confirmed speech (Whisper) with padding" },
    { "id": 1, "start": 12.7, "end": 14.3,  "duration": 1.6,
      "classification": "gap",    "speech_confidence": 0.0,
      "action": "remove", "review_required": false,
      "reason": "Non-speech gap between kept speech regions" }
  ],
  "questionable": [
    { "id": 17, "start": 49.4, "end": 49.75, "duration": 0.35,
      "classification": "possible_speech", "speech_confidence": 0.5,
      "action": "remove", "review_required": true,
      "reason": "Speech-like audio without transcribed text" }
  ],
  "summary": {
    "keep_seconds": 420.0,
    "remove_seconds": 180.0,
    "review_segments": 12,
    "remove_segments": 9,
    "keep_segments": 24
  }
}
```

The `questionable` array is preserved for inspection/debugging (so you can
see what was cut), but it no longer drives any user-facing step.

---

## Resume modes

If `dnd-has-state` finds `analysis/audio.json` (Whisper done) or
`analysis/timeline.json` (timeline built), `dnd-resume-prompt` offers:

- **`r` — Resume** — reuse analysis + timeline, just re-render the final
  cut. Fastest path when only the render itself is missing or stale.
- **`t` — Rebuild timeline** — drop `final.mp4` and `analysis/timeline.json`.
  Keep `audio.wav`, `vad.json`, `audio.json`. Use this when thresholds like
  `DND_PRE_ROLL` or `DND_MIN_REMOVE_DURATION` need tweaking without
  re-paying the Whisper cost.
- **`a` — Re-analyze** — same as `t` plus drop the audio extraction and
  the VAD/Whisper outputs. Use this when the input file changed or you
  want different Whisper output.
- **`f` — Fresh start** — nuke the entire workspace and start over.

Setting `DND_AUTO_RESUME=yes` skips the prompt and defaults to `r`.

---

## Render strategy

`renderer.sh` picks one of two paths based on `DND_RENDER_MODE`
(default `auto`) and whether NVENC is available:

| Mode | Per-segment work | Speed | Cut accuracy |
|------|------------------|-------|--------------|
| `auto` / `stream-copy` (default) | `ffmpeg -i <input> -ss <start> -to <end> -c copy` | **very fast** (seconds) | frame-accurate via MP4 index |
| `reencode` | `ffmpeg -i <input> -ss <start> -to <end> -c:v libx264 …` | slow on CPU, fast on NVENC | frame-accurate (re-encoded) |

In **`auto` mode** the renderer probes for a working `h264_nvenc` (encoders
list + a real test encode). If NVENC is available, it uses the re-encode
path; otherwise it falls back to the default stream-copy path.

The stream-copy path places `-ss` and `-to` *after* `-i` (output seek). For
MP4 sources ffmpeg uses the container's packet index to seek to the exact
packet at `<start>` and stops at the last packet with PTS `<= end`, so cuts
land at the nearest packet boundary rather than the previous keyframe. This
means adjacent segments do **not** overlap, with no re-encoding and no quality
loss. (For sources without a seekable index — rare for `.mp4` — the seek may
fall back to a keyframe snap; if you hit that, use `DND_RENDER_MODE=reencode`.)

Either path then joins all `seg_*.mp4` with the concat demuxer:
`ffmpeg -f concat -safe 0 -i <list.txt> -c copy -fflags +genpts -movflags +faststart <output>`.
`-fflags +genpts` regenerates PTS across segments so audio and video stay in
sync.

If the concat fails for any reason, the renderer falls back to copying the
original as the output with a warning — the workspace and segment files are
preserved for inspection.

Per-segment files (`seg_*.mp4` + `concat.txt`) are kept in `<ws>/.segments/`
by default. Set `DND_KEEP_SEGMENTS=0` to delete them after a successful
render.

This is dramatically faster than the previous re-encode + filter_complex
strategy and avoids the filter-graph length limit (concat demuxer has no
such ceiling — a video with thousands of keep-segments works fine). The
trade-off is that cuts are keyframe-snapped rather than frame-accurate,
which is invisible for most interview/talk content.

---

## Signals & terminal handling

`components/logger.sh` owns all the trap machinery:

| Trap | Handler | Effect |
|---|---|---|
| `EXIT` | `dnd-pause-on-exit` | If non-zero exit, logs `Script exited with status N. See <error.log> for details.` (or "See output above" if no error log). Then, if stdin is a tty and `DND_NO_PAUSE != 1`, reads from `/dev/tty` so you can read the error before the terminal closes. |
| `INT`  | `dnd-on-interrupt $?` | Logs `Interrupted (line N, exit=SIGNAL). Workspace preserved — see <log> and <error.log>. Re-run to resume.` then `exit 130`. |
| `TERM` | same as `INT`        | Same path. |

`dnd-cut` sets the `EXIT` trap on the first line of the function, so even
`Usage: dnd-cut <video-file>` and `Input file not found: …` paths get a
proper prompt before exiting.

---

## Dependencies

System:

- `ffmpeg`, `ffprobe` (rendering, audio extraction, probing)
- `jq` (timeline JSON manipulation)
- `python3` (driver; the heavy lifting goes through the venv)

Python venv (`$BASH_ALIASES_VENV_BIN`, default
`~/.bash_aliases_scripts/.venv/bin`):

- `python` (3.x)
- `whisper` (openai-whisper CLI)
- `webrtcvad`
- `scipy` (used for `scipy.io.wavfile`)
- `numpy`

`install.sh` reports `[OK]` / `[MISS]` for each of these.

---

## Limitations & known caveats

- **Whisper quality dominates.** On music, SFX, or non-speech content the
  transcript is mostly noise, every region becomes `vad_only` or
  `silence`, and you'll cut the entire video down to almost nothing. Run
  the pipeline on a representative sample before trusting it on a whole
  catalog.
- **Per-segment re-encode runs as many parallel ffmpeg jobs as cores.** On a
  machine with thousands of keep-segments the per-segment ffmpeg startup
  cost dominates. `DND_RENDER_THREADS` (default = `nproc`, capped at 16)
  bounds the parallelism.
- **No GPU memory detection.** `DND_WHISPER_DEVICE=cuda` will hard-fail on
  machines without a working CUDA stack. Set `DND_WHISPER_DEVICE=cpu` to
  fall back.
- **Pre/post roll assumes the speech region is centered in a wider
  silence.** For rapid back-and-forth dialogue, padding can overlap between
  adjacent speech regions; the timeline builder de-overlaps by merging, so
  cuts remain clean but the effective padding is reduced.
- **The resume prompt is single-keystroke.** There's no default-on-Enter
  — you must explicitly press `r`, `t`, `a`, or `f`. Setting
  `DND_AUTO_RESUME=yes` makes `r` the default and skips the prompt entirely.
- **No batch mode.** Each input is processed in its own workspace and its
  own dnd-cut invocation. Wrap it in a shell loop if you need to process
  many files.
- **No review step.** If the automatic cut is wrong (e.g. you wanted to
  keep a breath that VAD flagged and Whisper missed), you have to either
  re-run with different `DND_*` thresholds or hand-edit the final video in
  a traditional editor. There is no in-pipeline "did you mean to keep
  this?" prompt.

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Bad usage / missing input / missing dependency |
| `130` | Interrupted (SIGINT or SIGTERM) — workspace preserved, safe to re-run |

The `EXIT` trap is the single source of truth for the final user-facing
message; the rendered exit code is whatever the underlying command produced
plus 128 for signal-driven exits.
