package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testServer(t *testing.T) *Server {
	t.Helper()
	dir := t.TempDir()
	s := &Server{configPath: filepath.Join(dir, "lazydata", "connections.json"), pools: map[string]*sql.DB{}, cancels: map[string]context.CancelFunc{}}
	t.Cleanup(s.close)
	return s
}

func raw(t *testing.T, value any) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestProfilePersistenceAndPermissions(t *testing.T) {
	s := testServer(t)
	dbPath := filepath.Join(t.TempDir(), "sample.db")
	p, err := s.saveProfile(Profile{Name: "Local", Driver: "sqlite", Path: dbPath})
	if err != nil {
		t.Fatal(err)
	}
	if p.ID == "" || p.TimeoutMS != 30000 || p.Path != dbPath {
		t.Fatalf("unexpected normalized profile: %#v", p)
	}
	info, err := os.Stat(s.configPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("config mode = %o", info.Mode().Perm())
	}
	cfg, err := s.loadConfig()
	if err != nil || len(cfg.Connections) != 1 || cfg.PageSize != 200 {
		t.Fatalf("unexpected config: %#v, %v", cfg, err)
	}
}

func TestSQLHelpers(t *testing.T) {
	if got := quoteIdent("mssql", "a]b"); got != "[a]]b]" {
		t.Fatalf("quoted identifier = %q", got)
	}
	where, args := whereClause("postgres", "active", []Predicate{{Column: "team", Value: "core"}, {Column: "gone", IsNull: true}})
	if where != ` WHERE (active) AND "team" = $1 AND "gone" IS NULL` || len(args) != 1 {
		t.Fatalf("where = %q, args = %#v", where, args)
	}
	if !readLooking("-- note\n SELECT 1") || readLooking("DELETE FROM users") || readLooking("WITH x AS (SELECT 1) SELECT * FROM x") || !returnsRows("WITH x AS (SELECT 1) SELECT * FROM x") {
		t.Fatal("query classification failed")
	}
	if got := redact("connect postgres://sam:secret@host/db?password=other"); strings.Contains(got, "secret") || strings.Contains(got, "other") {
		t.Fatalf("secret was not redacted: %q", got)
	}
}

func TestDisplayColumnsPrefersLowercasePrimaryID(t *testing.T) {
	columns := displayColumns([]Column{
		{Name: "ID", Type: "numeric"},
		{Name: "uid", Type: "text"},
		{Name: "id", Type: "integer", Primary: true},
		{Name: "cid", Type: "text"},
	})
	if columns[0].Name != "id" || !columns[0].Primary || columns[1].Name != "ID" {
		t.Fatalf("unexpected display order: %#v", columns)
	}
}

func TestSQLiteFullPath(t *testing.T) {
	s := testServer(t)
	dbPath := filepath.Join(t.TempDir(), "sample.db")
	if err := os.WriteFile(dbPath, nil, 0600); err != nil {
		t.Fatal(err)
	}
	p, err := s.saveProfile(Profile{Name: "Local", Driver: "sqlite", Path: dbPath})
	if err != nil {
		t.Fatal(err)
	}
	query := func(sql string) any {
		t.Helper()
		result, err := s.handle(Request{ID: sql, Method: "query", Params: raw(t, queryParams{targetParams: targetParams{ProfileID: p.ID}, SQL: sql})})
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	query(`CREATE TABLE people (team TEXT, id INTEGER PRIMARY KEY, note TEXT)`)
	query(`INSERT INTO people(team,note) VALUES ('core','one'),('core','two'),(NULL,'three')`)

	tables, err := s.handle(Request{ID: "tables", Method: "tables", Params: raw(t, targetParams{ProfileID: p.ID})})
	if err != nil || len(tables.([]Table)) != 1 {
		t.Fatalf("tables = %#v, %v", tables, err)
	}
	columns, err := s.handle(Request{ID: "columns", Method: "columns", Params: raw(t, objectParams{ProfileID: p.ID, Table: "people"})})
	if err != nil || len(columns.([]Column)) != 3 || !columns.([]Column)[0].Primary {
		t.Fatalf("columns = %#v, %v", columns, err)
	}

	rowsValue, err := s.handle(Request{ID: "rows", Method: "rows", Params: raw(t, rowsParams{objectParams: objectParams{ProfileID: p.ID, Table: "people"}, Predicates: []Predicate{{Column: "team", Value: "core"}}, PageSize: 1})})
	rows := rowsValue.(ResultSet)
	if err != nil || len(rows.Rows) != 1 || !rows.HasMore {
		t.Fatalf("rows = %#v, %v", rows, err)
	}
	if len(rows.Columns) != 3 || rows.Columns[0] != "id" || rows.Rows[0][0] != int64(1) {
		t.Fatalf("id is not the first displayed column: %#v", rows)
	}
	distinctValue, err := s.handle(Request{ID: "distinct", Method: "distinct", Params: raw(t, distinctParams{rowsParams: rowsParams{objectParams: objectParams{ProfileID: p.ID, Table: "people"}}, Column: "team"})})
	if err != nil || len(distinctValue.([]map[string]any)) != 2 {
		t.Fatalf("distinct = %#v, %v", distinctValue, err)
	}
	selected := query(`SELECT id, team FROM people ORDER BY id`).([]ResultSet)
	if len(selected) != 1 || len(selected[0].Rows) != 3 {
		t.Fatalf("query result = %#v", selected)
	}
	multiple := query(`SELECT 1 AS first; SELECT 2 AS second`).([]ResultSet)
	if len(multiple) == 0 || len(multiple[len(multiple)-1].Rows) != 1 {
		t.Fatalf("multiple result sets = %#v", multiple)
	}
}

func TestRequestCancellation(t *testing.T) {
	s := testServer(t)
	ctx, done := s.requestContext("slow", 10000)
	s.mu.Lock()
	cancel := s.cancels["slow"]
	s.mu.Unlock()
	if cancel == nil {
		t.Fatal("request cancellation was not registered")
	}
	cancel()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("request context was not cancelled")
	}
	done()
	s.mu.Lock()
	_, exists := s.cancels["slow"]
	s.mu.Unlock()
	if exists {
		t.Fatal("request cancellation was not cleaned up")
	}
}

func TestProfileConnectionTestDoesNotCreateSQLiteFile(t *testing.T) {
	s := testServer(t)
	missing := filepath.Join(t.TempDir(), "missing.db")
	_, err := s.handle(Request{ID: "test", Method: "test_profile", Params: raw(t, Profile{Name: "Missing", Driver: "sqlite", Path: missing})})
	if err == nil {
		t.Fatal("expected missing SQLite file to fail")
	}
	if _, statErr := os.Stat(missing); !os.IsNotExist(statErr) {
		t.Fatalf("connection test created SQLite file: %v", statErr)
	}

	existing := filepath.Join(t.TempDir(), "existing.db")
	db, openErr := sql.Open("sqlite", existing)
	if openErr != nil {
		t.Fatal(openErr)
	}
	if _, execErr := db.Exec(`CREATE TABLE sample (id INTEGER)`); execErr != nil {
		t.Fatal(execErr)
	}
	db.Close()
	result, err := s.handle(Request{ID: "test-existing", Method: "test_profile", Params: raw(t, Profile{Name: "Existing", Driver: "sqlite", Path: existing})})
	if err != nil || result.(map[string]any)["connected"] != true {
		t.Fatalf("connection test = %#v, %v", result, err)
	}
}
