# SQL dialect notes

Check the driver with `agent-db list` before writing SQL.

| Task | PostgreSQL (`postgres`) | SQL Server (`mssql`) | SQLite (`sqlite`) |
| --- | --- | --- | --- |
| First N rows | `... LIMIT 10` | `SELECT TOP 10 ...` | `... LIMIT 10` |
| Skip rows | `LIMIT 10 OFFSET 20` | `ORDER BY ... OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY` | `LIMIT 10 OFFSET 20` |
| Quote a name | `"Order"` | `[Order]` | `"Order"` |
| Default schema | `public` | `dbo` | none |
| Current time | `now()` | `SYSDATETIME()` | `datetime('now')` |
| Text search (any case) | `col ILIKE '%x%'` | `col LIKE '%x%'` (usually case-insensitive) | `col LIKE '%x%'` (ASCII case-insensitive) |
| Row count of a table | `SELECT count(*) FROM t` | `SELECT COUNT(*) FROM t` | `SELECT count(*) FROM t` |
| Query plan | `EXPLAIN SELECT ...` | not available through this tool | `EXPLAIN QUERY PLAN SELECT ...` |
| Several statements per call | reads: no; with `--alter`: yes | yes | yes |

## Finding objects

`agent-db tables` lists base tables only. For views and other objects:

```sql
-- PostgreSQL
SELECT table_schema, table_name FROM information_schema.views
WHERE table_schema NOT IN ('pg_catalog', 'information_schema');

-- SQL Server
SELECT s.name AS schema_name, v.name FROM sys.views v
JOIN sys.schemas s ON s.schema_id = v.schema_id;

-- SQLite
SELECT name, type FROM sqlite_master WHERE type IN ('view', 'index', 'trigger');
```

Foreign keys:

```sql
-- PostgreSQL
SELECT tc.table_name, kcu.column_name, ccu.table_name AS references_table, ccu.column_name AS references_column
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_name = 'orders';

-- SQL Server
SELECT OBJECT_NAME(fk.parent_object_id) AS table_name, COL_NAME(fkc.parent_object_id, fkc.parent_column_id) AS column_name,
       OBJECT_NAME(fk.referenced_object_id) AS references_table, COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id) AS references_column
FROM sys.foreign_keys fk JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
WHERE OBJECT_NAME(fk.parent_object_id) = 'orders';

-- SQLite
PRAGMA foreign_key_list(orders);
```

## Large tables

Count before selecting, filter on indexed columns, and avoid `SELECT *` on
wide tables. Use `--timeout` instead of retrying a query that timed out, and
tell the user when a query is likely to be expensive on a production server.
