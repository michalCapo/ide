#!/bin/sh
set -eu

PAYLOAD_ID='@PAYLOAD_ID@'
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CACHE_BASE=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}
APP_DIR="$CACHE_BASE/nvim-portable/$PAYLOAD_ID"

if [ ! -x "$APP_DIR/nvim/bin/nvim" ]; then
  command -v tar >/dev/null 2>&1 || { echo 'nvim-portable requires tar to unpack itself' >&2; exit 127; }
  TMP_DIR="$APP_DIR.tmp.$$"
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  tail -n +@ARCHIVE_LINE@ "$0" | tar -xz -C "$TMP_DIR"
  mkdir -p "$(dirname "$APP_DIR")"
  rm -rf "$APP_DIR"
  mv "$TMP_DIR/nvim-payload" "$APP_DIR"
  rmdir "$TMP_DIR" 2>/dev/null || true
fi

export NVIM_PORTABLE_INIT="$APP_DIR/config/init.lua"
if [ -x "$SELF_DIR/lazygit" ]; then
  export NVIM_PORTABLE_LAZYGIT="$SELF_DIR/lazygit"
fi
if [ "${NVIM_PORTABLE_LAZYDIFF:-}" = 1 ]; then
  exec "$APP_DIR/nvim/bin/nvim" -u NORC --cmd "set runtimepath^=$APP_DIR/config" "$@"
fi
exec "$APP_DIR/nvim/bin/nvim" -u "$NVIM_PORTABLE_INIT" "$@"
