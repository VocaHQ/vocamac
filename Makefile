# VocaMac — Makefile
# Run `make help` for available commands.

.PHONY: build install install-cli dmg release test lint clean reset run help

.DEFAULT_GOAL := help

## Build .app bundle in repo root (fast, for development)
build:
	@./scripts/build.sh

## Build and install to /Applications (recommended for first-time setup)
install:
	@./scripts/install.sh

## Install CLI commands (vocamac, vocamac-build) to ~/.local/bin
install-cli:
	@./scripts/install.sh --cli

## Build DMG for distribution
dmg:
	@./scripts/dist.sh

## Release — tag and push to trigger GitHub Actions release workflow (usage: make release VERSION=0.4.0)
release:
	@./scripts/release.sh $(VERSION)

## Run tests
test:
	@swift package resolve
	@./scripts/fix-onnxruntime-framework-links.sh
	@swift test

## Lint Swift sources with the pinned SwiftLint (downloaded on first run)
lint:
	@./scripts/swiftlint.sh --quiet

## Remove build artifacts
clean:
	@echo "🧹 Cleaning build artifacts..."
	@swift package clean 2>/dev/null || true
	@rm -rf VocaMac.app
	@rm -rf .build
	@rm -rf .xcode-build
	@rm -rf dist
	@echo "✅ Clean complete"

## Reset all local VocaMac data (models, cache, preferences) — app must not be running
reset:
	@if pgrep -x VocaMac > /dev/null 2>&1; then echo "❌ VocaMac is running. Quit it first." && exit 1; fi
	@echo "⚠️  This will permanently delete all VocaMac local data:"
	@echo ""
	@echo "   • Downloaded whisper models (~76MB each)"
	@echo "   • Debug logs"
	@echo "   • Cached data"
	@echo "   • All preferences (selected model, language, onboarding state, etc.)"
	@echo ""
	@echo "Next launch will start as if freshly installed (onboarding + bundled tiny model)."
	@echo ""
	@bash -c 'read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || (echo "Aborted." && exit 1)'
	@rm -rf ~/Library/Application\ Support/VocaMac
	@rm -rf ~/Library/Caches/com.vocamac.app
	@defaults delete com.vocamac.app 2>/dev/null || true
	@echo "✅ Reset complete — next launch will start fresh"

## Launch the locally built .app (build first with `make build`)
run:
	@open VocaMac.app 2>/dev/null || (echo "❌ VocaMac.app not found. Run 'make build' first." && exit 1)

## Show this help
help:
	@echo "VocaMac — Available Commands"
	@echo ""
	@echo "  make build        Build .app bundle (fast, for development)"
	@echo "  make install      Build + install to /Applications (recommended)"
	@echo "  make install-cli  Install CLI commands to ~/.local/bin"
	@echo "  make dmg          Build DMG for distribution (output in dist/)"
	@echo "  make release VERSION=X.Y.Z  Tag and release (triggers CI signing + notarization)"
	@echo "  make test         Run tests"
	@echo "  make lint         Lint Swift sources (SwiftLint)"
	@echo "  make run          Launch the locally built .app"
	@echo "  make clean        Remove build artifacts"
	@echo "  make reset        Delete all local app data (models, cache, prefs)"
	@echo "  make help         Show this help"
	@echo ""
	@echo "Quick start:  make install"
