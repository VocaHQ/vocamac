#!/bin/bash
# smoke-test-app.sh — Launch a built VocaMac.app and fail if it crashes.
#
# Unit tests never start the real app, so crashes during launch (resource
# bundle lookup, AppState init, service init) have reached users before.
# This runs the bundle's own binary the way users do:
#
#   1. `--list-models` through the headless CLI, which must print the catalog
#      and exit 0 without starting the GUI.
#   2. The GUI, which must still be running after a settle period.
#
# Usage: ./scripts/smoke-test-app.sh [path/to/VocaMac.app] [seconds]
#
# Starting the GUI terminates any other running VocaMac, so run this on CI or
# when you don't mind your installed copy quitting.

set -euo pipefail

APP_PATH="${1:-VocaMac.app}"
SETTLE_SECONDS="${2:-20}"
BINARY="$APP_PATH/Contents/MacOS/VocaMac"
REPORTS_DIR="$HOME/Library/Logs/DiagnosticReports"
LOG_DIR="$HOME/Library/Application Support/VocaMac/logs"

if [ ! -x "$BINARY" ]; then
    echo "❌ No executable at $BINARY"
    exit 1
fi

# Crash reports written after this marker belong to this run.
MARKER="$(mktemp)"
GUI_PID=""

cleanup() {
    if [ -n "$GUI_PID" ] && kill -0 "$GUI_PID" 2>/dev/null; then
        kill "$GUI_PID" 2>/dev/null || true
        wait "$GUI_PID" 2>/dev/null || true
    fi
    rm -f "$MARKER"
}
trap cleanup EXIT

show_crash_reports() {
    local found=0
    if [ -d "$REPORTS_DIR" ]; then
        while IFS= read -r report; do
            found=1
            echo "::group::Crash report $(basename "$report")"
            head -c 20000 "$report"
            echo
            echo "::endgroup::"
        done < <(find "$REPORTS_DIR" -maxdepth 1 -name 'VocaMac*' -newer "$MARKER" 2>/dev/null)
    fi
    if [ "$found" -eq 0 ]; then
        echo "No crash report was written for this run."
    fi
    if [ -d "$LOG_DIR" ]; then
        local latest
        latest="$(find "$LOG_DIR" -maxdepth 1 -name '*.log' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1 || true)"
        if [ -n "$latest" ]; then
            echo "::group::Last app log lines ($latest)"
            tail -n 80 "$latest"
            echo "::endgroup::"
        fi
    fi
}

# ─── 1. Headless CLI ─────────────────────────────────────────────────────────

echo "▶ $BINARY --list-models"
set +e
CLI_OUTPUT="$("$BINARY" --list-models 2>&1)"
CLI_STATUS=$?
set -e
echo "$CLI_OUTPUT" | head -n 20
if [ "$CLI_STATUS" -ne 0 ]; then
    echo "❌ --list-models exited with status $CLI_STATUS"
    sleep 3  # give ReportCrash time to write the report
    show_crash_reports
    exit 1
fi
if [ -z "$CLI_OUTPUT" ]; then
    echo "❌ --list-models printed nothing"
    exit 1
fi
echo "✅ CLI ran"

# ─── 2. GUI launch ───────────────────────────────────────────────────────────

echo "▶ Launching the app for ${SETTLE_SECONDS}s"
"$BINARY" >/dev/null 2>&1 &
GUI_PID=$!

for ((second = 1; second <= SETTLE_SECONDS; second++)); do
    sleep 1
    if ! kill -0 "$GUI_PID" 2>/dev/null; then
        set +e
        wait "$GUI_PID"
        STATUS=$?
        set -e
        GUI_PID=""
        echo "❌ VocaMac quit ${second}s after launch (status $STATUS)"
        sleep 3
        show_crash_reports
        exit 1
    fi
done

echo "✅ App still running after ${SETTLE_SECONDS}s"
