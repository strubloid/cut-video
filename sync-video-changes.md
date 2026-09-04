# sync-video-changes — why the cut is wrong and how to fix it

This document is the research/plan behind the rewrite of `dnd-cut`. It explains
*why* the current pipeline cuts too much of the user's intro/outro and
introduces a lip-sync drift in the rendered output, and it lays out the new
strategy: **never re-encode — cut pieces straight out of the source video with
stream copy and concatenate them back together.**

---

## TL;DR

Two independent bugs in the current pipeline, both visible to the user:

| # | Bug | Effect on the user's video |
|---|-----|----------------------------|
| 1 | `vad_only` regions (VAD hears voice, Whisper didn't transcribe) are marked `action=remove` in `components/timeline.sh:104-108`. | Intro "hello, small things to do" and the outro "goodbye + talking to the YouTube audience" get classified as `vad_only` (Whisper commonly misfires on greetings / sign-offs / generic phrases) and get cut. The user is left with only the middle of the video. |
| 2 | `components/renderer.sh` re-encodes every segment with `libx264` / `h264_nvenc` + AAC, then builds chunks with a 20 ms `acrossfade`, then concatenates chunks with the concat demuxer. Re-encoding two streams independently + a crossfade + a concat is three independent places where audio and video can drift. | The user's final cut shows a subtle lip-sync offset that does **not** exist in the source. Opening the original in DaVinci Resolve and comparing makes it obvious the drift is introduced by *us*, not present in the source. |

Both bugs have the same root cause: the pipeline treats the audio and the
video as two separate media that we re-mux from scratch. The right model is
the opposite — the source file already has audio + video perfectly in sync;
the only thing we should do is **remove whole chunks of that source**.

The new strategy is therefore:

1. Classify only **true silence** as `remove`. Anything with any audio at
   all (speech, music, "vad-only", breaths, laughter, whatever) is `keep`.
2. For each kept range, write out the **bytes of the original file** that
   cover that range using `ffmpeg -c copy` (stream copy). No decode, no
   re-encode, no codec, no CRF, no preset, no crossfade.
3. Concatenate the pieces with the **concat demuxer at `-c copy`**. The
   output file is literally a stitched subset of the source file's packets.

Because we never touch the encoded audio/video, the A/V relationship that
the source encoded is preserved bit-for-bit. There is no codec delay to
accumulate, no audio crossfade to drift, no encoder timestamp rounding. The
only "imprecision" is that cuts happen on keyframe boundaries for the
video stream, which is fine and is in fact exactly what the user asked for
("whatever the things from the video would be reproduced").

---

## Bug 1 in detail — why the intro and outro get eaten

### Where the over-cutting happens

`components/timeline.sh` (lines 100-118) classifies every 50 ms time slot in
the audio as one of three states and assigns an action:

```python
if state == "speech":
    rec["action"] = "keep"
elif state == "vad_only":
    rec["action"] = "remove"            # <-- the bug
    rec["review_required"] = True
    rec["reason"] = "Speech-like audio without transcribed text"
else:  # silence
    if d < min_remove:
        rec["action"] = "keep"
    else:
        rec["action"] = "remove"        # <-- this one is correct
```

So three things can be marked `remove`:

* `vad_only` — VAD says "this looks like voice" but Whisper didn't transcribe
  anything there. This includes music with vocal-ish harmonics, breaths,
  "umm"s, laughter, off-mic chatter, and the *exact kind of phrasing that
  Whisper commonly hallucinates / drops* (greetings, sign-offs, "thanks for
  watching", "bye guys", "see you next time").
* `silence` longer than `DND_MIN_REMOVE_DURATION` (default 0.8 s) — this is
  correct; it's the only thing the user actually wants cut.

### Why this kills the intro and outro specifically

The user describes a typical YouTube-style video with three regions:

1. **Intro** — "hello, small things to do". Whisper frequently drops greetings
   (they look like noise to the acoustic model) and "small things to do" is
   often low-confidence filler. VAD hears voice; Whisper produces no high-
   confidence words → `vad_only` → **removed**.
2. **Body** — the actual content. Whisper transcribes this reliably → `speech`
   → kept.
3. **Outro** — "nice goodbye + talking to the YouTube public". The "goodbye"
   is a stock phrase Whisper often skips or marks low-confidence; the
   "talking to the YouTube public" often includes out-of-context sentences
   that Whisper doesn't tie to the rest of the transcript. Same result:
   `vad_only` → **removed**.

Net effect: the user sees the middle of the video and loses both ends,
exactly the symptom they reported.

### The fix

The user's intent — *"we just need to cut the empty spaces"* — is the
specification. Only `silence` should be eligible for removal. `vad_only` is
*not* empty; it has audio in it. So `vad_only` action becomes `keep`.

Concretely, in `components/timeline.sh`, replace lines 104-108:

```python
elif state == "vad_only":
    rec["action"] = "keep"               # was "remove"
    rec["review_required"] = False       # was True
    rec["reason"] = "Speech-like audio without transcribed text (kept)"
    rec["speech_confidence"] = round(review_thr, 3)
```

That's the entire fix for bug 1.

### Threshold defaults to revisit

With bug 1 fixed, the only thing that actually gets cut is "true silence
longer than `DND_MIN_REMOVE_DURATION`". The default 0.8 s is reasonable but
slightly aggressive for natural speech (a 1-second pause to think is normal).
Suggested new default: **1.2 s**, with `DND_PRE_ROLL=0.15` and
`DND_POST_ROLL=0.20` to keep breaths but cut silence. Users can still set
`DND_MIN_REMOVE_DURATION=0` to literally cut every gap.

`DND_SPEECH_KEEP_THRESHOLD=0.40` and `DND_MIN_SPEECH_DURATION=0.25` remain
useful (they drop Whisper hallucinations of single words, but those words
aren't on the keep-list anyway once `vad_only` becomes keep — so they only
matter inside the `speech` regions, which is fine).

---

## Bug 2 in detail — why the rendered output drifts out of sync

### Where the drift is introduced

Look at `components/renderer.sh`. There are three independent places where
audio and video timing can move relative to each other:

**Stage 1 — per-segment re-encode** (`renderer.sh:83-90`):

```bash
ffmpeg -y -nostdin -loglevel error \
  -ss "$start" -to "$end" -i "$input" \
  -c:v "$video_codec" -preset "$video_preset" "${quality_flag[@]}" \
  -c:a aac -b:a "$DND_AUDIO_BITRATE" \
  -pix_fmt yuv420p \
  -movflags +faststart \
  "$seg_file"
```

Every segment is **fully decoded and re-encoded** with `libx264` (or
`h264_nvenc`) for video and `aac` for audio. Two consequences:

* **AAC encoder delay.** The AAC encoder inserts ~1024-1104 silent samples
  at the start of every encode. After `-ss` seeking, those samples sit
  *before* the actual audio content in the segment. When two segments are
  concat'd, each contributes its own delay, but the first segment's
  initial delay is generally preserved while subsequent segments' delays
  may or may not be re-applied depending on how the concat demuxer handles
  timestamps. The result is a small but cumulative A/V offset.
* **Frame-rate rounding.** Even at fixed 30 fps, when ffmpeg re-emits the
  video stream it doesn't guarantee that the output's frame timing aligns
  with the original sample clock. A few ms here, a few ms there, and the
  mouth is off by a noticeable amount.

**Stage 2 — chunking with crossfade** (`renderer.sh:200-219`):

```bash
printf "[a0][a1]acrossfade=d=%s:c1=tri:c2=tri[c0];\n" "$crossfade_s" >> "$fc_file"
...
printf "%sconcat=n=%d:v=1:a=0[outv];\n" "$v_inputs" "$n" >> "$fc_file"
printf "[%s]anull[aout]\n" "$final_audio_label" >> "$fc_file"
```

The chunks are built by re-encoding the concatenated segments *again*,
with an `acrossfade` on the audio and a `null`/`anull` on the video. This
is a *second* encode pass, doubling the encoder-delay problem. Plus the
crossfade implicitly assumes both audio tracks are exactly the same
duration at the join — when they aren't (because of the AAC delay from
stage 1), the crossfade adds or drops samples asymmetrically. That's a
direct, audible source of drift.

**Stage 3 — concat demuxer** (`renderer.sh:163-171`):

```bash
ffmpeg -y -nostdin -loglevel error \
  -f concat -safe 0 -i "$concat_list" \
  -c copy -movflags +faststart \
  "$output"
```

The concat demuxer is `-c copy` (good — no further re-encode), but by the
time we reach this step the chunks' A/V timing has already been
double-distorted.

### Why the original is fine

When the user opens the original in DaVinci Resolve, audio and video are
in sync because the source file was *encoded once* by whatever tool made
the recording (OBS, a camera, etc.). The relative timing of audio samples
to video frames was set at that encode and never disturbed.

The whole point of this app is to **subset** that file — to keep some
ranges and discard others. Subsetting is a bit-level operation; it does
not require re-encoding at all. The current pipeline re-encodes three
times when it needs to re-encode zero times.

### The fix — stream copy

Replace the per-segment re-encode with a per-segment `-c copy`:

```bash
ffmpeg -y -nostdin -loglevel error \
  -ss "$start" -to "$end" -i "$input" \
  -c copy \
  -avoid_negative_ts make_zero \
  "$piece_file"
```

What this does:

* `-ss` and `-to` before `-i` trigger fast input seek on the keyframe.
  ffmpeg finds the keyframe at-or-before `$start`, copies bytes from there
  up to the keyframe at-or-after `$end`. No decode, no re-encode.
* `-c copy` instructs both the `video` and `audio` streams (and any
  subtitles / data streams if present) to be copied verbatim from the
  input's bitstream.
* `-avoid_negative_ts make_zero` rewrites the output's timestamps so
  piece 1 starts at PTS=0, which makes the subsequent concat safe.

The output `piece_NNNN.mp4` is a *valid* MP4 that contains a contiguous
subset of the input's packets, with the input's audio and video PTS
preserved exactly. There is no decoder, no encoder, no delay, no
crossfade. The A/V relationship is whatever the source had — which is
perfect sync.

Then concatenate the pieces with the concat demuxer at `-c copy`:

```bash
ffmpeg -y -nostdin -loglevel error \
  -f concat -safe 0 -i "$concat_list" \
  -c copy \
  "$output"
```

The concat demuxer with `-c copy` rewrites container timestamps so the
pieces flow continuously. It does not touch the codec payloads.

### Why this is safe at cut boundaries

For the **audio** stream, the cut is sample-accurate. The AAC frames in
the source are independent, so the demuxer just picks the next AAC frame
at or after the requested start time.

For the **video** stream, the cut is keyframe-aligned. Modern codecs
(h264, hevc, vp9) require that the next keyframe after a cut be reachable
from the start of the GOP; the stream-copy operation picks the nearest
preceding keyframe and the nearest following keyframe, and copies the
entire intervening GOP. This means each piece typically starts a fraction
of a second *before* the requested `$start` and ends a fraction of a
second *after* the requested `$end`. The user's words *"when we are
cutting needs to be a cut from the video, whatever the things from the
video would be reproduced"* explicitly accept this — we're not throwing
content away, we're just using keyframe-aligned edges.

In practice, for content with `keyint=2s` (typical OBS / x264 default),
the maximum misalignment per edge is ~2 s of "extra" video frames before
the actual audio begins. Those extra frames are usually the visual silence
just before the speaker opens their mouth (or just after they close it),
so the visible effect is negligible — and there is still no A/V *drift*
within the piece, because both streams were cut from the same source
moment and preserved together.

### What we drop from the renderer

The new renderer is dramatically smaller:

| Old | New |
|-----|-----|
| Codec detection (libx264 / h264_nvenc) | not needed |
| `DND_USE_GPU`, `DND_VIDEO_CRF`, `DND_AUDIO_BITRATE`, `DND_RENDER_THREADS` | unused |
| Parallel per-segment ffmpeg with PID tracking | unnecessary (stream copy is fast, sequential is fine and avoids temp-file races) |
| `refine.sh` — scene detection + zero-crossing snap | not needed (cuts are keyframe-aligned by definition) |
| Chunking with `acrossfade` | removed (it was the worst sync offender) |
| Three encode passes per segment (seg → chunk → concat) | zero encode passes |

The old renderer had ~250 lines; the new renderer is ~80.

---

## The new pipeline end-to-end

```
input.mp4
   │
   ▼
[1] ffmpeg -vn -ac 1 -ar 16000 -i input  →  analysis/audio.wav     (unchanged)
   │
   ▼
[2] webrtcvad on audio                     →  analysis/vad.json      (unchanged)
   │
   ▼
[3] whisper on audio (word timestamps)     →  analysis/audio.json    (unchanged)
   │
   ▼
[4] timeline classification:
       speech          → keep
       vad_only        → keep       (was: remove)
       silence <T      → keep
       silence ≥T      → remove     (this is the only thing cut)
       →  analysis/timeline.json                                       (small change)
   │
   ▼
[5] renderer:
       for each keep range:
           ffmpeg -ss S -to E -i input -c copy -avoid_negative_ts make_zero piece_NNNN.mp4
       ffmpeg -f concat -safe 0 -i concat.txt -c copy final.mp4
```

No `refine` step, no chunks, no crossfades, no re-encode, no GPU/CPU
detection. The audio and video of the input are never decoded, so the A/V
relationship in the source is preserved bit-for-bit in the output.

---

## Files changed

* `components/timeline.sh` — change `vad_only` action from `remove` to `keep`,
  drop the `questionable` list (it no longer drives anything) or keep it as
  a debug record.
* `components/config.sh` — change `DND_MIN_REMOVE_DURATION` default from
  `0.80` to `1.20`. Drop unused knobs (`DND_VIDEO_CRF`,
  `DND_AUDIO_BITRATE`, `DND_RENDER_THREADS`, `DND_USE_GPU`,
  `DND_CROSSFADE_MS`, `DND_CHUNK_SIZE`, `DND_SNAP_WINDOW_S`,
  `DND_AUDIO_SNAP_WINDOW_S`, `DND_KEEP_CHUNKS`).
* `components/renderer.sh` — full rewrite: stream-copy pieces + concat-copy.
* `dnd-cut.sh` — remove the `refine.sh` source and the
  `dnd-refine-cuts` invocation. Reuse `timeline.json` directly as the
  render plan (no `timeline.refined.json`).
* `PROJECT.md` — update to describe the new approach and the new config.

## What stays the same

* `install.sh`, `components/dependencies.sh`, `components/workspace.sh`,
  `components/audio.sh`, `components/vad.sh`, `components/whisper.sh`,
  `components/metadata.sh`, `components/finalize.sh`, `components/logger.sh`
  are unchanged.

---

## Risks and edge cases

1. **Stream-copy requires the codec to be MP4-friendly.** The current
   pipeline already assumes the input is a container/codec pair that
   ffmpeg can re-encode, which means it's also stream-copy-friendly.
   No regression here.

2. **Inputs with very long GOPs** (e.g. `keyint=300` on a 30 fps source →
   10 s GOP). The visible "bloat" at each cut edge will be up to 10 s of
   silent frames. We could mitigate by re-encoding *just* the first and
   last GOP of each piece to all-intra, but that brings re-encoding back.
   For the user's content (typical YouTube / OBS recordings with
   `keyint=2`), this is not an issue. Document it as a known caveat.

3. **Multi-audio / multi-subtitle inputs.** The current code already
   collapses to the first stream; stream copy inherits that. If a future
   user has multiple audio tracks they want to keep, they'd need to
   pass `-map 0` and per-stream flags; that's a future improvement, not
   a regression.

4. **First/last piece keyframe alignment.** The very first frame of the
   output will be a keyframe from somewhere *before* the first requested
   `$start`. This is fine — by definition the source had silence there
   (otherwise `$start` would have been earlier).

5. **`-avoid_negative_ts make_zero` vs `make_non_negative`.** `make_zero`
   is the right choice when concatenating; it pins the first piece's
   timestamps to start at exactly zero. `make_non_negative` would allow
   them to drift, which can confuse some players.

---

## Why this matches what the user actually said

* *"we just need to cut the empty spaces"* → only `silence ≥ T` is
  removed; everything else (speech, vad_only, breaths) is kept.
* *"when we are cutting needs to be a cut from the video, whatever the
  things from the video would be reproduced"* → stream copy gives us
  exactly the bytes from the source video for the kept ranges, no
  re-interpretation.
* *"we need the real video that we have as src when we are cutting,
  we need to split videos from that big video and later put them back
  together"* → that's literally what `ffmpeg -c copy` + concat does:
  splits the source into `.mp4` pieces (one per keep range), drops the
  ones in silence regions, and concatenates the rest.
* *"there is no need to sync audio this way as the video src has all
  the things sync"* → correct. Stream copy doesn't sync anything because
  it never decodes; the source's A/V relationship is preserved.
* *"i opened the original i cant feel this weird lip sync from the
  generated video"* → with stream copy there is no encoder, no AAC
  delay, no crossfade, so there is no drift to introduce.

---

## Verification plan

After implementing, the user should be able to:

1. Run `dnd-cut some_video.mp4` on a representative YouTube-style
   recording with a hello-intro, body, and goodbye-outro.
2. Open the original in DaVinci Resolve and the output side-by-side at
   a known speech point in the middle; the lip movement should match
   exactly. (Within stream copy's tolerance, the only allowed offset is
   the GOP-size of the previous keyframe, and that offset is constant
   across the whole output, not a drift.)
3. Open both files in ffprobe and confirm:
   * output duration == sum of keep-range durations (within
     GOP alignment tolerance),
   * output video codec / profile / pixel-format / sample-rate matches
     the source (because we copied it, not re-encoded it).

That's the spec.
