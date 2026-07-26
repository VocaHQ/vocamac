# VocaMac — AI Coding Agent Guidelines

## Project Overview

VocaMac is a **native macOS menu bar application** for local voice-to-text dictation, built with **Swift 5.9+** and **SwiftUI**. It uses **WhisperKit** (CoreML-based) for on-device speech recognition. The project also includes a **static marketing website** (`web/`) deployed to GitHub Pages at [vocamac.com](https://vocamac.com).

- **License:** AGPL-3.0
- **Minimum target:** macOS 13 (Ventura)
- **Build system:** Swift Package Manager
- **CI:** GitHub Actions (`.github/workflows/ci.yml`)
- **Website deployment:** GitHub Pages via release trigger (`.github/workflows/deploy-website.yml`)

---

## Critical Rule: Use Git Worktrees for Parallel Tasks

**When asked to perform multiple unrelated tasks simultaneously, ALWAYS use git worktrees.**

```bash
# Create worktrees in /tmp — never pollute the main workspace
git worktree add /tmp/vocamac-<task-name> -b <branch-name> main

# After work is complete, clean up
git worktree remove /tmp/vocamac-<task-name>
git worktree prune
```

**Why:** Concurrent work on the same directory causes branch conflicts, overwritten files, and corrupted state. Each worktree gets its own isolated copy of the repo on its own branch.

**Rules:**
- Create worktrees in `/tmp/` with the prefix `vocamac-`
- One worktree per branch, one branch per PR
- Always prune worktrees after pushing and creating PRs
- Never modify files in the main workspace when worktrees are active for that task

---

## Repository Structure

```
VocaMac/
├── Sources/VocaMac/
│   ├── App/              # App entry point, MenuBarExtra, MenuBarIcon
│   ├── Models/           # AppState, TranscriptionResult, WhisperModel
│   ├── Services/         # AudioEngine, HotKeyManager, ModelManager,
│   │                     #   SystemInfo, TextInjector, WhisperService
│   ├── Views/            # MenuBarView, SettingsView
│   └── Resources/        # Bundled resources (.gitkeep placeholder)
├── Tests/VocaMacTests/   # Unit tests
├── web/                  # Static website (HTML/CSS/JS, deployed to GitHub Pages)
├── Makefile              # make build, install, test, clean
├── scripts/              # build.sh, install.sh, uninstall.sh
├── docs/                 # ARCHITECTURE.md, DATA_MODEL.md, PRD.md
├── Package.swift         # SPM manifest
└── VocaMac.entitlements  # App sandbox entitlements
```

---

## Build & Run

```bash
# Build + install to /Applications (recommended)
make install

# Build .app bundle in repo root (fast dev iteration)
make build

# Install CLI commands to ~/.local/bin
make install-cli

# Run tests
make test

# Clean build artifacts
make clean
```

Or use the scripts directly:

```bash
./scripts/build.sh              # Build .app bundle (dev)
./scripts/install.sh            # Build + install to /Applications
./scripts/install.sh --cli      # Install CLI commands
```

The project builds on **macOS only** (requires AppKit, CoreML, AVFoundation). CI runs on `macos-15`.

---

## Code Style & Best Practices

### Swift Conventions
- Use **SwiftUI** for all views — no AppKit views unless absolutely necessary for system integration
- Use **`@Observable`** (or `ObservableObject` with `@Published`) for state management
- Prefer **`async/await`** over callbacks and closures for asynchronous work
- Use **`guard`** for early returns; avoid deep nesting
- Follow Apple's [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- Use meaningful names: `isRecording` not `flag`, `audioLevel` not `val`
- Mark sections with `// MARK: -` for organization
- Add doc comments (`///`) on all public types, methods, and non-trivial private methods

### Architecture Patterns
- **Single source of truth:** `AppState` is the central observable state object
- **Service layer:** Business logic lives in `Services/` (AudioEngine, WhisperService, etc.)
- **Views are thin:** Views observe state and dispatch actions — no business logic in views
- **Dependency injection:** Pass dependencies via `@EnvironmentObject` or init parameters

### Error Handling
- Never force-unwrap (`!`) unless the value is guaranteed (e.g., system symbols)
- Use `do/catch` with meaningful error types
- Surface errors to the user via `AppState.appStatus = .error` with clear messages
- Log errors with `print()` (we don't have a logging framework yet — use descriptive prefixes like `[AudioEngine]`, `[WhisperService]`)

### Performance
- This is a **menu bar app** — it must be lightweight and responsive
- Avoid unnecessary polling; prefer event-driven updates
- `ProcessMonitor` polls every 5 seconds — don't add more frequent timers
- Heavy work (transcription, model loading) runs on background threads
- UI updates must dispatch to `@MainActor`

---

## Testing Requirements

### Test Coverage
- **All new logic must have corresponding tests** in `Tests/VocaMacTests/`
- Test file naming: `<ClassName>Tests.swift` (e.g., `WhisperServiceTests.swift`)
- Use **XCTest** framework
- Run tests with `swift test` — this is what CI executes

### What to Test
- Model logic and state transitions in `AppState`
- Service layer methods (parsing, formatting, validation)
- Data model encoding/decoding
- Edge cases: empty input, nil values, boundary conditions

### What NOT to Test
- SwiftUI view rendering (no snapshot tests currently)
- System APIs (microphone, accessibility, pasteboard) — these require real hardware
- WhisperKit internals — that's a third-party dependency

---

## Website (`web/`)

- **Pure HTML/CSS/JS** — no build tools, no frameworks, no npm
- Served as static files from the `web/` directory
- Deployed to GitHub Pages on release via `.github/workflows/deploy-website.yml`
- Custom domain: `vocamac.com` (configured via `web/CNAME`)
- Logo: `web/logo.png` — SF Symbol `mic.fill` rendered in #007AFF (Apple system blue)
- Supports light/dark theme toggle
- Test locally: `cd web && python3 -m http.server 8080`

---

## Git & PR Workflow

### Branch Naming
- `feat/<description>` — new features
- `fix/<description>` — bug fixes
- `ui/<description>` — UI/UX improvements
- `chore/<description>` — maintenance, config, tooling
- `docs/<description>` — documentation updates
- `ci/<description>` — CI/CD changes

### Commit Messages
Follow [Conventional Commits](https://www.conventionalcommits.org/):
```
feat: add CPU monitoring to popover panel
fix: menu bar icon not showing colored states
ui: enlarge popover panel for Retina displays
docs: update README badges
chore: change license to AGPL-3.0
ci: add GitHub Actions build workflow
```

### Pull Requests
- **NEVER commit directly to main** — always create a feature branch and raise a PR
- One logical change per PR — don't bundle unrelated changes
- Write descriptive PR titles and bodies
- PRs must pass CI (`swift build` + `swift test`) before merge
- Squash merge preferred for clean history
- Wait for the user to review and merge — do not merge PRs yourself

### Release Notes — Do NOT Commit Them to the Repo

**Never create or commit `docs/RELEASE_NOTES_v*.md` files** (or any other per-version release-notes file inside the repo). These files clutter the source tree, become stale the moment the release ships, and duplicate content that already lives on the GitHub Release page.

The release-notes lifecycle is:

1. **Draft** the notes in a scratch location *outside* the repo (e.g. `/tmp/RELEASE_NOTES_vX.Y.Z.md`, a Gist, or directly in the GitHub Release "draft" UI).
2. **Reuse** that draft to update the version-bump PR description, the `gh release create --notes-file ...` invocation, and any related comms.
3. **Paste** the final text into the GitHub Release description when publishing.
4. **Delete** the local scratch file after the release goes live.

If a version bump PR needs changelog context, put the changelog table in the **PR description**, not in a tracked file. The single source of truth for shipped release notes is the **GitHub Release page** itself, which is also what the in-app update checker surfaces to users.

See `docs/RELEASE.md` → **Release Notes (out-of-tree)** for the full process.

---

## Key Dependencies

| Dependency | Purpose | Version |
|-----------|---------|---------|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | On-device speech-to-text via CoreML | 0.9.4+ |

Keep dependencies minimal. This app values being lightweight and self-contained.

---

## macOS-Specific Considerations

- **Entitlements** (`VocaMac.entitlements`): App uses microphone access and accessibility APIs
- **LSUIElement:** App runs as a menu bar agent (no dock icon)
- **Code signing:** Release builds are Developer ID signed and notarized. Local development builds fall back to ad-hoc signing if no Developer ID cert is in the Keychain.
- **Permissions:** With Developer ID signing, permissions persist across updates. Ad-hoc (local dev) builds will reset permissions on every rebuild.
- **MenuBarExtra limitations:** The label only renders `Image` or `Text` — custom SwiftUI views like `Canvas` won't appear. Use `NSImage` with `isTemplate = false` for colored menu bar icons.

---

## Common Pitfalls

1. **MenuBarExtra ignores SwiftUI colors** — Use `NSImage` with `sourceAtop` tinting and `isTemplate = false` for colored states
2. **`Canvas` doesn't work in menu bar** — It renders in popovers but not in `MenuBarExtra` labels
3. **Browser caches SVG/PNG aggressively** — When testing website changes, always hard refresh (`Cmd+Shift+R`)
4. **Accessibility permission resets on rebuild** — Expected with ad-hoc signing; release builds are Developer ID signed so permissions persist
5. **WhisperKit model download** — First run requires internet to download the whisper model; all subsequent runs are offline

---

## Cursor Cloud specific instructions

Cloud agents run on a **Linux x86_64** VM. This constrains what is runnable:

- **The Swift macOS app (`Sources/VocaMac/`) cannot be built or run here.** It depends on macOS-only frameworks (AppKit, CoreML, AVFoundation) and WhisperKit, targets `arm64` Apple Silicon, and there is no Swift toolchain on the VM. `make build/install/run` and `swift build/test` only work on macOS — CI runs them on `macos-15` (`.github/workflows/ci.yml`). For app changes, rely on that macOS CI job rather than trying to build locally.
- **The runnable component on Linux is the website in `web/`.** Note: the "Website" section above is outdated — the site is a **Hugo** project (extended edition), not hand-written static HTML, and there is no `python3 -m http.server` workflow. Build with `cd web && hugo --minify` (output in `web/public/`); run the dev server with `cd web && hugo server`. Both CI (`build-website`) and deploy (`deploy-website.yml`) use `hugo --minify` with the extended edition.
- **Hugo extended is required** (the site uses features that need the extended build). The startup update script installs it if missing. If `hugo version` doesn't report `+extended`, reinstall the extended edition.
- Content lives in `web/content/` (Markdown) and templates in `web/layouts/`. Adding a feature page means adding a Markdown file under `web/content/features/`.
