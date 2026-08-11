# VocaHQ feature parity (VocaMac)

Living plan for bringing VocaMac in line with the Voca family product bar, starting from VocaLinux v0.15.

**Org principle** ([VocaHQ/PRODUCT.md](https://github.com/VocaHQ/vocahq/blob/main/PRODUCT.md)): feature parity over time across platforms. Same jobs, native code. Not a shared UI toolkit, not identical screenshots.

**Sources reviewed for this draft:**

- VocaLinux `main` (v0.15 line): searchable sidebar settings (#601, #618), auto-pause + idle unload (#592), dictation polish (#554, #608), language catalog (#616)
- VocaMac `main`: tabbed settings, four-engine `TranscriptionRouter`, cursor overlay, stats, AX injection
- VocaHQ product principles and status labels

---

## 1. What "parity" means here

| Means | Does not mean |
|-------|---------------|
| Same user jobs: hotkey → speak → text at cursor | Shared GTK/SwiftUI widgets |
| Same settings topics and searchability | Pixel-identical layouts |
| Same power controls (pause for apps, unload when idle) | Porting `psutil` / logind / Vulkan pickers |
| Honest per-engine language and model labels | One engine stack on every OS |
| Shared vocabulary for features in docs and marketing | Shipping Linux-only packaging or IBus |

Platform adapters stay native: `NSWorkspace` instead of `psutil`, `NSWorkspace` sleep/wake instead of logind, Metal/CoreML instead of Vulkan.

---

## 2. Snapshot matrix

Status as of this document. Update cells when follow-up PRs land.

| Category | Capability | VocaLinux v0.15 | VocaMac | Target |
|----------|------------|-----------------|---------|--------|
| Core loop | Push-to-talk / toggle, silence stop, inject | Yes | Yes | Keep |
| Settings IA | Topic pages in a **left sidebar** | Yes | Yes (`NavigationSplitView`) | Keep |
| Settings IA | Live **settings search** | Yes | Yes | Keep |
| Settings IA | Persistent status / mic / test footer | Yes | Yes | Keep |
| Output | Trailing space after utterance | Yes | Yes | Keep |
| Output | Auto-capitalize after sentence ends | Yes (esp. VOSK path) | Yes | Keep |
| Output | Voice commands | Yes (engine-gated) | No | Later / optional |
| Output | Custom vocabulary | No | Yes (Whisper) | Keep; feed Linux later |
| Output | Translation | No | Yes (Whisper) | Keep |
| Power | Auto-pause while listed apps run | Yes | Yes | Keep |
| Power | Idle model unload (keep-alive) | Yes | Yes (opt-in) | Keep |
| Power | Sleep/wake recovery | Yes (logind) | Yes (`NSWorkspace`) | Keep |
| Models | Multi-engine catalog | 3 + remote | 4 on-device | Keep Mac lead |
| Models | Language catalog depth | ~33 + auto | ~36 + auto (searchable) | Keep |
| Updates | Stable / nightly channel picker | Yes | Nightly via separate cask/DMG | Align UX (follow-up) |
| Diagnostics | In-app log viewer | Yes | Copy/export only | Improve (follow-up) |
| Stats | Usage stats / streaks | Thin | Rich Stats sidebar page | Keep; feed Linux later |
| UX | Cursor mic overlay | No | Yes | Keep |
| UX | Onboarding wizard | Basic first-run | Full multi-step | Keep |

---

## 3. Unified settings IA (target)

Mirror VocaLinux topic names where they map cleanly. Keep Mac-only content under the right topic.

```
Dictation       Hotkey, mode, silence/VAD, output formatting, voice commands (later)
Speech Model    Engine/model picker, downloads, language catalog, translation/vocab
Audio           Device, mic test, sound effects
Performance     Auto-pause apps, idle unload, resource readout
Application     Launch at login, cursor overlay, clipboard preserve, notifications
Advanced        Engine knobs (gated), debug tools
About           Version, update channel, links, setup wizard
[Sidebar footer] Status, level meter, Test Dictation, Close
```

**macOS shell:** SwiftUI `NavigationSplitView` (or equivalent sidebar list + detail) + `.searchable`. Do not paste GTK layout into SwiftUI.

**Search contract** (match Linux behavior):

1. Index each control by title, subtitle, and optional keywords
2. Filter rows in place; badge match counts on sidebar pages
3. Jump to first page with matches; empty state when none
4. Esc clears search; restore previous page

Current tab → target page mapping:

| Today | Target page |
|-------|-------------|
| General (hotkey, language, translation, vocab, behavior) | Split across Dictation / Speech Model / Application |
| Models | Speech Model (+ resource bits → Performance) |
| Stats | Application or its own sidebar entry (keep Mac lead) |
| Audio | Audio |
| Debug | Advanced |
| About | About |

---

## 4. Power management (port of #592)

### 4.1 Auto-pause for apps

**Linux:** poll process basenames; unload model while any listed name runs; reload when none remain.

**Mac adapter:**

- Watch `NSWorkspace.shared.runningApplications` (and/or `NSWorkspace` launch/terminate notifications)
- Match on bundle ID and/or executable basename (user-facing list should prefer app names + bundle IDs)
- On pause: stop recording if active, call existing unload paths on `TranscriptionRouter` / engine services, set an `isAutoPaused` gate so hotkeys do not start capture
- On resume: lazy reload on next dictation (same as Linux), or warm-reload if already preferred

**Settings:** Performance page. Toggle + editable list + "Choose Running App…" picker.

**Defaults:** off; empty app list; poll / refresh interval ~5s (reuse the existing ProcessMonitor cadence mindset; do not add a second high-frequency timer).

### 4.2 Idle model unload ("keep-alive")

**Linux:** after N seconds idle (default 300, options 1-30 min), unload model; next dictation reloads.

**Mac adapter:**

- Arm timer when `AppStatus` returns to `.idle` after a transcription
- Cancel while recording/processing or while auto-paused
- Call the same unload APIs used on engine switch
- Surface cold-start latency honestly in UI copy

**Note:** `AudioEngine` already releases the AVAudioEngine after 3s idle for Bluetooth HFP. Idle *model* unload is separate and optional.

### 4.3 Sleep / wake

Subscribe to `NSWorkspace.willSleepNotification` / `didWakeNotification` (and/or screen sleep). On wake: refresh audio devices and hotkey tap health; bump keep-alive. Skip model reload if still auto-paused.

---

## 5. Dictation polish (port of #554 / #608)

Apply in one place before `TextInjector.inject`:

| Preference | Default | Behavior |
|------------|---------|----------|
| `appendTrailingSpace` | `true` | Append a trailing space after a completed utterance so the next PTT/toggle session does not glue onto the previous sentence |
| `autoCapitalize` | `true` | Capitalize start of session and after `.` `!` `?` when the engine did not already |

Whisper / Apple Speech often emit capitalization already; keep the pass idempotent (do not double-upcase). Marketing copy that already claims this behavior should match the implementation once shipped.

Voice commands stay **out of phase 1**. Port later as an optional, engine-aware post-processor, not as a default for WhisperKit.

---

## 6. Phased delivery

Originally planned as separate PRs. Phases **1–3** plus the language-catalog half of Phase 4 shipped together in the stacked implementation PR on top of this plan (user requested a single follow-up). Remaining Phase 4 (update channel UX, richer log viewer) and Phase 5 stay deferred.

### Phase 1: Output polish — **done**

- Trailing space + auto-capitalize preferences and injection hook
- Tests for edge cases (empty text, already capitalized, CJK, trailing punctuation)
- Settings toggles under Dictation/Output

### Phase 2: Performance / power — **done**

- `AutoPauseMonitor` + preferences + Settings UI
- `ModelKeepAlive` idle unload + preferences
- Sleep/wake hardening
- Tests with injected process snapshots / fake clocks

### Phase 3: Settings shell — **done**

- Sidebar navigation + searchable index
- Sidebar footer: status, level, Test Dictation, Close
- Rehome existing controls into the target IA
- Preserve Stats and Mac-only controls

### Phase 4: Catalog and updates

- Expand language list toward the VocaLinux catalog; searchable language picker — **done**
- Update channel selector (stable vs nightly) wired to the right GitHub release endpoints — **follow-up**
- Optional: richer log viewer in Advanced — **follow-up**

### Phase 5: Bidirectional / org

- Feed Mac wins back to Linux where useful: stats, custom vocabulary, translation UX, multi-engine honesty
- Keep the matrix in this file (and eventually a short matrix on vocahq.com) updated
- VocaWin / VocaPhone consume the same taxonomy when they grow past marketing

---

## 7. Suggested Swift touch points

| Work | Where |
|------|--------|
| Preferences | `AppState` `@AppStorage` keys (`vocamac.appendTrailingSpace`, `vocamac.autoCapitalize`, `vocamac.autoPause.*`, `vocamac.modelKeepAlive.*`) |
| Text polish | Small helper used from `AppState` before `TextInjector` |
| Auto-pause | New `AutoPauseMonitor` service; wire from `AppState` / app lifecycle |
| Idle unload | New `ModelKeepAlive` helper calling `TranscriptionRouter` unload APIs |
| Settings shell | Refactor `SettingsView.swift` off `TabView`; keep tab bodies as page views |
| Search index | Lightweight struct listing title/subtitle/keywords → page id (no new dependency) |
| Tests | `Tests/VocaMacTests/` mirrors Linux: pure matching + timeout logic without UI |

Reuse unload already present on Whisper / Parakeet / Apple Speech / Sherpa services. Do not invent a second model lifecycle path.

---

## 8. Explicit non-goals (do not port)

- IBus / ydotool / wtype / xdotool injection stacks
- Vulkan device picker
- VOSK as a Mac engine
- Flatpak / AppImage / AUR packaging
- systemd-logind D-Bus suspend API
- Remote OpenAI-compatible API engine (revisit only if VocaGateway needs a Mac client)

---

## 9. Acceptance bar for "settings parity"

A reviewer can open Settings and:

1. Navigate by left sidebar topics (not only top tabs)
2. Search "pause" or "idle" and land on Performance controls
3. See live recognition status and run Test Dictation without leaving Settings
4. Enable auto-pause, pick a running app, confirm the model unloads while it runs and reloads after
5. Enable idle unload, wait past the timeout (or advance a test clock), confirm unload + next-dictation reload
6. Dictate twice in a row with trailing-space on and get a clean space between utterances

---

## 10. Open questions

1. **Stats placement:** keep a dedicated sidebar item vs fold into Application?
2. **Auto-pause matching:** bundle ID only, or also process name for CLI tools / games?
3. **Idle unload default:** stay opt-in (Linux default) or recommend-on for large models?
4. **Voice commands:** skip until a Whisper-friendly design exists, or ship a small English command set behind a toggle?

Resolve these in the phase PRs; do not block Phase 1 on them.
