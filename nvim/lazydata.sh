#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: lazydata [OPTION]

Open the LazyData database viewer.

Options:
  -h, --help   Show this help and exit.
EOF
}

case ${1:-} in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) echo "lazydata: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NVIM_BIN=${LAZYDATA_NVIM:-$SELF_DIR/@INSTALL_NAME@}
if [ ! -x "$NVIM_BIN" ]; then NVIM_BIN=$(command -v "@INSTALL_NAME@" || true); fi
[ -n "$NVIM_BIN" ] || { echo 'lazydata requires @INSTALL_NAME@ on PATH' >&2; exit 127; }
LAZYDATA_SQL=${LAZYDATA_SQL:-${LAZYDATA_BACKEND:-$SELF_DIR/lazydata-sql}}
[ -x "$LAZYDATA_SQL" ] || { echo "lazydata SQL helper is missing: $LAZYDATA_SQL" >&2; exit 127; }
LAZYDATA_BACKEND=$LAZYDATA_SQL
export LAZYDATA_SQL LAZYDATA_BACKEND NVIM_PORTABLE_LAZYDATA=1
exec "$NVIM_BIN" -i NONE -c "lua require('views.lazydata').launch()"
