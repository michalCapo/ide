# nvim

Personal Neovim configuration packaged as a portable Linux executable. The
build bundles Neovim, this Lua configuration, the VS Code theme, and nvim-dap into a
self-extracting launcher. It also creates a `lazydiff` companion command.

## Requirements

- Linux (`x86_64` or `arm64`)
- `make`, `curl`, `tar`, and `sha256sum`

The VS Code theme and nvim-dap are included in this repository.

## Build and install

```sh
make build
make install
```

`make build` writes `dist/nvim` and `dist/lazydiff`. `make install` installs
both commands to `~/.local/bin` by default.

Build settings can be overridden on the command line:

```sh
make build ARCH=arm64 NVIM_VERSION=v0.12.4
make install PREFIX=/custom/prefix
```

Other useful commands:

```sh
make update  # refresh the cached Neovim download
make clean   # remove generated files
```

## Use as a regular config

Clone the repository to Neovim's config directory and start Neovim normally:

```sh
git clone git@github.com:michalCapo/nvim.git ~/.config/nvim
nvim
```

## License

This is a personal configuration. No license has been granted for reuse or
redistribution.
