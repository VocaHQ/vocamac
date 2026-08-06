# VocaMac Homebrew Distribution Guide

> **🍺 Homebrew is the recommended way to install VocaMac.** See the [README](../README.md#-quick-start) for the full installation options.

## Overview

VocaMac is distributed via Homebrew as a **cask**, not a formula. This distinction matters:

- **Formula** — for command-line tools and libraries built from source
- **Cask** — for pre-built macOS applications distributed as binaries (`.app`, `.dmg`)

Since VocaMac is a native macOS `.app` primarily distributed via Homebrew (with DMG downloads also available via GitHub Releases), a cask is the correct packaging format.

## Quick Start (For Users)

```bash
# Install
brew tap vocahq/vocamac
brew trust vocahq/vocamac
brew install --cask vocamac

# Upgrade to latest version
brew upgrade --cask vocamac

# Uninstall
brew uninstall --cask vocamac
brew untap vocahq/vocamac
```

After installation, VocaMac appears in `/Applications/VocaMac.app`. Launch it from Spotlight or the Applications folder.

`brew trust vocahq/vocamac` trusts the whole VocaMac tap. This is intentional: the stable and nightly casks conflict with each other, so Homebrew may load both cask definitions while resolving an install.

## Nightly Builds

A nightly cask is also available, built daily from the latest `main` branch:

```bash
brew tap vocahq/vocamac
brew trust vocahq/vocamac
brew install --cask vocamac-nightly
```

The nightly cask uses `version :latest` and `sha256 :no_check` because the DMG content changes with every daily build. Homebrew will always fetch the newest artifact without needing a cask definition update.

**Stable and nightly conflict.** Both casks install to `/Applications/VocaMac.app`, so you can only have one installed at a time. Uninstall the stable cask before installing nightly, or vice versa:

```bash
brew uninstall --cask vocamac
brew trust vocahq/vocamac
brew install --cask vocamac-nightly
```

Nightly is a pre-release build intended for testing and early feedback. Use the stable release for daily use.

No auto-update workflow is needed for the nightly cask. The cask definition itself never changes. Homebrew re-downloads the latest DMG each time `brew upgrade --cask vocamac-nightly` runs.

## Custom Tap Setup

The cask lives in a custom tap repository: `VocaHQ/homebrew-vocamac`.

### Creating the Tap Repository

1. Create a new public GitHub repository named `homebrew-vocamac` under the `VocaHQ` organization
2. The repository must follow Homebrew tap naming: `homebrew-<name>`
3. Clone it locally:
   ```bash
   git clone https://github.com/VocaHQ/homebrew-vocamac.git
   cd homebrew-vocamac
   ```
4. Create the cask directory structure:
   ```bash
   mkdir -p Casks
   ```
5. Copy the cask file from the main repo:
   ```bash
   cp /path/to/vocamac/homebrew/Casks/vocamac.rb Casks/
   ```
6. Commit and push:
   ```bash
   git add Casks/vocamac.rb
   git commit -m "chore: add vocamac cask"
   git push origin main
   ```

Users can then install with:

```bash
brew tap vocahq/vocamac
brew trust vocahq/vocamac
brew install --cask vocamac
```

## Testing Locally

Before pushing a cask update to the tap, test it from a tap checkout against a real DMG. Homebrew 6 rejects loose cask files outside a tap, so copy the cask into a local tap checkout first:

```bash
brew tap vocahq/vocamac
cp homebrew/Casks/vocamac.rb "$(brew --repository vocahq/vocamac)/Casks/vocamac.rb"
brew trust vocahq/vocamac
brew install --cask vocamac
```

This installs the cask from the local tap checkout. It requires a real DMG to exist at the URL specified in the cask (i.e., a published GitHub Release).

To verify the installation:

```bash
ls /Applications/VocaMac.app
brew info --cask vocamac
```

To uninstall after testing:

```bash
brew uninstall --cask vocamac
```

Then restore or commit the tap checkout changes, depending on whether the test was for a local-only change or a real tap update.

## Manual Cask Update

When a new VocaMac version ships, the cask needs two updates: the `version` string and the `sha256` checksum.

1. Download the new DMG:
   ```bash
   curl -L -o VocaMac-X.Y.Z-arm64.dmg \
     https://github.com/VocaHQ/vocamac/releases/download/vX.Y.Z/VocaMac-X.Y.Z-arm64.dmg
   ```

2. Compute the SHA-256:
   ```bash
   shasum -a 256 VocaMac-X.Y.Z-arm64.dmg
   ```

3. Update `homebrew/Casks/vocamac.rb`:
   - Change `version "X.Y.Z"` to the new version
   - Replace `sha256 :no_check` with `sha256 "<computed-sha256>"`

4. Test locally (see [Testing Locally](#testing-locally) above)

5. Commit and push to the tap repository:
   ```bash
   cd /path/to/homebrew-vocamac
   git add Casks/vocamac.rb
   git commit -m "chore: update vocamac to vX.Y.Z"
   git push origin main
   ```

## Auto-Update Workflow

The repository includes `.github/workflows/update-homebrew-cask.yml`, which automates cask updates on every release publish.

### How It Works

1. The workflow triggers on `release` event with `types: [published]`, or via `workflow_dispatch` (optional `tag` input; defaults to the latest release)
2. It extracts the version tag (e.g., `v0.6.2` → `0.6.2`)
3. It downloads the DMG from the release assets
4. It computes the SHA-256 checksum
5. It updates `homebrew/Casks/vocamac.rb` with the new version and sha256
6. It pushes the change to the `VocaHQ/homebrew-vocamac` tap repository

### Required GitHub Secret

The workflow needs a Personal Access Token with `repo` scope to push to the tap repository:

- **Secret name:** `HOMEBREW_TAP_TOKEN`
- **Scope:** `repo` (full control of private and public repositories)
- **Set at:** Repository Settings → Secrets and variables → Actions

Generate the token at [github.com/settings/tokens](https://github.com/settings/tokens). Prefer a **classic** PAT with the `repo` scope (works when the token owner is a VocaHQ org owner), or a **fine-grained** PAT with resource owner `VocaHQ`, repository access `homebrew-vocamac`, and permission **Contents: Read and write**. A fine-grained PAT issued under a personal account without org resource ownership cannot push to `VocaHQ/homebrew-vocamac`.

## Submitting to homebrew-cask

Once VocaMac meets the notability requirements, the cask can be submitted to the official [homebrew-cask](https://github.com/Homebrew/homebrew-cask) repository, eliminating the need for a custom tap.

### Requirements

- **75+ GitHub stars** on the repository
- **Signed and notarized** DMG (VocaMac already meets this)
- **Stable release** (not a pre-release or nightly)
- **Active maintenance** (recent commits, responsive maintainer)

### Submission Process

1. Fork [Homebrew/homebrew-cask](https://github.com/Homebrew/homebrew-cask)
2. Create a branch: `git checkout -b add-vocamac`
3. Run `brew create --cask <dmg-url>` to generate the cask file
4. Place it in `Casks/v/vocamac.rb` (note the subdirectory structure)
5. Test: `brew install --cask ./Casks/v/vocamac.rb`
6. Commit and open a PR against `Homebrew/homebrew-cask`
7. Respond to reviewer feedback

Once merged, users install with just `brew install --cask vocamac` — no tap required.

## Zap Behavior

Running `brew uninstall --zap vocamac` removes the app **and** all associated user data:

```ruby
zap trash: [
  "~/Library/Application Support/VocaMac",   # Downloaded models, user config
  "~/Library/Caches/com.vocamac.app",        # Cached data
  "~/Library/Preferences/com.vocamac.app.plist",  # UserDefaults/preferences
  "~/Library/Saved Application State/com.vocamac.app.savedState",  # Window state
]
```

This is useful for a clean reinstall or when troubleshooting. A plain `brew uninstall --cask vocamac` only removes the `.app` bundle and leaves user data intact.

## In-App Update Behavior

When VocaMac is installed via Homebrew Cask, the built-in update checker detects the Homebrew installation and disables in-app DMG downloads. Instead of showing a **"Download & Install"** button, the update banner and About tab display a Homebrew-specific message:

> Updates are managed by Homebrew. Run: `brew upgrade --cask vocamac`

Nightly users see the nightly token instead:

> Updates are managed by Homebrew. Run: `brew upgrade --cask vocamac-nightly`

### How Detection Works

Homebrew moves the launched app into the configured app directory, usually `/Applications/VocaMac.app`, and keeps cask metadata under the Homebrew prefix. VocaMac checks standard Apple Silicon and Intel Caskroom roots for the supported cask tokens (`vocamac` and `vocamac-nightly`), requires a Homebrew install receipt, and verifies that the cask's staged `VocaMac.app` entry resolves back to the running app bundle.

| Installation Method | Update Behavior |
|---|---|
| **DMG (manual)** | In-app download, SHA-256 verification, open DMG |
| **Homebrew Cask** | Shows the matching Homebrew upgrade command; no in-app download |

This prevents conflicts between Homebrew's version management and the app's own update mechanism. Always use `brew upgrade --cask vocamac` or `brew upgrade --cask vocamac-nightly` to update a Homebrew-installed copy of VocaMac.

## Troubleshooting

### Cask install fails with "SHA256 mismatch"

The checksum in the cask file doesn't match the downloaded DMG. This happens when the cask hasn't been updated for a new release.

**Fix:** Update the cask manually (see [Manual Cask Update](#manual-cask-update)) or wait for the auto-update workflow to complete.

### "It seems there is already an App at..."

A previous installation exists at `/Applications/VocaMac.app`.

**Fix:** Remove the existing app first:
```bash
rm -rf /Applications/VocaMac.app
brew trust vocahq/vocamac
brew install --cask vocamac
```

### Homebrew refuses to load the cask from an untrusted tap

Homebrew 6 requires explicit trust for casks from third-party taps. Trust the VocaMac tap rather than only one cask, because the stable and nightly casks declare `conflicts_with` and Homebrew may load the other cask while resolving an install.

**Fix:** Trust the VocaMac tap, then install again:

```bash
brew trust vocahq/vocamac
brew install --cask vocamac
```

### Cask not found after `brew tap`

The tap repository may not exist or the cask file is missing.

**Fix:** Verify the tap:
```bash
brew tap --repair vocahq/vocamac
ls "$(brew --prefix)/Homebrew/Library/Taps/VocaHQ/homebrew-vocamac/Casks/"
```

### App won't launch after Homebrew install

Homebrew installs the app to `/Applications/VocaMac.app` — it behaves identically to a manual DMG install. If the app won't launch:

1. Check Gatekeeper: `spctl --assess /Applications/VocaMac.app`
2. If quarantined: `xattr -d com.apple.quarantine /Applications/VocaMac.app`
3. Grant permissions in System Settings → Privacy & Security

### Auto-update workflow fails

Check the workflow run logs in the main repository's Actions tab. Common causes:

- `HOMEBREW_TAP_TOKEN` secret is missing or expired
- The tap repository doesn't exist or the token lacks write access
- The release DMG asset name doesn't match the expected pattern
