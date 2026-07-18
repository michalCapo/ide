SHELL := /bin/sh
.ONESHELL:

ARCH ?= x86_64
NVIM_VERSION ?= v0.12.4
LAZYGIT_VERSION ?= 0.63.0
VIFM_VERSION ?= 0.14.4

DIST_DIR := dist
DOWNLOAD_DIR := .cache
RELEASE_DIR := $(DIST_DIR)/release

NVIM_NAME := nvim
LAZYDIFF_NAME := lazydiff
LAZYGIT_NAME := lazygit
VIFM_NAME := vifm
NVIM_OUTPUT := $(DIST_DIR)/$(NVIM_NAME)
LAZYDIFF_OUTPUT := $(DIST_DIR)/$(LAZYDIFF_NAME)
LAZYGIT_OUTPUT := $(DIST_DIR)/$(LAZYGIT_NAME)
VIFM_OUTPUT := $(DIST_DIR)/$(VIFM_NAME)

NVIM_SOURCE_DIR := nvim
LAZYGIT_SOURCE_DIR := lazygit
VIFM_SOURCE_DIR := vifm

NVIM_ARCHIVE := $(DOWNLOAD_DIR)/nvim-linux-$(ARCH)-$(NVIM_VERSION).tar.gz
NVIM_URL := https://github.com/neovim/neovim/releases/download/$(NVIM_VERSION)/nvim-linux-$(ARCH).tar.gz
LAZYGIT_ARCHIVE := $(DOWNLOAD_DIR)/lazygit-linux-$(ARCH)-v$(LAZYGIT_VERSION).tar.gz
LAZYGIT_URL := https://github.com/jesseduffield/lazygit/releases/download/v$(LAZYGIT_VERSION)/lazygit_$(LAZYGIT_VERSION)_linux_$(ARCH).tar.gz
VIFM_APPIMAGE := $(DOWNLOAD_DIR)/vifm-linux-x86_64-v$(VIFM_VERSION).AppImage
VIFM_URL := https://github.com/vifm/vifm/releases/download/v$(VIFM_VERSION)/vifm-v$(VIFM_VERSION)-x86_64.AppImage

NVIM_SHA256_x86_64 := 012bf3fcac5ade43914df3f174668bf64d05e049a4f032a388c027b1ebd78628
NVIM_SHA256_arm64 := ceb7e88c6b681f0515d135dcdfad54f5eb4373b25ce6172197cd9a69c758063f
LAZYGIT_SHA256_x86_64 := cf5cfa3e116d7775f3600a51ec1d9ce7ba554a08b9566c7c2da83cb0023efabf
LAZYGIT_SHA256_arm64 := aac147abf5ce43afe6ae8bcb14b0d479111975a189302d7a99386deca70d57f7
VIFM_SHA256_x86_64 := c8568514e0bf276c2031a381ed7a2c48312deb29c528575060c7cd1da40d99c5

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
INSTALL_NAME ?= nvim
NVIM_PORTABLE_CACHE_DIR ?= $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)/nvim-portable
LAZYGIT_PORTABLE_CACHE_DIR ?= $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)/lazygit-portable
VIFM_PORTABLE_CACHE_DIR ?= $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)/vifm-portable

.PHONY: all help build update install release-assets publish clean

all: help

help:
	@printf '%s\n' \
	  'Available commands:' \
	  '  make build    Build portable nvim, lazydiff, and lazygit; also vifm on x86_64' \
	  '  make update   Refresh cached downloads for the selected architecture' \
	  '  make install  Build and install commands under ~/.local/bin' \
	  '  make publish  Build and publish the next GitHub release' \
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

$(LAZYGIT_ARCHIVE):
	set -eu
	case "$(ARCH)" in
	  x86_64) EXPECTED='$(LAZYGIT_SHA256_x86_64)' ;;
	  arm64) EXPECTED='$(LAZYGIT_SHA256_arm64)' ;;
	  *) echo "Unsupported architecture: $(ARCH)" >&2; exit 2 ;;
	esac
	mkdir -p "$(DOWNLOAD_DIR)"
	TMP="$@.tmp.$$$$"
	trap 'rm -f "$$TMP"' EXIT HUP INT TERM
	echo "Downloading Lazygit v$(LAZYGIT_VERSION) for Linux $(ARCH)..."
	curl -fL --retry 3 -o "$$TMP" "$(LAZYGIT_URL)"
	printf '%s  %s\n' "$$EXPECTED" "$$TMP" | sha256sum -c -
	mv "$$TMP" "$@"
	trap - EXIT HUP INT TERM

$(VIFM_APPIMAGE):
	set -eu
	mkdir -p "$(DOWNLOAD_DIR)"
	TMP="$@.tmp.$$$$"
	trap 'rm -f "$$TMP"' EXIT HUP INT TERM
	echo "Downloading Vifm v$(VIFM_VERSION) for Linux x86_64..."
	curl -fL --retry 3 -o "$$TMP" "$(VIFM_URL)"
	printf '%s  %s\n' '$(VIFM_SHA256_x86_64)' "$$TMP" | sha256sum -c -
	chmod 755 "$$TMP"
	mv "$$TMP" "$@"
	trap - EXIT HUP INT TERM

update:
	set -eu
	case "$(ARCH)" in x86_64|arm64) ;; *) echo "Unsupported architecture: $(ARCH)" >&2; exit 2 ;; esac
	rm -f "$(NVIM_ARCHIVE)" "$(LAZYGIT_ARCHIVE)"
	$(MAKE) "$(NVIM_ARCHIVE)" "$(LAZYGIT_ARCHIVE)" ARCH="$(ARCH)"
	if [ "$(ARCH)" = x86_64 ]; then
	  rm -f "$(VIFM_APPIMAGE)"
	  $(MAKE) "$(VIFM_APPIMAGE)"
	fi

build: $(NVIM_ARCHIVE) $(LAZYGIT_ARCHIVE)
	set -eu
	case "$(ARCH)" in x86_64|arm64) ;; *) echo "Unsupported architecture: $(ARCH)" >&2; exit 2 ;; esac
	test -f "$(NVIM_SOURCE_DIR)/init.lua" || { echo 'Neovim init.lua is missing' >&2; exit 1; }
	test -d "$(NVIM_SOURCE_DIR)/lua" || { echo 'Neovim lua directory is missing' >&2; exit 1; }
	test -d "$(NVIM_SOURCE_DIR)/vscode-theme" || { echo 'Bundled theme is missing' >&2; exit 1; }
	test -d "$(NVIM_SOURCE_DIR)/nvim-dap" || { echo 'Bundled nvim-dap is missing' >&2; exit 1; }
	test -f "$(LAZYGIT_SOURCE_DIR)/config.yml" || { echo 'Lazygit config is missing' >&2; exit 1; }
	test -x "$(LAZYGIT_SOURCE_DIR)/nvim-edit-parent" || { echo 'Lazygit edit helper is missing or not executable' >&2; exit 1; }
	WORK=$$(mktemp -d)
	trap 'rm -rf "$$WORK"' EXIT HUP INT TERM
	mkdir -p "$$WORK/nvim-payload/config" "$(DIST_DIR)"
	tar -xzf "$(NVIM_ARCHIVE)" -C "$$WORK"
	mv "$$WORK/nvim-linux-$(ARCH)" "$$WORK/nvim-payload/nvim"
	cp "$(NVIM_SOURCE_DIR)/init.lua" "$$WORK/nvim-payload/config/init.lua"
	cp -R "$(NVIM_SOURCE_DIR)/lua" "$$WORK/nvim-payload/config/lua"
	cp -R "$(NVIM_SOURCE_DIR)/vscode-theme" "$$WORK/nvim-payload/config/vscode-theme"
	cp -R "$(NVIM_SOURCE_DIR)/nvim-dap" "$$WORK/nvim-payload/config/nvim-dap"
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

	mkdir -p "$$WORK/lazygit-payload/config" "$$WORK/lazygit-unpacked"
	tar -xzf "$(LAZYGIT_ARCHIVE)" -C "$$WORK/lazygit-unpacked"
	test -x "$$WORK/lazygit-unpacked/lazygit" || { echo 'Lazygit archive does not contain lazygit' >&2; exit 1; }
	mv "$$WORK/lazygit-unpacked/lazygit" "$$WORK/lazygit-payload/lazygit"
	cp "$(LAZYGIT_SOURCE_DIR)/config.yml" "$(LAZYGIT_SOURCE_DIR)/light-theme.yml" "$(LAZYGIT_SOURCE_DIR)/state.yml" "$(LAZYGIT_SOURCE_DIR)/nvim-edit-parent" "$$WORK/lazygit-payload/config/"
	chmod 755 "$$WORK/lazygit-payload/config/nvim-edit-parent"
	LAZYGIT_CONFIG_HASH=$$(cd "$$WORK/lazygit-payload/config" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
	LAZYGIT_HASH=$$(sha256sum "$(LAZYGIT_ARCHIVE)" | cut -d' ' -f1)
	LAZYGIT_PAYLOAD_ID=$$(printf '%s\n' '$(LAZYGIT_VERSION)-$(ARCH)' "$$LAZYGIT_HASH" "$$LAZYGIT_CONFIG_HASH" | sha256sum | cut -c1-16)
	LAZYGIT_STUB="$$WORK/lazygit-stub"
	cp "$(LAZYGIT_SOURCE_DIR)/launcher.sh" "$$LAZYGIT_STUB"
	sed -i "s/@PAYLOAD_ID@/$$LAZYGIT_PAYLOAD_ID/" "$$LAZYGIT_STUB"
	LAZYGIT_ARCHIVE_LINE=$$(( $$(wc -l <"$$LAZYGIT_STUB") + 1 ))
	sed -i "s/@ARCHIVE_LINE@/$$LAZYGIT_ARCHIVE_LINE/" "$$LAZYGIT_STUB"
	tar -czf "$$WORK/lazygit-payload.tar.gz" -C "$$WORK" lazygit-payload
	cat "$$LAZYGIT_STUB" "$$WORK/lazygit-payload.tar.gz" >"$(LAZYGIT_OUTPUT)"
	chmod 755 "$(LAZYGIT_OUTPUT)"
	echo "Built $(LAZYGIT_OUTPUT) ($$(du -h "$(LAZYGIT_OUTPUT)" | cut -f1))"

	sed 's/@INSTALL_NAME@/$(INSTALL_NAME)/g' "$(NVIM_SOURCE_DIR)/lazydiff.sh" >"$(LAZYDIFF_OUTPUT)"
	chmod 755 "$(LAZYDIFF_OUTPUT)"
	echo "Built $(LAZYDIFF_OUTPUT)"

	if [ "$(ARCH)" = x86_64 ]; then
	  $(MAKE) "$(VIFM_APPIMAGE)"
	  test -f "$(VIFM_SOURCE_DIR)/vifmrc" || { echo 'Vifm config is missing' >&2; exit 1; }
	  VIFM_IMAGE=$$(cd "$(DOWNLOAD_DIR)" && pwd)/$$(basename "$(VIFM_APPIMAGE)")
	  mkdir -p "$$WORK/vifm-extract" "$$WORK/vifm-payload/config"
	  (cd "$$WORK/vifm-extract" && "$$VIFM_IMAGE" --appimage-extract >/dev/null 2>&1)
	  mv "$$WORK/vifm-extract/squashfs-root" "$$WORK/vifm-payload/app"
	  cp "$(VIFM_SOURCE_DIR)/vifmrc" "$$WORK/vifm-payload/config/vifmrc"
	  cp -R "$(VIFM_SOURCE_DIR)/colors" "$$WORK/vifm-payload/config/colors"
	  cp -R "$(VIFM_SOURCE_DIR)/scripts" "$$WORK/vifm-payload/config/scripts"
	  VIFM_CONFIG_HASH=$$(cd "$$WORK/vifm-payload/config" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
	  VIFM_HASH=$$(sha256sum "$(VIFM_APPIMAGE)" | cut -d' ' -f1)
	  VIFM_PAYLOAD_ID=$$(printf '%s\n' '$(VIFM_VERSION)-x86_64' "$$VIFM_HASH" "$$VIFM_CONFIG_HASH" | sha256sum | cut -c1-16)
	  VIFM_STUB="$$WORK/vifm-stub"
	  cp "$(VIFM_SOURCE_DIR)/launcher.sh" "$$VIFM_STUB"
	  sed -i "s/@PAYLOAD_ID@/$$VIFM_PAYLOAD_ID/" "$$VIFM_STUB"
	  VIFM_ARCHIVE_LINE=$$(( $$(wc -l <"$$VIFM_STUB") + 1 ))
	  sed -i "s/@ARCHIVE_LINE@/$$VIFM_ARCHIVE_LINE/" "$$VIFM_STUB"
	  tar -czf "$$WORK/vifm-payload.tar.gz" -C "$$WORK" vifm-payload
	  cat "$$VIFM_STUB" "$$WORK/vifm-payload.tar.gz" >"$(VIFM_OUTPUT)"
	  chmod 755 "$(VIFM_OUTPUT)"
	  echo "Built $(VIFM_OUTPUT) ($$(du -h "$(VIFM_OUTPUT)" | cut -f1))"
	else
	  rm -f "$(VIFM_OUTPUT)"
	  echo 'Skipped Vifm (not available for arm64)'
	fi

install: build
	install -d "$(BINDIR)"
	install -m 755 "$(NVIM_OUTPUT)" "$(BINDIR)/$(INSTALL_NAME)"
	install -m 755 "$(LAZYDIFF_OUTPUT)" "$(BINDIR)/$(LAZYDIFF_NAME)"
	install -m 755 "$(LAZYGIT_OUTPUT)" "$(BINDIR)/$(LAZYGIT_NAME)"
	if [ "$(ARCH)" = x86_64 ]; then install -m 755 "$(VIFM_OUTPUT)" "$(BINDIR)/$(VIFM_NAME)"; fi
	echo "Installed $(BINDIR)/$(INSTALL_NAME)"
	echo "Installed $(BINDIR)/$(LAZYDIFF_NAME)"
	echo "Installed $(BINDIR)/$(LAZYGIT_NAME)"
	if [ "$(ARCH)" = x86_64 ]; then echo "Installed $(BINDIR)/$(VIFM_NAME)"; fi
	rm -rf "$(NVIM_PORTABLE_CACHE_DIR)" "$(LAZYGIT_PORTABLE_CACHE_DIR)" "$(VIFM_PORTABLE_CACHE_DIR)"
	echo 'Cleared portable runtime caches'
	$(MAKE) clean

release-assets:
	set -eu
	WORK=$$(mktemp -d)
	trap 'rm -rf "$$WORK"' EXIT HUP INT TERM
	for ARCH_VALUE in x86_64 arm64; do
	  $(MAKE) build ARCH="$$ARCH_VALUE"
	  if [ "$$ARCH_VALUE" = x86_64 ]; then
	    tar -czf "$$WORK/nvim-linux-$$ARCH_VALUE.tar.gz" -C "$(DIST_DIR)" "$(NVIM_NAME)" "$(LAZYDIFF_NAME)" "$(LAZYGIT_NAME)" "$(VIFM_NAME)"
	  else
	    tar -czf "$$WORK/nvim-linux-$$ARCH_VALUE.tar.gz" -C "$(DIST_DIR)" "$(NVIM_NAME)" "$(LAZYDIFF_NAME)" "$(LAZYGIT_NAME)"
	  fi
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
	  x86_64|amd64) arch=x86_64; commands='nvim lazydiff lazygit vifm' ;;
	  aarch64|arm64) arch=arm64; commands='nvim lazydiff lazygit' ;;
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
	cache_base=$${XDG_CACHE_HOME:-"$$HOME/.cache"}
	rm -rf "$$cache_base/nvim-portable" "$$cache_base/lazygit-portable" "$$cache_base/vifm-portable"
	for command_name in $$commands; do echo "Installed $$BINDIR/$$command_name"; done
	case :$${PATH:-}: in
	  *:"$$BINDIR":*) ;;
	  *) echo "Add $$BINDIR to PATH to use these commands." ;;
	esac
	INSTALLER
	chmod 755 "$(RELEASE_DIR)/install.sh"
	cd "$(RELEASE_DIR)"
	sha256sum nvim-linux-x86_64.tar.gz nvim-linux-arm64.tar.gz >SHA256SUMS
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
	  NUMBERS=$${LATEST#v}; OLD_IFS=$$IFS; IFS=.; set -- $$NUMBERS; IFS=$$OLD_IFS
	  VERSION="v$$1.$$2.$$(( $$3 + 1 ))"
	fi
	gh release view "$$VERSION" >/dev/null 2>&1 && { echo "release already exists: $$VERSION" >&2; exit 1; } || true
	echo "Publishing $$VERSION from $$LOCAL_HEAD..."
	$(MAKE) release-assets
	gh release create "$$VERSION" "$(RELEASE_DIR)/nvim-linux-x86_64.tar.gz" "$(RELEASE_DIR)/nvim-linux-arm64.tar.gz" "$(RELEASE_DIR)/SHA256SUMS" "$(RELEASE_DIR)/install.sh" --target "$$LOCAL_HEAD" --title "$$VERSION" --generate-notes --fail-on-no-commits --latest
	gh api --paginate 'repos/{owner}/{repo}/releases?per_page=100' --jq '.[].tag_name' | while IFS= read -r OLD_VERSION; do
	  [ -n "$$OLD_VERSION" ] || continue
	  [ "$$OLD_VERSION" = "$$VERSION" ] || gh release delete "$$OLD_VERSION" --yes
	done
	gh release view "$$VERSION" --json url --jq .url

clean:
	rm -rf "$(DIST_DIR)"
