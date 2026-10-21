package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func cliServer(t *testing.T) *Server {
	t.Helper()
	s := testServer(t)
	dbPath := filepath.Join(t.TempDir(), "sample.db")
	if err := os.WriteFile(dbPath, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.saveProfile(Profile{Name: "Local", Driver: "sqlite", Path: dbPath}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.saveProfile(Profile{Name: "Remote", Driver: "postgres", Host: "db", User: "app", Password: "secret", Database: "shop", ReadOnly: true}); err != nil {
		t.Fatal(err)
	}
	return s
}

func runTestCommand(t *testing.T, s *Server, stdin string, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	err := s.runCommand(args[0], args[1:], strings.NewReader(stdin), &out, io.Discard)
	return out.String(), err
}

func TestCLIListHidesPasswords(t *testing.T) {
	s := cliServer(t)
	out, err := runTestCommand(t, s, "", "list")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "Remote") || !strings.Contains(out, "app@db:5432") || !strings.Contains(out, "read-only") {
		t.Fatalf("list output = %q", out)
	}
	jsonOut, err := runTestCommand(t, s, "", "list", "--json")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out+jsonOut, "secret") {
		t.Fatalf("list printed a password: %q %q", out, jsonOut)
	}
	var list []connectionInfo
	if err := json.Unmarshal([]byte(jsonOut), &list); err != nil || len(list) != 2 || list[0].Name != "Local" {
		t.Fatalf("list json = %q, %v", jsonOut, err)
	}
}

func TestCLIQueryAndSchema(t *testing.T) {
	s := cliServer(t)
	if _, err := runTestCommand(t, s, "CREATE TABLE people (id INTEGER PRIMARY KEY, note TEXT)", "query", "local", "--alter"); err != nil {
		t.Fatal(err)
	}
	if _, err := runTestCommand(t, s, "", "query", "Local", "INSERT INTO people(note) VALUES ('a\tb'),(NULL),('c')", "--alter"); err != nil {
		t.Fatal(err)
	}
	out, err := runTestCommand(t, s, "", "query", "Local", "SELECT id, note FROM people ORDER BY id", "--limit", "2")
	if err != nil {
		t.Fatal(err)
	}
	want := "id  note\n1   a\\tb\n2   NULL\n(first 2 row(s); more rows not shown)\n"
	if out != want {
		t.Fatalf("query output = %q, want %q", out, want)
	}
	jsonOut, err := runTestCommand(t, s, "SELECT count(*) AS n FROM people", "query", "--json", "Local", "-")
	if err != nil {
		t.Fatal(err)
	}
	var sets []ResultSet
	if err := json.Unmarshal([]byte(jsonOut), &sets); err != nil || len(sets) != 1 || sets[0].Rows[0][0] != float64(3) {
		t.Fatalf("query json = %q, %v", jsonOut, err)
	}
	if out, err := runTestCommand(t, s, "", "tables", "Local", "--no-header"); err != nil || out != "people\n" {
		t.Fatalf("tables = %q, %v", out, err)
	}
	out, err = runTestCommand(t, s, "", "columns", "Local", "people")
	if err != nil || !strings.Contains(out, "id      INTEGER  yes       yes") {
		t.Fatalf("columns = %q, %v", out, err)
	}
	for _, args := range [][]string{{"columns", "Local", "missing"}, {"columns", "Local", "missing", "--json"}} {
		if _, err := runTestCommand(t, s, "", args...); err == nil {
			t.Fatalf("%v did not fail", args)
		}
	}
	if err := s.runCommand("tables", []string{"Local"}, strings.NewReader(""), failingWriter{}, io.Discard); err == nil {
		t.Fatal("a failed output write did not fail the command")
	}
	if out, err := runTestCommand(t, s, "", "test", "Local"); err != nil || !strings.HasPrefix(out, "connected to Local") {
		t.Fatalf("test = %q, %v", out, err)
	}
}

func TestCLIErrors(t *testing.T) {
	s := cliServer(t)
	if _, err := runTestCommand(t, s, "", "query", "Nope", "SELECT 1"); err == nil || !strings.Contains(cliErrorText(err), "vimd list") {
		t.Fatalf("missing connection error = %v", err)
	}
	for _, args := range [][]string{{"query"}, {"list", "extra"}, {"tables", "Local", "--bogus"}, {"query", "Local", "--limit", "x"}, {"nope"}} {
		_, err := runTestCommand(t, s, "", args...)
		if _, ok := err.(usageError); !ok {
			t.Fatalf("%v: expected usage error, got %v", args, err)
		}
	}
	if _, err := runTestCommand(t, s, "", "query", "Local", "-- note\nSELECT 1"); err != nil {
		t.Fatalf("SQL starting with a comment was treated as an option: %v", err)
	}
}

func TestCLIIsReadOnlyWithoutAlter(t *testing.T) {
	s := cliServer(t)
	if _, err := runTestCommand(t, s, "", "query", "Local", "CREATE TABLE people (id INTEGER PRIMARY KEY)", "--alter"); err != nil {
		t.Fatal(err)
	}
	if _, err := runTestCommand(t, s, "", "query", "Local", "INSERT INTO people DEFAULT VALUES"); err == nil || !strings.Contains(err.Error(), "--alter") {
		t.Fatalf("write without --alter = %v", err)
	}
	// A write hidden after a SELECT must not persist.
	_, _ = runTestCommand(t, s, "", "query", "Local", "SELECT 1; INSERT INTO people DEFAULT VALUES")
	if out, err := runTestCommand(t, s, "", "query", "Local", "WITH n AS (SELECT count(*) AS c FROM people) SELECT c FROM n"); err != nil || !strings.Contains(out, "\n0\n") {
		t.Fatalf("read query = %q, %v", out, err)
	}
}

func TestServerReadOnlyModeBlocksTableChanges(t *testing.T) {
	s := cliServer(t)
	p, err := s.findProfile("Local")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.call("query", queryParams{targetParams: targetParams{ProfileID: p.ID}, SQL: "CREATE TABLE people (id INTEGER PRIMARY KEY)"}); err != nil {
		t.Fatal(err)
	}
	s.readOnly = true
	_, err = s.call("delete_rows", deleteRowsParams{objectParams: objectParams{ProfileID: p.ID, Table: "people"}, Rows: []map[string]any{{"id": 1}}})
	if err == nil || !strings.Contains(err.Error(), "--alter") {
		t.Fatalf("delete in read-only mode = %v", err)
	}
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, os.ErrClosed }

func TestReadOnlyGuardCoversFiltersAndAttach(t *testing.T) {
	s := cliServer(t)
	p, err := s.findProfile("Local")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.call("query", queryParams{targetParams: targetParams{ProfileID: p.ID}, SQL: "CREATE TABLE people (id INTEGER PRIMARY KEY)"}); err != nil {
		t.Fatal(err)
	}
	s.readOnly = true
	attach := fmt.Sprintf("SELECT 1; ATTACH '%s' AS w; INSERT INTO w.people DEFAULT VALUES; COMMIT", p.Path)
	_, _ = s.call("query", queryParams{targetParams: targetParams{ProfileID: p.ID}, SQL: attach})
	_, _ = s.call("rows", rowsParams{objectParams: objectParams{ProfileID: p.ID, Table: "people"}, RawWhere: "1=1"})
	s.readOnly = false
	out, err := runTestCommand(t, s, "", "query", "Local", "SELECT count(*) FROM people", "--alter")
	if err != nil || !strings.Contains(out, "\n0\n") {
		t.Fatalf("a read-only request changed data: %q, %v", out, err)
	}
}

func TestCLIFormats(t *testing.T) {
	s := cliServer(t)
	if _, err := runTestCommand(t, s, "CREATE TABLE t (id INTEGER PRIMARY KEY, note TEXT); INSERT INTO t(note) VALUES ('a,\"b\"'), (NULL), ('x\ty')", "query", "Local", "--alter"); err != nil {
		t.Fatal(err)
	}
	var out, status bytes.Buffer
	if err := s.runCommand("query", []string{"Local", "SELECT id, note FROM t ORDER BY id", "--format=csv"}, strings.NewReader(""), &out, &status); err != nil {
		t.Fatal(err)
	}
	if out.String() != "id,note\n1,\"a,\"\"b\"\"\"\n2,\n3,x\ty\n" || status.String() != "(3 row(s))\n" {
		t.Fatalf("csv = %q, status = %q", out.String(), status.String())
	}
	got, err := runTestCommand(t, s, "", "query", "Local", "SELECT id, note FROM t ORDER BY id", "--format", "tsv", "--no-header")
	if err != nil || got != "1\ta,\"b\"\n2\t\\N\n3\tx\\ty\n" {
		t.Fatalf("tsv = %q, %v", got, err)
	}
	for _, args := range [][]string{{"list", "--format", "xml"}, {"query", "Local", "SELECT 1", "--timeout", "0"}, {"query", "Local", "SELECT 1", "--timeout=soon"}} {
		if _, err := runTestCommand(t, s, "", args...); err == nil {
			t.Fatalf("%v: expected an error", args)
		}
	}
	if _, err := runTestCommand(t, s, "", "query", "Local", "SELECT 1", "--timeout", "5"); err != nil || s.timeoutMS != 5000 {
		t.Fatalf("--timeout 5 = %d ms, %v", s.timeoutMS, err)
	}
	if _, err := runTestCommand(t, s, "", "query", "Local", "SELECT 1", "--timeout=2m"); err != nil || s.timeoutMS != 120000 {
		t.Fatalf("--timeout=2m = %d ms, %v", s.timeoutMS, err)
	}
	if got := cliErrorText(fmt.Errorf("query: %w", context.DeadlineExceeded)); !strings.Contains(got, "--timeout") {
		t.Fatalf("timeout error = %q", got)
	}
}

func TestCLISkills(t *testing.T) {
	s := cliServer(t)
	list, err := runTestCommand(t, s, "", "skills")
	if err != nil || !strings.HasPrefix(list, "core  Core agent-db") {
		t.Fatalf("skills list = %q, %v", list, err)
	}
	core, err := runTestCommand(t, s, "", "skills", "get", "core")
	if err != nil || !strings.HasPrefix(core, "---\nname: core\n") || strings.Contains(core, "# SQL dialect notes") {
		t.Fatalf("skills get core = %q, %v", core, err)
	}
	full, err := runTestCommand(t, s, "", "skills", "get", "core", "--full")
	if err != nil || !strings.Contains(full, "# Command reference") || !strings.Contains(full, "# SQL dialect notes") {
		t.Fatalf("skills get core --full missing references, %v", err)
	}
	if _, err := runTestCommand(t, s, "", "skills", "get", "nope"); err == nil {
		t.Fatal("unknown skill did not fail")
	}
}
