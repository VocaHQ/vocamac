#!/bin/bash
# install.sh — Build and install VocaMac
#
# Usage:
#   ./scripts/install.sh          Build .app and install to /Applications (recommended)
#   ./scripts/install.sh --cli    Install CLI commands (vocamac, vocamac-build) to ~/.local/bin
#   ./scripts/install.sh --help   Show this help message

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ─── Help ───────────────────────────────────────────────────────────────────────

show_help() {
    echo "VocaMac Installer"
    echo ""
    echo "Usage:"
    echo "  ./scripts/install.sh          Build and install to /Applications (recommended)"
    echo "  ./scripts/install.sh --cli    Install CLI commands to ~/.local/bin"
    echo "  ./scripts/install.sh --help   Show this help"
    echo ""
    echo "Default mode builds VocaMac.app and copies it to /Applications."
    echo "Permissions (Microphone, Accessibility, Input Monitoring) are granted"
    echo "directly to VocaMac — no terminal permission workarounds needed."
    echo ""
    echo "CLI mode installs 'vocamac' and 'vocamac-build' shell commands."
    echo "Note: In CLI mode, macOS permissions are granted to your terminal app"
    echo "(Terminal, iTerm2, etc.) instead of VocaMac."
}

# ─── App Install (default) ──────────────────────────────────────────────────────

install_app() {
    echo "🔨 Building VocaMac.app..."
    "$SCRIPT_DIR/build.sh"
    echo ""

    # Kill any running instance
    pkill -f VocaMac 2>/dev/null || true
    sleep 1

    # Copy to /Applications
    echo "📦 Installing to /Applications..."
    if [ -d "/Applications/VocaMac.app" ]; then
        rm -rf "/Applications/VocaMac.app"
    fi
    cp -R "$PROJECT_DIR/VocaMac.app" "/Applications/VocaMac.app"

    echo "🚀 Launching VocaMac..."
    open "/Applications/VocaMac.app"

    echo ""
    echo "✅ VocaMac installed to /Applications and launched!"
    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│  First-time setup:                                         │"
    echo "│                                                            │"
    echo "│  1. Grant Microphone permission when prompted              │"
    echo "│  2. Grant Accessibility in System Settings                 │"
    echo "│  3. Grant Input Monitoring in System Settings              │"
    echo "│  4. Restart VocaMac after granting Input Monitoring        │"
    echo "│                                                            │"
    echo "│  Then hold Right Option (⌥) and start talking!             │"
    echo "└─────────────────────────────────────────────────────────────┘"
    echo ""
    echo "To rebuild after code changes:  ./scripts/install.sh"
    echo "To uninstall:                   ./scripts/uninstall.sh"
}

# ─── CLI Install ────────────────────────────────────────────────────────────────

install_cli() {
    echo "🔨 Building VocaMac (release)..."
    cd "$PROJECT_DIR"
    swift build -c release

    BINARY_PATH=".build/arm64-apple-macosx/release/VocaMac"

    if [ ! -f "$BINARY_PATH" ]; then
        echo "❌ Build failed — binary not found at $BINARY_PATH"
        exit 1
    fi

    echo "📦 Installing CLI commands to ~/.local/bin..."
    mkdir -p "$HOME/.local/bin"

    # Create vocamac launcher
    cat > "$HOME/.local/bin/vocamac" << LAUNCHER
#!/bin/bash
# VocaMac launcher.
# With arguments (vocamac --list-models, --transcribe-file …), run the
# headless CLI and leave a running VocaMac alone.
# Without arguments, kill any running instance and start the app fresh.
if [ "\$#" -gt 0 ]; then
    exec "$PROJECT_DIR/$BINARY_PATH" "\$@"
fi
killall VocaMac 2>/dev/null
sleep 0.5
"$PROJECT_DIR/$BINARY_PATH" &
echo "VocaMac started (PID: \$!)"
LAUNCHER
    chmod +x "$HOME/.local/bin/vocamac"

    # Create vocamac-build command
    cat > "$HOME/.local/bin/vocamac-build" << BUILDER
#!/bin/bash
# VocaMac rebuild — rebuilds from source
cd "$PROJECT_DIR"
killall VocaMac 2>/dev/null
swift build -c release
echo "✅ VocaMac rebuilt successfully"
BUILDER
    chmod +x "$HOME/.local/bin/vocamac-build"

    # Check PATH
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        echo ""
        echo "⚠️  ~/.local/bin is not in your PATH. Add it:"
        echo ""
        echo "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
        echo "    source ~/.zshrc"
        echo ""
    fi

    echo ""
    echo "✅ CLI commands installed!"
    echo ""
    echo "  vocamac          Launch VocaMac in background"
    echo "  vocamac-build    Rebuild from source"
    echo ""
    echo "⚠️  In CLI mode, grant permissions to your terminal app"
    echo "   (Terminal/iTerm2) in System Settings → Privacy & Security:"
    echo "   • Microphone"
    echo "   • Accessibility"
    echo "   • Input Monitoring"
}

# ─── Main ───────────────────────────────────────────────────────────────────────

case "${1:-}" in
    --cli)
        install_cli
        ;;
    --help|-h)
        show_help
        ;;
    *)
        install_app
        ;;
esac
