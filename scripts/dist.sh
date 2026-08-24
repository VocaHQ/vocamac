#!/bin/bash
# dist.sh — Build VocaMac and package as a signed, notarized DMG
# Usage: ./scripts/dist.sh [--skip-notarize] [--skip-sign]
#
# This script:
# 1. Builds VocaMac.app via build.sh (Developer ID signed if available)
# 2. Creates a beautiful DMG with:
#    - Branded background image with install instructions
#    - App icon on the left, Applications symlink on the right
#    - Properly sized and positioned Finder window
#    - README.txt with permission setup instructions
# 3. Signs the DMG with Developer ID
# 4. Notarizes with Apple and staples the ticket
#
# Environment variables:
#   CODE_SIGN_IDENTITY   — Passed through to build.sh
#   NOTARIZE_PROFILE     — Keychain profile name for notarytool (default: AC_PASSWORD)
#
# Flags:
#   --skip-notarize      — Build and sign but skip notarization (for local testing)
#   --skip-sign          — Skip signing entirely (ad-hoc only, Gatekeeper will block)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Parse flags
SKIP_NOTARIZE=false
SKIP_SIGN=false
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=true ;;
        --skip-sign)     SKIP_SIGN=true; SKIP_NOTARIZE=true ;;
    esac
done

# Get version from APP_VERSION env var (if set) or from build.sh's default APP_VERSION.
DEFAULT_APP_VERSION="$(grep '^APP_VERSION=' scripts/build.sh | sed 's/.*:-\(.*\)}.*/\1/' | head -1 || true)"
VERSION="${APP_VERSION:-$DEFAULT_APP_VERSION}"
if [ -z "$VERSION" ]; then
    echo "❌ Unable to determine app version. Set APP_VERSION or update scripts/build.sh." >&2
    exit 1
fi
ARCH=$(uname -m)
APP_NAME="VocaMac"
DMG_NAME="${APP_NAME}-${VERSION}-${ARCH}.dmg"
DIST_DIR="dist"
STAGING_DIR="${DIST_DIR}/.staging"
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-AC_PASSWORD}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VocaMac ${VERSION} — Distribution Build"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Step 1: Build ────────────────────────────────────────────────────────────
echo "▶ Step 1/5: Building VocaMac..."
"$SCRIPT_DIR/build.sh" release

if [ ! -d "VocaMac.app" ]; then
    echo "❌ VocaMac.app not found. Build failed."
    exit 1
fi

# Use CODE_SIGN_IDENTITY from environment (set by release workflow),
# or auto-detect from keychain
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)}"
echo "   Signed with: ${SIGNING_IDENTITY:-ad-hoc}"
echo ""

# ── Step 2: Stage DMG contents ───────────────────────────────────────────────
echo "▶ Step 2/5: Staging DMG contents..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$DIST_DIR"

# Copy app
cp -R VocaMac.app "$STAGING_DIR/"

# Applications symlink
ln -sf /Applications "$STAGING_DIR/Applications"

# Finder uses PNG density to convert the DMG background from pixels to points.
# If a raster editor drops these files to 72 DPI, the artwork renders at 2×
# while the Finder icons stay correctly positioned on the 660 × 520 window.
validate_dmg_background() {
    local path="$1"
    local expected_width="$2"
    local expected_height="$3"
    local metadata pixel_width pixel_height dpi_width dpi_height

    metadata="$(sips -g pixelWidth -g pixelHeight -g dpiWidth -g dpiHeight "$path")"
    pixel_width="$(echo "$metadata" | awk '/pixelWidth:/ { print $2 }')"
    pixel_height="$(echo "$metadata" | awk '/pixelHeight:/ { print $2 }')"
    dpi_width="$(echo "$metadata" | awk '/dpiWidth:/ { print $2 }')"
    dpi_height="$(echo "$metadata" | awk '/dpiHeight:/ { print $2 }')"

    if [ "$pixel_width" != "$expected_width" ] ||
       [ "$pixel_height" != "$expected_height" ] ||
       [ "$dpi_width" != "144.000" ] ||
       [ "$dpi_height" != "144.000" ]; then
        echo "❌ Invalid DMG background metadata: $path" >&2
        echo "   Expected ${expected_width}×${expected_height} at 144 DPI; got ${pixel_width}×${pixel_height} at ${dpi_width}×${dpi_height} DPI." >&2
        exit 1
    fi
}

# Copy branded background (hidden folder — standard DMG convention)
mkdir -p "$STAGING_DIR/.background"
if [ -f "Sources/VocaMac/Resources/dmg-background.png" ]; then
    validate_dmg_background "Sources/VocaMac/Resources/dmg-background.png" 1320 1040
    cp "Sources/VocaMac/Resources/dmg-background.png"    "$STAGING_DIR/.background/background.png"
fi
if [ -f "Sources/VocaMac/Resources/dmg-background@2x.png" ]; then
    validate_dmg_background "Sources/VocaMac/Resources/dmg-background@2x.png" 2640 2080
    cp "Sources/VocaMac/Resources/dmg-background@2x.png" "$STAGING_DIR/.background/background@2x.png"
fi

# No README.txt — instructions are on the background image and website
echo "   Staging complete."
echo ""

# ── Step 3: Create DMG ───────────────────────────────────────────────────────
echo "▶ Step 3/5: Creating DMG..."

# Create a writable DMG first so we can set Finder view options
TEMP_DMG="${DIST_DIR}/.tmp-rw.dmg"
hdiutil create -volname "VocaMac" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDRW \
    -size 500m \
    "$TEMP_DMG" > /dev/null

# Mount it
MOUNT_POINT=$(hdiutil attach "$TEMP_DMG" -readwrite -noverify -noautoopen \
    | grep -E '\s/Volumes/' | sed 's|.*\(/Volumes/[^\t]*\)|\1|' | tail -1 | xargs)

if [ -z "$MOUNT_POINT" ]; then
    echo "❌ Failed to mount DMG."
    exit 1
fi

echo "   Mounted at: $MOUNT_POINT"

# Set Finder window layout via AppleScript
# We run this in a loop because Finder can be slow to register the volume,
# and we need the .DS_Store to be written before we detach.
echo "   Configuring Finder layout..."

# Ensure any previous VocaMac volumes are ejected first
for vol in /Volumes/VocaMac*; do
    [ -d "$vol" ] && [ "$vol" != "$MOUNT_POINT" ] && hdiutil detach "$vol" 2>/dev/null || true
done

# Give Finder time to discover the volume
sleep 2

osascript << 'APPLESCRIPT'
tell application "Finder"
    tell disk "VocaMac"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 60, 860, 580}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 120
        set background picture of viewOptions to file ".background:background.png"
        set position of item "VocaMac.app" of container window to {170, 250}
        set position of item "Applications" of container window to {490, 250}
        close
        open
        delay 1
        -- Force a second pass to ensure settings stick
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 60, 860, 580}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 120
        set background picture of viewOptions to file ".background:background.png"
        set position of item "VocaMac.app" of container window to {170, 250}
        set position of item "Applications" of container window to {490, 250}
        update without registering applications
        delay 3
        close
    end tell
end tell
APPLESCRIPT

# Ensure .DS_Store is flushed to disk
sync
sleep 1

# Verify .DS_Store was written
if [ -f "$MOUNT_POINT/.DS_Store" ]; then
    echo "   Finder layout applied (.DS_Store written)"
else
    echo "   ⚠️  .DS_Store not found — Finder layout may not persist"
fi

# Unmount
hdiutil detach "$MOUNT_POINT" -quiet || hdiutil detach "$MOUNT_POINT" -force

# Convert to compressed final DMG
FINAL_DMG="${DIST_DIR}/${DMG_NAME}"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$FINAL_DMG" > /dev/null
rm -f "$TEMP_DMG"

echo "   DMG created: ${FINAL_DMG}"
echo ""

# ── Step 4: Sign DMG ─────────────────────────────────────────────────────────
echo "▶ Step 4/5: Signing DMG..."

if [ "$SKIP_SIGN" = true ]; then
    echo "   ⚠️  Skipped (--skip-sign)"
elif [ -z "$SIGNING_IDENTITY" ]; then
    echo "   ⚠️  No Developer ID found — DMG not signed (Gatekeeper will block)"
else
    codesign --sign "$SIGNING_IDENTITY" "$FINAL_DMG"
    echo "   Signed with: $SIGNING_IDENTITY"
fi
echo ""

# ── Step 5: Notarize ─────────────────────────────────────────────────────────
echo "▶ Step 5/5: Notarizing..."

if [ "$SKIP_NOTARIZE" = true ]; then
    echo "   ⚠️  Skipped (--skip-notarize)"
elif [ -z "$SIGNING_IDENTITY" ]; then
    echo "   ⚠️  Skipped — no Developer ID certificate"
else
    # Check that the notarization keychain profile exists
    if ! xcrun notarytool history --keychain-profile "$NOTARIZE_PROFILE" > /dev/null 2>&1; then
        echo "   ❌ Notarization keychain profile '$NOTARIZE_PROFILE' not found."
        echo "      Run: xcrun notarytool store-credentials \"$NOTARIZE_PROFILE\" \\"
        echo "               --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID"
        echo "      Then re-run: ./scripts/dist.sh"
        exit 1
    fi

    echo "   Submitting to Apple Notary Service..."
    SUBMIT_OUTPUT=$(xcrun notarytool submit "$FINAL_DMG" \
        --keychain-profile "$NOTARIZE_PROFILE" 2>&1)
    SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')

    if [ -z "$SUBMISSION_ID" ]; then
        echo "   ❌ Failed to submit for notarization:"
        echo "$SUBMIT_OUTPUT"
        exit 1
    fi

    echo "   Submission ID: $SUBMISSION_ID"
    echo "   Polling for completion (this typically takes 1–15 minutes)..."

    MAX_ATTEMPTS=60   # 60 × 30s = 30 minutes max
    ATTEMPT=0
    NETWORK_RETRIES=0
    MAX_NETWORK_RETRIES=10

    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        ATTEMPT=$((ATTEMPT + 1))
        sleep 30

        INFO_OUTPUT=$(xcrun notarytool info "$SUBMISSION_ID" \
            --keychain-profile "$NOTARIZE_PROFILE" 2>&1) || {
            NETWORK_RETRIES=$((NETWORK_RETRIES + 1))
            if [ $NETWORK_RETRIES -ge $MAX_NETWORK_RETRIES ]; then
                echo "   ❌ Too many network failures ($MAX_NETWORK_RETRIES). Giving up."
                echo "   Check manually: xcrun notarytool info $SUBMISSION_ID --keychain-profile $NOTARIZE_PROFILE"
                exit 1
            fi
            echo "   ⚠️  Network error (retry $NETWORK_RETRIES/$MAX_NETWORK_RETRIES), will try again in 30s..."
            continue
        }

        STATUS=$(echo "$INFO_OUTPUT" | grep "status:" | awk '{print $2}')

        case "$STATUS" in
            Accepted)
                echo "   ✅ Notarization accepted!"
                break
                ;;
            Invalid|Rejected)
                echo "   ❌ Notarization failed with status: $STATUS"
                echo "   Run: xcrun notarytool log $SUBMISSION_ID --keychain-profile $NOTARIZE_PROFILE"
                exit 1
                ;;
            *)
                # Still "In Progress" — keep polling
                printf "   … poll %d/%d (status: %s)\r" "$ATTEMPT" "$MAX_ATTEMPTS" "$STATUS"
                ;;
        esac
    done

    if [ "$STATUS" != "Accepted" ]; then
        echo "   ❌ Notarization timed out after $MAX_ATTEMPTS attempts."
        echo "   Check manually: xcrun notarytool info $SUBMISSION_ID --keychain-profile $NOTARIZE_PROFILE"
        exit 1
    fi

    echo "   Stapling notarization ticket..."
    xcrun stapler staple "$FINAL_DMG"
    echo "   Notarization complete."
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Distribution build complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  File:    ${FINAL_DMG}"
echo "  Size:    $(du -h "${FINAL_DMG}" | cut -f1)"
echo ""
echo "  SHA-256: $(shasum -a 256 "${FINAL_DMG}" | awk '{print $1}')"
echo ""
echo "  Path:    $(cd "$(dirname "$FINAL_DMG")" && pwd)/$(basename "$FINAL_DMG")"

# Clean up staging
rm -rf "$STAGING_DIR"
