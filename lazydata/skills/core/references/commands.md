# Command reference

`<conn>` is a saved connection name (case does not matter) or its ID.

| Command | What it does |
| --- | --- |
| `agent-db list` | Saved connections: name, driver, target, database, access |
| `agent-db test <conn>` | Connects and reports the time taken |
| `agent-db databases <conn>` | Databases on the server (SQLite: the file name) |
| `agent-db tables <conn>` | Base tables as `schema.table` (SQLite: `table`) |
| `agent-db columns <conn> <table>` | Columns with type, nullable, primary key, default |
| `agent-db query <conn> "<sql>"` | Runs SQL and prints every result set |
| `agent-db query <conn>` or `query <conn> -` | Reads the SQL from stdin |
| `agent-db open <conn>` | Opens the interactive viewer (for humans, not agents) |
| `agent-db skills [list]` | Lists bundled agent guides |
| `agent-db skills get <name> [--full]` | Prints a guide; `--full` adds its references |

## Options

Options may appear anywhere after the command. Use `--` to stop option
parsing when the SQL itself starts with `-`.

| Option | Applies to | Meaning |
| --- | --- | --- |
| `-d, --database <name>` | test, tables, columns, query, open | Use another database on the same server |
| `--format <table\|json\|csv\|tsv>` | list, databases, tables, columns, query | Output format (default `table`) |
| `--json` | same | Short for `--format json` |
| `--no-header` | table, csv, tsv output | Leave out the header row |
| `--limit <rows>` | query | Rows kept per result set (default 1000, `0` = all) |
| `--timeout <duration>` | all database commands | Overrides the saved timeout: `90s`, `5m`, or seconds |
| `--alter` | query, open | Allow statements and edits that change data |

## Output details

- Table output shows NULL as `NULL` and escapes tabs, newlines, and
  backslashes as `\t`, `\n`, `\\` so each row stays on one line.
- CSV follows RFC 4180. NULL and the empty string both become an empty field;
  use JSON or TSV when the difference matters.
- TSV uses PostgreSQL COPY text format: NULL is `\N`, and tabs, newlines, and
  backslashes are escaped.
- JSON keeps native types: numbers stay numbers, NULL is `null`, timestamps are
  RFC 3339 strings, and binary values are objects like `{"$binary": "0x89504E47"}`
  (table, CSV, and TSV show just `0x89504E47`).
- A statement that returns no rows (with `--alter`) prints
  `(N row(s) affected)`.

## Read-only mode in detail

Without `--alter`, only statements starting with SELECT, WITH, SHOW, EXPLAIN,
DESCRIBE, VALUES, or PRAGMA are accepted, and they run inside a transaction
that is always rolled back:

- PostgreSQL: a `READ ONLY` transaction; one statement per call.
- SQLite: the file is opened read-only and ATTACH is disabled.
- SQL Server: batches with COMMIT, ROLLBACK, EXEC, KILL, NEXT VALUE FOR, and
  similar statements are refused.

This protects against mistakes. It is not a security boundary: functions with
side effects can still run. Treat `--alter` as the only way to change data.
