#!/usr/bin/env bash
# Select Xcode 26 so Apple Speech (SpeechAnalyzer, Swift 6.2+) is compiled in.
# macos-15 runners default to Xcode 16.4, which leaves only the unsupported stub.
set -euo pipefail

XCODE=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1 || true)
if [ -z "${XCODE}" ]; then
  echo "Xcode 26 is required to build Apple Speech support" >&2
  ls /Applications/Xcode*.app 2>/dev/null || true
  exit 1
fi

sudo xcode-select -s "${XCODE}"
xcodebuild -version
