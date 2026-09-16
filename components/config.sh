#!/bin/bash

# ---------------------------------------------------------------------------
# Cut-region padding (kept around each speech / activity region).
# These are deliberately large; the priority is preserving speech,
# not maximizing compression. The pre/post-roll names are kept as
# backwards-compatible aliases of speech-start / speech-end padding.
# ---------------------------------------------------------------------------
export DND_PRE_ROLL="${DND_PRE_ROLL:-0.60}"
export DND_POST_ROLL="${DND_POST_ROLL:-0.70}"
export DND_SPEECH_START_PADDING="${DND_SPEECH_START_PADDING:-$DND_PRE_ROLL}"
export DND_SPEECH_END_PADDING="${DND_SPEECH_END_PADDING:-$DND_POST_ROLL}"

# ---------------------------------------------------------------------------
# Gap-handling thresholds (conservative).
# MIN_REMOVE_DURATION is the floor: gaps shorter than this are ALWAYS kept.
# MIN_KEEP_SILENCE_S is a hard floor specifically against aggressive cutting
# of natural conversational pauses.
# MERGE_GAP_S controls when nearby speech regions are merged into one
# conversational segment.
# ---------------------------------------------------------------------------
export DND_MIN_REMOVE_DURATION="${DND_MIN_REMOVE_DURATION:-4.00}"
export DND_MIN_KEEP_SILENCE_S="${DND_MIN_KEEP_SILENCE_S:-1.00}"
export DND_MERGE_GAP_S="${DND_MERGE_GAP_S:-1.50}"

# ---------------------------------------------------------------------------
# Word-boundary safety: cuts are never placed within this many seconds of
# any Whisper word. Larger value = safer (more audio kept around words).
# ---------------------------------------------------------------------------
export DND_WORD_BOUNDARY_SAFETY_S="${DND_WORD_BOUNDARY_SAFETY_S:-0.30}"

# ---------------------------------------------------------------------------
# Whisper confidence. Previously a strict filter that dropped quiet-speech
# words. Now used only for *labelling* speech_confidence; the timeline
# algorithm treats every Whisper word as activity regardless of probability.
# ---------------------------------------------------------------------------
export DND_SPEECH_KEEP_THRESHOLD="${DND_SPEECH_KEEP_THRESHOLD:-0.40}"
export DND_SPEECH_REVIEW_THRESHOLD="${DND_SPEECH_REVIEW_THRESHOLD:-0.50}"

# Micro speech regions (shorter than this) are dropped from the conversational
# segments. Defaults are conservative so single-word replies survive.
export DND_MIN_SPEECH_DURATION="${DND_MIN_SPEECH_DURATION:-0.25}"

# ---------------------------------------------------------------------------
# ffmpeg silencedetect parameters. Treated as ONE signal among several,
# never as a hard cut signal. noise is in dBFS, default is conservative
# for D&D sessions where background noise (fans, room tone) sits around
# -35 to -40 dBFS.
# ---------------------------------------------------------------------------
export DND_SILENCEDETECT_NOISE_DB="${DND_SILENCEDETECT_NOISE_DB:--35}"
export DND_SILENCEDETECT_MIN_DURATION="${DND_SILENCEDETECT_MIN_DURATION:-0.50}"

# ---------------------------------------------------------------------------
# Intro / outro preservation (presenter greeting / end screen).
# Set to 0 to disable.
# ---------------------------------------------------------------------------
export DND_PRESERVE_INTRO_S="${DND_PRESERVE_INTRO_S:-90}"
export DND_PRESERVE_END_S="${DND_PRESERVE_END_S:-300}"

# ---------------------------------------------------------------------------
# Whisper / VAD.
# ---------------------------------------------------------------------------
export DND_WHISPER_MODEL="${DND_WHISPER_MODEL:-small}"
export DND_WHISPER_LANGUAGE="${DND_WHISPER_LANGUAGE:-}"
export DND_WHISPER_DEVICE="${DND_WHISPER_DEVICE:-cuda}"

export DND_AUTO_RESUME="${DND_AUTO_RESUME:-ask}"
export DND_NO_PAUSE="${DND_NO_PAUSE:-0}"
export BASH_ALIASES_VENV_BIN="${BASH_ALIASES_VENV_BIN:-$HOME/.bash_aliases_scripts/.venv/bin}"

export DND_LOG_FILE="${DND_LOG_FILE:-}"
export DND_ERROR_LOG="${DND_ERROR_LOG:-}"
export DND_QUIT_REQUESTED="${DND_QUIT_REQUESTED:-0}"

# ---------------------------------------------------------------------------
# Refiner: expand-only. EXTEND_WINDOW_S is the maximum outward extension
# into surrounding silence. 0 disables extension entirely.
# ---------------------------------------------------------------------------
export DND_REFINE_WORD_SAFETY_S="${DND_REFINE_WORD_SAFETY_S:-$DND_WORD_BOUNDARY_SAFETY_S}"
export DND_REFINE_EXTEND_WINDOW_S="${DND_REFINE_EXTEND_WINDOW_S:-0.25}"
# Legacy knobs preserved for the shell layer:
export DND_SNAP_WINDOW_S="${DND_SNAP_WINDOW_S:-0.0}"
export DND_AUDIO_SNAP_WINDOW_S="${DND_AUDIO_SNAP_WINDOW_S:-0.0}"

# ---------------------------------------------------------------------------
# Renderer.
# ---------------------------------------------------------------------------
export DND_RENDER_MODE="${DND_RENDER_MODE:-auto}"
export DND_RENDER_THREADS="${DND_RENDER_THREADS:-}"
export DND_VIDEO_CRF="${DND_VIDEO_CRF:-18}"
export DND_AUDIO_BITRATE="${DND_AUDIO_BITRATE:-192k}"
export DND_KEEP_SEGMENTS="${DND_KEEP_SEGMENTS:-1}"

# Whether the renderer should snap to the PREVIOUS keyframe instead of the
# NEXT one when starting a cut. The previous-snap direction is safe: it can
# only add audio to the segment, never remove it. Set to 0 to revert.
export DND_RENDER_BACKWARD_KEYFRAME_SNAP="${DND_RENDER_BACKWARD_KEYFRAME_SNAP:-1}"

# Trim each rendered segment's end by this many seconds so the boundary
# does not share a packet with the next segment in stream-copy mode
# (which would cause a frame/audio to appear twice). 0.04 s ~= 1 frame
# at 25 fps. Set to 0 to disable the trim.
export DND_RENDER_BOUNDARY_EPSILON_S="${DND_RENDER_BOUNDARY_EPSILON_S:-0.04}"