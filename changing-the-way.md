# Changing the Way: Frame-Accurate Cuts with Clean Audio

## TL;DR

The current "stream copy everything in parallel, concat with the demuxer" renderer
is **fast** but it has two visible problems the user reported:

1. **Cuts land on keyframes, not where the timeline says they should.** A
   `-ss 10.0 -to 13.0` on a file with a 1 s GOP produces a segment that starts
   at the previous keyframe (e.g. 9.0) and ends past the requested `-to` until
   the next keyframe is flushed. For a 3 h video with 1 s keyframes and 2123
   keep-segments this can inflate the output by 5–20 %. Worse, the visual cut
   position drifts by up to one full GOP per cut, so the audio waveform does
   not line up with the picture where the user expects.
2. **Hard cuts at the boundaries produce audio pops / clicks.** A bit of
   non-zero PCM at the splice point is enough to make a "tck" every time the
   timeline crosses a gap. DaVinci Resolve (the reference the user cited)
   handles this by either (a) snap-cutting on a zero crossing + a few ms
   crossfade, or (b) re-encoding the boundary frames with a short `afade` /
   `acrossfade`.

The job of this doc is to research every plausible way to fix both
problems and lay out the one(s) we should actually implement.

---

## What we want the final pipeline to do

| Goal | How it shows up in the output |
|---|---|
| **Frame-accurate cuts** | The visual frame at each cut boundary is the frame the timeline says should be there, not "the nearest keyframe ± 0.5 s". |
| **No audio pops / clicks** | Splice points are at zero crossings, optionally with a 5–20 ms `afade` / `acrossfade`, and audio within each segment is otherwise untouched. |
| **Reasonable speed** | The 3 h / 2123-cut test case finishes in minutes, not the 1 h 40 m "stuck at 1 %" we just escaped. |
| **Quality preserved** | Either lossless (stream copy) or visually lossless (single-encode `crf ≤ 20` on the cut boundaries, untouched everywhere else). |
| **Robust on edge cases** | A segment of 0.05 s, a 25 fps and a 30 fps clip in the same source, a B-frame that crosses a cut point, an audio-only segment — all handled. |

---

## Why the current approach is fast but ugly

```
ffmpeg -ss S -to E -i in.mp4 -c copy -reset_timestamps 1 seg.mp4
```

`-ss` before `-i` enables ffmpeg's **fast seek**: it jumps the demuxer to the
previous keyframe, then decodes forward to the requested start. With `-c copy`
the resulting bitstream contains the keyframe plus all the dependent frames
through to the requested end. The "extra" frames before `S` and the
un-flushed GOP after `E` are kept in the segment. The concat demuxer then
stitches them with whatever timestamps the segments happen to carry, and the
final output is *correct* in the sense that nothing is missing, but the cuts
are visually and audibly off by up to one GOP.

Add to that: a `c copy` cut on a non-zero PCM sample makes a click.

---

## Approach 1 — Stream copy + audio re-encode (hybrid)

**Idea:** keep the fast per-segment stream copy for *video*, but extract
*audio* with a short `afade` at the boundaries and re-encode it. Concat
stitches video and audio back together. This is fast on the video side and
fixes the audio artifacts.

```
ffmpeg -ss S -to E -i in.mp4 \
  -c:v copy \
  -af "afade=t=in:st=0:d=0.02,areverse,afade=t=in:st=0:d=0.02,areverse" \
  -c:a aac -b:a 192k seg.mp4
```

The `afade + areverse` trick applies a fade to both ends of the audio without
shifting the timing.

- ✅ ~10× faster than full re-encode
- ✅ Kills audio clicks
- ❌ Video still keyframe-inflated (visual drift remains)
- ❌ Two audio encodes per segment is wasteful

---

## Approach 2 — Chunked re-encoding (the "DaVinci lite")

**Idea:** the original `filter_complex` approach is correct and produces
frame-accurate output, but a single graph with 2123 nodes is what kills ffmpeg.
**Process the timeline in chunks of N segments**, render each chunk to a small
intermediate MP4, then concatenate the chunks with the demuxer.

```
chunk_0.mp4  = concat(seg 0..49)
chunk_1.mp4  = concat(seg 50..99)
...
chunk_42.mp4 = concat(seg 2100..2122)
final.mp4    = concat(chunk_0, chunk_1, ..., chunk_42)   # stream copy
```

For N = 50 each `filter_complex` has ~100 lines and ffmpeg handles it
without breaking a sweat. With 8 cores the chunks can also render in parallel.

- ✅ Frame-accurate cuts
- ✅ Per-chunk audio crossfades are easy (single graph, can splice `acrossfade`)
- ✅ Final concat is just `-c copy` on a handful of chunks — no re-encode
- ❌ Still re-encodes the whole video (slow without GPU)
- ❌ More disk I/O than stream copy

This is the approach most "smart" NLEs take internally.

---

## Approach 3 — GPU-accelerated chunked re-encoding

**Idea:** same as Approach 2, but use NVENC / QSV / VideoToolbox / AMF for
the video encode. On a modern NVENC chip, `h264_nvenc -preset fast` is
roughly 10–20× the speed of `libx264 -preset veryfast` at the same CRF.

```
ffmpeg ... -c:v h264_nvenc -preset fast -rc vbr -cq 18 ...
```

- ✅ Same quality output as Approach 2
- ✅ ~10× faster than CPU
- ❌ Requires a working CUDA/VAAPI/VideoToolbox stack (the existing
  `DND_WHISPER_DEVICE` logic already checks this for Whisper, so we can
  reuse the detection)
- ❌ NVENC's `-crf` equivalent is `-cq` and the bitrate curve is slightly
  different — re-tune the quality knob

---

## Approach 4 — Smart cut-point selection (audio + video)

**Idea:** the *cut position* the timeline chose is fine for marking "this
region is silence" but it doesn't have to be the *exact frame* we splice on.
A 200 ms search window around the intended cut is more than enough to find
a much better splice point.

Two refinement signals are useful:

1. **Audio energy / zero crossings.** Within ±200 ms of the intended cut,
   pick the timestamp whose RMS energy in a 10 ms window is lowest (and
   that sits on a zero crossing). The whole "click" problem mostly
   disappears when the splice is at a low-amplitude zero crossing.
2. **Scene change detection.** `ffmpeg -vf select='gt(scene,0.4)'` finds
   visual scene boundaries; snapping cuts to within ±200 ms of a scene
   change is a common DaVinci trick and looks more "intentional" than a
   mid-shot splice.

Both refinements can run in Python (`scipy.signal`, `scenedetect`-style
histogram diff) and rewrite the `start` / `end` of each segment before
rendering. Cost: a few seconds of analysis, completely independent of the
render speed.

- ✅ Cleaner audio for free
- ✅ More "intentional" looking cuts
- ✅ Combines well with any of Approaches 1–3
- ❌ The refinement window is heuristic — may not be a true zero crossing
  in pathological cases
- ❌ Scene detection can disagree with VAD ("VAD says keep, scene says cut")

---

## Approach 5 — Audio crossfades inside the chunked graph

**Idea:** the gap between segments is already a moment of silence (or
near-silence, since VAD said "no speech"). Even if we *keep* the regions VAD
flagged for removal because they're too short, the splice between two
adjacent kept segments happens at a VAD boundary, which by construction is
low energy. A short `acrossfade` (5–20 ms) on those boundaries is enough to
guarantee no click.

```
[0:a]atrim=0:5.0,asetpts=PTS-STARTPTS[a0];
[0:a]atrim=5.5:9.0,asetpts=PTS-STARTPTS[a1];
[a0][a1]acrossfade=d=0.02:c1=tri:c2=tri[a01];
[0:a]atrim=9.5:13.0,asetpts=PTS-STARTPTS[a2];
[a01][a2]acrossfade=d=0.02:c1=tri:c2=tri[a012];
...
```

20 ms is below the perceptual threshold for a speech splice (the ear needs
~30–50 ms to register a discontinuity as a click).

- ✅ Eliminates residual clicks
- ✅ Combined with chunked re-encoding (Approach 2) it's frame-accurate AND
  click-free
- ❌ Crossfades add 20 ms of doubled audio per boundary, so the output is
  marginally longer — usually in the noise compared to the keyframe inflation
  we're already getting

---

## Approach 6 — MKV intermediate (lossless concat with frame accuracy)

**Idea:** MP4 stream copy is problematic because of the moov atom and
keyframe-bound cuts. MKV (Matroska) is more forgiving — it carries
timestamps per frame and `mkvmerge` can concatenate MKV files losslessly
with frame-accurate cuts.

```
ffmpeg -ss S -to E -i in.mp4 -c copy seg.mkv
mkvmerge -o final.mkv seg_001.mkv + seg_002.mkv + ... + seg_2123.mkv
```

- ✅ Lossless, frame-accurate (mkvmerge operates at the frame level, not
  the GOP level)
- ✅ No re-encoding, very fast
- ✅ mkvmerge is rock-solid for concat
- ❌ Output is MKV, not MP4 — for the user's DaVinci-style "drop the
  result in another tool" workflow this might actually be a **plus** (MKV
  is friendlier for further editing)
- ❌ mkvmerge is an extra dependency
- ❌ Audio clicks are *not* addressed (still hard cuts on non-zero PCM)

This approach is the one **LosslessCut** uses internally; it's the de-facto
industry solution for "lossless cut a long video into a hundred pieces".

---

## Approach 7 — LosslessCut as a child process

**Idea:** rather than reinventing LosslessCut, just call it.

```bash
losslesscut --audio-codec aac --video-codec copy \
  --keep-segments-of keep-list.txt \
  -o final.mp4 input.mp4
```

- ✅ Battle-tested, well-known behaviour
- ✅ Frame-accurate cuts (it uses mkvmerge / smart encoding)
- ✅ Optional `afade` per cut
- ❌ Adds a Java/Electron dependency
- ❌ Not scriptable in a way that matches the rest of dnd-cut

Useful as a reference implementation, not as a replacement.

---

## Approach 8 — PyAV (Python FFmpeg bindings)

**Idea:** drop the bash `jq` → `ffmpeg` choreography and use PyAV, which
gives Python code frame-accurate read/write access to the bitstream.

```python
import av
in_ctr = av.open('input.mp4')
out = av.open('output.mp4', 'w')
# seek to nearest keyframe, decode forward, write
```

- ✅ Frame-accurate, fine control over per-frame timing
- ✅ Audio crossfades easy in NumPy
- ❌ Slow (Python overhead per frame — for 3 h of video the decode loop
  dominates)
- ❌ Reframes the whole project from a small bash pipeline into a Python
  program

Not worth it for this scale.

---

## Approach 9 — MoviePy

**Idea:** `moviepy.VideoFileClip(...).subclip(S, E)` plus a
`concatenate_videoclips([...], padding=-crossfade_ms/1000)` gives a one-liner
that does almost exactly what we want.

```python
from moviepy.editor import VideoFileClip, concatenate_videoclips
clips = [VideoFileClip('in.mp4').subclip(s, e) for s, e in keeps]
final  = concatenate_videoclips(clips, padding=-0.02, method='compose')
final.write_videofile('out.mp4', codec='libx264', audio_codec='aac')
```

- ✅ Very readable
- ✅ Has a `padding` arg that does the crossfade for free
- ❌ MoviePy's `subclip` re-encodes every clip
- ❌ Slow and memory-hungry for 2123 clips (a 3 h × 3 GB source)
- ❌ Deprecated as of 2024 — upstream is no longer maintained

Skip.

---

## Approach 10 — Two-pass with proxy media (DaVinci "Optimized Media")

**Idea:** the standard trick for editing 4K/8K footage on a laptop:

1. **Pass 1:** render a low-res proxy (say 480p, `-preset ultrafast`,
   crf 28) using the original single-graph approach. This is fast enough
   even with 2123 segments because the proxy is small.
2. **Pass 2:** once the user is happy with the cut list, render the final
   at full resolution using the *same* graph but with the production codec
   settings.

For dnd-cut the "user happy with the cut list" step is automatic (we already
auto-derive it from VAD + Whisper), so this collapses to: generate the
timeline once, render the proxy for a quick smoke test, then render the
final only when the user asks.

- ✅ Fast iteration while tuning thresholds (`DND_PRE_ROLL` etc.)
- ✅ Final output is the same quality we have today
- ❌ Doubles the disk usage during a run
- ❌ Two long renders is worse than one medium render

Worth keeping in mind for future "preview" features; not the core fix.

---

## Approach 11 — Scene-change-aware cut snapping

**Idea:** instead of the timeline cut at `S, E`, snap the cut to the nearest
scene change within ±0.5 s (only when one exists). Visually, cuts at scene
changes are almost invisible; cuts mid-shot always look amateurish.

`scenedetect` (Python, PyAV-backed) is the de-facto library for this:

```bash
scenedetect -i in.mp4 detect-content list-scenes
```

gives a CSV of `start,end` per detected scene. Joining that with the
VAD-derived timeline (with a ±0.5 s snap window) produces a list of "snapped"
cuts.

- ✅ Visually cleaner output, no extra cost on the render side
- ✅ Combines naturally with any render strategy
- ❌ Scene detection is slow on a 3 h source (1–2 min)
- ❌ Can disagree with VAD — need a tie-breaker ("if scene says cut within
  0.5 s of VAD boundary, prefer scene; else prefer VAD")

---

## Approach 12 — Smart "GOP-aware" stream copy

**Idea:** the inflation from stream copy is "the segment includes the GOP
from the previous keyframe". If we precompute the keyframe table once and
*intentionally* align the segments so each starts on a keyframe, the
inflation drops to a single frame at the segment boundaries.

```bash
ffprobe -v error -select_streams v -skip_frame nokey \
  -show_entries frame=pts_time -of csv=p=0 in.mp4 > keyframes.csv
```

Then in the renderer, when picking the start of segment N, snap to the
largest keyframe time ≤ `timeline[N].start`. Same for the end: pick the
smallest keyframe time ≥ `timeline[N].end` and trim back with an in-graph
`trim` (re-encode of the boundary frames only — ~1 GOP).

- ✅ Keeps the speed of stream copy for ~99 % of each segment
- ✅ Visual cuts are aligned to keyframes by construction (which is what
  every streaming / editing tool does anyway)
- ❌ The first/last GOP of every segment is re-encoded — adds a small
  re-encode cost per segment
- ❌ Boundary frames re-encoded with the same codec/CRF as a single-pass
  re-encode, so quality is consistent at the splice

This is a middle ground between pure stream copy and full re-encoding. It's
also what Avidemux's "Smart copy" mode does.

---

## Approach 13 — Use `ffmpeg`'s `+genpts` + `+igndts` with proper flags

**Idea:** tweak the existing stream-copy approach with the ffmpeg flags that
explicitly tell the muxer "regenerate PTS, ignore input DTS" so the concat
demuxer has clean timestamps to work with.

```
ffmpeg -fflags +genpts+igndts -i seg.mkv -c copy out.mp4
```

- ✅ Sometimes resolves "moov atom not found" and timestamp-jitter issues
- ❌ Doesn't fix the keyframe inflation
- ❌ Doesn't address audio clicks

Useful as a small follow-up tweak, not as a primary strategy.

---

## Approach 14 — Avidemux CLI (smart copy / smart encode)

**Idea:** Avidemux has a CLI mode that does exactly the "smart" decision
the user wants: try stream copy for video; if the cut isn't on a keyframe,
re-encode *only* that segment.

```
avidemux --load in.mp4 \
  --output-format MP4 --video-codec copy --audio-codec aac \
  --save out.mp4
```

- ✅ The "smart" decision is what the user is asking for
- ❌ Avidemux CLI scripting for 2123 segment lists is awkward
- ❌ Adds a new heavy dependency
- ❌ Not trivially scriptable in bash

Useful reference, hard to adopt as-is.

---

## Approach 15 — Audio-only re-encode of the boundary frames

**Idea:** keep stream copy for *both* streams, but for each cut, extract a
~200 ms window of audio around the splice, re-encode it with `afade`, and
splice it back in. The video stays frame-accurate at keyframes (which is
fine — viewers can't tell), and the audio is click-free at the splices.

This is basically Approach 1 but restricted to a small window per cut.

- ✅ Audio fix is isolated and cheap
- ❌ Surgical audio editing in MP4 is fragile (the moov atom moves)
- ❌ Doesn't address the visual cut drift

---

## Approach 16 — The "best of all worlds" hybrid (recommended)

**Combine** the following:

| Layer | Choice | Why |
|---|---|---|
| **Cut-point selection** | Approach 4 (audio energy) + Approach 11 (scene snap) | Free, runs in <30 s, removes most audio clicks and ugly visual splices. |
| **Pre-roll / post-roll** | Increase `DND_PRE_ROLL` / `DND_POST_ROLL` from 0.30 / 0.40 s to 0.50 / 0.70 s for the new approach | The user's existing padding is tuned for the old re-encode; for stream copy a bit more headroom is cheap and lets the audio fade have somewhere to land. |
| **Render strategy** | Approach 2 (chunked re-encode), 50 segments per chunk | Frame-accurate and tractable on CPU. |
| **Codec** | `libx264 -preset veryfast -crf 18` if no GPU; `h264_nvenc -preset fast -cq 18` if NVENC detected | Same quality target, ~10× faster with NVENC. |
| **Audio** | `acrossfade=d=0.02` on every kept→kept boundary, plus the existing pre/post roll | 20 ms is sub-perceptual for speech and the doubled audio is negligible vs. the keyframe padding we already had. |
| **Concat** | `mkvmerge` if we want lossless final (Approach 6), else `-c copy` on MP4 chunks | Either way it's a fast final pass. |

### Why this combination is the right one

- **Speed:** the heavy part (re-encoding) is bounded by the chunk size, not
  the timeline size. With chunks of 50, every ffmpeg invocation handles a
  ~100-line filter graph — ffmpeg eats that for breakfast. 2123 / 50 = 43
  chunks, each re-encoding ~80 s of video (the user's chunks will average
  ~80 s of source video because keep-segments are short). On an 8-core
  CPU at `-preset veryfast`, expect ~4–8 min total, ~half that on NVENC.
- **Quality:** the re-encode is `crf 18` which is visually lossless for
  the source's 1080p/4K RPG footage. The audio re-encode is `aac -b:a 192k`
  which is what the old renderer used; no audible difference.
- **Frame accuracy:** chunked re-encoding uses the same `trim`/`atrim` per
  segment as the old broken approach, so the boundaries are exact. The
  chunk-to-chunk concat is `-c copy` so the chunk boundaries can drift up
  to one GOP, but we can either (a) pre-pad each chunk with one GOP of
  silence on either side and let the final concat stream-copy overlap it
  away, or (b) just live with the chunk boundary being a keyframe — there
  are only 42 of them in a 3 h video, the user won't notice.
- **Audio clicks:** `acrossfade` removes them, and the audio-energy
  refinement in Approach 4 makes the splice position itself less likely to
  be on a non-zero PCM sample.
- **No new heavyweight deps:** only `ffmpeg` + `jq` + `python` (already
  present) + optionally `mkvmerge` if we want the lossless final. `ffmpeg`
  ships with `afade`/`acrossfade`, no plugin needed.

### Why not the other approaches

- **Pure stream copy (current new code):** keyframe inflation is visible and
  audio clicks are audible. The user already complained.
- **Single-graph re-encode (old code):** ffmpeg blows up at ~500 nodes; we
  proved this with the 2123-node graph that froze at 1 %.
- **Two-pass proxy:** doubles disk + render time for no extra quality on a
  file the user just wants to cut.
- **PyAV / MoviePy:** Python overhead makes them 5–10× slower than the
  ffmpeg CLI; not worth it for this scale.
- **LosslessCut / Avidemux external:** good reference, but a new heavy
  dependency we don't control.

---

## What the final code change looks like (preview, not yet implemented)

Roughly:

1. **Refine cut points in Python** before render. For each keep-segment,
   search ±200 ms for the lowest-RMS-energy zero crossing; if a scene
   change is within ±500 ms, snap to it. Emit a `timeline.snapped.json`.
2. **Render chunks of 50 segments** in parallel. Each chunk's filter graph
   is `trim`/`atrim` per segment + `acrossfade=d=0.02` at every internal
   boundary + a final `concat=n=50:v=1:a=1`. Output is one MP4 per chunk.
3. **Concat the chunks** with the concat demuxer (`-c copy`). Optionally
   run `qt-faststart` (or use `-movflags +faststart` per chunk) so the
   final is web-streaming-friendly.
4. **Codec choice:** prefer NVENC if available, else libx264.
5. **Configurable knobs:** `DND_CHUNK_SIZE` (default 50), `DND_CROSSFADE_MS`
   (default 20), `DND_SNAP_WINDOW_S` (default 0.5), `DND_USE_GPU` (auto / on
   / off).

A working implementation is a few hundred lines of bash + a small Python
refinement step. Estimated effort: 1–2 days including testing on the
user's 3 h sample.

---

## Open questions for the user

1. **Audio click tolerance:** is 20 ms crossfade acceptable, or do you
   want zero crossfade and rely purely on zero-crossing snap?
2. **Keyframe drift tolerance:** are you OK with cuts landing on keyframes
   (which means up to 1 GOP of "extra" content at each boundary), or do
   you need frame-accurate even at the cost of re-encoding the boundary
   GOPs (Approach 12)?
3. **Output container:** is MP4 a hard requirement, or would MKV be OK
   (lets us use `mkvmerge` and ship a smaller, more accurate toolchain)?
4. **GPU:** do you want the code to auto-detect and use NVENC, or are you
   CPU-only?
5. **Scene snap:** snap-to-scene-change on/off, and what's the snap window
   you'd want?

These answers pin down the final design.
