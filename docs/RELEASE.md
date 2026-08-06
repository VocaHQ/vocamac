# VocaMac Release Process

## Overview

VocaMac uses GitHub Actions for CI/CD. Releases are triggered by pushing a version tag (e.g., `v0.1.0`). The release workflow builds the app, creates a DMG and ZIP archive, generates checksums, and publishes a draft GitHub Release.

## Versioning

We follow [Semantic Versioning](https://semver.org/):

```
vMAJOR.MINOR.PATCH
```

- **MAJOR** - Breaking changes or significant redesigns
- **MINOR** - New features, backward compatible
- **PATCH** - Bug fixes, minor improvements

Pre-release versions use suffixes: `v0.1.0-alpha`, `v0.1.0-beta.1`

## Release Checklist

### Before Tagging

1. **Ensure all PRs are merged** into `main`
2. **Verify CI passes** on the latest `main` commit
3. **Update version number** in all locations:
   - `scripts/build.sh` — both `CFBundleVersion` and `CFBundleShortVersionString` in the Info.plist template
   - `web/layouts/index.html` — `softwareVersion` in JSON-LD schema and hero version badge (two occurrences)
   - _(No Swift change needed — the About tab reads the version from `Info.plist` via `appVersionDisplay` in `SettingsView.swift`.)_
   - `homebrew/Casks/vocamac.rb` — version and sha256 (if doing a manual tap update)
   - **Do NOT** create a `docs/RELEASE_NOTES_vX.Y.Z.md` file — release notes live out-of-tree (see [Release Notes (out-of-tree)](#release-notes-out-of-tree) below)
4. **Test locally**:
   ```bash
   ./scripts/build.sh release
   open VocaMac.app
   ```
5. **Verify core functionality**:
   - App appears in menu bar
   - Push-to-talk recording works
   - Transcription produces correct text
   - Text injection works at cursor
   - Settings dialog opens and all tabs function
   - Model download and switching works
   - Sound effects play on start/stop
6. **Review README** for accuracy

### Creating a Release

1. **Tag the release**:
   ```bash
   git tag -a v0.2.0 -m "VocaMac v0.2.0"
   git push origin v0.2.0
   ```

2. **GitHub Actions automatically**:
   - Imports the Developer ID certificate from repository secrets
   - Builds the release binary with Developer ID signing
   - Creates a beautiful branded DMG (`VocaMac-0.5.0-arm64.dmg`)
   - Notarizes with Apple and staples the ticket
   - Packages as ZIP (`VocaMac-0.5.0-arm64.zip`)
   - Generates SHA-256 checksums
   - Creates a **draft** GitHub Release with all artifacts

3. **Review the draft release** at https://github.com/VocaHQ/vocamac/releases
   - Edit release notes if needed
   - Verify artifacts are attached
   - **Publish** the release when ready

4. **Homebrew tap auto-updates** — The `update-homebrew-cask.yml` workflow runs automatically on release publish, updating the custom tap with the new version and SHA. If it fails, update manually (see `docs/HOMEBREW.md`).

5. **Website auto-deploys** when the release is published (via `deploy-website.yml`)

## Release Notes (out-of-tree)

**We do not commit per-version release notes to this repository.** Files like `docs/RELEASE_NOTES_v0.6.1.md` should never appear in the source tree. The single source of truth for shipped notes is the **GitHub Release page**, which is also what `UpdateChecker` surfaces inside the app.

### Why out-of-tree?

- Release notes are written for end users and rarely re-edited after publish — they don't benefit from version control.
- Per-version files accumulate over time, cluttering `docs/` and producing stale content (e.g. notes for an unreleased version sitting on `main` for weeks).
- The PR description for the version-bump PR already provides the changelog context that reviewers need.
- The GitHub Release editor renders the same Markdown and is editable post-publish for typo fixes.

### Workflow

1. **Draft** the notes in a scratch location *outside* the repo. Recommended locations:
   - `/tmp/RELEASE_NOTES_vX.Y.Z.md` — quick local scratch, wiped on reboot
   - A private Gist — survives reboots, easy to share for review
   - The GitHub Release "Draft a new release" UI — write directly in the final destination
2. **Reuse** the draft for the version-bump PR description (paste the changelog table inline) and any pre-release comms (Slack, Discord, etc.).
3. **Publish** the release with the notes:
   ```bash
   gh release create vX.Y.Z --draft --notes-file /tmp/RELEASE_NOTES_vX.Y.Z.md
   # or just paste into the GitHub UI when promoting the auto-created draft
   ```
4. **Delete** the local scratch file once the release is live:
   ```bash
   rm /tmp/RELEASE_NOTES_vX.Y.Z.md
   ```

### What goes in the version-bump PR

The version-bump PR should only touch *code* files that carry the version string (`scripts/build.sh`, `web/layouts/index.html`). The **PR description** is where the changelog table lives — that gives reviewers the context they need without polluting the tree.

### Suggested PR-description template

```markdown
## Summary
Prepares the **vX.Y.Z** patch/minor release.

### Changes since vA.B.C
| PR | Type | Summary |
|---|---|---|
| #N | fix | … |
| #N | feat | … |

### Files updated
- `scripts/build.sh`
- `web/layouts/index.html`

### Release plan after merge
- Tag `vX.Y.Z`, push tag → `release.yml` builds, signs, notarizes, drafts the release
- Paste finalized notes from local scratch into the draft, publish
- Delete local scratch file

### Suggested release-notes line (Homebrew tap migration)
Homebrew: the tap moved to `vocahq/vocamac`. Existing installs keep working via
GitHub redirects; optionally `brew untap jatinkrmalik/vocamac && brew tap vocahq/vocamac`.
```

## In-App Update Integration

VocaMac includes an in-app update checker powered by GitHub Releases:

- Automatic check on launch (throttled to once every 24 hours)
- Manual check via **Settings -> About -> Check for Updates...**
- If a new version is available, VocaMac downloads the latest `arm64` DMG with progress
- Downloaded DMG integrity is verified using GitHub's SHA-256 release digest
- App opens the DMG and guides users to drag/replace in Applications

This implementation reuses existing release artifacts and does not require extra appcast or Sparkle infrastructure.

## Release Artifacts

Each release produces:

| Artifact | Description |
|----------|-------------|
| `VocaMac-X.Y.Z-arm64.dmg` | DMG disk image with drag-to-Applications installer |
| `VocaMac-X.Y.Z-arm64.zip` | ZIP archive of VocaMac.app |
| `checksums.txt` | SHA-256 checksums for verification |

## Architecture Support

Currently **Apple Silicon (arm64) only**. The build runs on `macos-15` runners which are arm64.

For universal binary support (arm64 + x86_64) in the future:
```bash
swift build -c release --arch arm64 --arch x86_64
```

## Code Signing

- **Developer ID Application** certificate — auto-detected from Keychain locally, imported from secrets in CI
- **Notarized** with Apple — no Gatekeeper warnings for users
- DMG is stapled so notarization validates offline
- Permissions persist across updates (no more manual re-grants)

## CI Workflows

### `ci.yml` - Build & Test

- **Triggers**: Push to `main`, pull requests to `main`
- **Steps**: Debug build, test suite, release build, app bundle verification
- **Caching**: SPM dependencies cached for faster builds
- **Concurrency**: Cancels in-progress runs for the same branch

### `release.yml` - Release

- **Triggers**: Push of version tags (`v*`)
- **Steps**: Build, test, create DMG + ZIP, generate checksums, create draft release
- **Output**: Draft GitHub Release with downloadable artifacts

### `deploy-website.yml` - Website

- **Triggers**: Release published, manual dispatch
- **Steps**: Deploy `web/` directory to GitHub Pages

## Manual Release (Without CI)

If you need to create a release locally:

```bash
# Build the app, create signed + notarized DMG
make dmg
# Output: dist/VocaMac-X.Y.Z-arm64.dmg

# Create ZIP from the signed .app
ditto -c -k --sequesterRsrc --keepParent VocaMac.app "dist/VocaMac-X.Y.Z-arm64.zip"

# Generate checksums
cd dist && shasum -a 256 VocaMac-*.dmg VocaMac-*.zip > checksums.txt
```

Then upload the artifacts manually to the GitHub Release page.

## Hotfix Process

For critical bugs in a released version:

1. Create a branch from the release tag: `git checkout -b fix/critical-bug v0.2.0`
2. Fix the bug, commit, push
3. Create a PR to `main`
4. After merge, tag a patch release: `v0.1.1`
5. Push the tag to trigger the release workflow
