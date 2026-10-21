#!/bin/bash
# build-appstore.sh — Build the Mac App Store variant of VocaMac, check it,
# archive it, and optionally upload it to App Store Connect.
# Usage: ./scripts/build-appstore.sh [--upload]
#
# This script:
# 1. Builds with scripts/build.sh in App Store mode (VOCAMAC_APP_STORE=1):
#    compiled with the APP_STORE condition, sandboxed with
#    VocaMac-AppStore.entitlements, ad-hoc signed, in dist/appstore/VocaMac.app
# 2. Checks the bundle: entitlements, Info.plist, architecture, and that the
#    code left out under APP_STORE really is gone
# 3. Wraps it in dist/appstore/VocaMac.xcarchive, the layout Xcode's archive
#    action produces, so xcodebuild can export it
# 4. With --upload: exports it for App Store Connect, which re-signs it with
#    cloud-managed Apple Distribution and Mac Installer Distribution
#    certificates, and uploads the package
#
# See docs/APP_STORE.md.
#
# Environment variables:
#   APP_VERSION                  — CFBundleShortVersionString, MAJOR.MINOR[.PATCH].
#                                  Defaults to the version in scripts/build.sh.
#   APP_BUILD_NUMBER             — CFBundleVersion. Must grow with every upload. Defaults to 1.
#   VOCAMAC_BUNDLED_MODEL_SOURCE — Passed through to build.sh (bundled Whisper Tiny).
#   APP_STORE_TEAM_ID            — Apple Developer Team ID (required for --upload).
#   APP_STORE_CONNECT_KEY_PATH   — App Store Connect API key, .p8 (required for --upload).
#   APP_STORE_CONNECT_API_KEY_ID — The key's ID (required for --upload).
#   APP_STORE_CONNECT_ISSUER_ID  — The key's issuer ID (required for --upload).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

UPLOAD=false
for arg in "$@"; do
    case "$arg" in
        --upload) UPLOAD=true ;;
        *) echo "Usage: $0 [--upload]" >&2; exit 2 ;;
    esac
done

APP_NAME="VocaMac"
BUNDLE_ID="com.vocamac.app"
OUT_DIR="dist/appstore"
# build.sh writes the App Store variant here.
APP_DIR="${OUT_DIR}/${APP_NAME}.app"
ARCHIVE_DIR="${OUT_DIR}/${APP_NAME}.xcarchive"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

fail() {
    echo "❌ $*" >&2
    exit 1
}

DEFAULT_APP_VERSION="$(grep '^APP_VERSION=' scripts/build.sh | sed 's/.*:-\(.*\)}.*/\1/' | head -1 || true)"
APP_VERSION="${APP_VERSION:-$DEFAULT_APP_VERSION}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-1}"

# App Store Connect takes plain numbers only: no pre-release or build suffix.
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    || fail "APP_VERSION must be MAJOR.MINOR[.PATCH] for the App Store, got '$APP_VERSION'"
[[ "$APP_BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
    || fail "APP_BUILD_NUMBER must be one to three dot-separated integers, got '$APP_BUILD_NUMBER'"

if [ "$UPLOAD" = true ]; then
    for name in APP_STORE_TEAM_ID APP_STORE_CONNECT_KEY_PATH APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_ISSUER_ID; do
        [ -n "${!name:-}" ] || fail "$name is required for --upload"
    done
    [ -f "$APP_STORE_CONNECT_KEY_PATH" ] || fail "No API key at $APP_STORE_CONNECT_KEY_PATH"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VocaMac ${APP_VERSION} (${APP_BUILD_NUMBER}) — Mac App Store build"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Step 1: Build ────────────────────────────────────────────────────────────
echo "▶ Step 1/4: Building the App Store variant..."
rm -rf "$OUT_DIR"
VOCAMAC_APP_STORE=1 APP_VERSION="$APP_VERSION" APP_BUILD_NUMBER="$APP_BUILD_NUMBER" \
    "$SCRIPT_DIR/build.sh" release
[ -d "$APP_DIR" ] || fail "build.sh did not produce $APP_DIR"
echo ""

# ── Step 2: Check ────────────────────────────────────────────────────────────
echo "▶ Step 2/4: Checking the bundle..."
BINARY="${APP_DIR}/Contents/MacOS/${APP_NAME}"
INFO_PLIST="${APP_DIR}/Contents/Info.plist"

plist_value() {
    "$PLIST_BUDDY" -c "Print :$1" "$INFO_PLIST" 2>/dev/null
}

[ "$(plist_value CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "CFBundleIdentifier is not $BUNDLE_ID"
[ "$(plist_value CFBundleShortVersionString)" = "$APP_VERSION" ] || fail "CFBundleShortVersionString is not $APP_VERSION"
[ "$(plist_value CFBundleVersion)" = "$APP_BUILD_NUMBER" ] || fail "CFBundleVersion is not $APP_BUILD_NUMBER"
[ "$(plist_value LSMinimumSystemVersion)" = "14.0" ] || fail "LSMinimumSystemVersion is not 14.0"
[ "$(plist_value LSApplicationCategoryType)" = "public.app-category.productivity" ] || fail "LSApplicationCategoryType is missing"
[ "$(plist_value ITSAppUsesNonExemptEncryption)" = "false" ] || fail "ITSAppUsesNonExemptEncryption is not false"
for key in NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription DTSDKName DTXcodeBuild; do
    [ -n "$(plist_value "$key")" ] || fail "Info.plist has no $key"
done
if plist_value NSAppleEventsUsageDescription >/dev/null; then
    fail "Info.plist still asks for Apple Events"
fi

[ "$(lipo -archs "$BINARY")" = "arm64" ] || fail "$BINARY is not arm64-only"

# App Review tries dictation without downloading a model, so an upload must
# carry Whisper Tiny the way the DMG does (VOCAMAC_BUNDLED_MODEL_SOURCE).
BUNDLED_TINY="${APP_DIR}/Contents/Resources/BundledModels/whisperkit-coreml/openai_whisper-tiny"
if [ -d "${BUNDLED_TINY}/MelSpectrogram.mlmodelc" ] && [ -d "${BUNDLED_TINY}/AudioEncoder.mlmodelc" ] \
    && [ -d "${BUNDLED_TINY}/TextDecoder.mlmodelc" ] && [ -f "${BUNDLED_TINY}/tokenizer.json" ] \
    && [ -f "${BUNDLED_TINY}/tokenizer_config.json" ]; then
    echo "   Whisper Tiny is bundled."
elif [ "$UPLOAD" = true ]; then
    fail "Whisper Tiny is not bundled. Set VOCAMAC_BUNDLED_MODEL_SOURCE as release.yml does."
else
    echo "   ⚠️  Whisper Tiny is not bundled (set VOCAMAC_BUNDLED_MODEL_SOURCE for a build to upload)"
fi

ENTITLEMENTS="$(codesign -d --entitlements - "$APP_DIR" 2>/dev/null)"
for entitlement in com.apple.security.app-sandbox com.apple.security.device.audio-input com.apple.security.network.client; do
    grep -q "$entitlement" <<< "$ENTITLEMENTS" || fail "The app is not signed with $entitlement"
done
if grep -q -e "apple-events" -e "temporary-exception" <<< "$ENTITLEMENTS"; then
    fail "The app is signed with an Apple Events or temporary-exception entitlement"
fi

# The APP_STORE condition took effect: no AppleScript, and none of the
# programs the direct download starts. (Short paths are stored inline in
# Swift code rather than as strings, so only the long ones can be checked.)
# grep reads all its input here: with -q it could quit early, and under
# pipefail the writer's SIGPIPE would read as "not found".
if nm -u "$BINARY" | grep "NSAppleScript" >/dev/null; then
    fail "The binary uses NSAppleScript; was it built without APP_STORE?"
fi
for tool in /usr/bin/hdiutil /usr/bin/tccutil; do
    if strings -a "$BINARY" | grep -xF "$tool" >/dev/null; then
        fail "The binary still refers to $tool; was it built without APP_STORE?"
    fi
done

# The export re-signs everything, so an ad-hoc signature that doesn't verify
# is reported rather than fatal.
codesign --verify --strict --verbose=2 "$APP_DIR" \
    || echo "   ⚠️  The ad-hoc signature does not verify strictly (see above)"
echo "   Bundle checks passed."
echo ""

# ── Step 3: Archive ──────────────────────────────────────────────────────────
echo "▶ Step 3/4: Creating ${ARCHIVE_DIR}..."
rm -rf "$ARCHIVE_DIR"
mkdir -p "${ARCHIVE_DIR}/Products/Applications"
ditto "$APP_DIR" "${ARCHIVE_DIR}/Products/Applications/${APP_NAME}.app"
cat > "${ARCHIVE_DIR}/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ApplicationProperties</key>
    <dict>
        <key>ApplicationPath</key>
        <string>Applications/${APP_NAME}.app</string>
        <key>Architectures</key>
        <array>
            <string>arm64</string>
        </array>
        <key>CFBundleIdentifier</key>
        <string>${BUNDLE_ID}</string>
        <key>CFBundleShortVersionString</key>
        <string>${APP_VERSION}</string>
        <key>CFBundleVersion</key>
        <string>${APP_BUILD_NUMBER}</string>
        <key>Team</key>
        <string>${APP_STORE_TEAM_ID:-}</string>
    </dict>
    <key>ArchiveVersion</key>
    <integer>2</integer>
    <key>CreationDate</key>
    <date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
    <key>Name</key>
    <string>${APP_NAME}</string>
    <key>SchemeName</key>
    <string>${APP_NAME}</string>
</dict>
</plist>
EOF
plutil -lint "${ARCHIVE_DIR}/Info.plist" >/dev/null
echo "   Archive ready."
echo ""

# ── Step 4: Upload ───────────────────────────────────────────────────────────
echo "▶ Step 4/4: Uploading..."
if [ "$UPLOAD" != true ]; then
    echo "   ⚠️  Skipped (pass --upload to send it to App Store Connect)"
else
    EXPORT_OPTIONS="${OUT_DIR}/ExportOptions.plist"
    cat > "$EXPORT_OPTIONS" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>${APP_STORE_TEAM_ID}</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>uploadSymbols</key>
    <false/>
</dict>
</plist>
EOF
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_DIR" \
        -exportPath "${OUT_DIR}/export" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$APP_STORE_CONNECT_KEY_PATH" \
        -authenticationKeyID "$APP_STORE_CONNECT_API_KEY_ID" \
        -authenticationKeyIssuerID "$APP_STORE_CONNECT_ISSUER_ID"
    echo "   Uploaded ${APP_VERSION} (${APP_BUILD_NUMBER}). App Store Connect processes it in a few minutes."
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ App Store build complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  App:     ${APP_DIR}"
echo "  Archive: ${ARCHIVE_DIR}"
