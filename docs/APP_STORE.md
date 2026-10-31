# Mac App Store build

VocaMac ships in two ways from the same source:

| | Direct download | Mac App Store |
|--|--|--|
| Channel | Developer ID DMG, Homebrew cask | Mac App Store (paid) |
| Built by | `scripts/build.sh`, `scripts/dist.sh`, `release.yml` (`v*` tags) | `scripts/build-appstore.sh`, `appstore.yml` (`appstore/v*` tags) |
| Compile condition | none | `APP_STORE` |
| Entitlements | `VocaMac.entitlements` (hardened runtime) | `VocaMac-AppStore.entitlements` (App Sandbox) |
| Updates | In-app updater (GitHub Releases) or `brew upgrade` | The App Store |
| Output | `VocaMac.app`, `dist/VocaMac-*.dmg` | `dist/appstore/VocaMac.app`, `dist/appstore/VocaMac.xcarchive` |

The direct download is unchanged by the App Store build. Everything specific
to the store sits behind the `APP_STORE` compile condition, and
`AppDistribution` (in `Sources/VocaMac/App/AppDistribution.swift`) tells the
UI what this build has.

## What the App Store build leaves out, and why

App Review requires the App Sandbox (Guideline 2.4.5(i)), forbids apps that
update themselves (2.4.5(vii)) or start code from outside their bundle, and
rarely grants the temporary exceptions that AppleScript control of other apps
needs. So under `APP_STORE`:

| Feature | In the App Store build | Why |
|--|--|--|
| Update check, download and in-place install (`UpdateChecker`, `UpdateInstaller`, update banner, window and About rows) | Never asks GitHub; the installer is compiled out; the UI is hidden | The App Store updates the app (2.4.5(vii)) |
| DMG, Homebrew and "latest release" copy in About and the update UI | Hidden | The App Store build is paid; pointing buyers at the free download elsewhere can read as steering them away from the store. Links to the source code, issues and Discord stay |
| Phone gateway (`GatewayEmbedController`): starting `vocagateway`, pairing | Compiled out; the Advanced row, the sub-page and its search entries are hidden | It starts a program from `~/.local/bin` or Homebrew |
| Pause Spotify while dictating (`SpotifyPauser`) | No Apple events; the toggle is hidden | AppleScript needs `com.apple.security.automation.apple-events` plus a temporary exception |
| Command Mode "remind me to…" (`VoiceAction`) | Says it isn't available; other voice actions work | AppleScript to Reminders, as above |
| Reset permissions (`tccutil`) | Compiled out; the row is hidden | Starts `/usr/bin/tccutil` |
| Crash report offer (`CrashReportFinder`) | Off | The sandbox can't read `~/Library/Logs/DiagnosticReports`; App Store Connect collects crashes |
| Killing stray copies run from a terminal (`ps`) | Compiled out | Starts `/bin/ps`; the store copy always runs from its bundle |

Reworked rather than removed:

- **Restart VocaMac** (`AppRelauncher`) opens a new instance through
  `NSWorkspace.openApplication(at:configuration:)` instead of `/usr/bin/open`,
  and quits once Launch Services has started it.
- **sherpa-onnx model archives** (`.tar.bz2`) are unpacked in-process:
  `VocaBZip2` (system `libbz2`) decompresses, `TarArchive` reads the tar,
  refusing absolute paths and `..`. The direct download keeps using
  `/usr/bin/tar`; `TarArchiveTests` checks the in-process path against
  archives made by the system `tar` and `bzip2`.
- **llama.cpp** (`llama.framework`) goes in `Contents/Frameworks` with an
  rpath to it, where App Store validation and re-signing look for nested code
  (the direct download keeps `Contents/lib`).
- **Save panel for logs** no longer starts in the home folder, which inside
  the sandbox is the app's container.

Unchanged and still needed: the hotkey event tap, typing and pasting text
(`CGEvent`), and reading text from other apps (`AXUIElement`). A sandboxed app
may use these once the user turns VocaMac on under Accessibility and Input
Monitoring, the same as the direct download. Model downloads (WhisperKit,
FluidAudio, sherpa-onnx, GGUF) already go to Application Support through
`FileManager`, which inside the sandbox is
`~/Library/Containers/com.vocamac.app/Data/Library/Application Support`.
Settings, history, logs and models start empty there: the App Store build
doesn't see the direct download's data.

## Entitlements

`VocaMac-AppStore.entitlements`:

| Entitlement | For |
|--|--|
| `com.apple.security.app-sandbox` | Required for the Mac App Store |
| `com.apple.security.device.audio-input` | The microphone |
| `com.apple.security.network.client` | Model downloads, the Custom Endpoint engine, AI servers on the LAN |
| `com.apple.security.files.user-selected.read-write` | Open and save panels: Transcribe File, export and import of settings, history and style rules, log export. Save panels need write access, so read-only isn't enough |
| `com.apple.security.files.bookmarks.app-scope` | Remembering the Notes export folder (an Obsidian vault, say) across launches, as a security-scoped bookmark |

No Apple Events entitlement and no temporary exceptions.

The MCP server (`--mcp`) and the community model list are left out of this
build, and imported models must be folders: unpacking a `.zip` needs
`/usr/bin/ditto`, a program outside the bundle.
`build-appstore.sh` fails if the signed app has either.

## Info.plist

The App Store build adds to the usual `Info.plist` (see `scripts/build.sh`):
`LSApplicationCategoryType` = `public.app-category.productivity`,
`ITSAppUsesNonExemptEncryption` = `false` (HTTPS and hashing only),
`NSSpeechRecognitionUsageDescription`, a numeric `CFBundleVersion` (the build
number), and the `DT*` / `BuildMachineOSBuild` keys Xcode writes, which App
Store Connect uses to check the SDK and Xcode version. It drops
`NSAppleEventsUsageDescription`. Bundle ID `com.vocamac.app`, arm64 only,
macOS 14 or later.

## Building locally

```bash
make appstore                      # or ./scripts/build-appstore.sh
```

This builds `dist/appstore/VocaMac.app` with `APP_STORE`, signs it ad hoc
with the sandbox entitlements, checks it, and wraps it in
`dist/appstore/VocaMac.xcarchive`. It uses its own derived data
(`.xcode-build-appstore`), so it never mixes with `make build`. To bundle
Whisper Tiny the way a release does, point `VOCAMAC_BUNDLED_MODEL_SOURCE` at
a folder holding `openai_whisper-tiny/` (see the model step in
`.github/workflows/appstore.yml`).

The ad-hoc copy runs sandboxed and is good for checking behaviour. Because
its signature changes on every build, macOS asks for Accessibility and Input
Monitoring again each time, as with any ad-hoc build.

## Uploading

The upload is `scripts/build-appstore.sh --upload`, run by
`.github/workflows/appstore.yml`. It exports the archive with
`method = app-store-connect`, `destination = upload` and automatic signing,
so Xcode signs with cloud-managed **Apple Distribution** and **Mac Installer
Distribution** certificates and creates the App Store provisioning profile.
No certificate needs to live in the repository.

Repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|--|--|
| `APP_STORE_CONNECT_API_KEY` | Contents of the `.p8` key file. Create it in App Store Connect → Users and Access → Integrations → App Store Connect API, with the **Admin** role (cloud signing needs it) |
| `APP_STORE_CONNECT_API_KEY_ID` | The key's Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID shown above the keys |
| `APP_STORE_TEAM_ID` | The 10-character Apple Developer Team ID |

Without all four, the workflow's gate job skips the upload on a manual run
and fails on a tag.

Before the first upload, App Store Connect needs a macOS app record for the
bundle ID `com.vocamac.app`.

To cut an upload:

1. Make sure CI is green on `main`, including **Verify App Store Bundle**.
2. Tag the commit and push the tag:

   ```bash
   git tag -a appstore/v1.2.0 -m "VocaMac 1.2.0 for the Mac App Store"
   git push origin appstore/v1.2.0
   ```

   The tag sets `CFBundleShortVersionString` (plain `MAJOR.MINOR.PATCH`, no
   suffix). The build number is the workflow's run number. Alternatively, run
   **App Store** from the Actions tab to upload the version in
   `scripts/build.sh` without a tag.
3. Wait for App Store Connect to finish processing (a few minutes; an email
   arrives), then test the build in TestFlight on a Mac.
4. Submit for review in App Store Connect. The workflow never submits.

`appstore/v*` tags don't match the `v*` tags that drive `release.yml`,
`nightly.yml` and the Homebrew cask, so an App Store upload never cuts a
GitHub Release.

## Manual test checklist

The sandbox and privacy prompts (TCC) can't be exercised in CI, which only
builds the App Store variant and launches it for 20 seconds. Before
submitting, on a Mac with no earlier VocaMac grants (or after
`tccutil reset All com.vocamac.app`), install the TestFlight build or run
`open dist/appstore/VocaMac.app` and check:

**First run and permissions**
- [ ] Onboarding opens. Allowing the **microphone** shows the system prompt and the grant sticks.
- [ ] **Accessibility**: the button opens System Settings, VocaMac is in the list (or can be dragged in from onboarding), and turning it on is picked up (after the relaunch onboarding offers, if asked).
- [ ] **Input Monitoring**: same as above; the hotkey works afterwards.
- [ ] **Restart VocaMac** (Settings › Advanced) quits and reopens one copy, still with its permissions.

**Dictation**
- [ ] With no network, dictation works right after onboarding with the bundled Whisper Tiny (no download).
- [ ] Hold-to-talk: hold the dictation key, speak, release; the text appears.
- [ ] Double-tap / hands-free start and stop.
- [ ] Text goes into **TextEdit** and **Notes** at the cursor, with and without "Restore clipboard after typing".
- [ ] Paste Last Dictation works.
- [ ] Command Mode edits selected text in TextEdit; "open Safari" and "search the web for…" work; "remind me to…" says it isn't available.

**Models**
- [ ] Download a Whisper model, a Parakeet model and a Specialized ONNX (sherpa) model; each loads and transcribes. The sherpa one exercises the in-process `.tar.bz2` extraction.
- [ ] Smart Cleanup downloads a GGUF and cleans a dictation.
- [ ] Models land under `~/Library/Containers/com.vocamac.app/Data/Library/Application Support/`.

**System**
- [ ] **Open at login**: turn it on, log out and in; VocaMac starts. Turn it off again.
- [ ] Transcribe File: open an audio file and save the transcript.
- [ ] Export and import settings; export logs.
- [ ] Mute other audio while dictating, and System Audio capture if used, still work.

**Store-specific**
- [ ] No update banner, no "Check for updates", nothing about the DMG, GitHub Releases or Homebrew in About, the menu, onboarding or the update UI.
- [ ] No Phone gateway row under Advanced, no "Pause Spotify" toggle, no "Reset permissions" row; searching Settings for "gateway", "spotify" or "updates" finds nothing.
- [ ] Console.app shows no sandbox denials (`deny`) for VocaMac during the steps above.
