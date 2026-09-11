#!/bin/bash
# build.sh — Build, bundle, and sign VocaMac
# Usage: ./scripts/build.sh [debug|release]
#
# This script:
# 1. Builds VocaMac with Swift Package Manager
# 2. Creates/updates the .app bundle
# 3. Code signs — Developer ID if CODE_SIGN_IDENTITY is set, ad-hoc otherwise
#
# Environment variables:
#   APP_VERSION         — Version string to embed in Info.plist. Defaults to 0.9.0.
#                         Set by CI for nightly builds (e.g., 0.9.0-nightly.20260512+abc1234).
#   VOCAMAC_KEEP_RUNNING — Set to 1 for isolated validation without stopping the installed app.
#   CODE_SIGN_IDENTITY  — Signing identity to use. Defaults to auto-detect
#                         Developer ID Application in the login keychain.
#                         Set to "-" to force ad-hoc signing.
#
# IMPORTANT: After the first build, grant Accessibility and Input Monitoring
# permissions to VocaMac.app. With Developer ID signing, permissions persist
# across rebuilds. With ad-hoc signing (no cert), permissions reset on every rebuild.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

CONFIG="${1:-release}"
BUNDLE_ID="com.vocamac.app"
APP_NAME="VocaMac"
APP_DIR="${APP_NAME}.app"
ENTITLEMENTS="VocaMac.entitlements"
APP_VERSION="${APP_VERSION:-0.9.0}"

# Resolve signing identity:
# 1. Use CODE_SIGN_IDENTITY env var if set
# 2. Auto-detect Developer ID Application in the login keychain (distribution)
# 3. Auto-detect Apple Development in the login keychain (local development)
# 4. Fall back to ad-hoc signing (-)
#
# An ad-hoc signature gets a fresh code identity on every build, so macOS
# treats each rebuild as a different app and drops its Accessibility and
# Input Monitoring grants. Any real certificate — including the free Apple
# Development one — keeps that identity stable across rebuilds, so prefer
# one over ad-hoc even when there is nothing to distribute.
SIGNING_MODE="ad-hoc"
if [ -z "${CODE_SIGN_IDENTITY+x}" ]; then
    IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
    DETECTED=$(echo "$IDENTITIES" | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
    if [ -n "$DETECTED" ]; then
        SIGNING_MODE="Developer ID"
    else
        DETECTED=$(echo "$IDENTITIES" | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
        if [ -n "$DETECTED" ]; then
            SIGNING_MODE="Apple Development"
        fi
    fi
    if [ -n "$DETECTED" ]; then
        CODE_SIGN_IDENTITY="$DETECTED"
        echo "🔐 Auto-detected signing identity: $CODE_SIGN_IDENTITY"
    else
        CODE_SIGN_IDENTITY="-"
        echo "⚠️  No signing certificate found — using ad-hoc signing"
    fi
elif [ "$CODE_SIGN_IDENTITY" != "-" ]; then
    SIGNING_MODE="explicit ($CODE_SIGN_IDENTITY)"
fi

if [ "$CODE_SIGN_IDENTITY" = "-" ]; then
    echo "🔏 Signing mode: ad-hoc (permissions reset on every rebuild)"
else
    echo "🔏 Signing mode: $SIGNING_MODE"
fi

# Kill any running VocaMac instances before building
if [ "${VOCAMAC_KEEP_RUNNING:-0}" != "1" ] && pgrep -f "VocaMac" > /dev/null 2>&1; then
    echo "🛑 Stopping running VocaMac..."
    pkill -f "VocaMac" 2>/dev/null
    sleep 1
fi

echo "🔨 Building VocaMac ($CONFIG)..."

# ── Build with xcodebuild ───────────────────────────────────────────────────
#
# We use xcodebuild instead of swift build because xcodebuild generates a
# Bundle.module accessor that checks Bundle.main.resourceURL (Contents/Resources/)
# in addition to Bundle.main.bundleURL (the .app root). This is critical for
# .app bundles where:
#   - Bundle.main.bundleURL resolves to the .app root (e.g. VocaMac.app/)
#   - codesign forbids placing bundles at the .app root
#   - Bundle.main.resourceURL resolves to Contents/Resources/ which IS allowed
#
# swift build generates a simpler accessor that only checks bundleURL + a
# hardcoded build-time path, which causes a fatalError crash on end-user machines.

DERIVED_DATA=".xcode-build"
XCODE_CONFIG="$(echo "${CONFIG}" | sed 's/release/Release/; s/debug/Debug/')"

# LLM.swift builds a Swift macro plugin (LLMMacros). Without the two skip
# flags, xcodebuild stops for interactive "trust this plugin?" approval, which
# never resolves in a script. Safe here because every package is version-pinned
# in Package.swift, so the code being trusted only changes on a deliberate bump.
xcodebuild build \
    -scheme VocaMac \
    -configuration "$XCODE_CONFIG" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'platform=macOS,arch=arm64' \
    -skipMacroValidation \
    -skipPackagePluginValidation \
    ONLY_ACTIVE_ARCH=YES \
    -quiet

# Find the built binary
BINARY="${DERIVED_DATA}/Build/Products/${XCODE_CONFIG}/${APP_NAME}"
if [ ! -f "$BINARY" ]; then
    echo "❌ Build failed — binary not found at $BINARY"
    exit 1
fi

# Check if this is a fresh bundle creation or an update
FIRST_TIME=false
if [ ! -d "${APP_DIR}" ]; then
    FIRST_TIME=true
fi

echo "📦 Updating app bundle..."

# Create bundle structure
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
mkdir -p "${APP_DIR}/Contents/Resources/BundledModels/whisperkit-coreml"

BUNDLED_MODEL_SOURCE="${VOCAMAC_BUNDLED_MODEL_SOURCE:-}"
if [ -n "$BUNDLED_MODEL_SOURCE" ]; then
  if [ -d "$BUNDLED_MODEL_SOURCE" ]; then
    echo "📦 Staging bundled model assets from: $BUNDLED_MODEL_SOURCE"
    rsync -a --delete --exclude='.git' "$BUNDLED_MODEL_SOURCE"/ "${APP_DIR}/Contents/Resources/BundledModels/whisperkit-coreml/"
  else
    echo "❌ VOCAMAC_BUNDLED_MODEL_SOURCE does not exist: $BUNDLED_MODEL_SOURCE"
    exit 1
  fi
fi

# Update binary
cp -f "$BINARY" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# App Intents metadata. xcodebuild doesn't run Xcode's metadata extraction for
# a Swift package executable, and without Contents/Resources/Metadata.appintents
# the Shortcuts app and Spotlight never see VocaMac's actions. Run the same
# extractor on the compiler's const-value output.
OBJECTS_DIR="${DERIVED_DATA}/Build/Intermediates.noindex/${APP_NAME}.build/${XCODE_CONFIG}/${APP_NAME}.build/Objects-normal/arm64"
mkdir -p "${APP_DIR}/Contents/Resources"
rm -rf "${APP_DIR}/Contents/Resources/Metadata.appintents"
if [ -f "${OBJECTS_DIR}/${APP_NAME}.SwiftFileList" ]; then
    CONST_VALUES_LIST="$(mktemp -t vocamac-constvalues)"
    find "$OBJECTS_DIR" -name '*.swiftconstvalues' > "$CONST_VALUES_LIST"
    if xcrun appintentsmetadataprocessor \
        --output "${APP_DIR}/Contents/Resources" \
        --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
        --module-name "${APP_NAME}" \
        --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
        --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
        --platform-family macOS \
        --deployment-target 14.0 \
        --target-triple arm64-apple-macos14.0 \
        --source-file-list "${OBJECTS_DIR}/${APP_NAME}.SwiftFileList" \
        --swift-const-vals-list "$CONST_VALUES_LIST" \
        --force --quiet-warnings > /dev/null 2>&1 \
        && [ -d "${APP_DIR}/Contents/Resources/Metadata.appintents" ]; then
        echo "🔗 App Intents metadata generated"
    else
        echo "⚠️  App Intents metadata could not be generated; Shortcuts actions will be missing." >&2
    fi
    rm -f "$CONST_VALUES_LIST"
else
    echo "⚠️  ${OBJECTS_DIR}/${APP_NAME}.SwiftFileList not found; skipping App Intents metadata." >&2
fi

# Embed llama.cpp (LLM.swift). The binary's rpath is @executable_path/../lib,
# so the framework has to land there or the app dies at launch with a dyld
# error. Missing it is a build failure, not something to ship quietly.
LLAMA_FRAMEWORK="${DERIVED_DATA}/Build/Products/${XCODE_CONFIG}/llama.framework"
if [ ! -d "$LLAMA_FRAMEWORK" ]; then
    echo "Error: llama.framework not found at ${LLAMA_FRAMEWORK}" >&2
    echo "LLM.swift's binary target did not build; the app would crash on launch." >&2
    exit 1
fi
mkdir -p "${APP_DIR}/Contents/lib"
rm -rf "${APP_DIR}/Contents/lib/llama.framework"
cp -a "$LLAMA_FRAMEWORK" "${APP_DIR}/Contents/lib/llama.framework"

# Update resource bundles — copy to Contents/Resources/
# xcodebuild's Bundle.module accessor checks Bundle.main.resourceURL first,
# which resolves to Contents/Resources/ for .app bundles. This is the correct
# and codesign-compatible location.
#
# Clean up any stale bundles at the app root from previous builds.
find "${APP_DIR}" -maxdepth 1 -name "*.bundle" ! -name "Contents" -exec rm -rf {} + 2>/dev/null || true

find "${DERIVED_DATA}/Build/Products/${XCODE_CONFIG}" -maxdepth 1 -name "*.bundle" | while read -r bundle; do
    bundle_name="$(basename "$bundle")"
    cp -rf "$bundle" "${APP_DIR}/Contents/Resources/"

    # Add a minimal Info.plist if missing so codesign accepts the bundle.
    if [ ! -f "${APP_DIR}/Contents/Resources/${bundle_name}/Info.plist" ]; then
        bundle_id="com.vocamac.resource.$(echo "${bundle_name%.bundle}" | tr '_ ' '-')"
        cat > "${APP_DIR}/Contents/Resources/${bundle_name}/Info.plist" << BPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${bundle_id}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
BPLIST
    fi
done

# Copy app icon and compile Asset Catalog
if [ -f "Sources/VocaMac/Resources/AppIcon.icns" ]; then
    cp -f "Sources/VocaMac/Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

    # Extract PNGs from .icns and compile an Asset Catalog (Assets.car)
    # Modern macOS requires Assets.car for icons to render in Finder
    ICONSET_DIR="/tmp/vocamac-icon-build.iconset"
    XCASSETS_DIR="/tmp/vocamac-icon-build.xcassets"
    rm -rf "$ICONSET_DIR" "$XCASSETS_DIR"

    iconutil --convert iconset "Sources/VocaMac/Resources/AppIcon.icns" -o "$ICONSET_DIR" 2>/dev/null
    if [ -d "$ICONSET_DIR" ]; then
        mkdir -p "${XCASSETS_DIR}/AppIcon.appiconset"
        cp "$ICONSET_DIR"/*.png "${XCASSETS_DIR}/AppIcon.appiconset/"
        cat > "${XCASSETS_DIR}/AppIcon.appiconset/Contents.json" << 'ICONJSON'
{
  "images": [
    {"filename":"icon_16x16.png","idiom":"mac","scale":"1x","size":"16x16"},
    {"filename":"icon_16x16@2x.png","idiom":"mac","scale":"2x","size":"16x16"},
    {"filename":"icon_32x32.png","idiom":"mac","scale":"1x","size":"32x32"},
    {"filename":"icon_32x32@2x.png","idiom":"mac","scale":"2x","size":"32x32"},
    {"filename":"icon_128x128.png","idiom":"mac","scale":"1x","size":"128x128"},
    {"filename":"icon_128x128@2x.png","idiom":"mac","scale":"2x","size":"128x128"},
    {"filename":"icon_256x256.png","idiom":"mac","scale":"1x","size":"256x256"},
    {"filename":"icon_256x256@2x.png","idiom":"mac","scale":"2x","size":"256x256"},
    {"filename":"icon_512x512.png","idiom":"mac","scale":"1x","size":"512x512"},
    {"filename":"icon_512x512@2x.png","idiom":"mac","scale":"2x","size":"512x512"}
  ],
  "info": {"author":"xcode","version":1}
}
ICONJSON
        # Compile Asset Catalog — produces Assets.car which modern macOS needs
        xcrun actool "$XCASSETS_DIR" \
            --compile "${APP_DIR}/Contents/Resources" \
            --platform macosx \
            --minimum-deployment-target 14.0 \
            --app-icon AppIcon \
            --output-partial-info-plist /tmp/vocamac-icon-partial.plist 2>/dev/null && \
            echo "📎 App icon compiled (Assets.car)" || \
            echo "📎 App icon copied (.icns only — actool unavailable)"

        rm -rf "$ICONSET_DIR" "$XCASSETS_DIR" /tmp/vocamac-icon-partial.plist 2>/dev/null
    else
        echo "📎 App icon copied (.icns only)"
    fi
fi

# Create/update Info.plist
cat > "${APP_DIR}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.vocamac.app.actions</string>
            <key>CFBundleURLSchemes</key>
            <array><string>vocamac</string></array>
        </dict>
    </array>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>VocaMac needs microphone access to capture your voice for transcription.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- Ollama and LM Studio serve plain HTTP on this Mac or the LAN. -->
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>NSAudioCaptureUsageDescription</key>
    <string>VocaMac captures system audio only when you start a System Audio transcription.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "🔏 Code signing (${BUNDLE_ID})..."

# Determine codesign options — enable hardened runtime for Developer ID (required for notarization)
CODESIGN_OPTIONS=""
if [ "$CODE_SIGN_IDENTITY" != "-" ]; then
    CODESIGN_OPTIONS="--options runtime"
fi

# Sign nested bundles in Contents/Resources/
find "${APP_DIR}/Contents/Resources" -maxdepth 1 -name "*.bundle" -exec \
    codesign --force --sign "$CODE_SIGN_IDENTITY" $CODESIGN_OPTIONS {} \; 2>/dev/null || true

# Nested code must be signed before the app that contains it.
codesign --force --sign "$CODE_SIGN_IDENTITY" $CODESIGN_OPTIONS \
    "${APP_DIR}/Contents/lib/llama.framework"

# Sign the main app
codesign --force --sign "$CODE_SIGN_IDENTITY" \
    $CODESIGN_OPTIONS \
    --identifier "$BUNDLE_ID" \
    --entitlements "$ENTITLEMENTS" \
    "${APP_DIR}"

echo "✅ Build complete!"
echo ""
echo "   App: $(pwd)/${APP_DIR}"
echo ""

# Verify
codesign -dv "${APP_DIR}" 2>&1 | grep -E "Identifier|CDHash"

echo ""
echo "🚀 To run:  open ${APP_DIR}"
echo "🔄 To rebuild: ./scripts/build.sh"

if [ "$FIRST_TIME" = true ]; then
    echo ""
    echo "⚠️  FIRST TIME SETUP:"
    echo "   1. Run: open ${APP_DIR}"
    echo "   2. System Settings → Privacy & Security → Accessibility → add VocaMac.app → ON"
    echo "   3. System Settings → Privacy & Security → Input Monitoring → add VocaMac.app → ON"
    echo "   4. Restart VocaMac: killall VocaMac && open ${APP_DIR}"
    if [ "$CODE_SIGN_IDENTITY" = "-" ]; then
        echo ""
        echo "   ⚠️  Permissions reset on every rebuild (ad-hoc signing limitation)."
        echo "   💡 TIP: To avoid this, add your Terminal app to Accessibility & Input Monitoring"
        echo "      and run the binary directly: ${APP_DIR}/Contents/MacOS/VocaMac"
    fi
fi
