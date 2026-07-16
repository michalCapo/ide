#!/bin/sh
set -eu

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NVIM_BIN=${LAZYDIFF_NVIM:-$SELF_DIR/@INSTALL_NAME@}
if [ ! -x "$NVIM_BIN" ]; then
  NVIM_BIN=$(command -v "@INSTALL_NAME@" || true)
fi
[ -n "$NVIM_BIN" ] || { echo 'lazydiff requires @INSTALL_NAME@ on PATH' >&2; exit 127; }
if [ "$#" -gt 0 ]; then
  export LAZYDIFF_FILE=$1
  shift
fi
export NVIM_PORTABLE_LAZYDIFF=1

# `e` writes the selected file and cursor position here. Once the lightweight
# viewer exits, pass that request through Lazygit's editor helper. The helper
# closes Lazygit, allowing the terminal's parent Neovim to open the file.
EDIT_HANDOFF=$(mktemp "${TMPDIR:-/tmp}/lazydiff-edit.XXXXXX")
trap 'rm -f "$EDIT_HANDOFF"' EXIT HUP INT TERM
export LAZYDIFF_EDIT_HANDOFF=$EDIT_HANDOFF

status=0
"$NVIM_BIN" -i NONE -c "lua require('views.lazydiff').launch({ focus_file = vim.env.LAZYDIFF_FILE })" || status=$?

if [ -s "$EDIT_HANDOFF" ]; then
  file=$(sed -n '1p' "$EDIT_HANDOFF")
  line=$(sed -n '2p' "$EDIT_HANDOFF")
  col=$(sed -n '3p' "$EDIT_HANDOFF")
  line=${line:-1}
  col=${col:-0}
  case $line in *[!0-9]*) line=1 ;; esac
  case $col in *[!0-9]*) col=0 ;; esac

  if [ -n "${LAZYGIT_NVIM_EDIT_REQUEST:-}" ] && [ -x "${LAZYGIT_NVIM_EDIT_HELPER:-}" ]; then
    "$LAZYGIT_NVIM_EDIT_HELPER" "$file" "$line" "$col"
    exit 0
  fi

  # Standalone lazydiff has no parent editor. Replace it with the normal
  # configured Neovim instead of leaving the file in the lightweight viewer.
  trap - EXIT HUP INT TERM
  rm -f "$EDIT_HANDOFF"
  unset NVIM_PORTABLE_LAZYDIFF LAZYDIFF_EDIT_HANDOFF LAZYDIFF_FILE
  exec "$NVIM_BIN" "+call cursor($line,$((col + 1)))" -- "$file"
fi

exit "$status"
