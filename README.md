<p align="center">
  <img src="web/static/brand/voca-logo-512.png" alt="VocaMac" width="128" height="128">
</p>

<h1 align="center">VocaMac</h1>

<p align="center"><strong>Your voice, your Mac, your privacy. Open-source dictation powered by AI.</strong></p>

<div align="center">
  
[![Build & Test](https://github.com/VocaHQ/vocamac/actions/workflows/ci.yml/badge.svg)](https://github.com/VocaHQ/vocamac/actions/workflows/ci.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS%2014%2B-lightgrey.svg)](https://github.com/VocaHQ/vocamac)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Release](https://img.shields.io/github/v/release/VocaHQ/vocamac?include_prereleases&label=Release)](https://github.com/VocaHQ/vocamac/releases)
[![Nightly](https://img.shields.io/badge/Nightly-download-blueviolet)](https://github.com/VocaHQ/vocamac/releases/tag/nightly)

[![Powered by WhisperKit](https://img.shields.io/badge/Powered%20by-WhisperKit-blueviolet.svg)](https://github.com/argmaxinc/WhisperKit)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-Optimized-black.svg?logo=apple&logoColor=white)](https://github.com/VocaHQ/vocamac)
[![Privacy](https://img.shields.io/badge/Privacy-100%25%20Local-brightgreen.svg)](https://github.com/VocaHQ/vocamac)
[![Works Offline](https://img.shields.io/badge/Works-Offline-success.svg)](https://github.com/VocaHQ/vocamac)

[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/VocaHQ/vocamac/pulls)
[![GitHub Issues](https://img.shields.io/github/issues/VocaHQ/vocamac)](https://github.com/VocaHQ/vocamac/issues)
[![GitHub Stars](https://img.shields.io/github/stars/VocaHQ/vocamac?style=social)](https://github.com/VocaHQ/vocamac/stargazers)
[![Twitter Follow](https://img.shields.io/twitter/follow/jatinkrmalik?style=social)](https://x.com/intent/user?screen_name=jatinkrmalik)
[![Discord](https://img.shields.io/discord/1538633755877580810?logo=discord&logoColor=white&label=Discord)](https://discord.gg/UMJduhcqn)
[![VocaHQ](https://img.shields.io/badge/VocaHQ-vocahq.com-1a7f4e)](https://vocahq.com)

</div>

<p align="center">Speak. It types. 100% offline, open-source voice-to-text for macOS - powered by WhisperKit. No cloud, no subscriptions, no data leaves your device. Just hold a hotkey, speak, and your words appear wherever your cursor is.</p>

---

## ✨ Features

- **🔒 100% Local** - All audio processing happens on your machine. No internet required — the Tiny model ships bundled and works out of the box offline.
- **⌨️ System-Wide Text Injection** - Transcribed text is typed wherever your cursor is: browsers, Slack, VS Code, spreadsheets, terminals - everywhere.
- **🎯 Push-to-Talk** - Hold a hotkey (default: Right Option) to record. Release to transcribe.
- **👆 Double-Tap Toggle** - Double-tap the hotkey to start/stop recording.
- **🧠 Smart Model Selection** - Auto-detects your Apple Silicon chip and RAM, then recommends the best whisper model via WhisperKit.
- **⚡ Native Apple Acceleration** - CoreML + Metal + Neural Engine acceleration on Apple Silicon. No manual setup.
- **📊 Visual Feedback** - Menu bar icon changes color during recording and processing. Audio level indicator shows input.
- **🔄 Auto-Updates** - Built-in update checker queries GitHub Releases on launch and lets you download and install the latest version in one click from within the app.
- **⚙️ Configurable** - Choose hotkey presets or record a custom activation key reserved by VocaMac while it runs, models, languages, silence detection thresholds, and more.

---

## 📸 Screenshots

<p align="center">
  <img src="docs/screenshots/popover-panel.png" alt="VocaMac Popover" width="400">
  <br>
  <em>Menu bar popover with status and controls</em>
</p>

<p align="center">
  <img src="docs/screenshots/menu-bar-idle.png" alt="Menu Bar - Idle" width="250">
  &nbsp;&nbsp;
  <img src="docs/screenshots/menu-bar-recording.png" alt="Menu Bar - Recording" width="250">
  <br>
  <em>Menu bar icon: idle (left) and recording (right)</em>
</p>

<p align="center">
  <img src="docs/screenshots/settings-general.png" alt="Settings - General" width="400">
  &nbsp;&nbsp;
  <img src="docs/screenshots/settings-models.png" alt="Settings - Models" width="400">
  <br>
  <em>Settings: General tab (left) and Models tab with resource monitoring (right)</em>
</p>

<p align="center">
  <img src="docs/screenshots/settings-audio.png" alt="Settings - Audio" width="400">
  &nbsp;&nbsp;
  <img src="docs/screenshots/settings-about.png" alt="Settings - About" width="400">
  <br>
  <em>Settings: Audio tab (left) and About tab (right)</em>
</p>

<p align="center">
  <img src="docs/screenshots/cursor-indicator.png" alt="Cursor Indicator" width="400">
  <br>
  <em>Floating mic indicator near text cursor during recording</em>
</p>

---

## 🏛️ Why WhisperKit?

VocaMac uses [WhisperKit](https://github.com/argmaxinc/WhisperKit) instead of raw whisper.cpp because:

| | WhisperKit | whisper.cpp |
|---|-----------|-------------|
| **Language** | Pure Swift (native) | C++ (requires bridging) |
| **Apple Silicon** | CoreML + Neural Engine | Metal only |
| **SPM Integration** | One-line dependency | Complex vendoring |
| **Model Format** | CoreML (optimized per device) | GGML (generic) |
| **Streaming** | First-class async/await | Manual threading |
| **Quality** | Same OpenAI Whisper models | Same OpenAI Whisper models |
| **Maintenance** | Argmax Inc. (commercial) | Community |

Same accuracy, dramatically better Apple platform integration.

---

## 📋 Requirements

- **macOS 14 (Sonoma)** or later
- **Apple Silicon Mac** (M1/M2/M3/M4) — **Intel Macs are not supported.** VocaMac is built for `arm64` only.
- **Xcode 15+** or Swift 5.9+ (only for building from source)

### Permissions

VocaMac requires three macOS permissions:

| Permission | Why |
|---|---|
| **Microphone** | Capture your voice for transcription |
| **Accessibility** | Global hotkeys and text injection into apps |
| **Input Monitoring** | Detect hotkey presses system-wide |

> **Note:** After granting Input Monitoring, a restart of VocaMac is required for it to take effect.

---

## 🚀 Quick Start

### Option 1: Install via Homebrew (Recommended)

```bash
brew tap vocahq/vocamac
brew trust vocahq/vocamac
brew install --cask vocamac
```

> **Still have the old tap?** If you previously used `jatinkrmalik/vocamac`, untap it first or Homebrew will error with `Cask vocamac exists in multiple taps`:
> ```bash
> brew untap jatinkrmalik/vocamac
> brew tap vocahq/vocamac && brew trust vocahq/vocamac && brew install --cask vocamac
> ```

Homebrew installs VocaMac to `/Applications/VocaMac.app`. Launch it from Spotlight or your Applications folder. Updates are a single command away:

```bash
brew upgrade --cask vocamac
```

> **Why Homebrew?** Terminal-based install. One-command updates. Permissions persist across upgrades. No manual DMG downloads. See [`docs/HOMEBREW.md`](docs/HOMEBREW.md) for the full Homebrew guide.

### Option 2: Download DMG

1. **Download** the latest `VocaMac-x.x.x-arm64.dmg` from the [Releases page](https://github.com/VocaHQ/vocamac/releases)
2. **Open** the DMG and drag VocaMac to Applications
3. **Open** VocaMac from Applications
4. **Grant permissions**: Microphone, Accessibility, and Input Monitoring when prompted

> VocaMac is **Developer ID signed and notarized** by Apple — macOS will open it without any security warnings.

### Option 3: Build from Source

```bash
git clone https://github.com/VocaHQ/vocamac.git
cd vocamac
make install
```

This builds VocaMac, installs it to `/Applications`, and launches it. Permissions are granted directly to VocaMac, just like the DMG method.

### Option 4: Launch/Build Helper Commands (For Developers)

```bash
git clone https://github.com/VocaHQ/vocamac.git
cd vocamac
make install-cli
```

This installs two development helpers to `~/.local/bin`:

- `vocamac &`: Launch VocaMac in background
- `vocamac-build`: Rebuild from source after pulling updates

These are launch/build helpers, not the headless transcription interface described below. Because the launcher runs a development binary from Terminal, macOS may assign its GUI permissions to the terminal app rather than the installed VocaMac app.

### Headless File Transcription CLI

The installed app binary can transcribe an existing audio file without opening the GUI, recording the microphone, injecting text, or disturbing an already-running VocaMac instance:

```bash
/Applications/VocaMac.app/Contents/MacOS/VocaMac \
  --transcribe-file /path/to/audio.wav \
  --json
```

By default, the command follows the model and language currently selected in the VocaMac app. `auto` language selection is passed to the engine as automatic detection. You can override either choice for one request without changing the saved app preferences:

```bash
/Applications/VocaMac.app/Contents/MacOS/VocaMac \
  --transcribe-file /path/to/audio.wav \
  --model parakeet-tdt-0.6b-v2 \
  --language en \
  --json
```

The model must already be downloaded in VocaMac. Headless mode never downloads a missing model automatically. Input is validated and converted with AVFoundation to mono, 16 kHz, Float32 PCM; files are limited to 500 MB and 30 minutes.

Only the selected model and language follow your app preferences. Translate-to-English and WhisperKit custom vocabulary are always off in headless mode, even if enabled in the app.

Successful transcription writes exactly one JSON object to stdout:

```json
{
  "audio_length_seconds": 4.3,
  "detected_language": "en",
  "duration_seconds": 0.72,
  "engine": "parakeet",
  "model": "parakeet-tdt-0.6b-v2",
  "text": "Transcribed text"
}
```

`engine` is one of `whisperkit`, `parakeet`, `apple_speech`, or `sherpa_onnx`. Operational messages continue to VocaMac's unified and file logs, keeping stdout safe for JSON consumers such as VocaPhone.

List every known model and its current state with:

```bash
/Applications/VocaMac.app/Contents/MacOS/VocaMac --list-models --json
```

The response is a `models` array whose entries have this schema:

```json
{
  "id": "parakeet-tdt-0.6b-v2",
  "name": "Parakeet v2 (English)",
  "engine": "parakeet",
  "selected": true,
  "downloaded": true,
  "supported": true,
  "system_managed": false
}
```

Failures exit nonzero and write a JSON error to stderr, for example:

```json
{"error":"model_not_downloaded","message":"Model is not downloaded: small"}
```

Stable error categories are `invalid_arguments`, `invalid_audio`, `model_not_found`, `model_not_downloaded`, `model_unsupported`, and `transcription_failed`. Use `--help` for command syntax; it exits without launching the GUI.

One-shot CLI mode loads the selected model in a separate process for each request. This preserves isolation from the running menu bar app, but the first request has the normal model-loading cost.

### First Launch

1. **VocaMac appears in your menu bar** (microphone icon, no Dock icon)
2. **Grant permissions**: Microphone, Accessibility, and Input Monitoring (see [Permissions](#permissions) above)
3. **First model download**: WhisperKit automatically downloads the recommended model for your device (~40–500 MB depending on hardware)
4. **Start dictating**: Hold the **Right Option** key, speak, and release. Your words appear at the cursor!

---

## 🌙 Nightly Builds

Nightly builds are automated builds from the latest `main` branch, published every day at midnight UTC when there are new commits. They let you try the latest features, fixes, and improvements before they land in a stable release.

**Why use a nightly build?**

- **Early access** — Test new features days or weeks before the next stable release
- **Help improve VocaMac** — Your feedback on nightly builds catches bugs before they reach everyone
- **Fully signed & notarized** — Nightly builds are Developer ID signed and notarized by Apple, just like stable releases. No Gatekeeper warnings, no right-click workarounds

**How to install:**

**Via Homebrew (recommended):**
```bash
brew tap vocahq/vocamac
brew trust vocahq/vocamac
brew install --cask vocamac-nightly
```

**Or via DMG:**
1. Download the latest `VocaMac-nightly-*.dmg` from the [Nightly Release](https://github.com/VocaHQ/vocamac/releases/tag/nightly)
2. Open the DMG and drag VocaMac to Applications
3. Grant permissions when prompted (same as a stable release)

**How to identify your build:**

Nightly builds embed the date and commit SHA in the version string. Open **Settings → About** to see something like:

```
Version 0.5.0-nightly.20260414+abc1234 (Nightly)
```

This helps us pinpoint the exact code you're running if you report an issue.

**Cadence & stability:**

| | Stable Release | Nightly Build |
|---|---|---|
| **Frequency** | When ready (manual tag) | Daily at midnight UTC |
| **Source** | Tagged commit | Latest `main` branch |
| **Signed & notarized** | ✅ Yes | ✅ Yes |
| **Stability** | Production-ready | May contain incomplete features or bugs |
| **Best for** | Daily use | Testing & early feedback |

> ⚠️ **Nightly builds may be unstable.** If you encounter issues, please [open a bug report](https://github.com/VocaHQ/vocamac/issues/new) — your feedback helps us ship better stable releases!

---

## 🎮 Usage

### Push-to-Talk (Default)

| Action | What Happens |
|--------|-------------|
| **Hold Right Option** | Recording starts (menu bar icon turns red) |
| **Speak** | Audio is captured locally |
| **Release Right Option** | Recording stops → transcription → text injected at cursor |

### Double-Tap Toggle

| Action | What Happens |
|--------|-------------|
| **Double-tap Right Option** | Recording starts |
| **Speak** | Audio is captured |
| **Double-tap Right Option again** | Recording stops → transcription → text injection |

Switch between modes in **Settings → General → Activation**.

---

## 🧠 Models

VocaMac runs four on-device speech engines and picks between them in **Settings → Models**, where models are grouped by engine. Everything runs locally.

### Parakeet — fastest, recommended for dictation

NVIDIA Parakeet TDT models running as CoreML on the Apple Neural Engine (via [FluidAudio](https://github.com/FluidInference/FluidAudio)).

| Model | Size | Speed | Languages |
|-------|------|-------|-----------|
| **Parakeet v3** | ~0.7 GB | ⚡⚡⚡⚡⚡ | 25 European languages + Japanese, auto-detected |
| **Parakeet v2** | ~1.2 GB | ⚡⚡⚡⚡⚡ | English only, highest recall |
| **Parakeet 110M** | ~0.2 GB | ⚡⚡⚡⚡⚡ | English only, smaller download and faster first load |

### Whisper — widest language coverage

OpenAI Whisper models via WhisperKit's CoreML format. The only engine that supports **translation to English** and **custom vocabulary**. The app auto-detects your hardware and recommends a variant.

| Model | Parameters | Size | Speed | Quality | Best For |
|-------|-----------|------|-------|---------|----------|
| **Tiny** | 39M | ~0.4 GB | ⚡⚡⚡⚡⚡ | Good | Quick notes, older Macs |
| **Base** | 74M | ~0.8 GB | ⚡⚡⚡⚡ | Better | Daily use on 8GB Macs |
| **Small** | 244M | ~1.5 GB | ⚡⚡⚡ | Great | 16GB+ Apple Silicon |
| **Medium** | 769M | ~2.5 GB | ⚡⚡ | Excellent | 24GB+ for high accuracy |
| **Large v3** | 1550M | ~4.8 GB | ⚡ | Best | Maximum accuracy |

### Apple Speech — managed by macOS (macOS 26+)

Apple's on-device SpeechAnalyzer engine. Assets are managed by macOS (language packs may download on first use) and are not stored in VocaMac's model folder. Covers roughly 30 locales.

### Specialized (ONNX) — niche needs

Community models via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). These run on the **CPU**, so on Apple Silicon prefer Parakeet unless you need one of these specifically.

| Model | Size | Best For |
|-------|------|----------|
| **Moonshine v2 Tiny** | ~60 MB | Very low-RAM Macs, English |
| **Moonshine v2 Base** | ~190 MB | Low-RAM Macs, English |
| **SenseVoice** | ~240 MB | Chinese, Japanese, Korean, Cantonese, English |
| **GigaAM v3** | ~270 MB | Russian, with punctuation |
| **Canary 180M Flash** | ~320 MB | English, Spanish, German, French |

Recordings longer than a model's single-pass limit are split at natural pauses and decoded segment by segment, since these models — unlike Whisper and Parakeet — do not chunk internally.

Models download automatically on first use and are cached locally — Whisper and Parakeet from [HuggingFace](https://huggingface.co/argmaxinc/whisperkit-coreml), the specialized models from sherpa-onnx's model releases.

> **Note:** SenseVoice and Canary fix their language when the model loads, so changing the transcription language reloads the active model. Whisper and Parakeet take the language per transcription.

---

## ⚙️ Configuration

Open Settings from the menu bar popover or with **⌘,**

### General
- **Activation mode** - Push-to-Talk or Double-Tap Toggle
- **Hotkey** - Choose from common presets or record a custom activation key directly from your keyboard. The selected key is consumed by VocaMac while the app is running.
- **Language** - Auto-detect or specify (English, Spanish, French, German, Chinese, Japanese, and more)
- **Launch at login**

### Audio
- **Max recording duration** - 30s, 60s, 120s, or 300s
- **Silence detection** - Auto-stop recording after configurable silence
- **Sound effects** - Toggle audio feedback for recording start/stop
- **Input device** - Select which microphone to use

### Models
- View system info and WhisperKit's hardware recommendation
- Download, load, and switch between models
- See which models are supported on your device

---

## 🏗️ Architecture

VocaMac is built with a clean, modular architecture using native Swift and SwiftUI:

```
VocaMacMain (pre-SwiftUI dispatcher)
├── CLIEntrypoint
│   ├── AudioFileLoader       - Existing-file validation and 16 kHz mono conversion
│   ├── ModelManager          - Saved model resolution and local-asset checks
│   └── TranscriptionRouter   - Whisper, Parakeet, Apple Speech, and sherpa-onnx
└── VocaMacApp (SwiftUI MenuBarExtra)
    ├── AppState              - Central observable state
    ├── HotKeyManager         - CGEventTap global hotkey listener
    ├── AudioEngine           - AVAudioEngine mic capture (16 kHz, mono, Float32)
    ├── SoundManager          - Audio feedback (start/stop recording cues)
    ├── TextInjector          - Clipboard + Cmd+V text injection
    ├── MenuBarView           - Status popover UI
    └── SettingsView          - Configuration tabs (General, Models, Audio, Debug, About)
```

For detailed documentation, see:
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) - Technical Architecture
- [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md) - Data Model & Entity Relationships

---

## 🔧 Development

### Prerequisites

- **Xcode 15+** or Swift 5.9+ toolchain
- **macOS 14+**

### Project Structure

```
VocaMac/
├── Package.swift                   # SPM config (WhisperKit, FluidAudio, sherpa-onnx)
├── Sources/
│   └── VocaMac/
│       ├── App/
│       │   └── VocaMacApp.swift    # SwiftUI MenuBarExtra app
│       ├── CLI/
│       │   ├── CLIEntrypoint.swift # Process dispatcher and headless execution
│       │   ├── HeadlessTranscriber.swift # Model resolution and router orchestration
│       │   └── AudioFileLoader.swift # File validation and PCM conversion
│       ├── Views/
│       │   ├── MenuBarView.swift   # Menu bar popover
│       │   └── SettingsView.swift  # Settings window (5 tabs)
│       ├── Services/
│       │   ├── AudioEngine.swift   # AVAudioEngine mic capture
│       │   ├── HotKeyManager.swift # CGEventTap global hotkeys
│       │   ├── WhisperService.swift# WhisperKit transcription wrapper
│       │   ├── ModelManager.swift  # Model download & management
│       │   ├── SoundManager.swift  # Audio feedback for recording
│       │   ├── TextInjector.swift  # Clipboard-based text injection
│       │   └── SystemInfo.swift    # Hardware detection
│       ├── Models/
│       │   ├── AppState.swift      # Central observable state
│       │   ├── TranscriptionResult.swift  # VocaTranscription type
│       │   └── WhisperModel.swift  # ModelSize enum, WhisperModelInfo
│       └── Resources/
├── Tests/
│   └── VocaMacTests/
├── Makefile                        # make build, install, test, clean
├── scripts/
│   ├── build.sh                    # Build .app bundle (dev)
│   ├── install.sh                  # Install app or development helpers
│   └── uninstall.sh                # Full uninstall & cleanup
├── web/                            # Marketing website (vocamac.com)
├── docs/
│   ├── ARCHITECTURE.md             # Technical Architecture
│   └── DATA_MODEL.md               # Data Model & Entity Relationships
├── LICENSE                         # AGPL-3.0 License
└── .gitignore
```

### Build Commands

```bash
make install        # Build + install to /Applications (recommended)
make install-cli    # Install CLI commands to ~/.local/bin
make build          # Build .app bundle in repo root (dev iteration)
make test           # Run tests
make run            # Launch the locally built .app
make clean          # Remove build artifacts
make help           # Show all commands
```

### Uninstall

To completely remove VocaMac and all its data (downloaded models, preferences, caches):

```bash
./scripts/uninstall.sh
```

Use `--keep-build` to preserve build artifacts:

```bash
./scripts/uninstall.sh --keep-build
```

### Troubleshooting

**Reset onboarding:** To re-trigger the first-launch onboarding wizard (e.g., after an upgrade or for testing), reset the onboarding flag:

```bash
defaults delete com.vocamac.app vocamac.hasCompletedOnboarding
```

Then relaunch VocaMac. This only clears the onboarding state; all other preferences (hotkey, language, model) are preserved.

**Reset all preferences:** To start completely fresh:

```bash
defaults delete com.vocamac.app
```

**Reset permissions (troubleshooting):** If permissions appear stuck or aren't being recognized after an update, you can reset them from **Settings → Debug → Reset All Permissions**, or manually via Terminal:

```bash
tccutil reset All com.vocamac.app
```

This clears all permission entries (Microphone, Accessibility, Input Monitoring) for VocaMac. On next launch, macOS will prompt you to re-grant them. With Developer ID signing, permissions normally persist across updates — this reset is only needed for troubleshooting.

**"Update check failed (HTTP 403)" on a shared / corporate / VPN network:** VocaMac checks for new releases by calling GitHub's public REST API, which is rate-limited to **60 unauthenticated requests per hour, per source IP**. When several people share the same egress IP (common on office VPNs, NAT'd networks, or busy CI runners), that quota is collectively exhausted and GitHub returns `HTTP 403` to every client from that IP — including VocaMac.

This is **not a bug in VocaMac** and there is nothing wrong with your install. To recover:

1. Disconnect from the VPN (or switch to a different network, e.g. your phone's hotspot).
2. Open VocaMac → **Settings → About → "Check for Updates…"** and wait for it to complete.
3. Reconnect to the VPN.

After one successful check, VocaMac caches the response's `ETag` and sends it as `If-None-Match` on every subsequent request. GitHub then replies with `304 Not Modified`, which **does not count against the rate limit**, so future checks succeed even from a rate-limited IP — until a new release ships and the ETag changes (at which point one fresh `200` response per machine is needed before `304`s resume).

---


## 🌐 Cross-Platform

VocaMac is the macOS member of the Voca family:

| Platform | Project | Status |
|----------|---------|--------|
|  Linux | [VocaLinux](https://github.com/VocaHQ/vocalinux) | ✅ Available |
|  macOS | [VocaMac](https://github.com/VocaHQ/vocamac) | 🚀 Beta |
| 🪟 Windows | [VocaWin](https://vocawin.com) | 📋 Planned |
| 📱 Phone | [VocaPhone](https://vocaphone.vocahq.com) | Android beta / iOS source build |
| 🔌 Gateway | [VocaGateway](https://github.com/VocaHQ/vocagateway) | Early |

Each platform uses native technologies for the best possible integration, while sharing the same UX patterns and Whisper model family.

---

## 🤝 Related Projects

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) - Swift native on-device speech recognition
- [VocaLinux](https://github.com/VocaHQ/vocalinux) - Voice-to-text for Linux
- [OpenAI Whisper](https://github.com/openai/whisper) - Original Whisper model

---

## ⚠️ Known Limitations

- **Larger models require a one-time download**: VocaMac ships with the Whisper Tiny model bundled — you can dictate immediately with no internet connection. Switching to a larger model (Small, Medium, Large) requires a one-time download; all subsequent launches work fully offline.
- **macOS only**: Requires macOS 14 (Sonoma) or later.
- **Permissions reset on rebuild (build-from-source only)**: When building from source without a Developer ID certificate, macOS resets Accessibility and Input Monitoring permissions on every rebuild due to ad-hoc signing. Release builds are Developer ID signed so permissions persist across updates.

### Permissions and Code Signing

Release builds of VocaMac are **Developer ID signed and notarized** by Apple. Accessibility and Input Monitoring permissions persist across updates — no manual re-granting required.

**For developers building from source:** If you don't have a Developer ID certificate, `build.sh` falls back to ad-hoc signing. With ad-hoc signing, macOS resets Accessibility and Input Monitoring permissions on every rebuild because the CDHash changes. This is standard macOS security behavior — all open-source apps with Accessibility (Rectangle, Maccy, AltTab, etc.) have the same limitation when ad-hoc signed.

**Workarounds for ad-hoc builds:**

| Approach | How | Permissions Persist |
|---|---|---|
| **Run from Terminal** | Grant permissions to Terminal.app once, then run `make run` | ✅ Always |
| **Re-grant manually** | System Settings → Privacy & Security after each rebuild | Per rebuild |

> **💡 Developer tip:** Add your Terminal app (Terminal.app or iTerm2) to both Accessibility and Input Monitoring in System Settings. Then run VocaMac directly from Terminal. Permissions are inherited and never reset.

---

## 📄 License

AGPL-3.0 License - see [LICENSE](LICENSE) for details.

## Star History

<a href="https://www.star-history.com/?repos=VocaHQ%2Fvocamac&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=VocaHQ/vocamac&type=date&theme=dark&legend=top-left&sealed_token=otfG_PjqVtfSDqjuVxBihRMsoeuZwc0ZnUdPqNX9TypLSfyjI0QHWwkE-IVtel80QH3TtIRZzDSNYISJ_tYCHQjqN5fWBUY028tmOiUPvH_MIJroI3Kidg" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=VocaHQ/vocamac&type=date&legend=top-left&sealed_token=otfG_PjqVtfSDqjuVxBihRMsoeuZwc0ZnUdPqNX9TypLSfyjI0QHWwkE-IVtel80QH3TtIRZzDSNYISJ_tYCHQjqN5fWBUY028tmOiUPvH_MIJroI3Kidg" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=VocaHQ/vocamac&type=date&legend=top-left&sealed_token=otfG_PjqVtfSDqjuVxBihRMsoeuZwc0ZnUdPqNX9TypLSfyjI0QHWwkE-IVtel80QH3TtIRZzDSNYISJ_tYCHQjqN5fWBUY028tmOiUPvH_MIJroI3Kidg" />
 </picture>
</a>

---

<div align="center">
  
Made with ❤️ for the macOS community!

</div>
