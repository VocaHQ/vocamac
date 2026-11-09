# VocaMac architecture

How a dictation travels from the hotkey to text in the focused app, and which
type owns each step. File names are under `Sources/VocaMac/` unless noted.
Rules for changing this code (layering, concurrency, logging, tests) live in
[`AGENTS.md`](../AGENTS.md); this page describes what the code does today.

## 1. Overview

VocaMac is a native macOS menu bar app (Swift, SwiftUI, Apple Silicon only,
macOS 14+). It records the microphone while a hotkey is held or toggled,
transcribes on this Mac with one of four engines (or a Custom Endpoint the
user hosts), tidies the text with rules and an optional local model, and
inserts it at the cursor.

```
HotKeyManager (CGEventTap)
      │ press / release
      ▼
AppState ──────────────────────────────────────────────────────────────┐
  │ startRecording                                                      │
  ▼                                                                     │
AudioEngine (AVAudioEngine → 16 kHz mono Float32)                       │
  │ stop: samples                                                       │
  ▼                                                                     │
TranscriptionRouter ── SpeechActivityTrimmer (Silero VAD)               │
  │                    └─ HallucinationGuard (when VAD is unsure)       │
  ├─ WhisperService      (WhisperKit, CoreML)                           │
  ├─ ParakeetService     (FluidAudio, CoreML / Neural Engine)           │
  ├─ AppleSpeechService  (SpeechAnalyzer, macOS 26+)                    │
  ├─ SherpaService       (sherpa-onnx, CPU)                             │
  └─ CustomEndpointService (remote, opt-in)                             │
  │ VocaTranscription                                                   │
  ▼                                                                     │
PauseParagraphs → DictationOutputPipeline                               │
  │   rules → CleanupNeed → TranscriptCleanupService → EditMerge        │
  ▼                                                                     │
InsertionFit → TextInjector (Accessibility write, else clipboard + ⌘V)  │
  │                                                                     │
  └─ after the paste: DictationHistoryStore, StatsManager, ─────────────┘
     CorrectionObserver (learning from the user's edits)
```

`AppState` (`Models/AppState.swift` and its `AppState+*.swift` extensions) is
the single source of truth: views observe it and dispatch to it. It talks to
speech engines only through `TranscriptionRouter`, and to the cleanup model
only through `DictationOutputPipeline` / `TranscriptCleanupService`.

## 2. Technology

| Layer | Technology | Pin / floor |
|-------|-----------|-------------|
| Language, UI | Swift 5.9+, SwiftUI; AppKit for windows, event taps, Accessibility | macOS 14 |
| Audio | `AVAudioEngine` input tap, `AVAudioConverter` | — |
| Hotkeys | `CGEventTap` | — |
| Text insertion | Accessibility (`AXUIElement`), `NSPasteboard` + `CGEvent` | — |
| Whisper | [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (CoreML) | `.upToNextMinor(from: "1.1.0")` |
| Parakeet, Silero VAD | [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML) | `.upToNextMinor(from: "0.17.5")` |
| Apple Speech | `SpeechAnalyzer` / `SpeechTranscriber` | macOS 26+ at runtime |
| Specialized models | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (ONNX Runtime, CPU) | exact `1.13.8` |
| Cleanup model | [LLM.swift](https://github.com/eastriverlee/LLM.swift) (llama.cpp, Metal) | exact `3.0.3` |
| Build | Swift Package Manager; `.app` via `scripts/build.sh` (`xcodebuild`) | — |

## 3. Recording

**Hotkeys.** `HotKeyManager` installs a session-level `CGEventTap` and
consumes only the configured keys. Activation is push-to-talk (hold) or
double-tap toggle; Command Mode, hands-free and paste-last have their own
shortcuts. The default key is Right Option.

**Capture.** `AudioEngine` taps the input node, converts each buffer to
16 kHz mono Float32 with `AVAudioConverter`, and appends it. It reports a
level for the overlay (`AudioMeterState`) and runs energy-based silence
detection for toggle mode (`SilenceDetectionSettings`). Device changes,
Bluetooth settling and channel selection are handled there and in
`AudioDeviceMonitor`.

**Stop.** On release, `AudioEngine` waits up to 0.1 s for the last buffer
(`stopTailWait`), or up to 0.3 s when the tail is still voiced
(`stopTailExtension`), then hands the samples back.

**Process while speaking** (off by default). `RecordingTranscription` and
`SpeechSegmenter` cut the recording at pauses and decode finished pieces while
the user is still talking; `CleanupSpeculator` cleans those pieces ahead of
the final pass. The final pass reuses an answer only for an identical request,
so correctness never depends on the speculation.

## 4. Transcription

### 4.1 `TranscriptionRouter`

`TranscriptionRouter` implements `SpeechTranscribing` and is the only type
`AppState` calls for speech. It:

1. **Loads** the selected model through `performLoad`: it unloads the other
   engines first, so only one speech model is resident; prepares the voice
   activity detector; and runs a warm-up decode for Whisper, Parakeet and
   sherpa-onnx so the first dictation is not the slow one.
2. **Serializes** loads and decodes on one queue (`operationSerializer`) and
   bounds each with a deadline (`Deadline`): 30 minutes for a first load that
   compiles for the Neural Engine, 5 minutes for a cached load, and a decode
   deadline that grows with audio length. A missed deadline abandons the
   engines; the next dictation reloads.
3. **Trims silence** (`audioWithoutSilence`, on unless Skip Silence is off):
   `SpeechActivityTrimmer` runs FluidAudio's Silero VAD over the recording,
   keeps speech with 0.2 s padding, shortens pauses to at most 0.4 s, and
   returns one of: keep, trim, no speech (nothing is decoded), or unsure.
4. **Decodes** on the active engine.
5. **Guards against hallucinations**: when the VAD was unsure,
   `HallucinationGuard` drops a transcript that is only a stock phrase
   ("Thank you.", "Thanks for watching"). Confirmed speech is never touched.
6. **Maps timings** back to the original recording when silence was trimmed.
7. **Counts model failures**: two failed decodes in a row unload the model so
   the next dictation reloads it.

### 4.2 Engines

| Engine | Service | Notes |
|--------|---------|-------|
| Whisper | `WhisperService` | Greedy decoding; prompt prefill with Dictionary and screen terms; retries an empty or looping result; audio over two minutes is decoded in chunks. Only engine with translate-to-English. |
| Parakeet | `ParakeetService`, `ParakeetUnifiedModel` | TDT models on the Neural Engine; Dictionary words through `ParakeetVocabularyBoost` (CTC rescoring, separate ~98 MB model). |
| Apple Speech | `AppleSpeechService` | System-managed assets; contextual strings from the Dictionary. |
| Specialized ONNX | `SherpaService`, `SherpaModelCatalog`, `Vendor/SherpaOnnxConfigBuilders.swift` | CPU only. Recordings longer than a model's single-pass limit are split at pauses and decoded per segment. |
| Custom Endpoint | `CustomEndpointService` | Uploads a WAV to a Whisper-compatible server the user configures. API key in the Keychain; plain HTTP only to loopback, private and `.local` hosts. |

Recognition hints come from `RecognitionHints` (Dictionary terms plus terms
read from the screen by `ScreenContextTerms`). Model metadata, sizes and
memory estimates live in `Models/WhisperModel.swift` (`ModelSize`) and
`Models/ModelRAMFit.swift`; downloads are handled by `ModelManager`.

## 5. Output pipeline

`DictationOutputPipeline.process` turns the transcript into the text that is
typed. Raw style returns it untouched. Otherwise:

### 5.1 Rule stages (`prepare`, no model)

In this order. Stages 1–6 run only where the style cleans up and the cleanup
level allows them. Stages 7–8 also run with "Formatting only, no AI", subject
to their own settings:

1. Hesitations ("um", "uh"); other languages lose only sounds that are a word
   nowhere, plus their own when the language is known.
2. Fillers this user always deletes, learned from their edits (prose only).
3. Stutters ("I I I think").
4. Cut-off words said again in full ("can you ple please").
5. Repeated phrases ("the the"; prose only).
6. Spoken corrections and change of mind (`SpokenCorrectionResolver`,
   `ChangeOfMindResolver`; prose only).
7. Personal Dictionary (`DictionaryCorrector`): replacements, near-misses and
   sound-alikes of the user's terms.
8. Snippets, spoken emoji and spoken numbers (`SnippetExpander`,
   `SpokenEmoji`, `SpokenNumbers`). Converted text is masked so later stages
   cannot change it.

The language decision for these rules comes from the transcription language
when one is set, otherwise from the text itself.

### 5.2 Deciding whether to ask the model (`planCleanup`)

The pipeline formats the rule output with `WritingStyleEngine` (the result
used whenever the model's is not), then returns it without a model pass when:
cleanup is off or the level is None; the text is romanized Hindi; it contains
spoken formatting commands; it is a short Code or Terminal command; a
non-English rewrite was asked for; or `CleanupNeed` finds nothing left for the
model. `CleanupNeed` is one-sided: when unsure, it asks the model.

### 5.3 The model pass

`TranscriptCleanupService` runs the local GGUF model (default Qwen 2.5 0.5B)
through LLM.swift. The system prompt is byte-stable per cleanup level, so
llama.cpp reuses its cache and reads only the new transcript;
`warmCleanupModel` re-primes it after anything that replaces the prompt in
the model. `RemoteCleanupService` is the opt-in endpoint alternative.

The answer is never taken whole:

- **Cleanup** (`EditMerge`) lines the answer up against the input and keeps
  each safe edit (punctuation, filler, spelling of a glossary term) while
  putting back any risky one (changed numbers, dropped sentences, renamed
  people). Non-English text is merged at the Light level.
- **Code and Terminal** keep only deletions of filler (`CleanupSalvage`);
  the model's text never enters a command.
- **Formal / Casual rewrites** are used whole only if `RewriteValidation`
  accepts them, else merged like cleanup.

Long dictations are split into slices at piece and paragraph boundaries;
slices that are already clean skip the model.

### 5.4 Formatting

`WritingStyleEngine` and `SpokenSymbolTransformer` apply the per-app writing
profile (`WritingStyleResolver`, `FrontmostAppResolver`): capitalization,
terminal punctuation, trailing space, lists, spoken symbols. `PauseParagraphs`
inserts a paragraph break at a long pause, placed with the engine's word
timings.

## 6. Delivery

1. **Fit to the field.** When Accessibility can read the focused field,
   `InsertionFit` adjusts the leading space and capitalization to the text
   already before and after the caret. In single-line fields (search boxes,
   subjects) it joins lines and drops the full stop of a single sentence. The
   field is read when recording starts and again before delivery; if the user
   moved to another field, nothing is fitted.
2. **Insert.** `TextInjector` first tries an Accessibility write of the
   selected text in single-line fields (`AXTextField`, `AXSearchField`,
   `AXComboBox`). Otherwise, or if that fails, it snapshots the clipboard,
   writes the transcript, waits 10 ms, posts ⌘V with `CGEvent`, waits until
   the target app has read the transcript (up to 2 s), and restores the
   clipboard. It refuses to paste when focus moved to another app, and leaves
   the transcript on the clipboard when Accessibility is not granted.
3. **After the paste**, off the wait: `DictationHistoryStore` completes the
   History entry, `StatsManager` records the dictation, and
   `CorrectionObserver` watches the field for the user's own edits to learn
   terms and fillers from.

## 7. Command Mode

Command Mode works on selected text (`AccessibilitySelectedTextService`).
`AppState` routes the spoken instruction in this order:

1. Undo.
2. Voice action (`VoiceActionParser` → `VoiceActionPolicy` →
   `VoiceActionPerforming`): chosen only from the user's spoken words by fixed
   patterns, never by the model or from selected text. Shortcuts run only from
   the user's allow-list.
3. Rule edit (`CommandExactEdit`).
4. The model through `CommandModelRunner`: prompt, answer,
   `CommandOutputCheck`, one retry. The model is a local slot, Apple
   Intelligence, or an endpoint (`TextTransforming`).

Model results that replace text are shown in `CommandReviewPanel` only when
`commandModeReview` asks for approval; it defaults to `.never`. Rule edits
always apply directly without review.

## 8. CLI

The same executable runs headless (`CLI/`). `--transcribe-file` decodes an
audio file with the model selected in the app (`--model`, `--language`,
`--json`, `--text`, `--output`; `--pieces` and `--cleanup` compare
piece-by-piece decoding), `--list-models` lists models, `--help` prints usage.
The CLI never constructs `AppState` and never starts SwiftUI, the microphone,
hotkeys, onboarding or text insertion. See [`CLI.md`](CLI.md).

## 9. Concurrency

- `AppState` and the views are `@MainActor`. The target builds with complete
  concurrency checking.
- The audio tap runs on AVAudioEngine's thread and only converts and appends.
- Model loads and decodes run off the main thread, one at a time, on the
  router's serializer; cleanup inference also runs off the main thread.
- Accessibility reads and writes into other processes run on a dedicated
  queue with timeouts (`AccessibilityTimeout`); ⌘V is posted from the main
  thread.
- `VocaMacObjC` turns `NSException`s from AVFoundation tap installation into
  `NSError`, which Swift cannot otherwise catch.

## 10. Storage and privacy

Everything lives under `~/Library/Application Support/VocaMac/`:

| Path | Contents |
|------|----------|
| `models/` | Whisper, Parakeet, sherpa-onnx (`models/sherpa-onnx/`) and cleanup (`models/cleanup/`) models |
| `History/` | Dictation history (on by default). Audio is written for crash recovery. Successful dictations with text delete their audio unless "Keep audio" is on; failed, cancelled, interrupted and empty dictations keep it for recovery |
| `logs/` | Rotated logs (`VocaLogger`); log lines carry character counts, not transcript text. `logs/failed-audio/` only when the `vocamac.debug.saveFailedAudio` default is set |

Network use: model downloads (Hugging Face, sherpa-onnx releases), the daily
update check against GitHub Releases, and, only when the user configures
them, the Custom Endpoint, a remote cleanup endpoint, or a Command Mode
endpoint. Endpoint API keys are stored in the Keychain.

Permissions: Microphone (entitlement), Accessibility and Input Monitoring
(TCC). Release builds are Developer ID signed and notarized with the hardened
runtime; the Mac App Store variant (`APP_STORE`) is sandboxed and drops
self-update, external processes and AppleScript (see
[`APP_STORE.md`](APP_STORE.md)).

## 11. Updates

`UpdateChecker` asks GitHub Releases at most once a day. DMG installs
download the new DMG, verify its SHA-256 and the Developer ID team of the
bundle inside, and swap it in (`UpdateInstaller`). Homebrew installs are
shown the `brew upgrade --cask vocamac` command instead.

## 12. Related documents

- [`MODELS.md`](MODELS.md): the speech model catalog.
- [`DATA_MODEL.md`](DATA_MODEL.md): stored data and preferences.
- [`CLI.md`](CLI.md), [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md),
  [`RELEASE.md`](RELEASE.md), [`APP_STORE.md`](APP_STORE.md).
- [`VOCAHQ_PARITY.md`](VOCAHQ_PARITY.md): parity with the other VocaHQ apps.
