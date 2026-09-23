#!/usr/bin/env bash
# Measure a speech model's peak memory while it loads and transcribes a file.
#
# Runs the headless CLI of the installed app and records:
#   - the process's maximum resident set size and peak memory footprint
#     (from /usr/bin/time -l), and
#   - how far the Neural Engine's system processes (ANECompilerService and
#     aned) grow during the run, as memory footprint sampled with top about
#     twice a second. CoreML compiles for the Neural Engine out of process,
#     so the app's own footprint misses that part of a first load.
#   - the rise in wired memory, where the kernel keeps a loaded model's
#     weights for the Neural Engine. The app's footprint misses those too.
#
# A cold run's peak is at least peak_footprint_mb + ane_rise_mb; a warm run's
# is peak_footprint_mb + wired_rise_mb. The other vm_stat counters are no use:
# macOS keeps moving pages between the free, inactive, active and compressed
# queues, so they drift by hundreds of MB either way while a model loads.
#
# By default the run starts without the CoreML compile cache, so it includes
# the one-time first-load compile. That is the number the pre-load memory
# gate has to allow for. The app shares that cache, so it is moved aside and
# put back when the run ends; otherwise the app would recompile every model
# on its next load (Voca Hinglish: about 5 minutes on an M1 Pro). Pass --warm
# to use the cache as it is.
#
# The model must already be downloaded; the CLI never downloads.
#
# Usage:
#   scripts/measure-model-ram.sh <model-id> <audio.wav> [--warm]
#
# Prints one CSV row:
#   model,run,wall_s,max_rss_mb,peak_footprint_mb,ane_rise_mb,wired_rise_mb,transcript_chars
#
# Set VOCAMAC to use a binary other than /Applications/VocaMac.app.

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <model-id> <audio.wav> [--warm]" >&2
    exit 1
fi

MODEL="$1"
AUDIO="$2"
RUN="cold"
[[ "${3:-}" == "--warm" ]] && RUN="warm"

VOCAMAC="${VOCAMAC:-/Applications/VocaMac.app/Contents/MacOS/VocaMac}"
COMPILE_CACHE="$HOME/Library/Caches/com.vocamac.app/com.apple.e5rt.e5bundlecache"
WORK_DIR="$(mktemp -d "$HOME/Library/Caches/vocamac-measure.XXXXXX")"
CACHE_BACKUP="$WORK_DIR/e5bundlecache"

cleanup() {
    kill "${SAMPLER_PID:-}" 2>/dev/null || true
    if [[ -d "$CACHE_BACKUP" ]]; then
        rm -rf "$COMPILE_CACHE"
        mv "$CACHE_BACKUP" "$COMPILE_CACHE"
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Same volume as the cache, so moving it aside is a rename, not a copy.
if [[ "$RUN" == "cold" && -d "$COMPILE_CACHE" ]]; then
    mv "$COMPILE_CACHE" "$CACHE_BACKUP"
fi

# Combined footprint of the Neural Engine's system processes, in bytes.
ane_footprint() {
    local pids args=()
    pids="$(pgrep -x ANECompilerService; pgrep -x aned)" || true
    for pid in $pids; do args+=(-pid "$pid"); done
    if [[ ${#args[@]} -eq 0 ]]; then
        echo 0
        return
    fi
    top -l 1 "${args[@]}" -stats mem | awk '
        $1 ~ /^[0-9.]+[BKMG][+-]?$/ {
            value = $1; sub(/[+-]$/, "", value)
            unit = substr(value, length(value)); value = substr(value, 1, length(value) - 1)
            scale = (unit == "G") ? 1e9 : (unit == "M") ? 1e6 : (unit == "K") ? 1e3 : 1
            total += value * scale
        }
        END { printf "%.0f\n", total }'
}

wired_bytes() {
    vm_stat | awk -v page="$(pagesize)" '
        /^Pages wired down:/ { gsub("\\.", "", $NF); printf "%.0f\n", $NF * page }'
}

BASELINE="$(ane_footprint)"
WIRED_BASELINE="$(wired_bytes)"
echo "$BASELINE" > "$WORK_DIR/highest"
echo "$WIRED_BASELINE" > "$WORK_DIR/wired"
(
    highest="$BASELINE"
    wired_highest="$WIRED_BASELINE"
    while true; do
        bytes="$(ane_footprint)"
        if (( bytes > highest )); then
            highest="$bytes"
            echo "$highest" > "$WORK_DIR/highest"
        fi
        wired="$(wired_bytes)"
        if (( wired > wired_highest )); then
            wired_highest="$wired"
            echo "$wired_highest" > "$WORK_DIR/wired"
        fi
    done
) &
SAMPLER_PID=$!

STATUS=0
/usr/bin/time -l "$VOCAMAC" --transcribe-file "$AUDIO" --model "$MODEL" --json \
    > "$WORK_DIR/out.json" 2> "$WORK_DIR/time.txt" || STATUS=$?

kill "$SAMPLER_PID" 2>/dev/null || true
wait "$SAMPLER_PID" 2>/dev/null || true

if [[ $STATUS -ne 0 ]]; then
    echo "error: $MODEL exited with $STATUS" >&2
    cat "$WORK_DIR/out.json" >&2
    exit "$STATUS"
fi

WALL="$(awk '/ real / { print $1 }' "$WORK_DIR/time.txt")"
MAX_RSS="$(awk '/maximum resident set size/ { print $1 }' "$WORK_DIR/time.txt")"
FOOTPRINT="$(awk '/peak memory footprint/ { print $1 }' "$WORK_DIR/time.txt")"
HIGHEST="$(cat "$WORK_DIR/highest")"
WIRED_HIGHEST="$(cat "$WORK_DIR/wired")"
CHARS="$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["text"].strip()))' "$WORK_DIR/out.json")"

if [[ "$CHARS" -eq 0 ]]; then
    echo "error: $MODEL returned an empty transcript" >&2
    exit 1
fi

awk -v model="$MODEL" -v run="$RUN" -v wall="$WALL" -v rss="$MAX_RSS" \
    -v footprint="$FOOTPRINT" -v ane_rise="$((HIGHEST - BASELINE))" \
    -v wired_rise="$((WIRED_HIGHEST - WIRED_BASELINE))" -v chars="$CHARS" 'BEGIN {
        printf "%s,%s,%.1f,%.0f,%.0f,%.0f,%.0f,%d\n", model, run, wall,
            rss / 1e6, footprint / 1e6, ane_rise / 1e6, wired_rise / 1e6, chars
    }'
