---
name: core
description: Core agent-db (vimd) usage guide. Read this before running any agent-db or vimd command. Covers finding a saved connection, exploring databases, tables, and columns, running read-only SQL queries, choosing output formats (table, JSON, CSV, TSV), row limits and timeouts, the --alter rule for changing data, and troubleshooting. Use when the user asks to look at, query, inspect, export, or change data in a database they have set up in vimd.
allowed-tools: Bash(agent-db:*), Bash(vimd:*)
---

# agent-db core

`agent-db` is a command-line tool for querying the user's saved database
connections (PostgreSQL, SQL Server, SQLite). It is the same program as `vimd`;
use whichever name is on PATH. Every command is one short, non-interactive call
that prints data to stdout and errors to stderr.

## The core loop

```bash
agent-db list                                  # 1. Find the connection name
agent-db tables <conn>                         # 2. See what tables exist
agent-db columns <conn> <schema.table>         # 3. Learn the columns and keys
agent-db query <conn> "SELECT ... LIMIT 20"    # 4. Read the data
```

Always look at `columns` before writing a query against a table you have not
seen. Guessing column names wastes calls and produces confusing errors.

## Safety rules

- **Everything is read-only by default.** A statement that may change data
  (INSERT, UPDATE, DELETE, DDL, procedures) fails with
  `Changes are blocked in read-only mode; add --alter to allow them`.
- **Only add `--alter` when the user explicitly asked to change data.** Never
  add it to get past an error, to "test" a statement, or because it seems
  harmless. Show the exact statement to the user first when the change is not
  trivial.
- Before an UPDATE or DELETE, run the same WHERE clause as a `SELECT count(*)`
  and check that the number matches what the user expects.
- Some connections are saved as read-only by the user. `--alter` does not
  override that, and you must not try to work around it.
- Each `query` call runs on its own. There is no open transaction between
  calls, so a change made with `--alter` is saved immediately.

## Connections are the user's responsibility

Connections, including their passwords, are created and edited only by the user
in the `vimd` viewer. Never create, edit, or delete connections, and never read
`~/.config/lazydata/connections.json`: it stores passwords in plain text.
`agent-db list` shows everything you need and never prints passwords. If the
connection you need does not exist, ask the user to add it.

## Output formats

| Need | Use |
| --- | --- |
| Read results yourself | default table output |
| Parse results in code | `--format json` (or `--json`) |
| Export for a spreadsheet | `--format csv` (NULL is an empty field) |
| Pipe to shell tools | `--format tsv` (NULL is `\N`, tabs/newlines escaped) |

- `--no-header` drops the header row (table, CSV, TSV).
- With CSV and TSV, status lines such as `(3 row(s))` go to stderr, so stdout
  holds only data. Use `> file.csv` to export.
- JSON for `query` is a list of result sets:
  `[{"columns": [...], "rows": [[...]], "message": "...", "has_more": true}]`.

## Rows and time limits

- `query` shows at most **1000 rows per result** by default. When more exist,
  the status says `first 1000 row(s); more rows not shown` (JSON:
  `"has_more": true`). Prefer a narrower query or `LIMIT`/`TOP` in SQL; use
  `--limit <rows>` (or `--limit 0` for all) only when you need the rows.
- Each connection has a saved timeout (30 s by default). For slow queries use
  `--timeout 2m` (or a number of seconds). A timeout fails with
  `timed out; use --timeout to allow more time`.

## Long SQL

Pass SQL through stdin to avoid shell quoting problems:

```bash
agent-db query <conn> --format json <<'SQL'
SELECT o.id, o.total, c.email
FROM orders o
JOIN customers c ON c.id = o.customer_id
WHERE o.created_at >= '2026-01-01'
ORDER BY o.total DESC
LIMIT 50
SQL
```

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Connection, SQL, read-only, timeout, or output error (message on stderr) |
| 2 | Wrong command or options; run `agent-db --help` |

## Troubleshooting

- `connection "x" was not found` → run `agent-db list` and use a listed name
  (names ignore case).
- `table "x" was not found` → run `agent-db tables <conn>`; on PostgreSQL and
  SQL Server include the schema (`sales.orders`). Without one, `public` and
  `dbo` are assumed.
- Wrong database on a server → `agent-db databases <conn>`, then add
  `-d <database>` to the command.
- Cannot connect → `agent-db test <conn>` and report the error to the user; do
  not try to change the connection.

Run `agent-db skills get core --full` for the complete command reference and
SQL dialect notes.
