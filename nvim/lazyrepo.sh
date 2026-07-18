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
exec "$NVIM_BIN" -i NONE -c "lua require('views.lazyrepo').launch()"
