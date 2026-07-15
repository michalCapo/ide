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

# GitUI uses libgit2 and cannot read OpenSSH's IdentityFile configuration.
# Give it an agent when the desktop/session did not provide one; regular git
# does not need this because it invokes OpenSSH directly.
STARTED_AGENT=0
if [ -z "${SSH_AUTH_SOCK:-}" ] && command -v ssh-agent >/dev/null 2>&1 && command -v ssh-add >/dev/null 2>&1; then
  eval "$(ssh-agent -s)" >/dev/null
  STARTED_AGENT=1
  for key in "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa"; do
    [ ! -f "$key" ] || ssh-add "$key" >/dev/null 2>&1 || true
  done
fi

USER_THEME=${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/gitui/theme.ron
set +e
if [ -f "$USER_THEME" ]; then
  "$APP_DIR/gitui" "$@"
else
  "$APP_DIR/gitui" --theme "$APP_DIR/theme.ron" "$@"
fi
STATUS=$?
set -e
if [ "$STARTED_AGENT" = 1 ]; then
  ssh-agent -k >/dev/null 2>&1 || true
fi
exit "$STATUS"
