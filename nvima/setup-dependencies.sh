#!/bin/sh
# Install editor tools in a private environment; never change system packages.
set -eu

DEPS_DIR=$1
MICROMAMBA=$2
export PATH="$DEPS_DIR/bin:$PATH"
PACKAGES=''

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    PACKAGES="$PACKAGES $2"
  fi
}

need rg ripgrep
need git git
need bash bash
need ctags universal-ctags
need node 'nodejs>=24,<27'
need typescript-language-server 'typescript-language-server>=6,<7'
need tsserver 'typescript>=6,<7'
need go go
need gopls gopls
need clangd clang-tools

# An existing Node installation can be too old for the language server.
if command -v node >/dev/null 2>&1 && ! node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 24 ? 0 : 1)' >/dev/null 2>&1; then
  PACKAGES="$PACKAGES nodejs>=24,<27"
fi

# Exuberant Ctags lacks the JSON output used by the project symbols view.
if command -v ctags >/dev/null 2>&1 && ! ctags --output-format=json -f - /dev/null >/dev/null 2>&1; then
  PACKAGES="$PACKAGES universal-ctags"
fi

[ -n "$PACKAGES" ] || exit 0
printf '%s\n' 'Vime: installing missing editor dependencies. First launch can take a few minutes.' >&2

ACTION=create
if [ -f "$DEPS_DIR/conda-meta/history" ]; then
  ACTION=install
fi

# Package names are fixed above. Word splitting passes one spec per argument.
# Micromamba handles downloads, checksums, shared libraries, and install locks.
mkdir -p "${DEPS_DIR%/*}"
LOG="${DEPS_DIR%/*}/setup.log"
if ! "$MICROMAMBA" --no-rc --no-env --root-prefix "${DEPS_DIR%/*}/packages" "$ACTION" \
  --yes --prefix "$DEPS_DIR" --override-channels --channel conda-forge \
  --strict-channel-priority $PACKAGES >"$LOG" 2>&1; then
  printf 'Vime: could not install dependencies. Details: %s\n' "$LOG" >&2
  exit 1
fi
printf '%s\n' 'Vime: dependencies are ready.' >&2
