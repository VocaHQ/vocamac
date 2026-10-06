#!/usr/bin/env bash
# Renders the 60-second VocaMac promo film from the screenshots in docs/screenshots.
#
# Every frame is drawn with Core Graphics (scripts/promo-film/) and piped into ffmpeg;
# the score is synthesized in Swift, so there are no samples or licensing to track.
# Scene cuts sit on the 96 BPM beat grid, so changing timings means changing whole bars.
#
# Usage: ./scripts/generate-promo-film.sh [OUTPUT.mp4]   (default: dist/vocamac-promo.mp4)
# Needs: macOS, Xcode command line tools, ffmpeg (brew install ffmpeg). Takes a few minutes.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="${1:-dist/vocamac-promo.mp4}"
BUILD="$(mktemp -d)"
trap 'rm -rf "${BUILD}"' EXIT

command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg" >&2; exit 1; }

mkdir -p "$(dirname "${OUT}")"
echo "==> Compiling the film renderer"
swiftc -O scripts/promo-film/Music.swift scripts/promo-film/Film.swift \
    scripts/promo-film/Scenes.swift scripts/promo-film/main.swift -o "${BUILD}/film"

echo "==> Rendering 3600 frames and the score"
"${BUILD}/film" \
    --shots docs/screenshots \
    --brand web/static/brand/voca-logo-512-dark.png \
    --out "${OUT}"
