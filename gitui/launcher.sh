#!/bin/sh
set -eu

PAYLOAD_ID='@PAYLOAD_ID@'
CACHE_BASE=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}
APP_DIR="$CACHE_BASE/gitui-portable/$PAYLOAD_ID"

if [ ! -x "$APP_DIR/gitui" ]; then
  command -v tar >/dev/null 2>&1 || { echo 'gitui-portable requires tar to unpack itself' >&2; exit 127; }
  TMP_DIR="$APP_DIR.tmp.$$"
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  tail -n +@ARCHIVE_LINE@ "$0" | tar -xz -C "$TMP_DIR"
  mkdir -p "$(dirname "$APP_DIR")"
  rm -rf "$APP_DIR"
  mv "$TMP_DIR/gitui-payload" "$APP_DIR"
  rmdir "$TMP_DIR" 2>/dev/null || true
fi

USER_THEME=${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/gitui/theme.ron
if [ -f "$USER_THEME" ]; then
  exec "$APP_DIR/gitui" "$@"
fi
exec "$APP_DIR/gitui" --theme "$APP_DIR/theme.ron" "$@"
