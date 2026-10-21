package main

import (
	"context"
	"database/sql"
	"embed"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"path"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"
)

const defaultQueryLimit = 1000

type cliOptions struct {
	Format   string
	NoHeader bool
	Alter    bool
	Full     bool
	Database string
	Limit    int
	Timeout  time.Duration
	Args     []string
}

var cliValueOptions = map[string]bool{"-d": true, "--database": true, "--limit": true, "--format": true, "--timeout": true}

func (o *cliOptions) set(name, value string) error {
	switch name {
	case "-d", "--database":
		o.Database = value
	case "--limit":
		n, err := strconv.Atoi(value)
		if err != nil || n < 0 {
			return fmt.Errorf("--limit must be a number of rows (0 = no limit)")
		}
		o.Limit = n
	case "--format":
		switch value {
		case "table", "json", "csv", "tsv":
			o.Format = value
		default:
			return fmt.Errorf("--format must be table, json, csv, or tsv")
		}
	case "--timeout":
		// A plain number is seconds; otherwise a Go duration such as 90s or 5m.
		d, err := time.ParseDuration(value)
		if n, numErr := strconv.Atoi(value); numErr == nil {
			d, err = time.Duration(n)*time.Second, nil
		}
		if err != nil || d <= 0 {
			return fmt.Errorf("--timeout must be a duration such as 30s or 5m")
		}
		o.Timeout = d
	}
	return nil
}

func parseCLIOptions(args []string) (cliOptions, error) {
	o := cliOptions{Format: "table", Limit: defaultQueryLimit}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		name, value, hasValue := arg, "", false
		if strings.HasPrefix(arg, "--") {
			name, value, hasValue = strings.Cut(arg, "=")
		}
		switch {
		case arg == "--":
			o.Args = append(o.Args, args[i+1:]...)
			return o, nil
		case arg == "--json":
			o.Format = "json"
		case arg == "--no-header":
			o.NoHeader = true
		case arg == "--alter":
			o.Alter = true
		case arg == "--full":
			o.Full = true
		case cliValueOptions[name]:
			if !hasValue {
				if i+1 >= len(args) {
					return o, fmt.Errorf("%s requires a value", arg)
				}
				i++
				value = args[i]
			}
			if err := o.set(name, value); err != nil {
				return o, err
			}
		// SQL text such as "-- note\nSELECT 1" contains spaces, so only a
		// single dash-prefixed word is treated as an unknown option.
		case strings.HasPrefix(arg, "-") && arg != "-" && !strings.ContainsAny(arg, " \t\n"):
			return o, fmt.Errorf("unknown option: %s", arg)
		default:
			o.Args = append(o.Args, arg)
		}
	}
	return o, nil
}

// runCLI serves the plain `vimd <command>` interface. Data goes to stdout and
// errors to stderr, so commands can be piped and scripted.
func runCLI(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	path, err := configPath()
	if err != nil {
		fmt.Fprintln(stderr, "vimd:", err)
		return 1
	}
	s := &Server{configPath: path, pools: map[string]*sql.DB{}, cancels: map[string]context.CancelFunc{}}
	defer s.close()
	if err := s.runCommand(args[0], args[1:], stdin, stdout, stderr); err != nil {
		var usage usageError
		if errors.As(err, &usage) {
			fmt.Fprintf(stderr, "vimd: %s\nRun 'vimd --help' for usage.\n", usage.message)
			return 2
		}
		fmt.Fprintln(stderr, "vimd:", cliErrorText(err))
		return 1
	}
	return 0
}

type usageError struct{ message string }

func (e usageError) Error() string { return e.message }

func cliErrorText(err error) string {
	text := redact(err.Error())
	var ae *APIError
	if errors.As(err, &ae) {
		text = ae.Message
		if ae.Detail != "" {
			text += ": " + ae.Detail
		}
	}
	if errors.Is(err, context.DeadlineExceeded) || strings.Contains(text, "deadline exceeded") {
		return "timed out; use --timeout to allow more time (" + text + ")"
	}
	return text
}

func (s *Server) runCommand(command string, args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	o, err := parseCLIOptions(args)
	if err != nil {
		return usageError{err.Error()}
	}
	s.readOnly = !o.Alter
	s.timeoutMS = int(o.Timeout.Milliseconds())
	out := &errWriter{w: stdout}
	if err := s.dispatchCommand(command, o, stdin, out, stderr); err != nil {
		return err
	}
	return out.err
}

// errWriter keeps the first write error, so a failed write (for example a
// full disk or closed pipe) makes the command fail.
type errWriter struct {
	w   io.Writer
	err error
}

func (e *errWriter) Write(p []byte) (int, error) {
	if e.err != nil {
		return 0, e.err
	}
	n, err := e.w.Write(p)
	e.err = err
	return n, err
}

func (s *Server) dispatchCommand(command string, o cliOptions, stdin io.Reader, stdout, stderr io.Writer) error {
	want := func(min, max int, usage string) error {
		if len(o.Args) < min || len(o.Args) > max {
			return usageError{"usage: vimd " + usage}
		}
		return nil
	}
	switch command {
	case "list":
		if err := want(0, 0, "list [--format <format>]"); err != nil {
			return err
		}
		return s.cliList(o, stdout)
	case "test":
		if err := want(1, 1, "test <connection> [-d <database>]"); err != nil {
			return err
		}
		return s.cliTest(o, stdout)
	case "databases":
		if err := want(1, 1, "databases <connection> [--format <format>]"); err != nil {
			return err
		}
		return s.cliCall(o, "databases", stdout)
	case "tables":
		if err := want(1, 1, "tables <connection> [-d <database>] [--format <format>]"); err != nil {
			return err
		}
		return s.cliCall(o, "tables", stdout)
	case "columns":
		if err := want(2, 2, "columns <connection> <table> [-d <database>] [--format <format>]"); err != nil {
			return err
		}
		return s.cliCall(o, "columns", stdout)
	case "query":
		if err := want(1, 2, "query <connection> [sql|-] [-d <database>] [--limit <rows>] [--timeout <duration>] [--alter] [--format <format>]"); err != nil {
			return err
		}
		return s.cliQuery(o, stdin, stdout, stderr)
	case "skills":
		return cliSkills(o, stdout)
	}
	return usageError{"unknown command: " + command}
}

// findProfile matches a connection by name (ignoring case) or by ID.
func (s *Server) findProfile(name string) (Profile, error) {
	cfg, err := s.loadConfig()
	if err != nil {
		return Profile{}, err
	}
	for _, p := range cfg.Connections {
		if p.ID == name || strings.EqualFold(p.Name, name) {
			return p, nil
		}
	}
	return Profile{}, &APIError{Code: "profile_missing", Message: fmt.Sprintf("connection %q was not found; run 'vimd list'", name)}
}

func (s *Server) call(method string, params any) (any, error) {
	raw, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}
	return s.handle(Request{ID: "cli", Method: method, Params: raw})
}

type connectionInfo struct {
	Name     string `json:"name"`
	Driver   string `json:"driver"`
	Target   string `json:"target"`
	Database string `json:"database,omitempty"`
	ReadOnly bool   `json:"read_only"`
}

func (s *Server) cliList(o cliOptions, stdout io.Writer) error {
	cfg, err := s.loadConfig()
	if err != nil {
		return err
	}
	// Passwords are never printed, not even in JSON output.
	list := make([]connectionInfo, 0, len(cfg.Connections))
	for _, p := range cfg.Connections {
		target := p.Path
		if p.Driver != "sqlite" {
			target = fmt.Sprintf("%s:%d", p.Host, p.Port)
			if p.User != "" {
				target = p.User + "@" + target
			}
		}
		list = append(list, connectionInfo{Name: p.Name, Driver: p.Driver, Target: target, Database: p.Database, ReadOnly: p.ReadOnly})
	}
	if o.Format == "json" {
		return writeJSON(stdout, list)
	}
	rows := make([][]any, 0, len(list))
	for _, c := range list {
		access := "read-write"
		if c.ReadOnly {
			access = "read-only"
		}
		rows = append(rows, []any{c.Name, c.Driver, c.Target, c.Database, access})
	}
	return writeRows(stdout, o, []string{"name", "driver", "target", "database", "access"}, rows)
}

func (s *Server) cliTest(o cliOptions, stdout io.Writer) error {
	p, err := s.findProfile(o.Args[0])
	if err != nil {
		return err
	}
	started := time.Now()
	if _, err := s.call("test", targetParams{ProfileID: p.ID, Database: o.Database}); err != nil {
		return err
	}
	elapsed := time.Since(started).Milliseconds()
	if o.Format == "json" {
		return writeJSON(stdout, map[string]any{"connected": true, "elapsed_ms": elapsed})
	}
	_, err = fmt.Fprintf(stdout, "connected to %s (%d ms)\n", p.Name, elapsed)
	return err
}

func (s *Server) cliCall(o cliOptions, method string, stdout io.Writer) error {
	p, err := s.findProfile(o.Args[0])
	if err != nil {
		return err
	}
	params := objectParams{ProfileID: p.ID, Database: o.Database}
	if method == "columns" {
		params.Schema, params.Table = splitTableName(p.Driver, o.Args[1])
	}
	result, err := s.call(method, params)
	if err != nil {
		return err
	}
	if columns, ok := result.([]Column); ok && len(columns) == 0 {
		return &APIError{Code: "table_missing", Message: fmt.Sprintf("table %q was not found or has no columns", o.Args[1])}
	}
	if o.Format == "json" {
		return writeJSON(stdout, result)
	}
	rows := [][]any{}
	switch value := result.(type) {
	case []string:
		for _, name := range value {
			rows = append(rows, []any{name})
		}
		return writeRows(stdout, o, []string{"database"}, rows)
	case []Table:
		for _, t := range value {
			name := t.Name
			if t.Schema != "" {
				name = t.Schema + "." + t.Name
			}
			rows = append(rows, []any{name})
		}
		return writeRows(stdout, o, []string{"table"}, rows)
	case []Column:
		for _, c := range value {
			rows = append(rows, []any{c.Name, c.Type, yesNo(c.Nullable), yesNo(c.Primary), c.Default})
		}
		return writeRows(stdout, o, []string{"column", "type", "nullable", "primary", "default"}, rows)
	}
	return nil
}

// splitTableName accepts "schema.table" or a bare table name, using the
// driver's default schema for the latter.
func splitTableName(driver, name string) (string, string) {
	if schema, table, ok := strings.Cut(name, "."); ok && driver != "sqlite" {
		return schema, table
	}
	switch driver {
	case "postgres":
		return "public", name
	case "mssql":
		return "dbo", name
	}
	return "", name
}

func (s *Server) cliQuery(o cliOptions, stdin io.Reader, stdout, stderr io.Writer) error {
	p, err := s.findProfile(o.Args[0])
	if err != nil {
		return err
	}
	query := ""
	if len(o.Args) == 2 && o.Args[1] != "-" {
		query = o.Args[1]
	} else {
		data, err := io.ReadAll(stdin)
		if err != nil {
			return err
		}
		query = string(data)
	}
	result, err := s.call("query", queryParams{targetParams: targetParams{ProfileID: p.ID, Database: o.Database}, SQL: query, Limit: o.Limit})
	if err != nil {
		return err
	}
	sets := result.([]ResultSet)
	if o.Format == "json" {
		return writeJSON(stdout, sets)
	}
	// CSV and TSV keep stdout pure data, so status lines go to stderr.
	status := stdout
	if o.Format != "table" {
		status = stderr
	}
	printed := false
	for _, set := range sets {
		if len(set.Columns) > 0 {
			if printed {
				fmt.Fprintln(stdout)
			}
			if err := writeRows(stdout, o, set.Columns, set.Rows); err != nil {
				return err
			}
			printed = true
		}
		fmt.Fprintf(status, "(%s)\n", set.Message)
	}
	return nil
}

func yesNo(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}

func writeJSON(w io.Writer, value any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(value)
}

func valueText(value any) string {
	if s, ok := value.(string); ok {
		return s
	}
	return fmt.Sprint(value)
}

// cellEscaper uses PostgreSQL COPY text escapes, so every row stays on one line.
var cellEscaper = strings.NewReplacer("\\", "\\\\", "\n", "\\n", "\r", "\\r", "\t", "\\t")

// writeRows prints a header and rows as an aligned table, CSV (NULL is an empty
// field), or TSV (PostgreSQL COPY text format, NULL is \N).
func writeRows(w io.Writer, o cliOptions, header []string, rows [][]any) error {
	switch o.Format {
	case "csv":
		cw := csv.NewWriter(w)
		if !o.NoHeader {
			cw.Write(header)
		}
		for _, row := range rows {
			cells := make([]string, len(row))
			for i, value := range row {
				if value != nil {
					cells[i] = valueText(value)
				}
			}
			cw.Write(cells)
		}
		cw.Flush()
		return cw.Error()
	case "tsv":
		if !o.NoHeader {
			cells := make([]string, len(header))
			for i, name := range header {
				cells[i] = cellEscaper.Replace(name)
			}
			fmt.Fprintln(w, strings.Join(cells, "\t"))
		}
		for _, row := range rows {
			cells := make([]string, len(row))
			for i, value := range row {
				cells[i] = `\N`
				if value != nil {
					cells[i] = cellEscaper.Replace(valueText(value))
				}
			}
			fmt.Fprintln(w, strings.Join(cells, "\t"))
		}
		return nil
	}
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	if !o.NoHeader {
		fmt.Fprintln(tw, strings.Join(header, "\t"))
	}
	for _, row := range rows {
		cells := make([]string, len(row))
		for i, value := range row {
			cells[i] = "NULL"
			if value != nil {
				cells[i] = cellEscaper.Replace(valueText(value))
			}
		}
		fmt.Fprintln(tw, strings.Join(cells, "\t"))
	}
	return tw.Flush()
}

// Skills are agent guides bundled into the binary, in the same layout as
// agent-browser skills: skills/<name>/SKILL.md plus optional references.
//
//go:embed skills
var skillFiles embed.FS

func skillDescription(name string) (string, error) {
	data, err := skillFiles.ReadFile(path.Join("skills", name, "SKILL.md"))
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(data), "\n") {
		if value, ok := strings.CutPrefix(line, "description:"); ok {
			return strings.TrimSpace(value), nil
		}
	}
	return "", nil
}

func cliSkills(o cliOptions, stdout io.Writer) error {
	entries, err := skillFiles.ReadDir("skills")
	if err != nil {
		return err
	}
	if len(o.Args) == 0 || (o.Args[0] == "list" && len(o.Args) == 1) {
		rows := [][]any{}
		for _, entry := range entries {
			description, err := skillDescription(entry.Name())
			if err != nil {
				return err
			}
			// Like agent-browser, keep the list to one short line per skill.
			if len(description) > 70 {
				description = description[:strings.LastIndex(description[:70], " ")] + "..."
			}
			rows = append(rows, []any{entry.Name(), description})
		}
		return writeRows(stdout, cliOptions{Format: "table", NoHeader: true}, []string{"name", "description"}, rows)
	}
	if o.Args[0] != "get" || len(o.Args) != 2 {
		return usageError{"usage: vimd skills [list] | vimd skills get <name> [--full]"}
	}
	dir := path.Join("skills", o.Args[1])
	main, err := skillFiles.ReadFile(path.Join(dir, "SKILL.md"))
	if err != nil {
		return &APIError{Code: "skill_missing", Message: fmt.Sprintf("skill %q was not found; run 'vimd skills list'", o.Args[1])}
	}
	if _, err := stdout.Write(main); err != nil {
		return err
	}
	if !o.Full {
		return nil
	}
	references, err := fs.Glob(skillFiles, path.Join(dir, "references", "*.md"))
	if err != nil {
		return err
	}
	for _, name := range references {
		data, err := skillFiles.ReadFile(name)
		if err != nil {
			return err
		}
		fmt.Fprintf(stdout, "\n---\n\n<!-- %s -->\n\n", strings.TrimPrefix(name, dir+"/"))
		if _, err := stdout.Write(data); err != nil {
			return err
		}
	}
	return nil
}
