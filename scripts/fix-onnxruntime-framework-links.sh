#!/bin/bash
# fix-onnxruntime-framework-links.sh — Restore the symlinks in the resolved
# ONNX Runtime macOS framework so `swift test` can sign its test bundle.
# Usage: ./scripts/fix-onnxruntime-framework-links.sh   (after `swift package resolve`)
#
# onnxruntime-libs 1.28.2, which sherpa-onnx 1.13.8 pins exactly, zips its
# macOS xcframework with every framework symlink replaced by a copy
# (csukuangfj/onnxruntime-libs#62). Under the SwiftBuild backend (Swift 6.4,
# Xcode 27) the framework is embedded in VocaMacTests.xctest, and codesign
# rejects a versioned framework whose top level is not symlinks, so the test
# bundle fails to sign. `swift build`, the native build system and the
# xcodebuild app build are unaffected.
#
# Safe to run repeatedly: a framework that already has its links is skipped.
# Delete this script once the pinned onnxruntime-libs ships intact archives.

set -euo pipefail
shopt -s nullglob

cd "$(dirname "$0")/.."

for framework in .build/artifacts/onnxruntime-libs/*/onnxruntime.xcframework/macos-*/onnxruntime.framework; do
    [ -d "$framework/Versions/A" ] || continue
    [ -L "$framework/Versions/Current" ] && continue

    for entry in "$framework"/*; do
        name="$(basename "$entry")"
        if [ "$name" = "Versions" ] || [ -L "$entry" ]; then
            continue
        fi
        # Anything only present at the top level belongs inside the version.
        if [ -e "$framework/Versions/A/$name" ]; then
            rm -rf "$entry"
        else
            mv "$entry" "$framework/Versions/A/$name"
        fi
        ln -s "Versions/Current/$name" "$framework/$name"
    done

    rm -rf "$framework/Versions/Current"
    ln -s A "$framework/Versions/Current"
    echo "Restored framework symlinks in $framework"
done
