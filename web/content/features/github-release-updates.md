---
title: "GitHub Release Updates"
subtitle: "VocaMac checks GitHub Releases for updates. Homebrew users run `brew upgrade`. DMG users get in-app downloads."
description: "VocaMac includes built-in update checks powered by the GitHub Releases API. See new versions in-app, download the signed DMG with progress, and install safely."
keywords: "mac app update checker, github releases updater, signed dmg updates, menu bar app update flow, vocamac updates"
icon: "⬇️"
---

## Built-In Update Checks

VocaMac checks for new releases directly from GitHub. It compares your current app version to the latest stable release, then shows an in-app update banner when a newer version is available.

If you installed VocaMac via Homebrew (`brew install --cask vocamac`), updates are managed by Homebrew — simply run `brew upgrade --cask vocamac`. VocaMac detects Homebrew installs and guides you accordingly.

The check is lightweight and rate-limit friendly:

- automatic check on launch (at most once every 24 hours)
- manual **Check for Updates...** button in **Settings / About**
- no extra account, login, or update service required

## Update Flow (DMG Installs)

When an update is found, VocaMac shows a clear, non-intrusive banner in the menu bar popover. From there, you can open update details, review release notes, and start the download.

![VocaMac update sheet showing release notes and Download & Install button](/screenshots/update-ux.png)

The app then:

1. downloads the latest `arm64` DMG from the GitHub Release asset
2. shows real-time download progress
3. verifies the file integrity using the SHA-256 digest from GitHub's release API
4. opens the DMG so you can drag VocaMac to Applications

This keeps the install process familiar and transparent while still making updates much faster.

## Security and Trust

VocaMac only checks `https://api.github.com/repos/VocaHQ/vocamac/releases/latest` and downloads release assets served from GitHub over HTTPS.

Each downloaded DMG is validated against the release digest before the app offers to open it. Releases remain Developer ID signed and notarized, matching the existing distribution process.

## Permissions Across Updates

Since VocaMac is now signed with a stable Developer ID identity, permissions are expected to carry over across updates. In most cases, you can update and continue dictating without re-granting access.

If permissions ever look stale, the Debug tab still includes a one-click permission reset helper.
