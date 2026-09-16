# dnd-cut

A "drag-and-drop" style bash pipeline that **safely** removes obviously
empty / background-only time from long-form videos (D&D session
recordings, interviews, talks, podcasts). It is a **pre-editing cleanup
tool**, not a finished editor — its job is to give the human editor a
shorter, safer starting point.

```
dnd-cut session.mp4  →  dnd-cut  →  session.dnd-cut/final.mp4
```

The whole thing is plain bash orchestrating real Python files + ffmpeg/jq —
no frameworks, no daemons, no compiled code, no embedded heredocs.

---

## Design principles (read this first)

The pipeline is built around one non-negotiable rule:

> **Never sacrifice spoken content just to make the video shorter.**

If the system is uncertain whether a section contains speech, **KEEP IT**.

That rule cascades into five priorities the pipeline enforces in order:

1. Preserve speech.
2. Preserve complete words (no clipping consonants).
3. Preserve conversations.
4. Preserve natural conversational pauses.
5. Remove genuinely unnecessary empty / background-only time.

A 10% shorter video with all speech intact is much better than a 30%
shorter video that requires recovering missing pieces from the original
recording.

The previous version of this tool optimised in the opposite order. It
was too aggressive in three ways that compounded into word-clipping:

| Old behaviour                                              | Fix                                            |
|------------------------------------------------------------|------------------------------------------------|
| VAD-only regions (audio without Whisper text) auto-removed | VAD-only regions are now *kept* as potential speech |
| Any silence ≥ 2 s removed                                  | Default silence floor is 4 s; short pauses preserved |
| Whisper word probability `< 0.40` reclassified as silence  | Every Whisper word contributes to a speech interval regardless of confidence |
| `refine.py` snapped cuts INTO the lowest-RMS window inside `±0.2 s` (often *inside* a word) | `refine.py` only ever **expands** keep regions outward into silence; never shrinks toward speech |
| Stream-copy renderer snapped each segment start to the **next** keyframe (consuming up to one full GOP of pre-roll) | Default is to snap to the **previous** keyframe (can only add audio, never remove) |

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
- [Testing](#testing)
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
4. Runs **ffmpeg `silencedetect`** as a complementary quiet-zone signal.
5. Classifies the timeline conservatively:
   - **`speech`** — Whisper words OR VAD activity → **keep**.
     Every Whisper word, regardless of confidence, contributes to a
     speech interval. Low-probability words are *not* reclassified as
     silence (that was the bug that ate quiet speakers).
   - **`gap`** — silence between speech intervals.
     Removed only if (a) it's at least `DND_MIN_REMOVE_DURATION` long,
     AND (b) it contains no Whisper word OR VAD activity. Anything
     else is kept, even if "long".
6. Pads every kept speech region with `DND_SPEECH_START_PADDING` /
   `DND_SPEECH_END_PADDING` and adds a defensive
   `DND_WORD_BOUNDARY_SAFETY_S` around any Whisper word so the
   renderer can't chop a consonant.
7. Refines cut points with an **expand-only** policy: cuts can only
   move outward into silence, never inward toward speech.
8. Renders `final.mp4` with the stream-copy renderer; cuts snap to
   the **previous** keyframe so they can only add audio, never remove
   it.

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
│   ├── silence_detect.py    # ffmpeg silencedetect -> JSON regions
│   ├── timeline.py          # classify + build edit list (conservative)
│   └── refine.py            # snap cuts OUTWARD into silence (expand-only)
├── components/
│   ├── config.sh            # tunables (exported env vars with defaults)
│   ├── logger.sh            # dnd-log / dnd-warn / dnd-err + EXIT/INT traps
│   ├── dependencies.sh      # dnd-dependencies-check
│   ├── workspace.sh         # workspace dir, resume prompt
│   ├── metadata.sh          # ffprobe wrapper
│   ├── audio.sh             # ffmpeg → 16 kHz mono wav
│   ├── silence.sh           # ffmpeg silencedetect wrapper
│   ├── vad.sh               # shells out to python/vad.py
│   ├── whisper.sh           # whisper CLI wrapper
│   ├── timeline.sh          # shells out to python/timeline.py
│   ├── refine.sh            # shells out to python/refine.py
│   ├── renderer.sh          # stream-copy segments + concat demuxer
│   └── finalize.sh          # print summary
└── tests/                   # Python unit tests (no pytest dep)
    ├── run_tests.py         # `python3 tests/run_tests.py`
    ├── fixtures.py          # synthetic VAD/whisper/silence generators
    └── test_timeline.py     # 12 tests covering the 7 required scenarios
```

The shell components are thin orchestrators — they call the Python files in
`python/` via the venv interpreter (`$BASH_ALIASES_VENV_BIN/python`). No
Python lives inside shell heredocs anymore.

Each component file is independently sourceable and exports a small set of
`dnd-*` functions. `dnd-cut.sh` just sources them in order and orchestrates.

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
| `DND_SPEECH_START_PADDING` | `0.60` | seconds of audio kept BEFORE each speech region |
| `DND_SPEECH_END_PADDING`   | `0.70` | seconds of audio kept AFTER each speech region |
| `DND_PRE_ROLL`    | `0.60` | backwards-compat alias for `DND_SPEECH_START_PADDING` |
| `DND_POST_ROLL`   | `0.70` | backwards-compat alias for `DND_SPEECH_END_PADDING` |
| `DND_WORD_BOUNDARY_SAFETY_S` | `0.30` | cuts are never placed within this many seconds of any Whisper word |
| `DND_MIN_REMOVE_DURATION`  | `4.00` | silence shorter than this is NEVER removed |
| `DND_MIN_KEEP_SILENCE_S`   | `1.00` | hard floor specifically against aggressive cutting of natural conversational pauses |
| `DND_MERGE_GAP_S`          | `1.50` | speech intervals closer than this are merged into one conversational segment |
| `DND_MIN_SPEECH_DURATION`  | `0.25` | speech regions shorter than this are dropped |
| `DND_SPEECH_KEEP_THRESHOLD` | `0.40` | Whisper word probability used only for *labelling*; not used for filtering |
| `DND_SILENCEDETECT_NOISE_DB`   | `-35` | dBFS threshold for ffmpeg `silencedetect` |
| `DND_SILENCEDETECT_MIN_DURATION` | `0.5` | minimum silence duration for ffmpeg `silencedetect` |
| `DND_PRESERVE_INTRO_S`     | `90`   | seconds at the start of the video to always keep. Set to `0` to disable. |
| `DND_PRESERVE_END_S`       | `300`  | seconds at the end of the video to always keep. Set to `0` to disable. |
| `DND_WHISPER_MODEL`     | `small` | whisper model size |
| `DND_WHISPER_LANGUAGE`  | *(auto)* | language hint (e.g. `en`, `pt`, `es`); empty = Whisper auto-detects from the audio |
| `DND_WHISPER_DEVICE`    | `cuda`  | `cuda` / `cpu` |
| `DND_REFINE_WORD_SAFETY_S`    | `0.30` | refine-step word-boundary guard |
| `DND_REFINE_EXTEND_WINDOW_S`  | `0.25` | how far outward (seconds) the refiner can extend cuts into silence |
| `DND_RENDER_BACKWARD_KEYFRAME_SNAP` | `1` | `1` = snap to previous keyframe (safe); `0` = legacy forward snap |
| `BASH_ALIASES_VENV_BIN` | `~/.bash_aliases_scripts/.venv/bin` | path to the Python venv |

### Tune for more or less compression

- **Less aggressive (preserve more):** raise `DND_MIN_REMOVE_DURATION`
  (e.g. `6.0`), raise `DND_SPEECH_START_PADDING` / `DND_SPEECH_END_PADDING`
  (e.g. `1.0`).
- **More aggressive (cut more):** lower `DND_MIN_REMOVE_DURATION`
  (e.g. `2.5`), lower the merge gap (e.g. `0.8`). Be aware this
  increases the risk of removing breathing space inside conversations.

---

## The pipeline

`dnd-cut.sh:22` (`dnd-cut()`) runs the stages in order.

| # | Stage | Component | Output |
|---|---|---|---|
| 1 | Validate input, check deps | `dependencies.sh` | — |
| 2 | Create workspace | `workspace.sh` | `<input-dir>/<basename>.dnd-cut/` |
| 3 | ffprobe metadata | `metadata.sh` | `analysis/metadata.json` |
| 4 | Extract mono 16 kHz wav | `audio.sh` | `analysis/audio.wav` |
| 5 | ffmpeg `silencedetect` | `silence.sh` | `analysis/silence.json` |
| 6 | WebRTC VAD | `vad.sh` | `analysis/vad.json` |
| 7 | Whisper word-timestamp transcription | `whisper.sh` | `analysis/audio.json` |
| 8 | Conservative timeline + edit list | `timeline.sh` → `python/timeline.py` | `analysis/timeline.json` + `analysis/segments.json` |
| 9 | Expand-only refine | `refine.sh` → `python/refine.py` | `analysis/timeline.refined.json` |
| 10 | Render final cut | `renderer.sh` | `final.mp4` |
| 11 | Print summary | `finalize.sh` | stdout |

---

## Configuration

All knobs live in `components/config.sh` and can be overridden at invocation
time, e.g. `DND_SPEECH_END_PADDING=1.0 dnd-cut talk.mp4`. The defaults are
tuned for **preservation over compression** and assume D&D-style content
with a mix of loud and quiet speakers.

- **Padding** (`SPEECH_START_PADDING` / `SPEECH_END_PADDING`) keeps a
  cushion of audio around every speech region. Larger = safer. Defaults
  are deliberately conservative (0.60 / 0.70 s).
- **`WORD_BOUNDARY_SAFETY_S`** is a defensive guard: cuts are never
  placed within this many seconds of any Whisper word, no matter what
  the padding or refiner did. Default 0.30 s.
- **`MIN_REMOVE_DURATION`** is the silence floor for removal. Below
  this, gaps are ALWAYS kept. Default 4 s — long enough that real
  pauses (breaths, thinking) survive, short enough that obvious dead
  time goes away.
- **`MIN_KEEP_SILENCE_S`** is a hard floor specifically against
  aggressive cutting of natural conversational pauses. Defaults to
  1.0 s.
- **`MERGE_GAP_S`** controls when nearby speech regions are merged
  into one conversational segment. Default 1.5 s — two bursts
  separated by less than this are treated as one thought.
- **`MIN_SPEECH_DURATION`** drops speech regions shorter than this.
  Default 0.25 s — short enough that a one-word reply ("No.")
  survives, long enough to drop truly tiny blips.
- **`SPEECH_KEEP_THRESHOLD`** is now only used for *labelling* the
  speech_confidence field. It is no longer used to filter out
  Whisper words — every word contributes to a speech interval
  regardless of confidence.

---

## Workspace layout

```
<dir>/<basename>.dnd-cut/
├── analysis/
│   ├── metadata.json          # ffprobe dump
│   ├── audio.wav              # 16 kHz mono PCM, used by VAD + Whisper
│   ├── silence.json           # ffmpeg silencedetect regions [{start,end,duration}, ...]
│   ├── vad.json               # WebRTC VAD regions  [{start,end}, ...]
│   ├── audio.json             # Whisper word-timestamp output
│   ├── segments.json          # every classified region in the video
│   └── timeline.json          # edit list + summary + words + silence inputs
│                              # + refiner output (timeline.refined.json)
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
    { "id": 0, "start": 0.0,  "end": 0.4,  "duration": 0.4,
      "classification": "gap",    "speech_confidence": 0.0,
      "action": "keep", "review_required": false,
      "reason": "Gap shorter than MIN_REMOVE_DURATION (4.00s); kept to preserve natural conversational pacing." },
    { "id": 1, "start": 0.4,  "end": 12.7, "duration": 12.3,
      "classification": "speech", "speech_confidence": 0.95,
      "action": "keep", "review_required": false,
      "reason": "Speech/activity region with safety padding" },
    { "id": 2, "start": 12.7, "end": 31.4, "duration": 18.7,
      "classification": "gap",   "speech_confidence": 0.0,
      "action": "remove", "review_required": false,
      "reason": "Long quiet gap with no VAD/Whisper activity (>= 4.00s)." }
  ],
  "words": [ /* all Whisper words used for word-boundary safety */ ],
  "summary": {
    "keep_seconds": 420.0, "remove_seconds": 180.0,
    "keep_segments": 24,   "remove_segments": 9,
    "silence_inputs": 12,  "vad_regions": 40, "whisper_words": 1200
  },
  "inputs": {
    "silence_regions": [/* ffmpeg silencedetect output */]
  }
}
```

The `questionable` array from earlier versions is gone: there is no
longer any "auto-remove VAD-only" path, so the concept doesn't apply.

---

## Resume modes

If `dnd-has-state` finds `analysis/audio.json` (Whisper done) or
`analysis/timeline.json` (timeline built), `dnd-resume-prompt` offers:

- **`r` — Resume** — reuse analysis + timeline, just re-render the final
  cut. Fastest path when only the render itself is missing or stale.
- **`t` — Rebuild timeline** — drop `final.mp4` and `analysis/timeline.json`
  + `timeline.refined.json`. Keep `audio.wav`, `vad.json`, `audio.json`,
  `silence.json`. Use this when thresholds like `DND_SPEECH_END_PADDING`
  or `DND_MIN_REMOVE_DURATION` need tweaking without re-paying the
  Whisper cost.
- **`a` — Re-analyze** — same as `t` plus drop the audio extraction and
  the VAD/Whisper/silencedetect outputs. Use this when the input file
  changed or you want different Whisper output.
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
packet at `<start>` and stops at the last packet with PTS `<= end`.

**Keyframe snap direction (safety):** with
`DND_RENDER_BACKWARD_KEYFRAME_SNAP=1` (default), each segment's start is
snapped to the *previous* keyframe, not the next. This can only ADD audio
to the segment — it can never consume pre-roll. Set to `0` to revert to
the legacy forward-snap direction (unsafe for word boundaries; only use
if you know what you're doing).

The path joins all `seg_*.mp4` with the concat demuxer:
`ffmpeg -f concat -safe 0 -i <list.txt> -c copy -fflags +genpts -movflags +faststart <output>`.
`-fflags +genpts` regenerates PTS across segments so audio and video stay
in sync.

If the concat fails for any reason, the renderer falls back to copying the
original as the output with a warning — the workspace and segment files are
preserved for inspection.

Per-segment files (`seg_*.mp4` + `concat.txt`) are kept in `<ws>/.segments/`
by default. Set `DND_KEEP_SEGMENTS=0` to delete them after a successful
render.

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

- `ffmpeg`, `ffprobe` (rendering, audio extraction, probing, `silencedetect`)
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

## Testing

Tests live under `tests/` and run with the standard library only:

```bash
python3 tests/run_tests.py                 # plain runner
python3 -m unittest discover -s tests      # unittest discovery
```

The fixtures (`tests/fixtures.py`) generate synthetic VAD regions,
Whisper words, and silence-detect regions in-memory and invoke
`python/timeline.py` as a subprocess. Audio-only stages (refine) get a
synthetic 16 kHz mono wav via `numpy`.

The test suite covers the seven scenarios from the brief (long empty
space, short conversational pause, quiet speaker, word boundary,
multi-speaker conversation, background noise, long silence after
speech) plus edge cases:

- Intro/outro preservation.
- Pure silence (single remove segment).
- Missing / malformed `silence.json` (graceful fallback).
- Short gap (below MIN_REMOVE_DURATION) is never removed.
- Refiner never shrinks a keep region toward speech.

If you change anything in `python/timeline.py` or `python/refine.py`,
run the tests. New behavior should come with new tests.

---

## Limitations & known caveats

- **Whisper quality dominates.** On music, SFX, or non-speech content the
  transcript is mostly noise and the pipeline will tend to keep
  everything (which is the safer default).
- **No speaker diarization.** Two people talking over each other is
  still hard to model. Whisper transcribes the louder voice; the softer
  voice may be classified as `vad_only` and is now *kept* (safer than
  the old behaviour of cutting it).
- **No GPU memory detection.** `DND_WHISPER_DEVICE=cuda` will hard-fail
  on machines without a working CUDA stack. Set `DND_WHISPER_DEVICE=cpu`
  to fall back.
- **No review step.** If the automatic cut is wrong, re-run with
  different `DND_*` thresholds or hand-edit `timeline.json` /
  `timeline.refined.json` and re-render with `[r]`.
- **Resume prompt is single-keystroke.** No default-on-Enter — you
  must explicitly press `r`, `t`, `a`, or `f`. Setting
  `DND_AUTO_RESUME=yes` makes `r` the default.
- **No batch mode.** Each input gets its own workspace and dnd-cut
  invocation. Wrap it in a shell loop if you need to process many
  files.