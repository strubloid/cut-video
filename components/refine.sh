#!/bin/bash

function dnd-refine-cuts() {
  local ws="$1"
  local input="$2"
  local plan_json="$ws/analysis/timeline.json"
  local refined_json="$ws/analysis/timeline.refined.json"
  local audio_wav="$ws/analysis/audio.wav"
  local snap_window="${DND_SNAP_WINDOW_S:-0.5}"
  local audio_window="${DND_AUDIO_SNAP_WINDOW_S:-0.2}"

  dnd-log "Refining cut points (scene snap window=${snap_window}s, audio window=${audio_window}s)..."

  local pybin="${BASH_ALIASES_VENV_BIN}/python"
  "$pybin" - "$plan_json" "$refined_json" "$audio_wav" "$input" \
            "$snap_window" "$audio_window" <<'PYEOF'
import sys, json
import numpy as np
from scipy.io import wavfile
import subprocess
import re

(plan_p, ref_p, wav_p, input_p, snap_window_s, audio_window_s) = sys.argv[1:7]
snap_window = float(snap_window_s)
audio_window = float(audio_window_s)

with open(plan_p) as f:
    plan = json.load(f)

rate, data = wavfile.read(wav_p)
if data.ndim > 1:
    data = data[:, 0]
data = data.astype(np.float64)
n_samples = len(data)
duration = n_samples / rate
print(f"[refine] audio: {rate} Hz, {duration:.2f}s, {n_samples} samples", file=sys.stderr)


def detect_scenes(input_file, threshold=0.4):
    cmd = [
        'ffmpeg', '-hide_banner', '-nostats', '-i', input_file,
        '-vf', f"select='gt(scene,{threshold})',showinfo",
        '-an', '-f', 'null', '-'
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    except subprocess.TimeoutExpired:
        print("[refine] scene detection timed out, continuing without scene snap", file=sys.stderr)
        return []

    scene_times = []
    for line in result.stderr.split('\n'):
        m = re.search(r'pts_time:([\d.]+)', line)
        if m:
            t = float(m.group(1))
            if 0.0 < t < duration:
                scene_times.append(t)
    return scene_times


def find_best_cut(time, window=0.2):
    start_sample = max(0, int((time - window) * rate))
    end_sample   = min(n_samples, int((time + window) * rate))
    if end_sample - start_sample < int(0.02 * rate):
        return time

    segment = data[start_sample:end_sample]
    win_size = max(1, int(0.010 * rate))
    n_win = max(1, (len(segment) - win_size) // win_size)
    if n_win == 0:
        return time

    rms = np.empty(n_win, dtype=np.float64)
    for i in range(n_win):
        s = segment[i*win_size:(i+1)*win_size]
        rms[i] = float(np.sqrt(np.mean(s * s)) + 1e-9)

    k = int(np.argmin(rms))
    min_sample = k * win_size + win_size // 2

    signs = np.sign(segment)
    zero_crossings = np.where(np.diff(signs) != 0)[0]
    if len(zero_crossings) == 0:
        return time

    distances = np.abs(zero_crossings - min_sample)
    nearest_zc = int(zero_crossings[int(np.argmin(distances))])
    return (start_sample + nearest_zc) / rate


def snap_to_scene(time, scenes, window):
    best = None
    best_d = window + 1
    for s in scenes:
        d = abs(s - time)
        if d <= window and d < best_d:
            best = s
            best_d = d
    return best


scenes = detect_scenes(input_p)
print(f"[refine] detected {len(scenes)} scene changes in {input_p}", file=sys.stderr)

kept = [s for s in plan['timeline'] if s.get('action') == 'keep']
print(f"[refine] refining {len(kept)} keep-segments...", file=sys.stderr)

refined_timeline = []
scene_snapped = 0
audio_snapped = 0
unchanged = 0

for seg in plan['timeline']:
    if seg.get('action') != 'keep':
        refined_timeline.append(seg)
        continue

    orig_s, orig_e = seg['start'], seg['end']
    new_s, new_e = orig_s, orig_e

    snapped_s = snap_to_scene(orig_s, scenes, snap_window)
    if snapped_s is not None:
        new_s = round(snapped_s, 3)
        scene_snapped += 1
    else:
        new_s = round(find_best_cut(orig_s, audio_window), 3)
        if abs(new_s - orig_s) > 0.001:
            audio_snapped += 1
        else:
            unchanged += 1

    snapped_e = snap_to_scene(orig_e, scenes, snap_window)
    if snapped_e is not None:
        new_e = round(snapped_e, 3)
    else:
        new_e = round(find_best_cut(orig_e, audio_window), 3)

    if new_e - new_s < 0.05:
        new_s, new_e = orig_s, orig_e

    new_seg = dict(seg)
    new_seg['start'] = new_s
    new_seg['end'] = new_e
    new_seg['duration'] = round(new_e - new_s, 3)
    new_seg['original_start'] = orig_s
    new_seg['original_end'] = orig_e
    refined_timeline.append(new_seg)

with open(ref_p, 'w') as f:
    json.dump({
        'duration': plan['duration'],
        'timeline': refined_timeline,
        'questionable': plan.get('questionable', []),
        'summary': plan.get('summary', {}),
        'refinement': {
            'scene_changes_detected': len(scenes),
            'scene_snapped': scene_snapped,
            'audio_snapped': audio_snapped,
            'unchanged': unchanged,
        },
    }, f, indent=2)

print(f"[refine] scene-snap: {scene_snapped}, audio-snap: {audio_snapped}, unchanged: {unchanged}", file=sys.stderr)
print(f"[refine] wrote {ref_p}", file=sys.stderr)
PYEOF
}
