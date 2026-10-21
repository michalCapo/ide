# Portable terminal tools

Personal Neovim, database, and Git tools packaged as portable Linux commands.
The build bundles `nvim` and `vime` with their configuration and also creates
the `vimi`, `vimg`, and `vimd` companion commands.

## Included commands

Each command is built for both `x86_64` and `arm64`:

- `nvim`: the full editor
- `vime`: the slimmer editor
- `vimi`: the Git diff viewer
- `vimg`: the Git repository dashboard
- `vimd`: the LazyData database viewer, with its `vimd-sql` helper; also
  installed as `agent-db` for AI agents

These commands were previously named `nvima`, `lazydiff`, `lazyrepo`,
`lazydata`, and `lazydata-sql`. `make install` and the release installer
remove the old names.

The launchers unpack their bundled configuration below
`${XDG_CACHE_HOME:-~/.cache}`.

`vime` is a slimmer build of the same editor. It keeps file management, LSP,
completion, editing/navigation, and UI/shell features, and leaves out the AI
agents, Git tools, database viewer, debugger, and run configurations. It builds
its own payload and installs beside `nvim`, so both commands stay available.

On first launch, `vime` automatically installs missing language servers
(TypeScript/JavaScript, Go, and C/C++), Node.js, TypeScript, Go, ripgrep, Git, Bash,
and Universal Ctags. Tools already available on `PATH` are reused. Downloads
and their libraries stay under `${XDG_DATA_HOME:-~/.local/share}/vime/`;
no sudo or shell configuration changes are needed. First-time setup needs
internet access and can take a few minutes. Later launches reuse the tools.
If setup fails, the editor still opens and retries on its next launch.
Setup details are saved to `${XDG_DATA_HOME:-~/.local/share}/vime/setup.log`.
Set `VIME_INSTALL_DEPS=0` to skip automatic installation. Help and version
commands do not install dependencies.

Inside a Libro terminal, `nvim` and `vime` show images, PDFs, and HTML files in
a Libro Browser panel beside the editor. Use `o` in the file explorer, `gx`, or
`Space b v` for the current file. Other files, and files outside Libro, open in
the default app.

## Requirements

- Linux (`x86_64` or `arm64`)
- `make`, `curl`, `tar`, `sha256sum`, Bash, and Go 1.27.1 or newer when building

The Neovim plugins and themes are included in this repository. The downloaded
Neovim release is checksum-verified and retained in `.cache/`.

## Build and install

Install the latest release:

```sh
curl -fsSL https://github.com/michalCapo/nvim/releases/latest/download/install.sh | sh
```

This verifies the release checksum and installs the commands supported by the
current architecture into `~/.local/bin`. Add that directory to `PATH` if
needed.

To build and install from a checkout:

```sh
make build
make install
```

`make build` writes commands to `dist/`. `make install` installs them to
`~/.local/bin` by default.

`make publish` also copies the Linux release archives and `SHA256SUMS` into
`../libro/tools/` (`make libro-tools` does only that step; set `LIBRO_DIR` for
another checkout). Libro packs them into its Linux builds.

Review changes in the current Git repository, initially focusing a specific
repository-relative file:

```sh
vimi
vimi path/to/file
vimi --help
```

Running `vimi` without arguments prints its usage. Pass one `FILE` argument
to launch the viewer. Use `--` before a file whose name begins with `-`.

Open the repository-wide dashboard from anywhere inside a Git repository:

```sh
vimg
vimg --help
```

The dashboard uses Files, Local/Remote/Stash, and Commits columns. In terminals
narrower than 100 columns it collapses to the active panel; use `h`/`l` or
`Tab`/`Shift-Tab` to move between panels.
In Files, press `o` to open the selected file in the OS default application.

Open the database viewer:

```sh
vimd
vimd --help
vimd open prod            # read-only
vimd open prod --alter    # allow row edits, deletes, and writes
```

`vimd` (or its alias `agent-db`) also works as a plain command-line tool for
scripts and AI agents. It prints data to stdout and errors to stderr, and exits with 0 on success, 1 on a
connection or SQL error, and 2 on invalid usage:

```sh
vimd list                                   # saved connections, no passwords
vimd test prod                              # check the connection
vimd databases prod
vimd tables prod
vimd columns prod public.users
vimd query prod "SELECT id, email FROM users"
vimd query prod --json < report.sql         # SQL from stdin, JSON output
vimd query prod --format csv "SELECT * FROM orders" > orders.csv
vimd query prod --timeout 5m < slow-report.sql
vimd query prod --alter "DELETE FROM sessions WHERE expired"
vimd skills get core --full                 # usage guide for AI agents
```

Connections are matched by name, ignoring case. Use `-d <database>` to target
another database, `--limit <rows>` to change the 1000-row default per result
(`0` shows all rows), and `--timeout <time>` (`90s`, `5m`, or seconds) to
override the saved timeout. `--format` prints `table` (default), `json`, `csv`
(NULL is empty), or `tsv` (PostgreSQL COPY text, NULL is `\N`); `--no-header`
drops the header row. With CSV and TSV, status lines go to stderr. Commands are read-only by default: a query that may change
data fails unless `--alter` is given, and read-only queries run in a transaction
that is always rolled back. Connections saved as read-only never allow changes.
Connections hold passwords, so they are added and edited only in the viewer;
the command line can list them but never shows passwords.

`vimd skills` bundles usage guides for AI agents, in the same style as
`agent-browser skills`: `vimd skills list` shows them and
`vimd skills get core --full` prints the core guide with its references.

LazyData supports PostgreSQL, SQL Server, and SQLite through its bundled
`vimd-sql` helper. Connection profiles are managed at startup and stored with mode `0600`
in `${XDG_CONFIG_HOME:-~/.config}/lazydata/connections.json`. Passwords are
stored in plaintext in that file.

Use `j`/`k` and `gg`/`G` to move, `Tab` to change panels, `Enter` to open a
table, `1`/`2` for rows/columns, `c` to search and jump to a column, `/` for
search or a WHERE clause, `v` to view the complete selected cell in a large
read-only buffer, and `u` for distinct values from the selected column. Press
`yy` to copy the current field's complete value to the clipboard. Mark a row
with `Space`, then press `y` to copy it; when several rows are marked, `y`
copies all marked rows in display order without
truncating their values. In the full-value viewer, `yy`
copies the current line and visual-mode `y` copies the selection. Use
`Shift-K`/`Shift-J` to sort the cursor column ascending/descending. Press `f`
to manage active filters; from that dialog, `<C-e>` opens an editable `SELECT`
query containing every active filter. From the table, `:query` does the same
(`:Query` is the native command spelling). Press
`Space` to mark one or more rows. Press `e` to edit the current cell, or to set
the selected column on every marked row. Cell edits are staged so you can
change several fields and rows before `<C-s>` executes them together in one
transaction; `U` discards the staged changes. Press `d` to delete the marked
rows after confirmation; with no marks, `d` targets the current row. Editing
and deletion require a primary key and are unavailable on read-only connections.
An `id` column is displayed first and rows default to descending `id` order.
The table sidebar hides while the table has
focus; press `Tab` to show and focus it again. Tables load 30 rows at a time.
The active panel shows operation-specific loading messages for table queries,
sorting, filters, SQL execution, and other database requests, then clears them
when the request finishes. `[[`/`]]` load the previous or next 30-row page, and
`[b`/`]b` switch open tables or query tabs. `<C-e>` opens a query and `<C-r>` runs it. In the
connection dialog, `<C-t>` tests the connection and `<C-s>` saves it. Press `?`
inside LazyData for the complete key list.

Build settings can be overridden on the command line:

```sh
make build ARCH=arm64 NVIM_VERSION=v0.12.5
make install PREFIX=/custom/prefix
```

Version overrides also require overriding the matching architecture-specific
SHA-256 variable because release checksums are pinned in the Makefile.

Other useful commands:

```sh
make update  # refresh cached downloads for ARCH
make clean   # remove dist/ but keep cached downloads
```

## Source layout

- `nvim/` contains the Neovim configuration, bundled plugins, shared views, and
  companion command templates.
- `nvima/` contains the reduced Neovim configuration and launcher used by the
  `vime` command.
- The root `Makefile` builds all portable commands and release assets.

## Use as a regular Neovim config

Clone the repository and link its Neovim directory:

```sh
git clone git@github.com:michalCapo/nvim.git ~/code/nvim
ln -s ~/code/nvim/nvim ~/.config/nvim
nvim
```

## License

This is a personal configuration. No license has been granted for reuse or
redistribution. Bundled upstream projects retain their own licenses.
