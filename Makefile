SHELL := /bin/sh
.ONESHELL:

ARCH ?= x86_64
NVIM_VERSION ?= v0.12.5
MICROMAMBA_VERSION := 2.9.0-0

DIST_DIR := dist
DOWNLOAD_DIR := .cache
RELEASE_DIR := $(DIST_DIR)/release

NVIM_NAME := nvim
NVIMA_NAME := vime
LAZYDIFF_NAME := vimi
LAZYREPO_NAME := vimg
LAZYDATA_NAME := vimd
LAZYDATA_SQL_NAME := vimd-sql
LAZYDATA_ALIAS_NAME := agent-db
NVIM_OUTPUT := $(DIST_DIR)/$(NVIM_NAME)
NVIMA_OUTPUT := $(DIST_DIR)/$(NVIMA_NAME)
LAZYDIFF_OUTPUT := $(DIST_DIR)/$(LAZYDIFF_NAME)
LAZYREPO_OUTPUT := $(DIST_DIR)/$(LAZYREPO_NAME)
LAZYDATA_OUTPUT := $(DIST_DIR)/$(LAZYDATA_NAME)
LAZYDATA_SQL_OUTPUT := $(DIST_DIR)/$(LAZYDATA_SQL_NAME)

NVIM_SOURCE_DIR := nvim
NVIMA_SOURCE_DIR := nvima

NVIM_ARCHIVE := $(DOWNLOAD_DIR)/nvim-linux-$(ARCH)-$(NVIM_VERSION).tar.gz
NVIM_URL := https://github.com/neovim/neovim/releases/download/$(NVIM_VERSION)/nvim-linux-$(ARCH).tar.gz

NVIM_SHA256_x86_64 := bce0f56eda1f1b1db6eee8f4133d7a38813ea07933837dd1777411ca384c6875
NVIM_SHA256_arm64 := 1aa5ca085249580ae0f91eb14f27ec0919773ff2d99a163d03f3d6c21ac29725

MICROMAMBA_BINARY := $(DOWNLOAD_DIR)/micromamba-$(ARCH)-$(MICROMAMBA_VERSION)
MICROMAMBA_PLATFORM_x86_64 := linux-64
MICROMAMBA_PLATFORM_arm64 := linux-aarch64
MICROMAMBA_SHA256_x86_64 := 366cd9cd8be14df1ab8ed50352a82111082a36686b2d389fdb79a92c3fafb3e3
MICROMAMBA_SHA256_arm64 := 9f93b974adcb4d166996af969b6cd371287d1a3e52733704727884d9b74cb7a7

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
INSTALL_NAME ?= nvim
LIBRO_DIR ?= $(CURDIR)/../libro
NVIM_PORTABLE_CACHE_DIR ?= $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)/nvim-portable

.PHONY: all help build update install release-assets libro-tools publish clean

all: help

help:
	@printf '%s\n' \
	  'Available commands:' \
	  '  make build    Build portable nvim, vime, vimi, vimg, and vimd' \
	  '  make update   Refresh cached downloads for the selected architecture' \
	  '  make install  Build and install commands under ~/.local/bin' \
	  '  make libro-tools  Build release assets and copy them into the Libro project' \
	  '  make publish  Build and publish the next GitHub release, and copy it into Libro' \
	  '  make clean    Remove generated files; keep cached downloads'

$(NVIM_ARCHIVE):
	set -eu
	case "$(ARCH)" in
	  x86_64) EXPECTED='$(NVIM_SHA256_x86_64)' ;;
	  arm64) EXPECTED='$(NVIM_SHA256_arm64)' ;;
	  *) echo "Unsupported architecture: $(ARCH)" >&2; exit 2 ;;
	esac
	mkdir -p "$(DOWNLOAD_DIR)"
	TMP="$@.tmp.$$$$"
	trap 'rm -f "$$TMP"' EXIT HUP INT TERM
	echo "Downloading Neovim $(NVIM_VERSION) for Linux $(ARCH)..."
	curl -fL --retry 3 -o "$$TMP" "$(NVIM_URL)"
	printf '%s  %s\n' "$$EXPECTED" "$$TMP" | sha256sum -c -
	mv "$$TMP" "$@"
	trap - EXIT HUP INT TERM

$(MICROMAMBA_BINARY):
	set -eu
	case "$(ARCH)" in x86_64|arm64) ;; *) echo "Unsupported architecture: $(ARCH)" >&2; exit 2 ;; esac
	mkdir -p "$(DOWNLOAD_DIR)"
	TMP="$@.tmp.$$$$"
	trap 'rm -f "$$TMP"' EXIT HUP INT TERM
	curl -fL --retry 3 -o "$$TMP" "https://github.com/mamba-org/micromamba-releases/releases/download/$(MICROMAMBA_VERSION)/micromamba-$(MICROMAMBA_PLATFORM_$(ARCH))"
	printf '%s  %s\n' '$(MICROMAMBA_SHA256_$(ARCH))' "$$TMP" | sha256sum -c -
	chmod 755 "$$TMP"
	mv "$$TMP" "$@"
	trap - EXIT HUP INT TERM

update:
	set -eu
	case "$(ARCH)" in x86_64|arm64) ;; *) echo "Unsupported architecture: $(ARCH)" >&2; exit 2 ;; esac
	rm -f "$(NVIM_ARCHIVE)"
	$(MAKE) "$(NVIM_ARCHIVE)" ARCH="$(ARCH)"

build: $(NVIM_ARCHIVE) $(MICROMAMBA_BINARY)
	set -eu
	case "$(ARCH)" in x86_64|arm64) ;; *) echo "Unsupported architecture: $(ARCH)" >&2; exit 2 ;; esac
	test -f "$(NVIM_SOURCE_DIR)/init.lua" || { echo 'Neovim init.lua is missing' >&2; exit 1; }
	test -d "$(NVIM_SOURCE_DIR)/lua" || { echo 'Neovim lua directory is missing' >&2; exit 1; }
	test -d "$(NVIM_SOURCE_DIR)/vscode-theme" || { echo 'Bundled theme is missing' >&2; exit 1; }
	test -d "$(NVIM_SOURCE_DIR)/nvim-dap" || { echo 'Bundled nvim-dap is missing' >&2; exit 1; }
	test -d "$(NVIM_SOURCE_DIR)/supermaven-nvim" || { echo 'Bundled supermaven-nvim is missing' >&2; exit 1; }
	test -f "$(NVIMA_SOURCE_DIR)/init.lua" || { echo 'nvima init.lua is missing' >&2; exit 1; }
	test -f "$(NVIMA_SOURCE_DIR)/launcher.sh" || { echo 'nvima launcher is missing' >&2; exit 1; }
	WORK=$$(mktemp -d)
	trap 'rm -rf "$$WORK"' EXIT HUP INT TERM
	mkdir -p "$$WORK/nvim-payload/config" "$(DIST_DIR)"
	tar -xzf "$(NVIM_ARCHIVE)" -C "$$WORK"
	mv "$$WORK/nvim-linux-$(ARCH)" "$$WORK/nvim-payload/nvim"
	cp "$(NVIM_SOURCE_DIR)/init.lua" "$$WORK/nvim-payload/config/init.lua"
	cp -R "$(NVIM_SOURCE_DIR)/lua" "$$WORK/nvim-payload/config/lua"
	cp -R "$(NVIM_SOURCE_DIR)/vscode-theme" "$$WORK/nvim-payload/config/vscode-theme"
	cp -R "$(NVIM_SOURCE_DIR)/nvim-dap" "$$WORK/nvim-payload/config/nvim-dap"
	cp -R "$(NVIM_SOURCE_DIR)/supermaven-nvim" "$$WORK/nvim-payload/config/supermaven-nvim"
	CONFIG_HASH=$$(cd "$$WORK/nvim-payload/config" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
	NVIM_HASH=$$(sha256sum "$(NVIM_ARCHIVE)" | cut -d' ' -f1)
	PAYLOAD_ID=$$(printf '%s\n' '$(NVIM_VERSION)-$(ARCH)' "$$NVIM_HASH" "$$CONFIG_HASH" | sha256sum | cut -c1-16)
	STUB="$$WORK/nvim-stub"
	cp "$(NVIM_SOURCE_DIR)/launcher.sh" "$$STUB"
	sed -i "s/@PAYLOAD_ID@/$$PAYLOAD_ID/" "$$STUB"
	ARCHIVE_LINE=$$(( $$(wc -l <"$$STUB") + 1 ))
	sed -i "s/@ARCHIVE_LINE@/$$ARCHIVE_LINE/" "$$STUB"
	tar -czf "$$WORK/nvim-payload.tar.gz" -C "$$WORK" nvim-payload
	cat "$$STUB" "$$WORK/nvim-payload.tar.gz" >"$(NVIM_OUTPUT)"
	chmod 755 "$(NVIM_OUTPUT)"
	echo "Built $(NVIM_OUTPUT) ($$(du -h "$(NVIM_OUTPUT)" | cut -f1))"

	NVIMA_MK=$$WORK/nvima-payload
	mkdir -p "$$NVIMA_MK/config/lua/views"
	cp -R "$$WORK/nvim-payload/nvim" "$$NVIMA_MK/nvim"
	cp "$(NVIMA_SOURCE_DIR)/init.lua" "$$NVIMA_MK/config/init.lua"
	cp "$(NVIMA_SOURCE_DIR)/setup-dependencies.sh" "$$NVIMA_MK/config/setup-dependencies.sh"
	cp "$(NVIMA_SOURCE_DIR)/micromamba-LICENSE.txt" "$$NVIMA_MK/config/micromamba-LICENSE.txt"
	cp "$(MICROMAMBA_BINARY)" "$$NVIMA_MK/config/micromamba"
	cp "$(NVIM_SOURCE_DIR)/lua/views/references.lua" "$$NVIMA_MK/config/lua/views/references.lua"
	cp "$(NVIM_SOURCE_DIR)/lua/views/search.lua" "$$NVIMA_MK/config/lua/views/search.lua"
	cp -R "$(NVIM_SOURCE_DIR)/vscode-theme" "$$NVIMA_MK/config/vscode-theme"
	NVIMA_CONFIG_HASH=$$(cd "$$NVIMA_MK/config" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
	NVIMA_PAYLOAD_ID=$$(printf '%s\n' '$(NVIM_VERSION)-$(ARCH)' "$$NVIM_HASH" "$$NVIMA_CONFIG_HASH" | sha256sum | cut -c1-16)
	NVIMA_STUB="$$WORK/nvima-stub"
	cp "$(NVIMA_SOURCE_DIR)/launcher.sh" "$$NVIMA_STUB"
	sed -i "s/@PAYLOAD_ID@/$$NVIMA_PAYLOAD_ID/" "$$NVIMA_STUB"
	NVIMA_ARCHIVE_LINE=$$(( $$(wc -l <"$$NVIMA_STUB") + 1 ))
	sed -i "s/@ARCHIVE_LINE@/$$NVIMA_ARCHIVE_LINE/" "$$NVIMA_STUB"
	tar -czf "$$WORK/nvima-payload.tar.gz" -C "$$WORK" nvima-payload
	cat "$$NVIMA_STUB" "$$WORK/nvima-payload.tar.gz" >"$(NVIMA_OUTPUT)"
	chmod 755 "$(NVIMA_OUTPUT)"
	echo "Built $(NVIMA_OUTPUT) ($$(du -h "$(NVIMA_OUTPUT)" | cut -f1))"

	sed 's/@INSTALL_NAME@/$(INSTALL_NAME)/g' "$(NVIM_SOURCE_DIR)/lazydiff.sh" >"$(LAZYDIFF_OUTPUT)"
	chmod 755 "$(LAZYDIFF_OUTPUT)"
	echo "Built $(LAZYDIFF_OUTPUT)"
	sed 's/@INSTALL_NAME@/$(INSTALL_NAME)/g' "$(NVIM_SOURCE_DIR)/lazyrepo.sh" >"$(LAZYREPO_OUTPUT)"
	chmod 755 "$(LAZYREPO_OUTPUT)"
	echo "Built $(LAZYREPO_OUTPUT)"
	sed 's/@INSTALL_NAME@/$(INSTALL_NAME)/g' "$(NVIM_SOURCE_DIR)/lazydata.sh" >"$(LAZYDATA_OUTPUT)"
	chmod 755 "$(LAZYDATA_OUTPUT)"
	case "$(ARCH)" in x86_64) GOARCH_VALUE=amd64 ;; arm64) GOARCH_VALUE=arm64 ;; esac
	CGO_ENABLED=0 GOOS=linux GOARCH="$$GOARCH_VALUE" go build -C lazydata -trimpath -ldflags='-s -w' -o "$(CURDIR)/$(LAZYDATA_SQL_OUTPUT)" .
	chmod 755 "$(LAZYDATA_SQL_OUTPUT)"
	echo "Built $(LAZYDATA_OUTPUT) and $(LAZYDATA_SQL_OUTPUT)"

install: build
	install -d "$(BINDIR)"
	rm -f "$(BINDIR)/lazydata-backend" "$(BINDIR)/nvima" "$(BINDIR)/lazydiff" "$(BINDIR)/lazyrepo" "$(BINDIR)/lazydata" "$(BINDIR)/lazydata-sql"
	install -m 755 "$(NVIM_OUTPUT)" "$(BINDIR)/$(INSTALL_NAME)"
	install -m 755 "$(NVIMA_OUTPUT)" "$(BINDIR)/$(NVIMA_NAME)"
	install -m 755 "$(LAZYDIFF_OUTPUT)" "$(BINDIR)/$(LAZYDIFF_NAME)"
	install -m 755 "$(LAZYREPO_OUTPUT)" "$(BINDIR)/$(LAZYREPO_NAME)"
	install -m 755 "$(LAZYDATA_OUTPUT)" "$(BINDIR)/$(LAZYDATA_NAME)"
	install -m 755 "$(LAZYDATA_SQL_OUTPUT)" "$(BINDIR)/$(LAZYDATA_SQL_NAME)"
	ln -sf "$(LAZYDATA_NAME)" "$(BINDIR)/$(LAZYDATA_ALIAS_NAME)"
	echo "Installed $(BINDIR)/$(INSTALL_NAME)"
	echo "Installed $(BINDIR)/$(NVIMA_NAME)"
	echo "Installed $(BINDIR)/$(LAZYDIFF_NAME)"
	echo "Installed $(BINDIR)/$(LAZYREPO_NAME)"
	echo "Installed $(BINDIR)/$(LAZYDATA_NAME)"
	echo "Installed $(BINDIR)/$(LAZYDATA_SQL_NAME)"
	echo "Installed $(BINDIR)/$(LAZYDATA_ALIAS_NAME) -> $(LAZYDATA_NAME)"
	rm -rf "$(NVIM_PORTABLE_CACHE_DIR)"
	echo 'Cleared portable runtime caches'
	$(MAKE) clean

release-assets:
	set -eu
	WORK=$$(mktemp -d)
	trap 'rm -rf "$$WORK"' EXIT HUP INT TERM
	for ARCH_VALUE in x86_64 arm64; do
	  $(MAKE) build ARCH="$$ARCH_VALUE"
	  tar -czf "$$WORK/nvim-linux-$$ARCH_VALUE.tar.gz" -C "$(DIST_DIR)" "$(NVIM_NAME)" "$(NVIMA_NAME)" "$(LAZYDIFF_NAME)" "$(LAZYREPO_NAME)" "$(LAZYDATA_NAME)" "$(LAZYDATA_SQL_NAME)"
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
	commands='nvim vime vimi vimg vimd vimd-sql'
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
	  "$$work/SHA256SUMS" >"$$work/$$asset.sha256" || fail "checksum not found for $$asset"
	(cd "$$work" && sha256sum -c "$$asset.sha256") || fail 'checksum verification failed'
	mkdir -p "$$work/unpacked" "$$BINDIR"
	tar -xzf "$$work/$$asset" -C "$$work/unpacked"
	for command_name in $$commands; do
	  [ -f "$$work/unpacked/$$command_name" ] || fail "release archive does not contain $$command_name"
	  chmod 755 "$$work/unpacked/$$command_name"
	done
	stage="$$BINDIR/.nvim-install.$$$$"
	mkdir "$$stage"
	trap 'rm -rf "$$work" "$$stage"' EXIT HUP INT TERM
	for command_name in $$commands; do cp "$$work/unpacked/$$command_name" "$$stage/$$command_name"; done
	for command_name in $$commands; do mv "$$stage/$$command_name" "$$BINDIR/$$command_name"; done
	rmdir "$$stage"
	ln -sf vimd "$$BINDIR/agent-db"
	rm -f "$$BINDIR/lazydata-backend" "$$BINDIR/nvima" "$$BINDIR/lazydiff" "$$BINDIR/lazyrepo" "$$BINDIR/lazydata" "$$BINDIR/lazydata-sql"
	cache_base=$${XDG_CACHE_HOME:-"$$HOME/.cache"}
	rm -rf "$$cache_base/nvim-portable"
	for command_name in $$commands; do echo "Installed $$BINDIR/$$command_name"; done
	echo "Installed $$BINDIR/agent-db -> vimd"
	case :$${PATH:-}: in
	  *:"$$BINDIR":*) ;;
	  *) echo "Add $$BINDIR to PATH to use these commands." ;;
	esac
	INSTALLER
	chmod 755 "$(RELEASE_DIR)/install.sh"
	cd "$(RELEASE_DIR)"
	sha256sum nvim-linux-x86_64.tar.gz nvim-linux-arm64.tar.gz >SHA256SUMS
	echo "Built release assets in $(RELEASE_DIR)/"

# Libro ships these archives inside its own release builds.
libro-tools: release-assets
	set -eu
	[ -d "$(LIBRO_DIR)" ] || { echo "Libro project not found at $(LIBRO_DIR); set LIBRO_DIR" >&2; exit 1; }
	mkdir -p "$(LIBRO_DIR)/tools"
	cp "$(RELEASE_DIR)/nvim-linux-x86_64.tar.gz" "$(RELEASE_DIR)/nvim-linux-arm64.tar.gz" "$(RELEASE_DIR)/SHA256SUMS" "$(LIBRO_DIR)/tools/"
	echo "Copied CLI tools to $(LIBRO_DIR)/tools/"

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
	  NUMBERS=$${LATEST#v}; OLD_IFS=$$IFS; IFS=.; set -- $$NUMBERS; IFS=$$OLD_IFS
	  VERSION="v$$1.$$2.$$(( $$3 + 1 ))"
	fi
	gh release view "$$VERSION" >/dev/null 2>&1 && { echo "release already exists: $$VERSION" >&2; exit 1; } || true
	echo "Publishing $$VERSION from $$LOCAL_HEAD..."
	$(MAKE) libro-tools
	gh release create "$$VERSION" "$(RELEASE_DIR)/nvim-linux-x86_64.tar.gz" "$(RELEASE_DIR)/nvim-linux-arm64.tar.gz" "$(RELEASE_DIR)/SHA256SUMS" "$(RELEASE_DIR)/install.sh" --target "$$LOCAL_HEAD" --title "$$VERSION" --generate-notes --fail-on-no-commits --latest
	gh api --paginate 'repos/{owner}/{repo}/releases?per_page=100' --jq '.[].tag_name' | while IFS= read -r OLD_VERSION; do
	  [ -n "$$OLD_VERSION" ] || continue
	  [ "$$OLD_VERSION" = "$$VERSION" ] || gh release delete "$$OLD_VERSION" --yes
	done
	gh release view "$$VERSION" --json url --jq .url

clean:
	rm -rf "$(DIST_DIR)"
