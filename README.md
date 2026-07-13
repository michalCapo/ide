# Portable terminal tools

Personal Neovim, Lazygit, and Vifm configuration packaged as portable Linux
commands. The build bundles each upstream executable with its configuration and
also creates the `lazydiff` companion command.

## Included commands

| Command | x86_64 | arm64 |
| --- | --- | --- |
| `nvim` | yes | yes |
| `lazydiff` | yes | yes |
| `lazygit` | yes | yes |
| `vifm` | yes | no |

Vifm is omitted on ARM64 because upstream does not publish an ARM64 Linux
binary. Existing `~/.config/lazygit` and `~/.config/vifm` directories are not
changed. The launchers unpack their bundled configuration below
`${XDG_CACHE_HOME:-~/.cache}`.

## Requirements

- Linux (`x86_64` or `arm64`)
- `make`, `curl`, `tar`, `sha256sum`, and Bash
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
needed. It also creates `~/.local/bin/vim` as a symlink to `nvim`.

To build and install from a checkout:

```sh
make build
make install
```

`make build` writes commands to `dist/`. `make install` installs them to
`~/.local/bin` by default and creates a `vim` symlink beside `nvim`.

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
- `lazygit/` contains the Lazygit configuration and parent-editor helper.
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
