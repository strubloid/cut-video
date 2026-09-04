#!/bin/bash

function dnd-build-timeline() {
  local ws="$1"
  local duration="$2"
  local vad_json="$ws/analysis/vad.json"
  local whisper_json="$ws/analysis/audio.json"
  local segments_json="$ws/analysis/segments.json"
  local timeline_json="$ws/analysis/timeline.json"

  dnd-log "Building classified timeline..."

  local pybin="${BASH_ALIASES_VENV_BIN}/python"
  "$pybin" - "$vad_json" "$whisper_json" "$segments_json" "$timeline_json" \
           "$duration" "$DND_MIN_SPEECH_DURATION" "$DND_MIN_REMOVE_DURATION" \
           "$DND_SPEECH_KEEP_THRESHOLD" \
           "$DND_PRE_ROLL" "$DND_POST_ROLL" <<'PYEOF'
import sys, json

(vad_p, wh_p, seg_p, tl_p, dur,
 min_speech, min_remove,
 keep_thr,
 pre_roll, post_roll) = sys.argv[1:11]

duration      = float(dur)
min_speech    = float(min_speech)
min_remove    = float(min_remove)
keep_thr      = float(keep_thr)
pre_roll      = float(pre_roll)
post_roll     = float(post_roll)

with open(vad_p) as f:
    vad = json.load(f)
with open(wh_p) as f:
    wh  = json.load(f)

words = []
for seg in wh.get("segments", []):
    no_speech_prob = float(seg.get("no_speech_prob", 0.0) or 0.0)
    if no_speech_prob > 0.6:
        continue
    for w in seg.get("words", []) or []:
        if "start" not in w or "end" not in w:
            continue
        prob = float(w.get("probability", 0.0) or 0.0)
        txt  = (w.get("word") or "").strip()
        if not txt:
            continue
        words.append({
            "start": float(w["start"]),
            "end":   float(w["end"]),
            "probability": prob,
            "word":  txt,
        })

RES = 0.05
n = int(duration / RES) + 2
labels = ["silence"] * n
vad_p_arr = [0.0] * n

for w in words:
    if w["probability"] < keep_thr:
        continue
    s = max(0, int(w["start"] / RES))
    e = min(n - 1, int(w["end"]   / RES))
    for i in range(s, e + 1):
        labels[i] = "speech"

for r in vad:
    s = max(0, int(r["start"] / RES))
    e = min(n - 1, int(r["end"]   / RES))
    for i in range(s, e + 1):
        if labels[i] == "silence":
            labels[i] = "vad_only"

regions = []
cur = labels[0]; cs = 0
for i in range(1, n):
    if labels[i] != cur:
        regions.append((cur, cs * RES, i * RES))
        cur = labels[i]; cs = i
regions.append((cur, cs * RES, n * RES))

classified = []
idx = 0
for state, s, e in regions:
    d = e - s
    rec = {
        "id": idx,
        "start": round(s, 3),
        "end":   round(e, 3),
        "duration": round(d, 3),
        "classification": state,
        "speech_confidence": 0.0,
        "action": "keep",
        "review_required": False,
        "reason": "",
    }
    if state == "speech":
        rec["action"] = "keep"
        rec["reason"] = "Whisper transcribed words in this range"
        rec["speech_confidence"] = 1.0
    elif state == "vad_only":
        rec["action"] = "keep"
        rec["review_required"] = False
        rec["reason"] = "Speech-like audio without transcribed text (kept: not silence)"
        rec["speech_confidence"] = 0.5
    else:
        if d < min_remove:
            rec["action"] = "keep"
            rec["reason"] = f"Silence shorter than MIN_REMOVE_DURATION ({min_remove}s)"
            rec["speech_confidence"] = 0.0
        else:
            rec["action"] = "remove"
            rec["review_required"] = False
            rec["reason"] = "No speech-like audio detected"
            rec["speech_confidence"] = 0.0
    classified.append(rec)
    idx += 1

classified = [
    r for r in classified
    if not (r["classification"] == "speech" and r["duration"] < min_speech)
]

def expand_speech(seg):
    return {
        "start":  max(0.0, seg["start"]  - pre_roll),
        "end":    min(duration, seg["end"] + post_roll),
        "classification": seg.get("classification", "speech"),
    }

expanded = [
    expand_speech(r) for r in classified
    if r["action"] == "keep" and r["classification"] != "silence"
]
expanded.sort(key=lambda x: x["start"])

merged = []
for r in expanded:
    if merged and r["start"] <= merged[-1]["end"]:
        merged[-1]["end"] = max(merged[-1]["end"], r["end"])
    else:
        merged.append(dict(r))

timeline = []
seg_id = 0
cursor = 0.0
for m in merged:
    if m["start"] > cursor:
        gap_d = m["start"] - cursor
        if gap_d >= min_remove:
            timeline.append({
                "id": seg_id,
                "start":  round(cursor, 3),
                "end":    round(m["start"], 3),
                "duration": round(gap_d, 3),
                "classification": "silence",
                "speech_confidence": 0.0,
                "action": "remove",
                "review_required": False,
                "reason": "Empty space (no audio detected) — removed",
            })
            seg_id += 1
    cls = m.get("classification", "speech")
    timeline.append({
        "id": seg_id,
        "start":  round(m["start"], 3),
        "end":    round(m["end"], 3),
        "duration": round(m["end"] - m["start"], 3),
        "classification": cls,
        "speech_confidence": 1.0 if cls == "speech" else 0.5,
        "action": "keep",
        "review_required": False,
        "reason": "Kept audio region (with padding)" if cls == "speech"
                  else "Kept audio region — speech-like without Whisper transcript",
    })
    seg_id += 1
    cursor = m["end"]

if cursor < duration - 0.01:
    gap_d = duration - cursor
    if gap_d >= min_remove:
        timeline.append({
            "id": seg_id,
            "start":  round(cursor, 3),
            "end":    round(duration, 3),
            "duration": round(gap_d, 3),
            "classification": "silence",
            "speech_confidence": 0.0,
            "action": "remove",
            "review_required": False,
            "reason": "Trailing empty space — removed",
        })
        seg_id += 1

with open(seg_p, "w") as f:
    json.dump(classified, f, indent=2)

with open(tl_p, "w") as f:
    json.dump({
        "duration":    round(duration, 3),
        "timeline":    timeline,
        "summary": {
            "keep_seconds":      round(sum(t["duration"] for t in timeline if t["action"] == "keep"), 3),
            "remove_seconds":    round(sum(t["duration"] for t in timeline if t["action"] == "remove"), 3),
            "remove_segments":   sum(1 for t in timeline if t["action"] == "remove"),
            "keep_segments":     sum(1 for t in timeline if t["action"] == "keep"),
        },
    }, f, indent=2)
PYEOF
}
