SHELL := /bin/sh
.ONESHELL:

ARCH ?= x86_64
NVIM_VERSION ?= v0.12.4
DIST_DIR := dist
DOWNLOAD_DIR := .cache
NAME := nvim
OUTPUT := $(DIST_DIR)/$(NAME)
LAZYDIFF_NAME := lazydiff
LAZYDIFF_OUTPUT := $(DIST_DIR)/$(LAZYDIFF_NAME)
NVIM_ARCHIVE := $(DOWNLOAD_DIR)/nvim-linux-$(ARCH)-$(NVIM_VERSION).tar.gz
NVIM_URL := https://github.com/neovim/neovim/releases/download/$(NVIM_VERSION)/nvim-linux-$(ARCH).tar.gz
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
INSTALL_NAME ?= nvim
VSCODE_THEME_DIR := vscode-theme
NVIM_DAP_DIR := nvim-dap
PORTABLE_CACHE_DIR ?= $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)/nvim-portable
RELEASE_DIR := $(DIST_DIR)/release

.PHONY: all help build update install release-assets publish clean

all: help

help:
	@printf '%s\n' \
	  'Available commands:' \
	  '  make build    Build the portable nvim and lazydiff executables in dist/' \
	  '  make update   Refresh the cached official Neovim download' \
	  '  make install  Build and install it as ~/.local/bin/nvim' \
	  '  make publish  Build and publish the next GitHub release' \
	  '  make clean    Remove generated files; keep the Neovim download'

$(NVIM_ARCHIVE):
	set -eu
	case "$(ARCH)" in x86_64|arm64) ;; *) echo "Unsupported architecture: $(ARCH)" >&2; exit 2 ;; esac
	mkdir -p "$(DOWNLOAD_DIR)"
	TMP="$@.tmp.$$$$"
	trap 'rm -f "$$TMP"' EXIT HUP INT TERM
	echo "Downloading Neovim $(NVIM_VERSION) for Linux $(ARCH)..."
	curl -fL --retry 3 -o "$$TMP" "$(NVIM_URL)"
	mv "$$TMP" "$@"
	trap - EXIT HUP INT TERM

update:
	set -eu
	rm -f "$(NVIM_ARCHIVE)"
	$(MAKE) "$(NVIM_ARCHIVE)"

build: $(NVIM_ARCHIVE)
	set -eu
	case "$(ARCH)" in x86_64|arm64) ;; *) echo "Unsupported architecture: $(ARCH)" >&2; exit 2 ;; esac
	test -f init.lua || { echo "init.lua is missing" >&2; exit 1; }
	test -d lua || { echo "lua/ is missing" >&2; exit 1; }
	test -d "$(VSCODE_THEME_DIR)" || { echo "Bundled theme is missing: $(VSCODE_THEME_DIR)" >&2; exit 1; }
	test -d "$(NVIM_DAP_DIR)" || { echo "Bundled nvim-dap is missing: $(NVIM_DAP_DIR)" >&2; exit 1; }
	WORK=$$(mktemp -d)
	trap 'rm -rf "$$WORK"' EXIT HUP INT TERM
	mkdir -p "$$WORK/payload/config" "$(DIST_DIR)"
	tar -xzf "$(NVIM_ARCHIVE)" -C "$$WORK"
	mv "$$WORK/nvim-linux-$(ARCH)" "$$WORK/payload/nvim"
	cp init.lua "$$WORK/payload/config/init.lua"
	cp -R lua "$$WORK/payload/config/lua"
	cp -R "$(VSCODE_THEME_DIR)" "$$WORK/payload/config/vscode-theme"
	cp -R "$(NVIM_DAP_DIR)" "$$WORK/payload/config/nvim-dap"
	CONFIG_HASH=$$(cd "$$WORK/payload/config" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
	NVIM_HASH=$$(sha256sum "$(NVIM_ARCHIVE)" | cut -d' ' -f1)
	PAYLOAD_ID=$$(printf '%s\n' '$(NVIM_VERSION)-$(ARCH)' "$$NVIM_HASH" "$$CONFIG_HASH" | sha256sum | cut -c1-16)
	STUB="$$WORK/stub"
	cat >"$$STUB" <<'LAUNCHER'
	#!/bin/sh
	set -eu
	PAYLOAD_ID='PAYLOAD_ID_VALUE'
	CACHE_BASE=$${XDG_CACHE_HOME:-$${HOME:-/tmp}/.cache}
	APP_DIR="$$CACHE_BASE/nvim-portable/$$PAYLOAD_ID"
	if [ ! -x "$$APP_DIR/nvim/bin/nvim" ]; then
	  command -v tar >/dev/null 2>&1 || { echo 'nvim-portable requires tar to unpack itself' >&2; exit 127; }
	  TMP_DIR="$$APP_DIR.tmp.$$$$"
	  rm -rf "$$TMP_DIR"
	  mkdir -p "$$TMP_DIR"
	  tail -n +ARCHIVE_LINE "$$0" | tar -xz -C "$$TMP_DIR"
	  mkdir -p "$$(dirname "$$APP_DIR")"
	  rm -rf "$$APP_DIR"
	  mv "$$TMP_DIR/payload" "$$APP_DIR"
	  rmdir "$$TMP_DIR" 2>/dev/null || true
	fi
	export NVIM_PORTABLE_INIT="$$APP_DIR/config/init.lua"
	if [ "$${NVIM_PORTABLE_LAZYDIFF:-}" = 1 ]; then
	  exec "$$APP_DIR/nvim/bin/nvim" -u NORC --cmd "set runtimepath^=$$APP_DIR/config" "$$@"
	fi
	exec "$$APP_DIR/nvim/bin/nvim" -u "$$NVIM_PORTABLE_INIT" "$$@"
	LAUNCHER
	sed -i "s/PAYLOAD_ID_VALUE/$$PAYLOAD_ID/" "$$STUB"
	ARCHIVE_LINE=$$(( $$(wc -l <"$$STUB") + 1 ))
	sed -i "s/ARCHIVE_LINE/$$ARCHIVE_LINE/" "$$STUB"
	tar -czf "$$WORK/payload.tar.gz" -C "$$WORK" payload
	cat "$$STUB" "$$WORK/payload.tar.gz" >"$(OUTPUT)"
	chmod 755 "$(OUTPUT)"
	echo "Built $(OUTPUT) ($$(du -h "$(OUTPUT)" | cut -f1))"
	cat >"$(LAZYDIFF_OUTPUT)" <<'LAZYDIFF'
	#!/bin/sh
	set -eu
	SELF_DIR=$$(CDPATH= cd -- "$$(dirname -- "$$0")" && pwd)
	NVIM_BIN=$${LAZYDIFF_NVIM:-$$SELF_DIR/$(INSTALL_NAME)}
	if [ ! -x "$$NVIM_BIN" ]; then
	  NVIM_BIN=$$(command -v "$(INSTALL_NAME)" || true)
	fi
	[ -n "$$NVIM_BIN" ] || { echo 'lazydiff requires $(INSTALL_NAME) on PATH' >&2; exit 127; }
	if [ "$$#" -gt 0 ]; then
	  export LAZYDIFF_FILE=$$1
	  shift
	fi
	export NVIM_PORTABLE_LAZYDIFF=1
	exec "$$NVIM_BIN" -i NONE -c "lua require('views.lazydiff').launch({ focus_file = vim.env.LAZYDIFF_FILE })"
	LAZYDIFF
	chmod 755 "$(LAZYDIFF_OUTPUT)"
	echo "Built $(LAZYDIFF_OUTPUT)"

install: build
	install -d "$(BINDIR)"
	install -m 755 "$(OUTPUT)" "$(BINDIR)/$(INSTALL_NAME)"
	install -m 755 "$(LAZYDIFF_OUTPUT)" "$(BINDIR)/$(LAZYDIFF_NAME)"
	echo "Installed $(BINDIR)/$(INSTALL_NAME)"
	echo "Installed $(BINDIR)/$(LAZYDIFF_NAME)"
	rm -rf "$(PORTABLE_CACHE_DIR)"
	echo "Cleared $(PORTABLE_CACHE_DIR)"
	$(MAKE) clean

release-assets:
	set -eu
	WORK=$$(mktemp -d)
	trap 'rm -rf "$$WORK"' EXIT HUP INT TERM
	for ARCH_VALUE in x86_64 arm64; do
	  $(MAKE) build ARCH="$$ARCH_VALUE"
	  tar -czf "$$WORK/nvim-linux-$$ARCH_VALUE.tar.gz" -C "$(DIST_DIR)" "$(NAME)" "$(LAZYDIFF_NAME)"
	done
	rm -rf "$(RELEASE_DIR)"
	mkdir -p "$(RELEASE_DIR)"
	mv "$$WORK"/nvim-linux-*.tar.gz "$(RELEASE_DIR)/"
	cat >"$(RELEASE_DIR)/install.sh" <<'INSTALLER'
	#!/bin/sh
	set -eu

	REPOSITORY=michalCapo/nvim
	BASE_URL=$${NVIM_RELEASE_BASE_URL:-"https://github.com/$$REPOSITORY/releases/latest/download"}
	BINDIR=$${HOME:+"$$HOME/.local/bin"}

	fail() {
	  echo "nvim installer: $$*" >&2
	  exit 1
	}

	[ -n "$${BINDIR:-}" ] || fail 'HOME is not set'

	for command_name in curl tar sha256sum mktemp; do
	  command -v "$$command_name" >/dev/null 2>&1 || fail "required command not found: $$command_name"
	done

	[ "$$(uname -s)" = Linux ] || fail "unsupported operating system: $$(uname -s)"

	case $$(uname -m) in
	  x86_64|amd64) arch=x86_64 ;;
	  aarch64|arm64) arch=arm64 ;;
	  *) fail "unsupported Linux architecture: $$(uname -m)" ;;
	esac

	asset="nvim-linux-$$arch.tar.gz"
	work=$$(mktemp -d)
	trap 'rm -rf "$$work"' EXIT HUP INT TERM

	echo "Downloading the latest nvim release for $$arch..."
	curl -fL --retry 3 -o "$$work/$$asset" "$$BASE_URL/$$asset"
	curl -fL --retry 3 -o "$$work/SHA256SUMS" "$$BASE_URL/SHA256SUMS"

	awk -v asset="$$asset" '$$2 == asset { print; found = 1 } END { exit !found }' \
	  "$$work/SHA256SUMS" > "$$work/$$asset.sha256" \
	  || fail "checksum not found for $$asset"
	(cd "$$work" && sha256sum -c "$$asset.sha256") || fail 'checksum verification failed'

	mkdir -p "$$work/unpacked" "$$BINDIR"
	tar -xzf "$$work/$$asset" -C "$$work/unpacked"
	[ -f "$$work/unpacked/nvim" ] || fail 'release archive does not contain nvim'
	[ -f "$$work/unpacked/lazydiff" ] || fail 'release archive does not contain lazydiff'
	chmod 755 "$$work/unpacked/nvim" "$$work/unpacked/lazydiff"

	stage="$$BINDIR/.nvim-install.$$$$"
	mkdir "$$stage"
	trap 'rm -rf "$$work" "$$stage"' EXIT HUP INT TERM
	cp "$$work/unpacked/nvim" "$$stage/nvim"
	cp "$$work/unpacked/lazydiff" "$$stage/lazydiff"
	mv "$$stage/nvim" "$$BINDIR/nvim"
	mv "$$stage/lazydiff" "$$BINDIR/lazydiff"
	rmdir "$$stage"

	cache_base=$${XDG_CACHE_HOME:-"$$HOME/.cache"}
	rm -rf "$$cache_base/nvim-portable"

	echo "Installed $$BINDIR/nvim"
	echo "Installed $$BINDIR/lazydiff"
	case :$${PATH:-}: in
	  *:"$$BINDIR":*) ;;
	  *) echo "Add $$BINDIR to PATH to use these commands." ;;
	esac
	INSTALLER
	chmod 755 "$(RELEASE_DIR)/install.sh"
	cd "$(RELEASE_DIR)"
	sha256sum nvim-linux-x86_64.tar.gz nvim-linux-arm64.tar.gz > SHA256SUMS
	echo "Built release assets in $(RELEASE_DIR)/"

publish:
	set -eu
	command -v gh >/dev/null 2>&1 || { echo 'publish requires the GitHub CLI (gh)' >&2; exit 127; }
	gh auth status >/dev/null
	BRANCH=$$(git branch --show-current)
	[ "$$BRANCH" = main ] || { echo "publish must run from main (current: $${BRANCH:-detached HEAD})" >&2; exit 1; }
	[ -z "$$(git status --porcelain)" ] || { echo 'publish requires a clean worktree' >&2; exit 1; }
	LOCAL_HEAD=$$(git rev-parse HEAD)
	REMOTE_HEAD=$$(git ls-remote origin refs/heads/main | awk '{print $$1}')
	[ -n "$$REMOTE_HEAD" ] || { echo 'could not resolve origin/main' >&2; exit 1; }
	[ "$$LOCAL_HEAD" = "$$REMOTE_HEAD" ] || { echo 'main must be pushed and match origin/main before publishing' >&2; exit 1; }
	LATEST=$$(gh release list --exclude-drafts --exclude-pre-releases --limit 1 --json tagName --jq '.[0].tagName // ""')
	if [ -z "$$LATEST" ]; then
	  VERSION=v0.1.0
	else
	  printf '%s\n' "$$LATEST" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "latest stable release has unsupported tag: $$LATEST" >&2; exit 1; }
	  NUMBERS=$${LATEST#v}
	  OLD_IFS=$$IFS
	  IFS=.
	  set -- $$NUMBERS
	  IFS=$$OLD_IFS
	  VERSION="v$$1.$$2.$$(( $$3 + 1 ))"
	fi
	gh release view "$$VERSION" >/dev/null 2>&1 && { echo "release already exists: $$VERSION" >&2; exit 1; } || true
	echo "Publishing $$VERSION from $$LOCAL_HEAD..."
	$(MAKE) release-assets
	gh release create "$$VERSION" \
	  "$(RELEASE_DIR)/nvim-linux-x86_64.tar.gz" \
	  "$(RELEASE_DIR)/nvim-linux-arm64.tar.gz" \
	  "$(RELEASE_DIR)/SHA256SUMS" \
	  "$(RELEASE_DIR)/install.sh" \
	  --target "$$LOCAL_HEAD" --title "$$VERSION" --generate-notes --fail-on-no-commits --latest
	gh api --paginate 'repos/{owner}/{repo}/releases?per_page=100' --jq '.[].tag_name' | while IFS= read -r OLD_VERSION; do
	  [ -n "$$OLD_VERSION" ] || continue
	  [ "$$OLD_VERSION" = "$$VERSION" ] || gh release delete "$$OLD_VERSION" --yes
	done
	gh release view "$$VERSION" --json url --jq .url

clean:
	rm -rf "$(DIST_DIR)"
