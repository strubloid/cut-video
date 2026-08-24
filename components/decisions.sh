#!/bin/bash

function dnd-decisions-load() {
  local ws="$1"
  if [[ -f "$ws/decisions.json" ]]; then
    cat "$ws/decisions.json"
  else
    echo '{"updated": "", "items": []}'
  fi
}

function dnd-decision-for() {
  local dec_json="$1"
  local sid="$2"
  jq -r --argjson id "$sid" '
    (.items[] | select(.segment == $id) | .decision) // "pending"
  ' "$dec_json"
}

function dnd-decisions-append() {
  local ws="$1"
  local sid="$2"
  local decision="$3"
  local decisions="$ws/decisions.json"

  if [[ ! -f "$decisions" ]]; then
    echo '{"updated": "", "items": []}' > "$decisions"
  fi

  local tmp
  tmp=$(mktemp)
  jq --arg ts "$(date -Iseconds)" --argjson id "$sid" --arg d "$decision" '
    .updated = $ts
    | .items = (
        (.items | map(select(.segment != $id)))
        + [{segment: $id, decision: $d, ts: $ts}]
      )
  ' "$decisions" > "$tmp" && mv "$tmp" "$decisions"
}
