#!/usr/bin/env bash
#
# Cloud Agent install script for VocaMac.
#
# VocaMac is primarily a native macOS menu bar app (Swift + SwiftUI) that depends
# on AppKit, CoreML and AVFoundation, so `swift build`/`swift test` only work on
# macOS. This Cloud Agent runs on Linux, so the reproducible end-to-end dev
# experience here is the marketing website in `web/`, a Hugo site.
#
# This script provisions the Hugo (extended) toolchain and verifies the site
# builds. It is idempotent: re-running it is a no-op once Hugo is installed.
set -euo pipefail

# Pinned to match the version the site is developed/deployed with. `latest` is
# used in CI, but pin here for deterministic Cloud Agent builds.
HUGO_VERSION="0.164.0"
INSTALL_DIR="/usr/local/bin"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[install] $*"; }

install_hugo() {
  local arch hugo_arch url tmp
  arch="$(uname -m)"
  case "$arch" in
    x86_64) hugo_arch="amd64" ;;
    aarch64 | arm64) hugo_arch="arm64" ;;
    *) echo "[install] Unsupported architecture: $arch" >&2; exit 1 ;;
  esac

  url="https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-${hugo_arch}.tar.gz"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  log "Downloading Hugo extended v${HUGO_VERSION} (${hugo_arch})"
  curl -fsSL "$url" -o "$tmp/hugo.tar.gz"
  tar -xzf "$tmp/hugo.tar.gz" -C "$tmp" hugo
  sudo install -m 0755 "$tmp/hugo" "${INSTALL_DIR}/hugo"
}

# Install Hugo only if the pinned extended version is not already present.
if command -v hugo >/dev/null 2>&1 \
  && hugo version | grep -q "v${HUGO_VERSION}" \
  && hugo version | grep -qi "extended"; then
  log "Hugo extended v${HUGO_VERSION} already installed — skipping"
else
  install_hugo
fi

hugo version

# Verify the website builds cleanly. Output (web/public, web/resources) is
# gitignored; this both validates the toolchain and warms Hugo's caches.
log "Building website (cd web && hugo --minify --gc)"
( cd "${ROOT}/web" && hugo --minify --gc )
log "Website build succeeded"
