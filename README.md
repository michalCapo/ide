# Portable terminal tools

Personal Neovim, database, Git, and file-management tools packaged as portable
Linux commands. The build bundles each executable with its configuration and
also creates the `lazydata`, `lazydiff`, and `lazyrepo` companion commands.

## Included commands

| Command | x86_64 | arm64 |
| --- | --- | --- |
| `nvim` | yes | yes |
| `lazydiff` | yes | yes |
| `lazyrepo` | yes | yes |
| `lazydata` | yes | yes |
| `lazygit` | yes | yes |
| `vifm` | yes | no |

Vifm is omitted on ARM64 because upstream does not publish an ARM64 Linux
binary. Existing `~/.config/lazygit` and `~/.config/vifm` directories are not
changed. The launchers unpack their bundled configuration below
`${XDG_CACHE_HOME:-~/.cache}`.

## Requirements

- Linux (`x86_64` or `arm64`)
- `make`, `curl`, `tar`, `sha256sum`, Bash, and Go 1.25.7 or newer when building
- x86_64 host when building the Vifm package

The Neovim plugins, themes, Lazygit configuration, and Vifm configuration are
included in this repository. Downloaded upstream binaries are checksum-verified
and retained in `.cache/`.

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

Review changes in the current Git repository, initially focusing a specific
repository-relative file:

```sh
lazydiff
lazydiff path/to/file
lazydiff --help
```

Running `lazydiff` without arguments prints its usage. Pass one `FILE` argument
to launch the viewer. Use `--` before a file whose name begins with `-`.

Open the repository-wide dashboard from anywhere inside a Git repository:

```sh
lazyrepo
lazyrepo --help
```

The dashboard uses Files, Local/Remote/Stash, and Commits columns. In terminals
narrower than 100 columns it collapses to the active panel; use `h`/`l` or
`Tab`/`Shift-Tab` to move between panels.

Open the database viewer:

```sh
lazydata
lazydata --help
```

LazyData supports PostgreSQL, SQL Server, and SQLite through its bundled
`lazydata-sql` helper. Connection profiles are managed at startup and stored with mode `0600`
in `${XDG_CONFIG_HOME:-~/.config}/lazydata/connections.json`. Passwords are
stored in plaintext in that file.

Use `j`/`k` and `gg`/`G` to move, `Tab` to change panels, `Enter` to open a
table, `1`/`2` for rows/columns, `c` to search and jump to a column, `/` for
search or a WHERE clause, `v` to view the complete selected cell in a large
read-only buffer, and `u` for distinct values from the selected column.
An `id` column is displayed first. The table sidebar hides while the table has
focus; press `Tab` to show and focus it again. `[p`/`]p` page data and
`[t`/`]t` switch open tables or query tabs. `<C-e>` opens a query and `<C-r>` runs it. In the
connection dialog, `<C-t>` tests the connection and `<C-s>` saves it. Press `?`
inside LazyData for the complete key list.

Build settings can be overridden on the command line:

```sh
make build ARCH=arm64 NVIM_VERSION=v0.12.4 LAZYGIT_VERSION=0.63.0
make build VIFM_VERSION=0.14.4
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

- `nvim/` contains the Neovim configuration, bundled plugins, and launcher
  templates.
- `lazygit/` contains the active Lazygit configuration and parent-editor helper.
- `vifm/` contains the Vifm configuration, colors, and scripts.
- The root `Makefile` builds all portable commands and release assets.

Vifm runtime history (`vifminfo`) is intentionally not tracked. A clean state
file is created in the extracted portable cache.

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
