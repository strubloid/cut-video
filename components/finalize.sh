#!/bin/bash

function dnd-reconstruct-plan() {
  local ws="$1"
  local plan_json="$ws/analysis/timeline.json"
  local decisions="$ws/decisions.json"
  local final_plan="$ws/analysis/final-plan.json"

  jq -s '
    .[0] as $plan | .[1] as $dec
    | ( $dec.items | map(select(.decision=="restore")) | map(.segment) ) as $restore_ids
    | ( $plan.timeline        | map(select(.action=="keep")) ) as $keeps
    | ( $plan.questionable
        | map(select((.id as $i | $restore_ids | index($i)) != null))
        | map({start: .start, end: .end, classification: "restored",
               speech_confidence: .speech_confidence,
               reason: "Restored after manual review"})
      ) as $restored
    | ([$keeps[], $restored[]] | sort_by(.start)) as $all
    | ( reduce $all[] as $r ([];
          if . == [] then
            [{start: $r.start, end: $r.end, classification: $r.classification,
              speech_confidence: $r.speech_confidence, reason: $r.reason}]
          elif $r.start <= .[-1].end then
            .[:-1] + [ .[-1] | .end = (if $r.end > .end then $r.end else .end end) ]
          else
            . + [{start: $r.start, end: $r.end, classification: $r.classification,
                  speech_confidence: $r.speech_confidence, reason: $r.reason}]
          end
        )
      ) as $merged
    | ( reduce ($merged | range(0; length), -1) as $i (
          {timeline: [], last_end: 0, next_id: 0};
          if $i == -1 then
            if .last_end < $plan.duration then
              .timeline += [{
                id: .next_id,
                start: .last_end,
                end:   $plan.duration,
                duration: ($plan.duration - .last_end),
                classification: "gap",
                speech_confidence: 0,
                action: (if ($plan.duration - .last_end) >= $MIN_REMOVE_DURATION | not then "keep" else "remove" end),
                reason: "Trailing gap"
              }]
            else . end
          else
            . as $st
            | (if $merged[$i].start > $st.last_end and ($merged[$i].start - $st.last_end) > 0 then
                [{id: $st.next_id,
                  start: $st.last_end,
                  end:   $merged[$i].start,
                  duration: ($merged[$i].start - $st.last_end),
                  classification: "gap",
                  speech_confidence: 0,
                  action: "remove",
                  reason: "Non-speech gap"}]
               else [] end) as $pre
            | ($pre | length) as $plen
            | {
                timeline: ($st.timeline + $pre + [{
                  id: ($st.next_id + $plen),
                  start: $merged[$i].start,
                  end:   $merged[$i].end,
                  duration: ($merged[$i].end - $merged[$i].start),
                  classification: $merged[$i].classification,
                  speech_confidence: $merged[$i].speech_confidence,
                  action: "keep",
                  reason: $merged[$i].reason
                }]),
                last_end: $merged[$i].end,
                next_id:  ($st.next_id + $plen + 1)
              }
          end
        )
        | .timeline
      ) as $timeline
    | {
        duration: $plan.duration,
        timeline: $timeline,
        summary: $plan.summary,
      }' --argjson MIN_REMOVE_DURATION "$DND_MIN_REMOVE_DURATION" \
         "$plan_json" "$decisions" > "$final_plan"
}

function dnd-render-final() {
  local ws="$1"
  local input="$2"
  local plan_json="$ws/analysis/final-plan.json"
  local output="$ws/final.mp4"
  dnd-render-from-plan "$input" "$output" "$plan_json"
}

function dnd-print-summary() {
  local ws="$1"
  local input="$2"
  local plan_json="$ws/analysis/timeline.json"
  local final_plan="$ws/analysis/final-plan.json"
  local decisions="$ws/decisions.json"

  local orig_dur final_dur auto_rm qseg restored reviewed
  orig_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input")
  final_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$ws/final.mp4" 2>/dev/null || echo "n/a")
  auto_rm=$(jq '[.timeline[] | select(.action=="remove")] | map(.duration) | add // 0' "$plan_json")
  qseg=$(jq '.questionable | length' "$plan_json")
  restored=$(jq '[.items[] | select(.decision=="restore")] | length' "$decisions")
  reviewed=$(jq '[.items[] | select(.decision!="pending")] | length' "$decisions")

  cat <<EOF
============================================================
  DND video cut summary
============================================================
  Original duration : ${orig_dur}s
  Automatically removed : ${auto_rm}s
  Questionable segments  : ${qseg}
  Restored              : ${restored}
  Segments reviewed     : ${reviewed}
  Final duration        : ${final_dur}s
  Final output          : $ws/final.mp4
============================================================
EOF
}
