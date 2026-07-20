package main

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	_ "github.com/microsoft/go-mssqldb"
	_ "modernc.org/sqlite"
)

const configVersion = 1

type Profile struct {
	ID                     string `json:"id"`
	Name                   string `json:"name"`
	Driver                 string `json:"driver"`
	Host                   string `json:"host,omitempty"`
	Port                   int    `json:"port,omitempty"`
	User                   string `json:"user,omitempty"`
	Password               string `json:"password,omitempty"`
	Database               string `json:"database,omitempty"`
	Path                   string `json:"path,omitempty"`
	SSLMode                string `json:"ssl_mode,omitempty"`
	Encrypt                bool   `json:"encrypt,omitempty"`
	TrustServerCertificate bool   `json:"trust_server_certificate,omitempty"`
	ReadOnly               bool   `json:"read_only,omitempty"`
	TimeoutMS              int    `json:"timeout_ms,omitempty"`
}

type Config struct {
	Version     int       `json:"version"`
	PageSize    int       `json:"page_size"`
	Connections []Profile `json:"connections"`
}

type Request struct {
	ID     string          `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type Response struct {
	ID     string    `json:"id"`
	OK     bool      `json:"ok"`
	Result any       `json:"result,omitempty"`
	Error  *APIError `json:"error,omitempty"`
}

type APIError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	Detail  string `json:"detail,omitempty"`
}

type Predicate struct {
	Column string `json:"column"`
	Value  any    `json:"value"`
	IsNull bool   `json:"is_null,omitempty"`
}

type Server struct {
	configPath string
	mu         sync.Mutex
	writeMu    sync.Mutex
	pools      map[string]*sql.DB
	cancels    map[string]context.CancelFunc
	out        *json.Encoder
}

func main() {
	path, err := configPath()
	if err != nil {
		fmt.Fprintln(os.Stderr, "lazydata-sql:", err)
		os.Exit(1)
	}
	s := &Server{configPath: path, pools: map[string]*sql.DB{}, cancels: map[string]context.CancelFunc{}, out: json.NewEncoder(os.Stdout)}
	defer s.close()
	scan := bufio.NewScanner(os.Stdin)
	scan.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for scan.Scan() {
		var req Request
		if err := json.Unmarshal(scan.Bytes(), &req); err != nil {
			s.send(Response{OK: false, Error: apiError("invalid_request", "Invalid JSON request", err)})
			continue
		}
		go s.dispatch(req)
	}
	if err := scan.Err(); err != nil {
		fmt.Fprintln(os.Stderr, "lazydata-sql:", err)
	}
}

func configPath() (string, error) {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "lazydata", "connections.json"), nil
}

func apiError(code, message string, err error) *APIError {
	e := &APIError{Code: code, Message: message}
	if err != nil {
		e.Detail = redact(err.Error())
	}
	return e
}

var passwordPattern = regexp.MustCompile(`(?i)(password|pwd)(=|%3D)[^&;\s]+`)
var credentialPattern = regexp.MustCompile(`(?i)(postgres|sqlserver)://([^:@/\s]+):([^@/\s]+)@`)

func redact(value string) string {
	value = passwordPattern.ReplaceAllString(value, "$1$2[redacted]")
	return credentialPattern.ReplaceAllString(value, "$1://$2:[redacted]@")
}

func (s *Server) send(resp Response) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_ = s.out.Encode(resp)
}

func (s *Server) dispatch(req Request) {
	result, err := s.handle(req)
	if err != nil {
		var ae *APIError
		if !errors.As(err, &ae) {
			ae = apiError("backend_error", "Database operation failed", err)
		}
		s.send(Response{ID: req.ID, OK: false, Error: ae})
		return
	}
	s.send(Response{ID: req.ID, OK: true, Result: result})
}

func (e *APIError) Error() string { return e.Message }

func decode[T any](raw json.RawMessage) (T, error) {
	var value T
	if len(raw) == 0 {
		raw = []byte("{}")
	}
	if err := json.Unmarshal(raw, &value); err != nil {
		return value, &APIError{Code: "invalid_params", Message: "Invalid request parameters", Detail: err.Error()}
	}
	return value, nil
}

func (s *Server) handle(req Request) (any, error) {
	switch req.Method {
	case "profiles":
		return s.loadConfig()
	case "save_profile":
		p, err := decode[Profile](req.Params)
		if err != nil {
			return nil, err
		}
		return s.saveProfile(p)
	case "delete_profile":
		p, err := decode[struct {
			ID string `json:"id"`
		}](req.Params)
		if err != nil {
			return nil, err
		}
		return map[string]bool{"deleted": true}, s.deleteProfile(p.ID)
	case "test":
		return s.test(req)
	case "test_profile":
		return s.testProfile(req)
	case "databases":
		return s.databases(req)
	case "tables":
		return s.tables(req)
	case "columns":
		return s.columns(req)
	case "rows":
		return s.rows(req)
	case "distinct":
		return s.distinct(req)
	case "query":
		return s.query(req)
	case "cancel":
		p, err := decode[struct {
			RequestID string `json:"request_id"`
		}](req.Params)
		if err != nil {
			return nil, err
		}
		s.mu.Lock()
		cancel := s.cancels[p.RequestID]
		s.mu.Unlock()
		if cancel != nil {
			cancel()
		}
		return map[string]bool{"cancelled": cancel != nil}, nil
	default:
		return nil, &APIError{Code: "unknown_method", Message: "Unknown backend method: " + req.Method}
	}
}

func defaultConfig() Config {
	return Config{Version: configVersion, PageSize: 200, Connections: []Profile{}}
}

func (s *Server) loadConfig() (Config, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loadConfigUnlocked()
}

func (s *Server) loadConfigUnlocked() (Config, error) {
	data, err := os.ReadFile(s.configPath)
	if errors.Is(err, os.ErrNotExist) {
		return defaultConfig(), nil
	}
	if err != nil {
		return Config{}, &APIError{Code: "config_read", Message: "Could not read connection profiles", Detail: err.Error()}
	}
	cfg := defaultConfig()
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Config{}, &APIError{Code: "config_invalid", Message: "Connection profile file is invalid", Detail: err.Error()}
	}
	if cfg.Version != configVersion {
		return Config{}, &APIError{Code: "config_version", Message: fmt.Sprintf("Unsupported connection profile version: %d", cfg.Version)}
	}
	if cfg.PageSize <= 0 {
		cfg.PageSize = 200
	}
	return cfg, nil
}

func validateProfile(p *Profile) error {
	p.Name, p.Driver, p.Host, p.Database, p.Path = strings.TrimSpace(p.Name), strings.ToLower(strings.TrimSpace(p.Driver)), strings.TrimSpace(p.Host), strings.TrimSpace(p.Database), strings.TrimSpace(p.Path)
	if p.ID == "" {
		p.ID = fmt.Sprintf("%d", time.Now().UnixNano())
	}
	if p.Name == "" {
		return &APIError{Code: "profile_name", Message: "Connection name is required"}
	}
	if p.TimeoutMS <= 0 {
		p.TimeoutMS = 30000
	}
	switch p.Driver {
	case "postgres":
		if p.Host == "" {
			return &APIError{Code: "profile_host", Message: "PostgreSQL host is required"}
		}
		if p.Port == 0 {
			p.Port = 5432
		}
		if p.SSLMode == "" {
			p.SSLMode = "prefer"
		}
	case "mssql":
		if p.Host == "" {
			return &APIError{Code: "profile_host", Message: "SQL Server host is required"}
		}
		if p.Port == 0 {
			p.Port = 1433
		}
	case "sqlite":
		if p.Path == "" {
			return &APIError{Code: "profile_path", Message: "SQLite path is required"}
		}
		absolute, err := filepath.Abs(p.Path)
		if err != nil {
			return &APIError{Code: "profile_path", Message: "SQLite path is invalid", Detail: err.Error()}
		}
		p.Path = absolute
	default:
		return &APIError{Code: "profile_driver", Message: "Driver must be postgres, mssql, or sqlite"}
	}
	return nil
}

func (s *Server) writeConfigUnlocked(cfg Config) error {
	dir := filepath.Dir(s.configPath)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return &APIError{Code: "config_write", Message: "Could not create LazyData config directory", Detail: err.Error()}
	}
	_ = os.Chmod(dir, 0700)
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".connections.*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(0600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, s.configPath); err != nil {
		return err
	}
	return os.Chmod(s.configPath, 0600)
}

func (s *Server) saveProfile(p Profile) (Profile, error) {
	if err := validateProfile(&p); err != nil {
		return Profile{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	cfg, err := s.loadConfigUnlocked()
	if err != nil {
		return Profile{}, err
	}
	found := false
	for i := range cfg.Connections {
		if cfg.Connections[i].ID == p.ID {
			cfg.Connections[i] = p
			found = true
			break
		}
		if strings.EqualFold(cfg.Connections[i].Name, p.Name) {
			return Profile{}, &APIError{Code: "profile_duplicate", Message: "A connection with that name already exists"}
		}
	}
	if !found {
		cfg.Connections = append(cfg.Connections, p)
	}
	sort.SliceStable(cfg.Connections, func(i, j int) bool {
		return strings.ToLower(cfg.Connections[i].Name) < strings.ToLower(cfg.Connections[j].Name)
	})
	for key, db := range s.pools {
		if strings.HasPrefix(key, p.ID+"\x00") {
			db.Close()
			delete(s.pools, key)
		}
	}
	if err := s.writeConfigUnlocked(cfg); err != nil {
		return Profile{}, err
	}
	return p, nil
}

func (s *Server) deleteProfile(id string) error {
	if id == "" {
		return &APIError{Code: "invalid_params", Message: "Profile ID is required"}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	cfg, err := s.loadConfigUnlocked()
	if err != nil {
		return err
	}
	next := cfg.Connections[:0]
	for _, p := range cfg.Connections {
		if p.ID != id {
			next = append(next, p)
		}
	}
	if len(next) == len(cfg.Connections) {
		return &APIError{Code: "profile_missing", Message: "Connection profile was not found"}
	}
	cfg.Connections = next
	for key, db := range s.pools {
		if strings.HasPrefix(key, id+"\x00") {
			db.Close()
			delete(s.pools, key)
		}
	}
	return s.writeConfigUnlocked(cfg)
}

func (s *Server) profile(id string) (Profile, error) {
	cfg, err := s.loadConfig()
	if err != nil {
		return Profile{}, err
	}
	for _, p := range cfg.Connections {
		if p.ID == id {
			return p, nil
		}
	}
	return Profile{}, &APIError{Code: "profile_missing", Message: "Connection profile was not found"}
}

func driverName(p Profile) string {
	if p.Driver == "postgres" {
		return "pgx"
	}
	if p.Driver == "mssql" {
		return "sqlserver"
	}
	return "sqlite"
}

func dsn(p Profile, database string) (string, error) {
	if database == "" {
		database = p.Database
	}
	switch p.Driver {
	case "postgres":
		u := &url.URL{Scheme: "postgres", Host: net.JoinHostPort(p.Host, strconv.Itoa(p.Port)), Path: "/" + database}
		if p.User != "" {
			u.User = url.UserPassword(p.User, p.Password)
		}
		q := u.Query()
		q.Set("sslmode", p.SSLMode)
		u.RawQuery = q.Encode()
		return u.String(), nil
	case "mssql":
		u := &url.URL{Scheme: "sqlserver", Host: net.JoinHostPort(p.Host, strconv.Itoa(p.Port))}
		if p.User != "" {
			u.User = url.UserPassword(p.User, p.Password)
		}
		q := u.Query()
		q.Set("database", database)
		q.Set("encrypt", strconv.FormatBool(p.Encrypt))
		q.Set("TrustServerCertificate", strconv.FormatBool(p.TrustServerCertificate))
		u.RawQuery = q.Encode()
		return u.String(), nil
	case "sqlite":
		path := p.Path
		if p.ReadOnly {
			u := &url.URL{Scheme: "file", Path: path}
			q := u.Query()
			q.Set("mode", "ro")
			u.RawQuery = q.Encode()
			return u.String(), nil
		}
		return path, nil
	}
	return "", errors.New("unsupported driver")
}

func (s *Server) pool(profileID, database string) (*sql.DB, Profile, error) {
	p, err := s.profile(profileID)
	if err != nil {
		return nil, p, err
	}
	if p.Driver == "sqlite" {
		info, statErr := os.Stat(p.Path)
		if statErr != nil {
			return nil, p, &APIError{Code: "sqlite_missing", Message: "SQLite database file does not exist", Detail: statErr.Error()}
		}
		if !info.Mode().IsRegular() {
			return nil, p, &APIError{Code: "sqlite_invalid", Message: "SQLite database path is not a regular file"}
		}
		database = p.Path
	} else if database == "" {
		database = p.Database
	}
	key := p.ID + "\x00" + database
	s.mu.Lock()
	if db := s.pools[key]; db != nil {
		s.mu.Unlock()
		return db, p, nil
	}
	s.mu.Unlock()
	connection, err := dsn(p, database)
	if err != nil {
		return nil, p, err
	}
	db, err := sql.Open(driverName(p), connection)
	if err != nil {
		return nil, p, err
	}
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(2)
	db.SetConnMaxIdleTime(5 * time.Minute)
	s.mu.Lock()
	if existing := s.pools[key]; existing != nil {
		s.mu.Unlock()
		db.Close()
		return existing, p, nil
	}
	s.pools[key] = db
	s.mu.Unlock()
	return db, p, nil
}

func (s *Server) requestContext(id string, timeout int) (context.Context, func()) {
	if timeout <= 0 {
		timeout = 30000
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Millisecond)
	s.mu.Lock()
	s.cancels[id] = cancel
	s.mu.Unlock()
	return ctx, func() { cancel(); s.mu.Lock(); delete(s.cancels, id); s.mu.Unlock() }
}

type targetParams struct {
	ProfileID string `json:"profile_id"`
	Database  string `json:"database"`
}

func (s *Server) test(req Request) (any, error) {
	p, err := decode[targetParams](req.Params)
	if err != nil {
		return nil, err
	}
	db, profile, err := s.pool(p.ProfileID, p.Database)
	if err != nil {
		return nil, err
	}
	ctx, done := s.requestContext(req.ID, profile.TimeoutMS)
	defer done()
	if err := db.PingContext(ctx); err != nil {
		return nil, err
	}
	return map[string]bool{"connected": true}, nil
}

func (s *Server) testProfile(req Request) (any, error) {
	p, err := decode[Profile](req.Params)
	if err != nil {
		return nil, err
	}
	if err := validateProfile(&p); err != nil {
		return nil, err
	}
	if p.Driver == "sqlite" {
		info, statErr := os.Stat(p.Path)
		if statErr != nil {
			return nil, &APIError{Code: "sqlite_missing", Message: "SQLite database file does not exist", Detail: statErr.Error()}
		}
		if !info.Mode().IsRegular() {
			return nil, &APIError{Code: "sqlite_invalid", Message: "SQLite database path is not a regular file"}
		}
		p.ReadOnly = true
	}
	connection, err := dsn(p, p.Database)
	if err != nil {
		return nil, err
	}
	db, err := sql.Open(driverName(p), connection)
	if err != nil {
		return nil, err
	}
	defer db.Close()
	ctx, done := s.requestContext(req.ID, p.TimeoutMS)
	defer done()
	started := time.Now()
	if err := db.PingContext(ctx); err != nil {
		return nil, err
	}
	return map[string]any{"connected": true, "elapsed_ms": time.Since(started).Milliseconds()}, nil
}

func queryStrings(ctx context.Context, db *sql.DB, query string, args ...any) ([]string, error) {
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var values []string
	for rows.Next() {
		var value string
		if err := rows.Scan(&value); err != nil {
			return nil, err
		}
		values = append(values, value)
	}
	return values, rows.Err()
}

func (s *Server) databases(req Request) (any, error) {
	p, err := decode[targetParams](req.Params)
	if err != nil {
		return nil, err
	}
	db, profile, err := s.pool(p.ProfileID, p.Database)
	if err != nil {
		return nil, err
	}
	if profile.Driver == "sqlite" {
		return []string{filepath.Base(profile.Path)}, nil
	}
	ctx, done := s.requestContext(req.ID, profile.TimeoutMS)
	defer done()
	if profile.Driver == "postgres" {
		return queryStrings(ctx, db, `SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY lower(datname)`)
	}
	return queryStrings(ctx, db, `SELECT name FROM sys.databases WHERE state = 0 ORDER BY lower(name)`)
}

type Table struct {
	Schema string `json:"schema"`
	Name   string `json:"name"`
}

func (s *Server) tables(req Request) (any, error) {
	p, err := decode[targetParams](req.Params)
	if err != nil {
		return nil, err
	}
	db, profile, err := s.pool(p.ProfileID, p.Database)
	if err != nil {
		return nil, err
	}
	ctx, done := s.requestContext(req.ID, profile.TimeoutMS)
	defer done()
	var query string
	if profile.Driver == "postgres" {
		query = `SELECT table_schema, table_name FROM information_schema.tables WHERE table_type='BASE TABLE' AND table_schema NOT IN ('pg_catalog','information_schema') ORDER BY lower(table_schema), lower(table_name)`
	}
	if profile.Driver == "mssql" {
		query = `SELECT s.name, t.name FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id ORDER BY lower(s.name), lower(t.name)`
	}
	if profile.Driver == "sqlite" {
		query = `SELECT '', name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY lower(name)`
	}
	rows, err := db.QueryContext(ctx, query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []Table{}
	for rows.Next() {
		var t Table
		if err := rows.Scan(&t.Schema, &t.Name); err != nil {
			return nil, err
		}
		result = append(result, t)
	}
	return result, rows.Err()
}

type Column struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	Nullable bool   `json:"nullable"`
	Default  any    `json:"default,omitempty"`
	Primary  bool   `json:"primary"`
}
type objectParams struct {
	ProfileID string `json:"profile_id"`
	Database  string `json:"database"`
	Schema    string `json:"schema"`
	Table     string `json:"table"`
}

func displayColumns(columns []Column) []Column {
	bestIndex, bestRank := -1, 0
	for i, column := range columns {
		rank := 0
		switch {
		case column.Name == "id" && column.Primary:
			rank = 4
		case column.Name == "id":
			rank = 3
		case strings.EqualFold(column.Name, "id") && column.Primary:
			rank = 2
		case strings.EqualFold(column.Name, "id"):
			rank = 1
		}
		if rank > bestRank {
			bestIndex, bestRank = i, rank
		}
	}
	if bestIndex > 0 {
		ordered := make([]Column, 0, len(columns))
		ordered = append(ordered, columns[bestIndex])
		ordered = append(ordered, columns[:bestIndex]...)
		ordered = append(ordered, columns[bestIndex+1:]...)
		columns = ordered
	}
	return columns
}

func (s *Server) columnsFor(ctx context.Context, db *sql.DB, profile Profile, p objectParams) ([]Column, error) {
	result := []Column{}
	if profile.Driver == "sqlite" {
		rows, err := db.QueryContext(ctx, `PRAGMA table_info(`+quoteIdent("sqlite", p.Table)+`)`)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		for rows.Next() {
			var cid, notnull, primary int
			var name, typ string
			var def any
			if err := rows.Scan(&cid, &name, &typ, &notnull, &def, &primary); err != nil {
				return nil, err
			}
			result = append(result, Column{Name: name, Type: typ, Nullable: notnull == 0, Default: normalize(def), Primary: primary > 0})
		}
		return displayColumns(result), rows.Err()
	}
	var query string
	if profile.Driver == "postgres" {
		query = `SELECT c.column_name,c.data_type,c.is_nullable='YES',c.column_default,EXISTS(SELECT 1 FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage ku ON ku.constraint_name=tc.constraint_name AND ku.constraint_schema=tc.constraint_schema WHERE tc.constraint_type='PRIMARY KEY' AND tc.table_schema=c.table_schema AND tc.table_name=c.table_name AND ku.column_name=c.column_name) FROM information_schema.columns c WHERE c.table_schema=$1 AND c.table_name=$2 ORDER BY c.ordinal_position`
	} else {
		query = `SELECT c.name,ty.name,c.is_nullable,OBJECT_DEFINITION(c.default_object_id),CASE WHEN ic.column_id IS NULL THEN CAST(0 AS bit) ELSE CAST(1 AS bit) END FROM sys.columns c JOIN sys.types ty ON c.user_type_id=ty.user_type_id LEFT JOIN sys.indexes i ON i.object_id=c.object_id AND i.is_primary_key=1 LEFT JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id AND ic.column_id=c.column_id WHERE c.object_id=OBJECT_ID(@p1+'.'+@p2) ORDER BY c.column_id`
	}
	rows, err := db.QueryContext(ctx, query, p.Schema, p.Table)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var c Column
		var def any
		if err := rows.Scan(&c.Name, &c.Type, &c.Nullable, &def, &c.Primary); err != nil {
			return nil, err
		}
		c.Default = normalize(def)
		result = append(result, c)
	}
	return displayColumns(result), rows.Err()
}

func (s *Server) columns(req Request) (any, error) {
	p, err := decode[objectParams](req.Params)
	if err != nil {
		return nil, err
	}
	db, profile, err := s.pool(p.ProfileID, p.Database)
	if err != nil {
		return nil, err
	}
	ctx, done := s.requestContext(req.ID, profile.TimeoutMS)
	defer done()
	return s.columnsFor(ctx, db, profile, p)
}

func quoteIdent(driver, name string) string {
	if driver == "mssql" {
		return "[" + strings.ReplaceAll(name, "]", "]]") + "]"
	}
	return `"` + strings.ReplaceAll(name, `"`, `""`) + `"`
}

func qualified(driver, schema, table string) string {
	if schema == "" {
		return quoteIdent(driver, table)
	}
	return quoteIdent(driver, schema) + "." + quoteIdent(driver, table)
}

func placeholder(driver string, n int) string {
	if driver == "postgres" {
		return "$" + strconv.Itoa(n)
	}
	if driver == "mssql" {
		return "@p" + strconv.Itoa(n)
	}
	return "?"
}

func whereClause(driver string, raw string, predicates []Predicate) (string, []any) {
	parts, args := []string{}, []any{}
	if strings.TrimSpace(raw) != "" {
		parts = append(parts, "("+strings.TrimSpace(raw)+")")
	}
	for _, p := range predicates {
		id := quoteIdent(driver, p.Column)
		if p.IsNull || p.Value == nil {
			parts = append(parts, id+" IS NULL")
		} else {
			args = append(args, p.Value)
			parts = append(parts, id+" = "+placeholder(driver, len(args)))
		}
	}
	if len(parts) == 0 {
		return "", args
	}
	return " WHERE " + strings.Join(parts, " AND "), args
}

type rowsParams struct {
	objectParams
	RawWhere   string      `json:"raw_where"`
	Predicates []Predicate `json:"predicates"`
	Page       int         `json:"page"`
	PageSize   int         `json:"page_size"`
}
type ResultSet struct {
	Columns  []string `json:"columns"`
	Rows     [][]any  `json:"rows"`
	Affected *int64   `json:"affected,omitempty"`
	Message  string   `json:"message,omitempty"`
	Page     int      `json:"page,omitempty"`
	HasMore  bool     `json:"has_more,omitempty"`
}

func scanRows(rows *sql.Rows, limit int) (ResultSet, error) {
	cols, err := rows.Columns()
	if err != nil {
		return ResultSet{}, err
	}
	result := ResultSet{Columns: cols, Rows: [][]any{}}
	for rows.Next() {
		raw := make([]any, len(cols))
		ptr := make([]any, len(cols))
		for i := range raw {
			ptr[i] = &raw[i]
		}
		if err := rows.Scan(ptr...); err != nil {
			return result, err
		}
		for i := range raw {
			raw[i] = normalize(raw[i])
		}
		result.Rows = append(result.Rows, raw)
		if limit > 0 && len(result.Rows) >= limit {
			break
		}
	}
	return result, rows.Err()
}

func scanResultSets(rows *sql.Rows) ([]ResultSet, error) {
	sets := []ResultSet{}
	for {
		result, err := scanRows(rows, 0)
		if err != nil {
			return nil, err
		}
		result.Message = fmt.Sprintf("%d row(s)", len(result.Rows))
		sets = append(sets, result)
		if !rows.NextResultSet() {
			break
		}
	}
	return sets, rows.Err()
}

func normalize(v any) any {
	switch x := v.(type) {
	case []byte:
		return string(x)
	case time.Time:
		return x.Format(time.RFC3339Nano)
	default:
		return x
	}
}

func (s *Server) rows(req Request) (any, error) {
	p, err := decode[rowsParams](req.Params)
	if err != nil {
		return nil, err
	}
	if p.Page < 0 {
		p.Page = 0
	}
	if p.PageSize <= 0 {
		p.PageSize = 200
	}
	if p.PageSize > 1000 {
		p.PageSize = 1000
	}
	db, profile, err := s.pool(p.ProfileID, p.Database)
	if err != nil {
		return nil, err
	}
	ctx, done := s.requestContext(req.ID, profile.TimeoutMS)
	defer done()
	cols, err := s.columnsFor(ctx, db, profile, p.objectParams)
	if err != nil {
		return nil, err
	}
	order := ""
	for _, c := range cols {
		if c.Primary {
			if order == "" {
				order = " ORDER BY "
			} else {
				order += ","
			}
			order += quoteIdent(profile.Driver, c.Name)
		}
	}
	where, args := whereClause(profile.Driver, p.RawWhere, p.Predicates)
	table := qualified(profile.Driver, p.Schema, p.Table)
	selected := make([]string, 0, len(cols))
	for _, column := range cols {
		selected = append(selected, quoteIdent(profile.Driver, column.Name))
	}
	selectList := strings.Join(selected, ",")
	offset := p.Page * p.PageSize
	var query string
	if profile.Driver == "mssql" {
		if order == "" {
			order = " ORDER BY (SELECT NULL)"
		}
		query = fmt.Sprintf("SELECT %s FROM %s%s%s OFFSET %d ROWS FETCH NEXT %d ROWS ONLY", selectList, table, where, order, offset, p.PageSize+1)
	} else {
		query = fmt.Sprintf("SELECT %s FROM %s%s%s LIMIT %d OFFSET %d", selectList, table, where, order, p.PageSize+1, offset)
	}
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result, err := scanRows(rows, p.PageSize+1)
	if err != nil {
		return nil, err
	}
	result.Page = p.Page
	result.HasMore = len(result.Rows) > p.PageSize
	if result.HasMore {
		result.Rows = result.Rows[:p.PageSize]
	}
	return result, nil
}

type distinctParams struct {
	rowsParams
	Column string `json:"column"`
}

func (s *Server) distinct(req Request) (any, error) {
	p, err := decode[distinctParams](req.Params)
	if err != nil {
		return nil, err
	}
	db, profile, err := s.pool(p.ProfileID, p.Database)
	if err != nil {
		return nil, err
	}
	ctx, done := s.requestContext(req.ID, profile.TimeoutMS)
	defer done()
	where, args := whereClause(profile.Driver, p.RawWhere, p.Predicates)
	col := quoteIdent(profile.Driver, p.Column)
	table := qualified(profile.Driver, p.Schema, p.Table)
	query := fmt.Sprintf("SELECT %s, COUNT(*) AS lazydata_count FROM %s%s GROUP BY %s ORDER BY lazydata_count DESC", col, table, where, col)
	if profile.Driver == "mssql" {
		query = "SELECT TOP 200 " + strings.TrimPrefix(query, "SELECT ")
	} else {
		query += " LIMIT 200"
	}
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []map[string]any{}
	for rows.Next() {
		var value any
		var count int64
		if err := rows.Scan(&value, &count); err != nil {
			return nil, err
		}
		result = append(result, map[string]any{"value": normalize(value), "is_null": value == nil, "count": count})
	}
	return result, rows.Err()
}

type queryParams struct {
	targetParams
	SQL string `json:"sql"`
}

var firstToken = regexp.MustCompile(`(?is)^\s*(?:(?:--[^\n]*(?:\n|$)|/\*.*?\*/)\s*)*([a-z]+)`)

func readLooking(query string) bool {
	m := firstToken.FindStringSubmatch(query)
	if len(m) < 2 {
		return false
	}
	switch strings.ToLower(m[1]) {
	case "select", "show", "explain", "describe", "values":
		return true
	}
	return false
}

func returnsRows(query string) bool {
	if readLooking(query) {
		return true
	}
	m := firstToken.FindStringSubmatch(query)
	if len(m) < 2 {
		return false
	}
	switch strings.ToLower(m[1]) {
	case "with", "pragma":
		return true
	}
	return false
}
func (s *Server) query(req Request) (any, error) {
	p, err := decode[queryParams](req.Params)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(p.SQL) == "" {
		return nil, &APIError{Code: "empty_query", Message: "Query is empty"}
	}
	db, profile, err := s.pool(p.ProfileID, p.Database)
	if err != nil {
		return nil, err
	}
	ctx, done := s.requestContext(req.ID, profile.TimeoutMS)
	defer done()
	if profile.ReadOnly && !readLooking(p.SQL) {
		return nil, &APIError{Code: "read_only", Message: "This connection is read-only"}
	}
	if returnsRows(p.SQL) {
		rows, err := db.QueryContext(ctx, p.SQL)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		return scanResultSets(rows)
	}
	res, err := db.ExecContext(ctx, p.SQL)
	if err != nil {
		return nil, err
	}
	affected, affErr := res.RowsAffected()
	out := ResultSet{Message: "Query completed"}
	if affErr == nil {
		out.Affected = &affected
		out.Message = fmt.Sprintf("%d row(s) affected", affected)
	}
	return []ResultSet{out}, nil
}

func (s *Server) close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, cancel := range s.cancels {
		cancel()
	}
	for _, db := range s.pools {
		db.Close()
	}
}
