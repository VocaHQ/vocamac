#!/bin/bash
# check-app-warnings.sh — Fail if the app target's own sources produced any
# compiler warning.
#
# The VocaMac target builds with complete concurrency checking
# (StrictConcurrency in Package.swift), so a data race the compiler can see
# shows up as a warning. Dependencies' warnings are ignored.
#
# Usage: swift build 2>&1 | tee build.log; ./scripts/check-app-warnings.sh build.log

set -euo pipefail

LOG="${1:?usage: check-app-warnings.sh <build log>}"

# A missing or empty log would otherwise read as "no warnings".
if [ ! -r "$LOG" ] || [ ! -s "$LOG" ]; then
    echo "❌ Build log $LOG is missing, unreadable, or empty"
    exit 1
fi

CLEAN="$(sed -E 's/\x1b\[[0-9;]*m//g' "$LOG")"
# grep exits 1 when nothing matches, which is the good case.
WARNINGS="$(printf '%s\n' "$CLEAN" \
    | { grep -E '/Sources/(VocaMac|VocaMacObjC)/[^:]+:[0-9]+:[0-9]+: warning:' || [ $? -eq 1 ]; } \
    | sort -u)"

if [ -n "$WARNINGS" ]; then
    COUNT="$(printf '%s\n' "$WARNINGS" | wc -l | tr -d ' ')"
    echo "❌ $COUNT compiler warning(s) in app sources:"
    printf '%s\n' "$WARNINGS"
    exit 1
fi
echo "✅ No compiler warnings in app sources"
