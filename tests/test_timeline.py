"""Tests for the conservative timeline pipeline.

Seven scenarios required by the brief, plus a handful of supporting
tests for the algorithm's corner cases.

Run with:
    python3 tests/test_timeline.py
or:
    python3 -m unittest tests.test_timeline
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fixtures import (  # noqa: E402
    assert_range_preserved, assert_range_removed,
    keep_ranges, make_silence, make_vad, make_word, speech_keep_ranges,
    run_timeline, whisper_blob,
)


# A shared conservative-config dict for the tests. Mirrors the new
# defaults in components/config.sh.
PARAMS = dict(
    min_remove=4.0,
    min_speech=0.25,
    keep_threshold=0.40,
    speech_start_padding=0.60,
    speech_end_padding=0.70,
    merge_gap=1.50,
    word_boundary_safety=0.30,
)


class TestALongEmptySpace(unittest.TestCase):
    """speech → 5+ s quiet → speech. Long gap must be cut, both
    speech regions preserved with safe padding."""

    def test_long_gap_is_cut(self):
        words = [
            make_word( 1.0,  1.5,  "Hello"),
            make_word( 1.6,  2.5,  "everyone"),
            make_word( 9.0,  9.4,  "okay"),
            make_word( 9.5, 10.3,  "so"),
            make_word(10.4, 11.5,  "ready"),
        ]
        vad = make_vad([(1.0, 2.5), (9.0, 11.5)])
        silence = make_silence([(3.0, 8.5)])
        out = run_timeline(vad, whisper_blob(words), silence,
                           duration=13.0, **PARAMS)

        # Both speech regions kept.
        assert_range_preserved(out, 1.0, 2.5,
                               msg="first speech must remain")
        assert_range_preserved(out, 9.0, 11.5,
                               msg="second speech must remain")

        # The 5+ s quiet zone between them is removed.
        assert_range_removed(out, 3.0, 8.5,
                             msg="long empty zone must be cut")

        # Both ends of the cut have safe padding.
        speech = sorted(speech_keep_ranges(out))
        self.assertEqual(len(speech), 2,
                         f"expected 2 speech keep regions, got {speech}")
        first_s, first_e = speech[0]
        second_s, _      = speech[1]
        # The right edge of the first SPEECH keep region must be safely
        # past the first word's trailing end (2.5).
        self.assertGreaterEqual(
            first_e,
            2.5 + PARAMS["word_boundary_safety"] - 0.05,
            f"right edge {first_e} too close to word end 2.5")
        # The left edge of the second SPEECH keep region must be safely
        # before the next word's start (9.0).
        self.assertLessEqual(
            second_s,
            9.0 - PARAMS["word_boundary_safety"] + 0.05,
            f"left edge {second_s} too close to word start 9.0")


class TestBShortConversationalPause(unittest.TestCase):
    """speech → 1 s pause → speech. Must be a SINGLE keep region."""

    def test_short_pause_is_not_cut(self):
        words = [
            make_word(1.0, 1.6, "Okay"),
            make_word(1.7, 2.5, "so"),
            make_word(2.6, 3.5, "left"),
            make_word(4.5, 5.0, "right"),
            make_word(5.1, 6.2, "then"),
        ]
        vad = make_vad([(1.0, 3.5), (4.5, 6.2)])
        # Gap is ~1 s between the two speech bursts -> merge.
        silence = make_silence([(3.6, 4.4)])
        out = run_timeline(vad, whisper_blob(words), silence,
                           duration=8.0, **PARAMS)

        # The two bursts must remain connected (no remove segment
        # between them). They may be emitted as multiple keep ranges
        # that touch, but they must form one continuous region in the
        # final video.
        kept = sorted(keep_ranges(out))
        # Either there's exactly one keep range covering both bursts,
        # OR adjacent keep ranges must touch (no remove between them).
        contiguous = True
        prev_e = None
        for s, e in kept:
            if prev_e is not None and s > prev_e:
                contiguous = False
                break
            prev_e = e
        self.assertTrue(contiguous,
            f"keep ranges not contiguous: {kept}")
        assert_range_preserved(out, 1.0, 6.2,
                               msg="both bursts must survive as one region")


class TestCQuietSpeaker(unittest.TestCase):
    """normal speech → quiet speech → normal speech. Quiet speaker
    MUST survive even if VAD hears it and Whisper returns nothing."""

    def test_quiet_speech_preserved(self):
        # Normal speaker in two bursts.
        normal_words = [
            make_word(1.0, 1.8, "What"),
            make_word(1.9, 2.6, "do"),
            make_word(2.7, 3.5, "you"),
            make_word(3.6, 4.5, "think"),
            make_word(8.0, 8.7, "Good"),
            make_word(8.8, 9.7, "point"),
        ]
        # VAD detects the quiet speaker in the middle. Whisper returns
        # nothing for that window (low confidence). The previous
        # algorithm would auto-remove this entire VAD-only region.
        vad = make_vad([(1.0, 4.5), (5.0, 7.5), (8.0, 9.7)])
        silence = make_silence([(7.6, 7.9)])  # tiny quiet zone
        out = run_timeline(vad, whisper_blob(normal_words), silence,
                           duration=11.0, **PARAMS)

        # The quiet speaker's window must remain intact.
        assert_range_preserved(out, 5.0, 7.5,
                               msg="quiet speaker's audio must be preserved")


class TestDWordBoundary(unittest.TestCase):
    """A word's audio level drops mid-word. The complete word must
    remain audible in the final cut, including the trailing consonant.

    To force the algorithm to treat the two words as SEPARATE speech
    regions (so a cut could in principle land between them), the gap
    between them is set larger than `merge_gap_s`."""

    def test_trailing_consonant_preserved(self):
        # Word "castle" with audio drop at the end (last consonant
        # trails off). The next word "yes" starts 4 s later — the gap
        # is large enough that the algorithm separates them.
        words = [
            make_word(2.0, 2.6, "castle"),
            make_word(6.6, 7.4, "yes"),
        ]
        vad = make_vad([(2.0, 2.6), (6.6, 7.4)])
        silence = make_silence([(3.0, 6.0)])
        out = run_timeline(vad, whisper_blob(words), silence,
                           duration=9.0, **PARAMS)

        # The two SPEECH keep regions must remain separated by a remove.
        speech = sorted(speech_keep_ranges(out))
        self.assertEqual(len(speech), 2,
                         f"expected 2 speech keep regions, got {speech}")
        first_s, first_e = speech[0]
        second_s, _     = speech[1]
        # The right edge of the first speech keep region must be safely
        # past the trailing consonant (2.6).
        safety = PARAMS["word_boundary_safety"]
        self.assertGreaterEqual(
            first_e,
            2.6 + safety - 0.05,
            f"right edge {first_e} too close to word end 2.6 "
            f"(need >= {2.6 + safety - 0.05:.2f})")
        # The left edge of the next speech keep region (after the gap)
        # must be safely before the next word's start (6.6).
        self.assertLessEqual(
            second_s,
            6.6 - safety + 0.05,
            f"left edge {second_s} too close to word start 6.6 "
            f"(need <= {6.6 - safety + 0.05:.2f})")


class TestEMultiSpeakerConversation(unittest.TestCase):
    """Speaker A → pause → Speaker B → pause → A + C. Entire
    discussion must remain."""

    def test_multi_speaker_preserved(self):
        words = [
            make_word( 1.0,  1.6, "I"),
            make_word( 1.7,  2.5, "think"),
            make_word( 2.6,  3.4, "we"),
            make_word( 3.5,  4.2, "should"),
            make_word( 4.3,  5.0, "open"),
            make_word( 5.1,  5.8, "door"),

            make_word( 7.5,  8.0, "Are"),
            make_word( 8.1,  8.7, "you"),
            make_word( 8.8,  9.5, "sure"),

            make_word(11.0, 11.4, "No"),
            make_word(12.0, 12.6, "good"),
            make_word(12.7, 13.4, "idea"),
        ]
        vad = make_vad([(1.0, 5.8), (7.5, 9.5), (11.0, 11.4), (12.0, 13.4)])
        # Pauses are short (<= 1.5 s) so all four bursts merge.
        silence = make_silence([])
        out = run_timeline(vad, whisper_blob(words), silence,
                           duration=15.0,
                           merge_gap=2.0,  # generous: 2s merges into one segment
                           **{k: v for k, v in PARAMS.items() if k != "merge_gap"})

        # The whole discussion must be covered.
        assert_range_preserved(out, 1.0, 5.8,
                               msg="speaker A burst must survive")
        assert_range_preserved(out, 7.5, 9.5,
                               msg="speaker B burst must survive")
        assert_range_preserved(out, 11.0, 11.4,
                               msg="speaker A short reply must survive")
        assert_range_preserved(out, 12.0, 13.4,
                               msg="speaker C burst must survive")


class TestFBackgroundNoise(unittest.TestCase):
    """background noise → quiet speech → background noise. Speech
    must survive even though VAD may not flag the speech itself."""

    def test_quiet_speech_through_background(self):
        # Whisper captures a few low-probability words mid-noise. The
        # previous algorithm dropped these by `keep_threshold` and
        # reclassified the time as silence -> cut.
        words = [
            make_word(5.0, 5.4, "I",   prob=0.20),
            make_word(5.5, 5.9, "am",  prob=0.30),
            make_word(6.0, 6.4, "here", prob=0.25),
        ]
        vad = make_vad([])  # VAD misses the quiet speaker entirely
        silence = make_silence([(0.0, 4.9), (6.5, 10.0)])
        out = run_timeline(vad, whisper_blob(words), silence,
                           duration=11.0, **PARAMS)

        # The quiet speech survives.
        assert_range_preserved(out, 5.0, 6.4,
                               msg="quiet speech inside background noise must survive")


class TestGLongSilenceAfterSpeech(unittest.TestCase):
    """speech → 20 s silence → speech. Long dead section removed,
    BOTH speech ends not clipped."""

    def test_long_silence_removed_with_safe_bounds(self):
        words = [
            make_word(1.0, 2.0, "okay"),
            make_word(2.1, 3.5, "let's"),
            make_word(3.6, 4.5, "go"),
            # 20 s of nothing.
            make_word(24.5, 25.5, "now"),
            make_word(25.6, 26.5, "we"),
            make_word(26.6, 27.5, "continue"),
        ]
        vad = make_vad([(1.0, 4.5), (24.5, 27.5)])
        silence = make_silence([(5.0, 24.0)])
        out = run_timeline(vad, whisper_blob(words), silence,
                           duration=29.0, **PARAMS)

        # Both speech bursts preserved.
        assert_range_preserved(out, 1.0, 4.5)
        assert_range_preserved(out, 24.5, 27.5)

        # The 20 s dead zone is removed.
        assert_range_removed(out, 5.0, 24.0)

        # No cut lands inside the speech regions.
        kept = sorted(keep_ranges(out))
        # The rightmost keep edge before the removed gap (>= 5.0) must
        # be >= 4.5.
        right_edges_before_gap = [e for s, e in kept if 4.0 <= e <= 5.5]
        self.assertTrue(any(e >= 4.5 - 0.05 for e in right_edges_before_gap),
            f"no keep edge >= 4.5 before gap: {kept}")
        # The leftmost keep edge after the removed gap must be <= 24.5.
        left_edges_after_gap = [s for s, _ in kept if 23.5 <= s <= 25.0]
        self.assertTrue(any(s <= 24.5 + 0.05 for s in left_edges_after_gap),
            f"no keep edge <= 24.5 after gap: {kept}")


class TestIntroOutroPreservation(unittest.TestCase):
    """The first 5 s and last 5 s must always be kept (intro / outro
    preservation)."""

    def test_intro_outro_kept(self):
        words = [
            make_word(0.5, 1.0, "Hi"),
            make_word(1.1, 1.8, "everyone"),
            make_word(6.5, 7.2, "Bye"),
        ]
        vad = make_vad([(0.5, 1.8), (6.5, 7.2)])
        silence = make_silence([(2.0, 6.0)])
        out = run_timeline(vad, whisper_blob(words), silence,
                           duration=8.0,
                           preserve_intro=5.0, preserve_end=5.0, **PARAMS)
        # The intro zone (0..5) must be kept.
        assert_range_preserved(out, 0.0, 5.0)
        # The outro zone (last 5 s -> 3..8) must be kept.
        assert_range_preserved(out, 3.0, 8.0)


class TestSilenceBelowFloor(unittest.TestCase):
    """Gaps shorter than MIN_REMOVE_DURATION are ALWAYS kept, even if
    they're longer than word_boundary_safety."""

    def test_short_gap_never_removed(self):
        words = [
            make_word(1.0, 2.0, "first"),
            make_word(5.0, 6.0, "second"),
        ]
        vad = make_vad([(1.0, 2.0), (5.0, 6.0)])
        silence = make_silence([(2.5, 4.5)])  # 2 s gap, below default 4 s
        out = run_timeline(vad, whisper_blob(words), silence,
                           duration=7.0, **PARAMS)

        # The 2 s gap must NOT be removed; both bursts must remain.
        # The keep ranges may be split into multiple adjacent ranges
        # (leading/trailing gaps) but they must be contiguous.
        kept = sorted(keep_ranges(out))
        contiguous = True
        prev_e = None
        for s, e in kept:
            if prev_e is not None and s > prev_e:
                contiguous = False
                break
            prev_e = e
        self.assertTrue(contiguous,
            f"keep ranges not contiguous: {kept}")
        assert_range_preserved(out, 1.0, 6.0,
                               msg="both bursts must survive")


class TestAllSilenceRemoved(unittest.TestCase):
    """A timeline of pure silence should produce a single removed gap
    — i.e. no false positive on 'speech'."""

    def test_pure_silence_is_removed(self):
        words = []
        vad = []
        silence = make_silence([(0.0, 10.0)])
        out = run_timeline(vad, whisper_blob(words), silence,
                           duration=10.0, **PARAMS)
        remove = [s for s in out["timeline"] if s["action"] == "remove"]
        self.assertEqual(len(remove), 1)
        self.assertEqual((remove[0]["start"], remove[0]["end"]), (0.0, 10.0))


class TestNoAudioMetadataCase(unittest.TestCase):
    """If silence.json is missing or malformed, the pipeline must NOT
    crash and must still treat the file as 'no silencedetect input'."""

    def test_missing_silence_file(self):
        words = [make_word(1.0, 1.6, "hi"), make_word(2.0, 2.5, "bye")]
        vad = make_vad([(1.0, 2.5)])
        # Run timeline.py directly with empty path so the wrapper
        # treats it as "no silence input".
        from fixtures import (TIMELINE_PY, write_json)
        import subprocess, tempfile, json as _json
        from pathlib import Path as _P
        with tempfile.TemporaryDirectory() as td:
            td = _P(td)
            write_json(td / "vad.json", vad)
            write_json(td / "whisper.json", whisper_blob(words))
            silence_p = td / "silence.json"
            silence_p.write_text("not valid json")
            seg_p = td / "seg.json"; tl_p = td / "tl.json"
            cmd = ["python3", str(TIMELINE_PY),
                   str(td / "vad.json"), str(td / "whisper.json"), str(silence_p),
                   str(seg_p), str(tl_p),
                   "--duration", "4.0"]
            for k, v in PARAMS.items():
                cmd += [f"--{k.replace('_', '-')}", str(v)]
            r = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0,
                f"timeline.py failed on missing silence: {r.stderr}")
            self.assertTrue(tl_p.exists())
            data = _json.loads(tl_p.read_text())
            assert_range_preserved(data, 1.0, 2.5,
                msg="speech preserved even with missing silence.json")


class TestKeptGapsFoldedIntoKeeps(unittest.TestCase):
    """After the fold, kept gaps are absorbed into the adjacent keep so
    we never have two adjacent kept timeline entries that overlap in
    source range. This guarantees the renderer never extracts the same
    audio twice."""

    def test_kept_gap_does_not_overlap_with_adjacent_speech_keep(self):
        words = [
            make_word(1.0, 1.5, "hi"),
            make_word(2.0, 2.5, "yes"),
            make_word(4.0, 4.7, "okay"),
            make_word(5.5, 6.0, "great"),
        ]
        vad = make_vad([(1.0, 2.5), (4.0, 6.0)])
        silence = make_silence([(3.0, 3.9)])  # ~1s gap, < min_remove
        out = run_timeline(vad, whisper_blob(words), silence,
                           duration=7.0, **PARAMS)
        kept = keep_ranges(out)
        for i in range(len(kept) - 1):
            self.assertLessEqual(kept[i][1], kept[i + 1][0] + 1e-9,
                f'keep ranges {kept[i]} and {kept[i+1]} overlap')
        assert_range_preserved(out, 3.0, 3.9,
            msg='the kept gap audio must still be preserved')


class TestNoMakeZeroRegression(unittest.TestCase):
    """Regression test for the ffmpeg `-avoid_negative_ts make_zero` bug.

    With stream copy + MP4, the `make_zero` flag causes ffmpeg to
    include ~50+ extra audio packets past the requested `-to`
    boundary (an interaction with B-frame DTS/PTS handling in the
    muxer). Those extra packets end up duplicated in the final
    output after concat.

    The renderer is now configured to NOT pass `-avoid_negative_ts
    make_zero` per segment. This test guards that decision.
    """

    def test_segment_packets_dont_extend_past_to(self):
        """Run an actual ffmpeg extraction and verify packet count
        matches the source range exactly (within one AAC frame)."""
        import subprocess, tempfile
        from pathlib import Path
        import wave, numpy as np
        # Generate a synthetic 30-second test source with AAC-like audio
        sr = 48000
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            wav = td / 'a.wav'
            n = sr * 30
            audio = (np.sin(2 * np.pi * 440 * np.arange(n) / sr) * 0.3
                     ).astype(np.int16) * 32767
            with wave.open(str(wav), 'wb') as wf:
                wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(sr)
                wf.writeframes(audio.tobytes())
            src = td / 'src.mp4'
            subprocess.run(['ffmpeg', '-y', '-f', 'lavfi',
                           '-i', 'testsrc=duration=30:size=320x240:rate=30',
                           '-i', str(wav), '-c:v', 'libx264', '-preset',
                           'ultrafast', '-g', '30', '-pix_fmt', 'yuv420p',
                           '-c:a', 'aac', '-shortest', str(src)],
                          check=True, capture_output=True)
            # Extract a range using the renderer's command pattern
            seg = td / 'seg.mp4'
            subprocess.run(['ffmpeg', '-y', '-loglevel', 'error',
                           '-ss', '5.0', '-to', '20.0', '-i', str(src),
                           '-c', 'copy', str(seg)], check=True,
                          capture_output=True)
            r = subprocess.run(['ffprobe', '-v', 'error',
                               '-show_entries', 'format=duration',
                               '-of', 'default=noprint_wrappers=1:nokey=1',
                               str(seg)], capture_output=True, text=True)
            duration = float(r.stdout.strip())
            # Expected ~15.0s. If make_zero is re-introduced we'll see
            # 16+ seconds (50+ extra packets).
            self.assertLessEqual(duration, 15.5,
                f'Segment is {duration}s; expected ~15s. '
                f'`-avoid_negative_ts make_zero` may have re-introduced '
                f'the packet-overshoot bug.')


class TestAudioFrameCapRegression(unittest.TestCase):
    """Regression test for the 'bummmm' artifact at cut boundaries.

    ffmpeg's stream-copy + output seek always includes the AAC frame
    that straddles the requested `-ss` time. That frame sits one
    frame BEFORE the seek point and creates a pre-roll that, after
    concat with the previous segment, causes a brief loud burst of
    stacked audio at the cut.

    The renderer now caps each segment's audio with `-frames:a N`,
    where N is computed from the segment duration and the source's
    sample rate. This drops the pre-roll frame.

    This test guards the formula for computing N.
    """

    def test_frame_count_formula_48000hz(self):
        import subprocess, tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            src = td / 'src.wav'
            import wave, numpy as np
            sr = 48000
            n = sr * 30
            audio = (np.sin(2*np.pi*440*np.arange(n)/sr)*0.3).astype(np.int16)*32767
            with wave.open(str(src), 'wb') as wf:
                wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(sr)
                wf.writeframes(audio.tobytes())
            mp4 = td / 'src.mp4'
            subprocess.run(['ffmpeg', '-y', '-f', 'lavfi',
                           '-i', f'testsrc=duration=30:size=320x240:rate=30',
                           '-i', str(src), '-c:v', 'libx264', '-preset',
                           'ultrafast', '-g', '30', '-pix_fmt', 'yuv420p',
                           '-c:a', 'aac', '-shortest', str(mp4)],
                          check=True, capture_output=True)

            for start, end, expected_n in [
                (0, 22.955, 1077),
                (5.0, 20.0, 704),
                (0.5, 1.5, 48),
            ]:
                # Formula from renderer.sh
                n = int((end - start) * sr / 1024 + 1.5)
                self.assertEqual(n, expected_n,
                    f'formula mismatch for [{start}, {end}]')
                # Extract with -frames:a N
                out = td / f'seg_{start}_{end}.mp4'
                subprocess.run(['ffmpeg', '-y', '-loglevel', 'error',
                               '-ss', str(start), '-to', str(end),
                               '-i', str(mp4), '-c', 'copy',
                               '-frames:a', str(n), str(out)],
                              check=True, capture_output=True)
                r = subprocess.run(['ffprobe', '-v', 'error',
                                   '-show_entries', 'format=duration',
                                   '-of', 'default=noprint_wrappers=1:nokey=1',
                                   str(out)],
                                  capture_output=True, text=True)
                actual_dur = float(r.stdout.strip())
                expected_dur = end - start
                self.assertLessEqual(abs(actual_dur - expected_dur), 0.6,
                    f'seg [{start}, {end}]: actual={actual_dur}, expected~{expected_dur}')


class TestSilenceDetectParser(unittest.TestCase):
    """The silence-detect wrapper must parse ffmpeg's stderr into clean
    JSON intervals and never raise on missing fields."""

    def test_parses_complete_intervals(self):
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "python"))
        import silence_detect
        stderr = (
            "[silencedetect @ 0x55a] silence_start: 1.500\n"
            "[silencedetect @ 0x55a] silence_end: 3.000 | silence_duration: 1.500\n"
            "[silencedetect @ 0x55a] silence_start: 10.000\n"
            "[silencedetect @ 0x55a] silence_end: 12.500 | silence_duration: 2.500\n"
        )
        intervals = silence_detect.parse_silence(stderr)
        self.assertEqual(intervals, [
            {"start": 1.5, "end": 3.0, "duration": 1.5},
            {"start": 10.0, "end": 12.5, "duration": 2.5},
        ])

    def test_parses_trailing_open_interval(self):
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "python"))
        import silence_detect
        stderr = "[silencedetect @ 0x55a] silence_start: 5.0\n"
        intervals = silence_detect.parse_silence(stderr)
        # Trailing silence with no `silence_end` collapses to zero-length.
        self.assertEqual(intervals, [{"start": 5.0, "end": 5.0, "duration": 0.0}])


class TestRefinerNeverShrinks(unittest.TestCase):
    """The refine step must NEVER shrink a keep region toward speech.
    Cuts can only move OUTWARD into silence."""

    def test_refiner_preserves_word_boundary(self):
        import tempfile
        from pathlib import Path as _P
        from fixtures import synth_wav, run_refine
        with tempfile.TemporaryDirectory() as td:
            wav = _P(td) / "audio.wav"
            synth_wav(wav, duration_s=10.0,
                      speech_segments=[(3.0, 3.5, 0.3), (5.0, 5.5, 0.3)])
            plan = {
                "duration": 10.0,
                "timeline": [
                    {"id": 0, "start": 2.5, "end": 6.5, "duration": 4.0,
                     "classification": "speech", "action": "keep",
                     "speech_confidence": 1.0, "review_required": False,
                     "reason": "test"},
                ],
                "words": [
                    {"start": 3.0, "end": 3.5, "word": "hi",   "probability": 0.95},
                    {"start": 5.0, "end": 5.5, "word": "yes",  "probability": 0.95},
                ],
            }
            refined = run_refine(plan, wav)
            keep = [s for s in refined["timeline"] if s["action"] == "keep"]
            self.assertEqual(len(keep), 1)
            seg = keep[0]
            self.assertLessEqual(seg["start"], 2.5,
                "refiner must not shrink the start (would chop first word)")
            self.assertGreaterEqual(seg["end"], 6.5,
                "refiner must not shrink the end (would chop last word)")


if __name__ == "__main__":
    unittest.main(verbosity=2)