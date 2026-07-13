# nvim

Personal Neovim configuration packaged as a portable Linux executable. The
build bundles Neovim, this Lua configuration, the VS Code theme, and nvim-dap into a
self-extracting launcher. It also creates a `lazydiff` companion command.

## Requirements

- Linux (`x86_64` or `arm64`)
- `make`, `curl`, `tar`, and `sha256sum`

The VS Code theme and nvim-dap are included in this repository.

## Build and install

Install the latest release on Linux (`x86_64` or `arm64`):

```sh
curl -fsSL https://github.com/michalCapo/nvim/releases/latest/download/install.sh | sh
```

This verifies the release checksum and installs `nvim` and `lazydiff` to
`~/.local/bin`. Add that directory to `PATH` if needed.

To build and install from a checkout instead:

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

## Publish a release

Publishing requires Linux, the build requirements above, and an authenticated
[GitHub CLI](https://cli.github.com/):

```sh
make publish
```

Run it from a clean `main` branch that has been pushed to `origin`. It builds
both supported architectures and publishes them directly to GitHub Releases.
The first release is `v0.1.0`; later releases automatically increment the patch
number (`v0.1.1`, `v0.1.2`, and so on). After the new release succeeds, older
releases are deleted so only the latest remains. Their Git tags are retained for
version history.

## Use as a regular config

Clone the repository to Neovim's config directory and start Neovim normally:

```sh
git clone git@github.com:michalCapo/nvim.git ~/.config/nvim
nvim
```

## License

This is a personal configuration. No license has been granted for reuse or
redistribution.
