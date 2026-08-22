# VocaMac — AI Coding Agent Guidelines

Agent-facing rules for this repo. Product copy lives in `README.md` and `web/`.

## Project overview

Native **macOS menu bar** dictation app (Swift 5.9+, SwiftUI). Four on-device engines; `TranscriptionRouter` dispatches to the engine that owns the selected model.

| Engine | Library / API | Runtime |
|--------|---------------|---------|
| Whisper | [WhisperKit](https://github.com/argmaxinc/WhisperKit) | OpenAI Whisper, CoreML |
| Parakeet | [FluidAudio](https://github.com/FluidInference/FluidAudio) | NVIDIA Parakeet TDT, CoreML on the Neural Engine |
| Apple Speech | SpeechAnalyzer / SpeechTranscriber | macOS 26+, system-managed assets |
| Specialized ONNX | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Moonshine, SenseVoice, GigaAM, Canary; CPU-only |

The marketing site is Hugo in `web/`, deployed to GitHub Pages at [vocamac.com](https://vocamac.com).

| | |
|--|--|
| License | AGPL-3.0 |
| Minimum OS | macOS 14 Sonoma; **Apple Silicon only** (`arm64`) |
| Build | Swift Package Manager; `.app` bundles via `scripts/build.sh` (`xcodebuild`) |
| CI | GitHub Actions (`.github/workflows/ci.yml`): app on `macos-15` + Xcode 26; site on Ubuntu |
| Website | Hugo 0.165.0 extended; deploy via `.github/workflows/deploy-website.yml` |

---

## Critical: git worktrees for every branch and PR

Never create a branch, commit, or open a pull request in the primary checkout. Always use a linked git worktree so the main working tree stays on `main` and stays clean. Do not `git switch` / `git checkout` a feature branch in the primary directory, and do not leave it dirty.

```bash
git fetch origin
git worktree add /tmp/vocamac-<task> -b <type>/<short-name> origin/main

# All edits, commits, and `gh pr create` happen inside that worktree.

git worktree remove /tmp/vocamac-<task>
git worktree prune
```

Rules:

- One worktree per branch, one branch per PR
- Place worktrees **outside** the primary working tree (`/tmp/vocamac-<task>` or a sibling directory such as `../.worktrees/vocamac-<task>`)
- Never run two tasks in the same worktree
- Never commit directly to `main`
- Clean up the worktree after the PR is pushed

---

## Repository structure

```
Sources/VocaMac/
├── App/              # VocaMacApp, MenuBarIcon, BrandAssets, DockVisibilityCoordinator
├── CLI/              # Headless --transcribe-file / --list-models (no AppState)
├── Models/           # AppState, engines, models, stats, overlay, updates
├── Services/         # Audio, hotkeys, engines, router, logger, overlay, sounds, stats, updates
├── Vendor/           # SherpaOnnxConfigBuilders (sherpa-onnx Swift config)
├── Views/            # Menu bar, settings, onboarding, stats, updates
└── Resources/        # App icon, start/stop sounds, brand bitmaps
Sources/VocaMacObjC/  # NSException catcher for AVFoundation taps
Tests/VocaMacTests/   # XCTest; Mocks/ for fakes
web/                  # Hugo site — see web/AGENTS.md
homebrew/             # Cask sources mirrored to the tap
docs/                 # ARCHITECTURE, DATA_MODEL, RELEASE, HOMEBREW (no per-version notes)
scripts/              # build, install, dist, release, uninstall, Xcode 26 select
Makefile              # make build / install / test / dmg / release / reset
Package.swift         # SPM: VocaMac + VocaMacObjC
VocaMac.entitlements  # Microphone
```

---

## Build & run

```bash
make install       # Build + install to /Applications (recommended)
make build         # .app in repo root (fast iteration)
make install-cli   # vocamac / vocamac-build → ~/.local/bin
make test          # swift test (what CI runs for the app)
make dmg           # Dist DMG → dist/
make run           # open the locally built .app
make clean
```

Scripts: `./scripts/build.sh` (dev `.app`), `./scripts/install.sh`, `./scripts/install.sh --cli`.

**macOS only** (AppKit, CoreML, AVFoundation). CI uses `scripts/select-xcode-26.sh` so Apple Speech APIs compile in.

`swift build` / `swift test` are for compile and unit tests. Shipping `.app` bundles **must** go through `scripts/build.sh` (`xcodebuild`): SPM’s `swift build` `Bundle.module` accessor does not resolve `Contents/Resources` and crashes on user machines.

---

## Architecture (for agents)

- **Single source of truth:** `AppState` (`ObservableObject` + `@Published`). Views observe and dispatch; they do not own business logic.
- **Service layer:** `Sources/VocaMac/Services/`. `TranscriptionRouter` is the `SpeechTranscribing` facade — views and `AppState` must not call Whisper / Parakeet / Apple Speech / Sherpa services directly.
- **CLI:** same executable, headless. Flags: `--transcribe-file`, `--list-models`, `--help` (`-h`). Production CLI must not construct `AppState` or start SwiftUI, mic capture, hotkeys, onboarding, or text injection.
- **ObjC helper:** `VocaMacObjC` converts `NSException` (e.g. AVAudioEngine tap install) into `NSError`. Swift cannot catch those exceptions.
- **DI:** `@EnvironmentObject` or init parameters.

---

## Code style

### Swift

- SwiftUI for views. AppKit only for system integration (windows, event taps, Accessibility, `NSImage` menu bar icon).
- Prefer `@Observable` for new types. Existing `AppState` is `ObservableObject` — match the surrounding type; do not mix styles in one object.
- `async/await` over callbacks. `guard` for early returns; avoid deep nesting.
- Follow [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/). Names: `isRecording`, not `flag`.
- `// MARK: -` sections. `///` on public types/methods and non-trivial private methods.

### Errors and logging

- Never force-unwrap (`!`) unless the value is guaranteed (e.g. system symbols).
- `do/catch` with meaningful error types. Surface user-visible failures via `AppState.appStatus = .error`.
- Log with **`VocaLogger`** (`debug` / `info` / `warning` / `error` + `LogCategory`). Do **not** use `print()`.
- Logs go to Console.app (`os.Logger`) and `~/Library/Application Support/VocaMac/logs/` (rotated files).

### Performance

- Menu bar app: stay lightweight. Prefer event-driven updates over extra timers.
- `ProcessMonitor` polls every **5 seconds** — do not add tighter polling.
- Transcription and model load off the main thread; UI updates on `@MainActor`.

---

## Testing

- New logic → `Tests/VocaMacTests/<ClassName>Tests.swift` (XCTest).
- CI app job runs `swift build` and `swift test`.
- **Test:** `AppState` transitions, service parsing/formatting/validation, Codable, CLI, Logger, edge cases (empty, nil, bounds).
- **Do not test:** SwiftUI snapshots, microphone / Accessibility / pasteboard hardware, WhisperKit / FluidAudio / sherpa-onnx internals.
- Fakes live in `Tests/VocaMacTests/Mocks/`.

---

## Website (`web/`)

See **`web/AGENTS.md`**. Short version: Hugo-generated static HTML; hand-written CSS/JS in `web/static/`; **no** React/Vue, no CSS framework, no bundler. `package.json` is check-only (`npm run check`). Product facts live in `web/data/product.toml`.

---

## Git & PR

### Branch names

`feat/<description>` · `fix/` · `ui/` · `chore/` · `docs/` · `ci/`

### Commits

[Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add CPU monitoring to popover panel
fix: menu bar icon not showing colored states
ui: enlarge popover panel for Retina displays
docs: update README badges
chore: change license to AGPL-3.0
ci: add GitHub Actions build workflow
```

### Pull requests

- **Never commit directly to `main`.** Branch in a worktree, then open a PR.
- One logical change per PR — do not bundle unrelated work.
- Descriptive title and body. PRs must pass CI before merge.
- Squash merge preferred.
- **Do not merge PRs yourself** — wait for the user to review and merge.

### Release notes — do not commit them

**Never create or commit `docs/RELEASE_NOTES_v*.md`** (or any other per-version release-notes file). They clutter the tree, go stale at ship, and duplicate the GitHub Release page.

1. Draft outside the repo (`/tmp/RELEASE_NOTES_vX.Y.Z.md`, a Gist, or the GitHub Release draft UI).
2. Reuse that draft for the version-bump PR body, `gh release create --notes-file …`, and comms.
3. Paste the final text into the GitHub Release when publishing.
4. Delete the local scratch file.

Version-bump changelog tables go in the **PR description**, not a tracked file. The GitHub Release is the source of truth (also what the in-app update checker shows). See `docs/RELEASE.md` → **Release Notes (out-of-tree)**.

---

## Dependencies

| Dependency | Purpose | Pin |
|------------|---------|-----|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | Whisper CoreML | `from: "0.9.4"` |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Parakeet CoreML / ANE | `.upToNextMinor(from: "0.15.5")` (pre-1.0) |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Specialized ONNX, CPU | revision pin (SPM not in a tagged release; xcframework v1.13.4) |

Keep dependencies minimal. Do not bump FluidAudio across a minor without checking `AsrManager.loadModels` / TDT decoder APIs.

---

## macOS specifics

- **Entitlements** (`VocaMac.entitlements`): microphone. Accessibility and Input Monitoring are TCC, not entitlements.
- **`LSUIElement`:** menu bar agent (no Dock icon). Settings / update windows use `DockVisibilityCoordinator` to show the Dock while a window needs focus.
- **Signing:** release = Developer ID + notarization. Local builds fall back to ad-hoc if no Developer ID cert is in the Keychain.
- **Permissions:** Developer ID persists TCC across updates. **Ad-hoc rebuilds reset Accessibility and Input Monitoring.**
- **MenuBarExtra:** the label may only render `Image` or `Text`. Colored icons: `NSImage` with `sourceAtop` tint and `isTemplate = false`.

---

## Common pitfalls

1. **MenuBarExtra ignores SwiftUI colors** — tint via `NSImage` + `sourceAtop`, `isTemplate = false`.
2. **`Canvas` is invisible in the menu bar label** — it works in popovers only.
3. **Browsers cache SVG/PNG aggressively** — hard-refresh (`Cmd+Shift+R`) when testing `web/`.
4. **Ad-hoc signing resets TCC** on every rebuild; expected locally, not for Developer ID releases.
5. **First download of extra models needs network** (Tiny is bundled). After that, engines run offline.
6. **Do not ship an `.app` from `swift build`** — use `make build` / `scripts/build.sh`.
