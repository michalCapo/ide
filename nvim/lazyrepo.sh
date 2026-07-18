#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: lazyrepo [OPTION]

Open the repository dashboard for the Git repository containing the current directory.

Options:
  -h, --help   Show this help and exit.
EOF
}

case ${1:-} in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) echo "lazyrepo: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NVIM_BIN=${LAZYREPO_NVIM:-$SELF_DIR/@INSTALL_NAME@}
if [ ! -x "$NVIM_BIN" ]; then NVIM_BIN=$(command -v "@INSTALL_NAME@" || true); fi
[ -n "$NVIM_BIN" ] || { echo 'lazyrepo requires @INSTALL_NAME@ on PATH' >&2; exit 127; }
export NVIM_PORTABLE_LAZYREPO=1

# An embedded parent Neovim owns the handoff file and opens the selected file
# after this dashboard exits.
if [ -n "${LAZYREPO_NVIM_EDIT_REQUEST:-}" ]; then
  exec "$NVIM_BIN" -i NONE -c "lua require('views.lazyrepo').launch()"
fi

# A standalone dashboard has no parent callback. Create the same handoff, then
# replace the dashboard with a normally configured Neovim when `e` is pressed.
EDIT_HANDOFF=$(mktemp "${TMPDIR:-/tmp}/lazyrepo-edit.XXXXXX")
trap 'rm -f "$EDIT_HANDOFF"' EXIT HUP INT TERM
export LAZYREPO_NVIM_EDIT_REQUEST=$EDIT_HANDOFF

status=0
"$NVIM_BIN" -i NONE -c "lua require('views.lazyrepo').launch()" || status=$?

if [ -s "$EDIT_HANDOFF" ]; then
  file=$(sed -n '1p' "$EDIT_HANDOFF")
  line=$(sed -n '2p' "$EDIT_HANDOFF")
  col=$(sed -n '3p' "$EDIT_HANDOFF")
  line=${line:-1}
  col=${col:-0}
  case $line in *[!0-9]*) line=1 ;; esac
  case $col in *[!0-9]*) col=0 ;; esac
  trap - EXIT HUP INT TERM
  rm -f "$EDIT_HANDOFF"
  unset NVIM_PORTABLE_LAZYREPO LAZYREPO_NVIM_EDIT_REQUEST
  exec "$NVIM_BIN" "+call cursor($line,$((col + 1)))" -- "$file"
fi

exit "$status"
