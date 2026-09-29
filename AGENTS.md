# VocaMac — AI Coding Agent Guidelines

Agent-facing rules for this repo. Product copy lives in `README.md` and `web/`.

## Commit attribution

Agents must not add themselves as commit co-authors or add `Co-authored-by`
trailers for agents.

## Project overview

Native **macOS menu bar** dictation app (Swift 5.9+, SwiftUI). Four on-device engines; `TranscriptionRouter` dispatches to the engine that owns the selected model. Optional post-transcript cleanup uses a local GGUF LLM (`TranscriptCleanupService`); views and `AppState` must not call `LLM` directly.

| Engine | Library / API | Runtime |
|--------|---------------|---------|
| Whisper | [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) | OpenAI Whisper, CoreML |
| Parakeet | [FluidAudio](https://github.com/FluidInference/FluidAudio) | NVIDIA Parakeet TDT, CoreML on the Neural Engine |
| Apple Speech | SpeechAnalyzer / SpeechTranscriber | macOS 26+, system-managed assets |
| Specialized ONNX | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Moonshine, SenseVoice, GigaAM, Canary; CPU-only |
| Cleanup (opt-in) | [LLM.swift](https://github.com/eastriverlee/LLM.swift) | Qwen / Ministral GGUF via llama.cpp Metal |

The marketing site is Hugo in `web/`, deployed to GitHub Pages at [vocamac.com](https://vocamac.com).

| | |
|--|--|
| License | AGPL-3.0 |
| Minimum OS | macOS 14 Sonoma; **Apple Silicon only** (`arm64`) |
| Build | Swift Package Manager; `.app` bundles via `scripts/build.sh` (`xcodebuild`) |
| CI | GitHub Actions (`.github/workflows/ci.yml`): app on `macos-15` + Xcode 26, plus a non-blocking macOS 27 + Xcode 27 test job; site on Ubuntu |
| Website | Hugo 0.166.0 extended; deploy via `.github/workflows/deploy-website.yml` |

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
scripts/              # build, install, dist, release, uninstall, Xcode 26 select, DMG background
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
make lint          # pinned SwiftLint, strict (CI fails on any violation)
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
- SwiftLint (`.swiftlint.yml`) must pass with `--strict`. Fix the code rather than adding `swiftlint:disable`; when a disable is warranted, scope it to the line (`disable:next`) and say why.

### Errors and logging

- Never force-unwrap (`!`) unless the value is guaranteed (e.g. system symbols).
- `do/catch` with meaningful error types. Surface user-visible failures via `AppState.appStatus = .error`.
- Log with **`VocaLogger`** (`debug` / `info` / `warning` / `error` + `LogCategory`). Do **not** use `print()`.
- Logs go to Console.app (`os.Logger`) and `~/Library/Application Support/VocaMac/logs/` (rotated files). Test runs write to `$TMPDIR/VocaMac-tests/logs/` instead, so `swift test` never touches the app's logs.

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
| [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (Argmax OSS SDK) | Whisper CoreML | `.upToNextMinor(from: "1.1.0")` |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Parakeet CoreML / ANE | `.upToNextMinor(from: "0.15.7")` (pre-1.0) |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Specialized ONNX, CPU | exact `1.13.8` (matching xcframework) |
| [LLM.swift](https://github.com/eastriverlee/LLM.swift) | GGUF cleanup (llama.cpp) | exact `3.0.3` (vendors a pinned llama.cpp xcframework) |

Cleanup models must not use a hybrid attention/recurrent architecture. Read `general.architecture` from the GGUF header: `qwen2`, `qwen3`, `mistral3`, `llama`, `gemma3` and `granite` are fine, `qwen35` is not. LLM.swift reuses the llama.cpp KV cache between calls and drops the non-shared suffix with `llama_memory_seq_rm`, which is wrong for hybrid attention/recurrent architectures (`qwen35`): Qwen 3.5 0.8B answered the first utterance and returned empty output for the next seven, and `LLM.reset()` aborts the process inside `llama_memory_recurrent::find_slot`. Measure any new model as well as checking its architecture — of eight small GGUFs benchmarked on the cleanup probes, Qwen 2.5 0.5B and Qwen 3 0.6B were the only ones worth shipping; Llama 3.2 3B scored no better at four times the size. For models that serve both cleanup and Command Mode, a later run (22 cleanup and 19 Command Mode probes, M1 Pro) put Ministral 3 3B level with Qwen 3 4B on cleanup at less memory, one probe behind it on Command Mode, and ahead of Qwen 3 1.7B and SmolLM3 3B. Granite 4.0 Micro and Llama 3.2 3B matched its total but translated German and French dictation to English (Granite, and Qwen 3 4B too) or dropped words (Llama). Read the outputs, not just pass counts: a tone rewrite that becomes a letter with `[Recipient's Name]` can pass naive checks. A supported architecture is not proof the model runs: Granite 4.0 1B generated only `@` on the pinned llama.cpp build.

Keep dependencies minimal. Do not bump FluidAudio across a minor without checking `AsrManager.loadModels` / TDT decoder APIs. Do not unpin LLM.swift to a branch or a bare `revision:` — pin the release tag so the vendored llama.cpp xcframework moves only on a deliberate bump.

`Package.resolved` is **tracked**, not ignored. Release builds resolve from a clean checkout, so the lockfile is the only thing that makes a tagged build reproducible. Commit it with any dependency change, and never add it back to `.gitignore`.

### GitHub Actions

- Pin every third-party action to a full commit SHA with the version in a trailing comment: `uses: actions/checkout@<sha> # v7.0.1`. Dependabot bumps both. Reusable workflows from `VocaHQ/*` may track `main`.
- Start new workflows at `permissions: {}` (or `contents: read`) and grant write scopes on the job that needs them.
- Pass `${{ … }}` values into `run:` scripts through `env:`, never inline.
- Check out with `persist-credentials: false` unless a later step pushes with that token.
- Run `zizmor .github/workflows` before pushing a workflow change; CI reports its findings to code scanning.

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
7. **`swift package resolve` failing on binary-artifact checksums** usually means a truncated download in the shared SwiftPM cache, not a tampered or re-uploaded release. Clear the offending entries and resolve again:

   ```bash
   find ~/Library/Caches/org.swift.swiftpm/artifacts -maxdepth 1 -iname "*onnxruntime*" -exec rm -rf {} +
   swift package resolve
   ```
