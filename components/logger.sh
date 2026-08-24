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

function dnd-on-interrupt() {
  local rc="${1:-130}"
  dnd-err "Interrupted (line ${LINENO:-?}, exit=$rc). Workspace preserved -- see $DND_LOG_FILE and $DND_ERROR_LOG. Re-run to resume."
  exit 130
}

function dnd-pause-on-exit() {
  local rc=$?
  if [[ $rc -ne 0 && $rc -ne 130 ]]; then
    if [[ -n "${DND_ERROR_LOG:-}" && -s "$DND_ERROR_LOG" ]]; then
      dnd-err "Script exited with status $rc. See $DND_ERROR_LOG for details."
    else
      dnd-err "Script exited with status $rc. See output above for details."
    fi
  fi
  if [[ "${DND_NO_PAUSE:-0}" == "1" || ! -t 0 ]]; then
    return 0
  fi
  printf '\n' >&2
  read -rp "[dnd] Press enter to exit... (set DND_NO_PAUSE=1 to skip) " </dev/tty || true
}
