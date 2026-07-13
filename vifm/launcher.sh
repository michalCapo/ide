#!/bin/sh
set -eu

PAYLOAD_ID='@PAYLOAD_ID@'
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CACHE_BASE=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}
APP_DIR="$CACHE_BASE/vifm-portable/$PAYLOAD_ID"

if [ ! -x "$APP_DIR/app/AppRun" ]; then
  command -v tar >/dev/null 2>&1 || { echo 'vifm-portable requires tar to unpack itself' >&2; exit 127; }
  TMP_DIR="$APP_DIR.tmp.$$"
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  tail -n +@ARCHIVE_LINE@ "$0" | tar -xz -C "$TMP_DIR"
  mkdir -p "$(dirname "$APP_DIR")"
  rm -rf "$APP_DIR"
  mv "$TMP_DIR/vifm-payload" "$APP_DIR"
  rmdir "$TMP_DIR" 2>/dev/null || true
fi

export PATH="$SELF_DIR:$PATH"
export VIFM="$APP_DIR/config"
export MYVIFMRC="$APP_DIR/config/vifmrc"
export APPDIR="$APP_DIR/app"
exec "$APP_DIR/app/AppRun" "$@"
