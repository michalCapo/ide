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
exec "$NVIM_BIN" -i NONE -c "lua require('views.lazydiff').launch({ focus_file = vim.env.LAZYDIFF_FILE })"
