#!/bin/bash
# release.sh — Tag a release and push to trigger GitHub Actions release workflow
# Usage: ./scripts/release.sh <version>
# Example: ./scripts/release.sh 0.4.0
#
# This script:
# 1. Validates the version and checks we're on main
# 2. Creates a git tag (v<version>)
# 3. Pushes the tag to origin, which triggers .github/workflows/release.yml
#
# The release workflow handles: build → sign → notarize → create GitHub Release

set -euo pipefail

VERSION="${1:?Usage: ./scripts/release.sh <version> (e.g., 0.4.0)}"
TAG="v${VERSION}"

# Validate we're not already on a tag
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "❌ Tag ${TAG} already exists. Aborting."
    exit 1
fi

# Validate we're on main
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "❌ Not on main branch (currently on ${CURRENT_BRANCH}). Switch to main first."
    exit 1
fi

# Validate working tree is clean
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "❌ Working tree has uncommitted changes. Commit or stash first."
    exit 1
fi

echo "🚀 Releasing VocaMac ${TAG}"
echo ""

# Ensure we're up to date
echo "📥 Pulling latest main..."
git pull origin main

# Tag and push
echo "🏷️  Creating tag ${TAG}..."
git tag "${TAG}"

echo "📤 Pushing tag to origin..."
git push origin "${TAG}"

echo ""
echo "✅ Release ${TAG} triggered!"
echo ""
echo "   GitHub Actions will build, sign, notarize, and create a draft release."
echo "   Watch progress: https://github.com/VocaHQ/vocamac/actions"
echo ""
echo "   Once complete, review and publish the draft release on GitHub."
