# VocaHQ feature parity (VocaMac)

Living plan for bringing VocaMac in line with the Voca family product bar, starting from VocaLinux v0.15.

**Org principle** ([VocaHQ/PRODUCT.md](https://github.com/VocaHQ/vocahq/blob/main/PRODUCT.md)): feature parity over time across platforms. Same jobs, native code. Not a shared UI toolkit, not identical screenshots.

**Sources reviewed:**

- VocaLinux `main` (v0.15 line): searchable sidebar settings (#601, #618), auto-pause + idle unload (#592), dictation polish (#554, #608), language catalog (#616)
- VocaMac: four-engine `TranscriptionRouter`, cursor overlay, stats, AX injection, plus the parity work shipped in PR #207
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

Status as of the #207 parity ship. Update cells when follow-up PRs land.

| Category | Capability | VocaLinux v0.15 | VocaMac | Target |
|----------|------------|-----------------|---------|--------|
| Core loop | Push-to-talk / toggle, silence stop, inject | Yes | Yes | Keep |
| Settings IA | Topic pages in a **left sidebar** | Yes | Yes (custom sidebar + detail) | Keep |
| Settings IA | Live **settings search** | Yes | Yes (sidebar search field) | Keep |
| Settings IA | Persistent status / mic / test footer | Yes | Yes (Test Dictation; no inject) | Keep |
| Output | Trailing space after utterance | Yes | Yes | Keep |
| Output | Auto-capitalize after sentence ends | Yes (esp. VOSK path) | Yes | Keep |
| Output | Per-app writing styles | No | Yes (Code / Terminal / Chat / Slack / Email / Notes) | Keep Mac lead; feed Linux later |
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
| Stats | Usage stats / streaks | Thin | Rich Stats sidebar page (+ Share) | Keep; feed Linux later |
| UX | Cursor mic overlay | No | Yes | Keep |
| UX | Onboarding wizard | Basic first-run | Full multi-step (About entry) | Keep |

---

## 3. Settings IA (shipped)

```
Dictation       Hotkey, mode, global output formatting (trailing space, auto-capitalize)
Writing Styles  Master toggle, default style, per-app rules, rule editor, live preview
Speech Model    Engine/model picker, downloads, language, translation/vocab (engine-gated)
Audio           Device, silence/VAD, sound effects
Performance     Model status, auto-pause apps, idle unload
Application     Launch at login, recording overlay, clipboard preserve
Stats           Usage totals, streaks, Share card
Advanced        System info, resource pills, permissions, debug logs
About           Version, updates, links, setup wizard
[Sidebar]       Search at top; status + Test Dictation footer (results only, no inject)
```

**macOS shell:** Custom sidebar + detail layout (not `NavigationSplitView`, which fought Tahoe toolbar chrome). Sidebar search field matches System Settings placement. One top-right sidebar toggle.

**Search contract:**

1. Index each control by title, subtitle, and optional keywords
2. Filter sidebar pages by match; badge counts when searching
3. Jump to first page with matches; empty state when none
4. Clearing search restores the previous page

Former tab → page mapping:

| Was | Now |
|-----|-----|
| General | Split across Dictation / Speech Model / Application |
| Models | Speech Model (system/resource bits → Advanced) |
| Stats | Stats (own sidebar item) |
| Audio | Audio |
| Debug | Advanced |
| About | About |

---

## 4. Power management (shipped; port of #592)

### 4.1 Auto-pause for apps

**Mac adapter:**

- Poll `NSWorkspace.shared.runningApplications` (~5s)
- Match on bundle ID **or** executable basename
- On pause: stop recording if active, unload via `TranscriptionRouter`, set `isAutoPaused`
- On resume: warm-reload selected model
- UI surfaces which app triggered pause (Performance + menu bar)

**Settings:** Performance page. Toggle + list + "Choose Running App…"

**Defaults:** off; empty app list.

### 4.2 Idle model unload

- Arm when status returns to idle; cancel while recording/processing/auto-paused
- Opt-in; default timeout 300s (1–30 min options)
- Next dictation reloads; Performance/menu bar show unload reason and approx RSS drop

### 4.3 Sleep / wake

`NSWorkspace.willSleepNotification` / `didWakeNotification`: cancel keep-alive on sleep; on wake refresh hotkey health and bump keep-alive (skip reload if still auto-paused).

---

## 5. Dictation polish (shipped; port of #554 / #608)

Applied in `DictationOutputFormatter` before `TextInjector.inject` (hotkey path). Settings Test Dictation shows results in the footer only and does **not** inject.

| Preference | Default | Behavior |
|------------|---------|----------|
| `appendTrailingSpace` | `true` | Space after each utterance |
| `autoCapitalize` | `true` | Capitalize start and after `.` `!` `?` when needed |

Voice commands remain out of scope for now.

---

## 5.1 Writing styles (Mac-first)

Per-app output shaping applied between transcription and injection.

`plain` is the lightest style, not a no-op: on top of the global Dictation
settings it applies Tier A symbol rules (spoken file extensions, explicit
bracket commands). Switching the feature off uses `WritingStyleRules.passthrough`,
which *is* byte-for-byte the pre-feature pipeline.

| Preference | Default | Behavior |
|------------|---------|----------|
| `writingStyle.enabled` | `true` | Master toggle; off restores the global-only pipeline |
| `writingStyle.defaultStyle` | `plain` | Used when the frontmost app has no rule |
| `writingStyle.bindings` | seeded | Versioned JSON of app → style rules |

**Resolution:** the frontmost app is read at injection time (`FrontmostAppResolver`),
with a record-start snapshot, then the last activated app, as fallbacks for when
VocaMac's own window has focus. That last fallback is what the menu bar row
depends on: `.menuBarExtraStyle(.window)` activates VocaMac, so while the
popover is open the frontmost app *is* VocaMac. Matching reuses the auto-pause
contract — bundle ID or normalized process name — via the shared
`AppIdentityMatching`.

**Symbol substitution** is tiered by confidence. Tier A is context-locked (known
file extensions, spoken case commands, bracket commands that carry an explicit
"open"/"close") and safe in prose. Tier B is heuristic (path slashes, identifier
joiners) and enabled only for Code and Terminal.

Saying "literally" before a word suppresses the substitution that word would
otherwise have taken part in ("literally dot json"). Whether the word is
consumed as a command is decided by re-running the line without it: if nothing
would have been rewritten, "literally" stays in the text. No word list can make
that call — it would have to contain "open", "close", "go", "dash" and
"forward" — and silently deleting an ordinary adverb from "I literally cannot"
is a worse failure than a missed escape.

Substitution preserves the case the engine produced — `Info.plist` and
`README.md` are the names on disk — and a line where no rule fires is returned
untouched, so ordinary dictation keeps its own spacing.

**Ordering with snippets:** snippet expansion runs *before* styling, with each
expansion masked as one `TextPlaceholder` scalar. Triggers are therefore matched
against the raw transcript (a style that trims a leading "so" cannot break one),
and the expansion — text the user authored — is never re-cased, re-punctuated,
or reshaped by symbol rules. The style engine masks the identifiers it builds
the same way, so sentence case cannot turn `readme.md` into `Readme.md`.

Engines differ in what they emit for the same speech, so the transformer
normalizes before matching. Whisper converts spoken symbols itself ("slash" →
`/`); Parakeet emits the literal word; Apple Speech fuses it to the next word
("slashcomponents"). A glued split runs first so every rule sees whole tokens.
Formatting is a pure function of the transcript, so it is identical across all
four engines — pinned by a regression test.

**Not ported / deferred:** on-device LLM refinement (`FoundationModels`),
user-authored named styles, window-title matching for browser tabs.

---

## 6. Phased delivery

Phases 1–3 and the language half of Phase 4 shipped in PR #207. Remaining Phase 4 and Phase 5 stay deferred.

### Phase 1: Output polish (done)

### Phase 2: Performance / power (done)

### Phase 3: Settings shell (done)

### Phase 4: Catalog and updates

- Expand language list; searchable picker (done)
- Update channel selector stable vs nightly (follow-up)
- Richer log viewer in Advanced (follow-up)

### Phase 5: Bidirectional / org

- Feed Mac wins back to Linux where useful: stats, custom vocabulary, translation UX, multi-engine honesty
- Keep this matrix (and eventually vocahq.com) updated
- VocaWin / VocaPhone reuse the same taxonomy when they grow past marketing

---

## 7. Swift touch points (implemented)

| Work | Where |
|------|--------|
| Preferences | `AppState` / `PreferenceKey` (`vocamac.appendTrailingSpace`, `vocamac.autoCapitalize`, `vocamac.autoPause.*`, `vocamac.modelKeepAlive.*`) |
| Text polish | `DictationOutputFormatter` |
| Auto-pause | `AutoPauseMonitor` |
| Idle unload | `ModelKeepAlive` |
| Sleep/wake | `SleepWakeMonitor` |
| Settings shell | `SettingsView` (custom sidebar + detail) |
| Search index | `SettingsSearchIndex` |
| Tests | `Tests/VocaMacTests/` (matching, formatter, keep-alive, search, languages, …) |

Unload reuses existing engine teardown via `TranscriptionRouter.unloadModel()`.

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

1. Navigate by left sidebar topics
2. Search "pause" or "idle" and land on Performance
3. See status and run Test Dictation in the footer (results appear there; no inject)
4. Enable auto-pause, pick a running app, confirm unload while it runs and reload after
5. Enable idle unload, wait past the timeout, confirm unload + next-dictation reload
6. Dictate twice with trailing space on and get a clean space between utterances
7. Search "style" or "filename" and land on Writing Styles
8. Dictate "open config dot json" into a Code-bound app and get `open config.json`
9. Dictate the same phrase into a Chat-bound app and get it unchanged

---

## 10. Decisions (resolved in #207)

1. **Stats placement:** dedicated sidebar item (keep Mac lead).
2. **Auto-pause matching:** bundle ID **or** process name.
3. **Idle unload default:** opt-in, default off (match Linux).
4. **Voice commands:** skip for now; revisit with a Whisper-friendly design.
