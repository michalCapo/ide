#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage: vimd [command] [args] [options]

Open the LazyData database viewer, or work with saved connections from the
command line. Without a command, the viewer opens on the connection list.

Start here (for AI agents):
  vimd skills get core --full

Commands:
  open <connection>              Open the viewer connected to <connection>
                                 (read-only unless --alter is given)
  list                           List saved connections (passwords are never shown)
  test <connection>              Check that <connection> can connect
  databases <connection>         List databases on the server
  tables <connection>            List tables
  columns <connection> <table>   Show columns of <table> (schema.table or table)
  query <connection> [sql|-]     Run SQL and print the result; reads SQL from
                                 stdin when sql is omitted or is -
  skills [list]                  List bundled guides for AI agents
  skills get <name> [--full]     Print a guide; --full adds its references

Options:
      --alter             Allow changes (INSERT, UPDATE, DELETE, DDL, row edits)
  -d, --database <name>   Use another database than the saved one
      --limit <rows>      Rows to show per result (default 1000, 0 = all)
      --timeout <time>    Override the saved timeout (90s, 5m, or seconds)
      --format <format>   Output as table (default), json, csv, or tsv
      --json              Same as --format json
      --no-header         Leave out the header row
  -h, --help              Show this help and exit

A connection is matched by name (ignoring case) or ID. Results go to stdout,
errors to stderr. Exit code 0 means success, 1 a connection or SQL error, and
2 invalid usage. Commands are read-only by default: a query that may change
data fails unless --alter is given. Connections saved as read-only never allow
changes. Connections are added and edited only in the viewer.

Examples:
  vimd list
  vimd tables prod
  vimd columns prod public.users
  vimd query prod "SELECT id, email FROM users LIMIT 5"
  vimd query prod --json < report.sql
  vimd query prod --format csv "SELECT * FROM orders" > orders.csv
  vimd query prod --alter "UPDATE users SET active = false WHERE id = 7"
USAGE
}

case ${1:-} in
  -h|--help) usage; exit 0 ;;
  ''|open|list|test|databases|tables|columns|query|skills) ;;
  *) echo "vimd: unknown command: $1" >&2; echo "Run 'vimd --help' for usage." >&2; exit 2 ;;
esac

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAZYDATA_SQL=${LAZYDATA_SQL:-${LAZYDATA_BACKEND:-$SELF_DIR/vimd-sql}}
[ -x "$LAZYDATA_SQL" ] || { echo "vimd SQL helper is missing: $LAZYDATA_SQL" >&2; exit 127; }

case ${1:-} in
  '') ;;
  open)
    shift
    open_usage='vimd: usage: vimd open <connection> [-d <database>] [--alter]'
    LAZYDATA_READ_ONLY=1 LAZYDATA_OPEN= LAZYDATA_OPEN_DATABASE=
    while [ $# -gt 0 ]; do
      case $1 in
        --alter) LAZYDATA_READ_ONLY=0 ;;
        -d|--database) [ $# -ge 2 ] || { echo "$open_usage" >&2; exit 2; }; LAZYDATA_OPEN_DATABASE=$2; shift ;;
        --database=*) LAZYDATA_OPEN_DATABASE=${1#--database=} ;;
        -*) echo "vimd: unknown option: $1" >&2; exit 2 ;;
        *) [ -z "$LAZYDATA_OPEN" ] || { echo "$open_usage" >&2; exit 2; }; LAZYDATA_OPEN=$1 ;;
      esac
      shift
    done
    [ -n "$LAZYDATA_OPEN" ] || { echo "$open_usage" >&2; exit 2; }
    export LAZYDATA_OPEN LAZYDATA_OPEN_DATABASE LAZYDATA_READ_ONLY
    ;;
  *) exec "$LAZYDATA_SQL" "$@" ;;
esac

NVIM_BIN=${LAZYDATA_NVIM:-$SELF_DIR/@INSTALL_NAME@}
if [ ! -x "$NVIM_BIN" ]; then NVIM_BIN=$(command -v "@INSTALL_NAME@" || true); fi
[ -n "$NVIM_BIN" ] || { echo 'vimd requires @INSTALL_NAME@ on PATH' >&2; exit 127; }
LAZYDATA_BACKEND=$LAZYDATA_SQL
export LAZYDATA_SQL LAZYDATA_BACKEND NVIM_PORTABLE_LAZYDATA=1
exec "$NVIM_BIN" -i NONE -c "lua require('views.lazydata').launch()"
