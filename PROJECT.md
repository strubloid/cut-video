# dnd-cut

A "drag-and-drop" style bash pipeline that automatically removes empty space
from long-form videos (interviews, talks, podcasts) using **WebRTC VAD** +
**OpenAI Whisper**. Single command in, single cut video out — no interactive
review, no manual decisions.

The whole thing is plain bash + Python heredocs + ffmpeg/jq — no frameworks,
no daemons, no compiled code.

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
   - **`vad_only`** — VAD heard voice but Whisper heard nothing → `keep`
     (intros, outros, music, laughter, anything with audio stays)
   - **`silence`** — no speech-like audio at all
     - short silences (< `DND_MIN_REMOVE_DURATION`) are kept (cheaper than
       a splice and natural pauses are kept)
     - long silences are removed automatically
5. **Splits the source video into pieces** with stream copy (no re-encode) and
   concatenates them back together with the concat demuxer. Because we never
   decode the source, the audio/video sync that was encoded into the source
   is preserved bit-for-bit in the output — no lip-sync drift.

Everything is idempotent — re-running picks up where it left off.

---

## Repository layout

```
cut-video/
├── dnd-cut.sh               # entry point: sources components, defines dnd-cut()
├── install.sh               # creates /usr/local/bin/dnd-cut symlink, checks deps
├── PROJECT.md               # this file
└── components/
    ├── config.sh            # tunables (exported env vars with defaults)
    ├── logger.sh            # dnd-log / dnd-warn / dnd-err + EXIT/INT traps
    ├── dependencies.sh      # dnd-dependencies-check
    ├── workspace.sh         # workspace dir, resume prompt
    ├── metadata.sh          # ffprobe wrapper
    ├── audio.sh             # ffmpeg → 16 kHz mono wav
    ├── vad.sh               # WebRTC VAD (Python heredoc)
    ├── whisper.sh           # whisper CLI wrapper
    ├── timeline.sh          # classify + build edit list (Python heredoc)
    ├── renderer.sh          # stream-copy split + concat (no re-encode)
    └── finalize.sh          # print summary
```

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
| `DND_PRE_ROLL`    | `0.15` | seconds of padding kept before each kept region |
| `DND_POST_ROLL`   | `0.20` | seconds of padding kept after each kept region |
| `DND_MIN_REMOVE_DURATION`  | `1.20` | silences shorter than this are NOT removed |
| `DND_MIN_SPEECH_DURATION`  | `0.25` | speech regions shorter than this are dropped |
| `DND_SPEECH_KEEP_THRESHOLD` | `0.40` | Whisper word probability required to mark `speech` |
| `DND_WHISPER_MODEL`     | `small` | whisper model size |
| `DND_WHISPER_LANGUAGE`  | `en`    | language hint |
| `DND_WHISPER_DEVICE`    | `cuda`  | `cuda` / `cpu` |
| `DND_KEEP_PIECES`       | _(unset)_ | if set, keeps `.pieces/` after the run for inspection |
| `BASH_ALIASES_VENV_BIN` | `~/.bash_aliases_scripts/.venv/bin` | path to the Python venv |

### Cut every silence, no matter how short

By default `DND_MIN_REMOVE_DURATION=1.20` means silences under 1.2 s are
preserved (a natural pause between sentences). To literally cut every gap:

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
| 7 | Classify timeline, build edit list | `timeline.sh` | `analysis/timeline.json` + `analysis/segments.json` |
| 8 | Render final cut (stream copy) | `renderer.sh` | `final.mp4` |
| 9 | Print summary | `finalize.sh` | stdout |

---

## Configuration

All knobs live in `components/config.sh` and can be overridden at invocation
time, e.g. `DND_PRE_ROLL=0.5 dnd-cut talk.mp4`. The defaults are tuned for
"natural-paced interview/talk" content.

- **Pre/post roll** adds a small cushion around every kept region so cuts
  don't chop breaths or trailing consonants.
- **`MIN_REMOVE_DURATION`** is the silence floor — silences shorter than
  this are kept as natural pauses. Set to `0` to cut every gap.
- **`MIN_SPEECH_DURATION`** drops `speech` regions shorter than this
  (Whisper occasionally hallucinates a one-word blip). `vad_only` regions
  are not affected by this knob — they're kept regardless.
- **`SPEECH_KEEP_THRESHOLD`** filters out low-confidence Whisper words
  (Whisper noise). Lower it to keep more; raise it to be more aggressive
  about ignoring Whisper noise.

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
      "reason": "Kept audio region (with padding)" },
    { "id": 1, "start": 12.7, "end": 14.3,  "duration": 1.6,
      "classification": "silence", "speech_confidence": 0.0,
      "action": "remove", "review_required": false,
      "reason": "Empty space (no audio detected) — removed" }
  ],
  "summary": {
    "keep_seconds": 420.0,
    "remove_seconds": 180.0,
    "remove_segments": 9,
    "keep_segments": 24
  }
}
```

`classification` is one of `speech` (Whisper transcribed words), `vad_only`
(VAD detected voice, Whisper did not), or `silence` (no audio). Only
`silence` segments longer than `DND_MIN_REMOVE_DURATION` are `remove`; all
other segments are `keep`.

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

`renderer.sh` does the simplest possible thing: it **splits the source video
into pieces with stream copy (`ffmpeg -c copy`) and concatenates them back
with the concat demuxer** (`ffmpeg -f concat -c copy`). The source's encoded
audio and video bytes pass through unchanged, so the audio/video sync that
was baked into the source by whatever tool recorded it is preserved
bit-for-bit in the output.

Concretely:

* For every keep-segment in `timeline.json`, run
  `ffmpeg -ss S -to E -i <input> -c copy -avoid_negative_ts make_zero piece_NNNN.mp4`.
  ffmpeg fast-seeks to the keyframe at-or-before `S`, copies bytes from
  there to the keyframe at-or-after `E`, and writes a valid MP4 containing
  that contiguous subset of the source's packets.
* After all pieces are cut, build a concat list and run
  `ffmpeg -f concat -safe 0 -i concat.txt -c copy final.mp4`.
  The concat demuxer rewrites container timestamps so the pieces flow
  continuously; the codec payloads are untouched.

Because no decoding happens, there is no encoder delay to accumulate, no
AAC priming samples, no audio crossfade to drift, no GPU/CPU codec choice to
make, and no CRF/preset/bitrate to tune. The output is *literally* a
stitched subset of the source's packets.

If the cut or concat fails for any reason, the renderer falls back to
copying the original as the output with a warning. The intermediate
`.pieces/` directory is removed unless `DND_KEEP_PIECES` is set.

### Cut precision

* **Audio** is cut sample-accurately. AAC frames are independent, so the
  concat picks the first AAC frame at-or-after the requested timestamp.
* **Video** is cut on keyframe boundaries. ffmpeg copies the GOP that
  contains the requested start, so each piece typically starts a fraction
  of a second *before* the requested `$start` (the previous keyframe) and
  ends a fraction of a second *after* the requested `$end` (the next
  keyframe). The visible "bloat" per cut edge is at most one GOP's worth
  of frames (typically ≤ 2 s for content encoded with OBS / x264
  defaults). Both streams inside that piece are still in lock-step because
  they came from the same source frame.

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

- **Whisper quality dominates the speech detection.** On music, SFX, or
  non-speech content the transcript is mostly noise, so most regions become
  `vad_only` (still kept) or `silence` (still cut if long enough). This is
  fine for the user's intent of "keep everything except empty space", but
  it means `dnd-cut` will not, by itself, drop music interludes.
- **Cut precision is limited by GOP size.** Video cuts land on the nearest
  preceding / following keyframe. For content with a 2-second GOP
  (typical OBS / x264 defaults) each cut edge can include up to ~2 s of
  extra video frames before / after the requested range. These are
  identical bytes from the source (no re-encoding), so quality is
  preserved; they are just visible silence at the boundary. For content
  with very long GOPs (10 s+), the bloat at each cut edge grows
  proportionally.
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
  keep a long silence that got cut), you can either re-run with different
  `DND_*` thresholds or hand-edit the final video in a traditional editor.
  There is no in-pipeline "did you mean to keep this?" prompt.

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
