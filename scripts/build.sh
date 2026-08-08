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
#   APP_VERSION         — Version string to embed in Info.plist. Defaults to 0.8.0.
#                         Set by CI for nightly builds (e.g., 0.8.0-nightly.20260512+abc1234).
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
APP_VERSION="${APP_VERSION:-0.8.0}"

# Resolve signing identity:
# 1. Use CODE_SIGN_IDENTITY env var if set
# 2. Auto-detect Developer ID Application in the login keychain
# 3. Fall back to ad-hoc signing (-)
if [ -z "${CODE_SIGN_IDENTITY+x}" ]; then
    DETECTED=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
    if [ -n "$DETECTED" ]; then
        CODE_SIGN_IDENTITY="$DETECTED"
        echo "🔐 Auto-detected signing identity: $CODE_SIGN_IDENTITY"
    else
        CODE_SIGN_IDENTITY="-"
        echo "⚠️  No Developer ID found — using ad-hoc signing"
    fi
fi

if [ "$CODE_SIGN_IDENTITY" = "-" ]; then
    echo "🔏 Signing mode: ad-hoc (permissions reset on every rebuild)"
else
    echo "🔏 Signing mode: Developer ID"
fi

# Kill any running VocaMac instances before building
if pgrep -f "VocaMac" > /dev/null 2>&1; then
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

xcodebuild build \
    -scheme VocaMac \
    -configuration "$XCODE_CONFIG" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'platform=macOS,arch=arm64' \
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>VocaMac needs microphone access to capture your voice for transcription.</string>
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
