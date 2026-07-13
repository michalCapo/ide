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
VSCODE_THEME_DIR ?= $(HOME)/.local/share/nvim/lazy/vscode-theme
PORTABLE_CACHE_DIR ?= $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)/nvim-portable

.PHONY: all help build update install clean

all: help

help:
	@printf '%s\n' \
	  'Available commands:' \
	  '  make build    Build the portable nvim and lazydiff executables in dist/' \
	  '  make update   Refresh the cached official Neovim download' \
	  '  make install  Build and install it as ~/.local/bin/nvim' \
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
	test -d "$(VSCODE_THEME_DIR)" || { echo "Theme is missing: $(VSCODE_THEME_DIR)" >&2; exit 1; }
	WORK=$$(mktemp -d)
	trap 'rm -rf "$$WORK"' EXIT HUP INT TERM
	mkdir -p "$$WORK/payload/config" "$(DIST_DIR)"
	tar -xzf "$(NVIM_ARCHIVE)" -C "$$WORK"
	mv "$$WORK/nvim-linux-$(ARCH)" "$$WORK/payload/nvim"
	cp init.lua "$$WORK/payload/config/init.lua"
	cp -R lua "$$WORK/payload/config/lua"
	cp -R "$(VSCODE_THEME_DIR)" "$$WORK/payload/config/vscode-theme"
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

clean:
	rm -rf "$(DIST_DIR)"
