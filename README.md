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
- `vimd`: the LazyData database viewer, with its `vimd-sql` helper

These commands were previously named `nvima`, `lazydiff`, `lazyrepo`,
`lazydata`, and `lazydata-sql`. `make install` and the release installer
remove the old names.

The launchers unpack their bundled configuration below
`${XDG_CACHE_HOME:-~/.cache}`.

`vime` is a slimmer build of the same editor. It keeps file management, LSP,
completion, editing/navigation, and UI/shell features, and leaves out the AI
agents, Git tools, database viewer, debugger, and run configurations. It builds
its own payload and installs beside `nvim`, so both commands stay available.

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
```

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
