#!/usr/bin/env bash
# Runs the pinned SwiftLint in strict mode, so `make lint` and CI use the same
# binary. The release zip is downloaded once into .build/, checked against its
# SHA-256, and reused. Extra arguments go to `swiftlint lint`.
#
# To upgrade: change VERSION, copy the new portable_swiftlint.zip digest from
# the release page into SHA256, and fix any new findings in the same PR.
set -euo pipefail

VERSION="0.65.1"
SHA256="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$ROOT/.build/swiftlint-$VERSION"
BINARY="$INSTALL_DIR/swiftlint"

if [ ! -x "$BINARY" ]; then
    echo "Downloading SwiftLint $VERSION..." >&2
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT
    curl -fsSL -o "$TMP_DIR/swiftlint.zip" \
        "https://github.com/realm/SwiftLint/releases/download/$VERSION/portable_swiftlint.zip"
    echo "$SHA256  $TMP_DIR/swiftlint.zip" | shasum -a 256 -c - >/dev/null
    mkdir -p "$INSTALL_DIR"
    unzip -q -o "$TMP_DIR/swiftlint.zip" -d "$INSTALL_DIR"
fi

cd "$ROOT"
exec "$BINARY" lint --strict "$@"
