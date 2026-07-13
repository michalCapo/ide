#!/bin/sh
set -eu

PAYLOAD_ID='@PAYLOAD_ID@'
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CACHE_BASE=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}
APP_DIR="$CACHE_BASE/lazygit-portable/$PAYLOAD_ID"

if [ ! -x "$APP_DIR/lazygit" ]; then
  command -v tar >/dev/null 2>&1 || { echo 'lazygit-portable requires tar to unpack itself' >&2; exit 127; }
  TMP_DIR="$APP_DIR.tmp.$$"
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  tail -n +@ARCHIVE_LINE@ "$0" | tar -xz -C "$TMP_DIR"
  mkdir -p "$(dirname "$APP_DIR")"
  rm -rf "$APP_DIR"
  mv "$TMP_DIR/lazygit-payload" "$APP_DIR"
  rmdir "$TMP_DIR" 2>/dev/null || true
fi

export PATH="$SELF_DIR:$PATH"
export LAZYGIT_NVIM_EDIT_HELPER="$APP_DIR/config/nvim-edit-parent"
export CONFIG_DIR="$APP_DIR/config"
if [ -z "${LG_CONFIG_FILE:-}" ]; then
  LG_CONFIG_FILE="$APP_DIR/config/config.yml"
  SCHEME=''
  if command -v gsettings >/dev/null 2>&1; then
    SCHEME=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || true)
  fi
  if [ -n "$SCHEME" ] && [ "$SCHEME" != "'prefer-dark'" ]; then
    LG_CONFIG_FILE="$LG_CONFIG_FILE,$APP_DIR/config/light-theme.yml"
  fi
  export LG_CONFIG_FILE
fi
exec "$APP_DIR/lazygit" "$@"
