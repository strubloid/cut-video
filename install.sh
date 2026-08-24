#!/bin/bash

INSTALL_NAME="dnd-cut"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
SOURCE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dnd-cut.sh"
VENV_BIN="${BASH_ALIASES_VENV_BIN:-$HOME/.bash_aliases_scripts/.venv/bin}"

action="${1:-install}"

uninstall() {
  printf 'Uninstalling %s...\n' "$INSTALL_NAME"
  if [[ -L "$INSTALL_DIR/$INSTALL_NAME" ]]; then
    if [[ -w "$INSTALL_DIR" ]]; then
      rm -f "$INSTALL_DIR/$INSTALL_NAME"
    else
      sudo rm -f "$INSTALL_DIR/$INSTALL_NAME"
    fi
    printf '  removed %s/%s\n' "$INSTALL_DIR" "$INSTALL_NAME"
  else
    printf '  no symlink at %s/%s\n' "$INSTALL_DIR" "$INSTALL_NAME"
  fi
}

install() {
  printf 'Installing %s from %s\n' "$INSTALL_NAME" "$SOURCE_SCRIPT"

  chmod +x "$SOURCE_SCRIPT" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh"
  printf '  made scripts executable\n'

  if [[ ! -d "$INSTALL_DIR" ]]; then
    printf '  [error] %s does not exist. Set INSTALL_DIR=/some/path and re-run.\n' "$INSTALL_DIR"
    return 1
  fi

  local sudo_cmd=""
  if [[ ! -w "$INSTALL_DIR" ]]; then
    sudo_cmd="sudo"
    printf '  %s is not writable -- will use sudo\n' "$INSTALL_DIR"
  fi

  if [[ -e "$INSTALL_DIR/$INSTALL_NAME" ]]; then
    $sudo_cmd rm -f "$INSTALL_DIR/$INSTALL_NAME"
    printf '  removed existing %s/%s\n' "$INSTALL_DIR" "$INSTALL_NAME"
  fi

  $sudo_cmd ln -s "$SOURCE_SCRIPT" "$INSTALL_DIR/$INSTALL_NAME"
  printf '  linked %s/%s -> %s\n' "$INSTALL_DIR" "$INSTALL_NAME" "$SOURCE_SCRIPT"

  printf '\nRuntime dependencies:\n'
  local missing=0
  for cmd in ffmpeg ffprobe jq python3; do
    if command -v "$cmd" >/dev/null 2>&1; then
      printf '  [OK]   %s\n' "$cmd"
    else
      printf '  [MISS] %s\n' "$cmd"
      missing=1
    fi
  done

  if [[ -x "$VENV_BIN/whisper" ]]; then
    printf '  [OK]   whisper (%s)\n' "$VENV_BIN/whisper"
  else
    printf '  [MISS] whisper (expected at %s/whisper)\n' "$VENV_BIN"
    missing=1
  fi

  if [[ -x "$VENV_BIN/python" ]] && "$VENV_BIN/python" -c "import webrtcvad, scipy.io.wavfile, numpy" 2>/dev/null; then
    printf '  [OK]   webrtcvad / scipy / numpy\n'
  else
    printf '  [MISS] webrtcvad / scipy / numpy -- fix with: %s/pip install webrtcvad scipy numpy\n' "$VENV_BIN"
    missing=1
  fi

  printf '\n'
  if [[ "$missing" -eq 1 ]]; then
    printf 'Install complete, but some dependencies are missing. Install them before running %s.\n' "$INSTALL_NAME"
  else
    printf 'Install complete. Run:  %s <video-file>\n' "$INSTALL_NAME"
  fi
}

case "$action" in
  install)   install ;;
  uninstall) uninstall ;;
  -h|--help|help)
    printf 'Usage: %s [install|uninstall]\n' "$(basename "$0")"
    printf '  install    link %s into %s (default)\n' "$INSTALL_NAME" "$INSTALL_DIR"
    printf '  uninstall  remove the %s symlink\n' "$INSTALL_NAME"
    printf 'Env: INSTALL_DIR=/custom/path  BASH_ALIASES_VENV_BIN=/path/to/venv\n'
    ;;
  *) printf 'Unknown action: %s\n' "$action"; exit 1 ;;
esac
