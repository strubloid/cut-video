#!/bin/bash

function dnd-log() {
  local ts
  ts="$(date -Iseconds 2>/dev/null || date)"
  if [[ -n "$DND_LOG_FILE" ]]; then
    printf '%s [INFO]  %s\n' "$ts" "$*" >> "$DND_LOG_FILE"
  fi
  printf '[dnd] %s\n' "$*" >&2
}

function dnd-warn() {
  local ts
  ts="$(date -Iseconds 2>/dev/null || date)"
  if [[ -n "$DND_LOG_FILE" ]]; then
    printf '%s [WARN]  %s\n' "$ts" "$*" >> "$DND_LOG_FILE"
  fi
  if [[ -n "$DND_ERROR_LOG" ]]; then
    printf '%s [WARN]  %s\n' "$ts" "$*" >> "$DND_ERROR_LOG"
  fi
  printf '[dnd][warn] %s\n' "$*" >&2
}

function dnd-err() {
  local ts
  ts="$(date -Iseconds 2>/dev/null || date)"
  if [[ -n "$DND_LOG_FILE" ]]; then
    printf '%s [ERROR] %s\n' "$ts" "$*" >> "$DND_LOG_FILE"
  fi
  if [[ -n "$DND_ERROR_LOG" ]]; then
    printf '%s [ERROR] %s\n' "$ts" "$*" >> "$DND_ERROR_LOG"
  fi
  printf '[dnd][error] %s\n' "$*" >&2
}

function dnd-format-ts() {
  local s="${1}"
  awk -v s="$s" 'BEGIN {
    h = int(s / 3600); s -= h*3600
    m = int(s / 60);   s -= m*60
    printf "%02d:%02d:%06.3f\n", h, m, s
  }'
}

function dnd-valid-json() {
  local p="$1"
  [[ -f "$p" ]] || return 1
  jq empty "$p" >/dev/null 2>&1
}
