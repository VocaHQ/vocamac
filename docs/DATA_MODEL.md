# VocaMac — Data Model & Entity Relationship Document

**Version:** 1.0
**Date:** 2026-03-04
**Author:** Jatin Kumar Malik
**Status:** Draft

---

## 1. Overview

VocaMac is a stateful desktop application with no database. All state is held in-memory during runtime, with user preferences persisted via `UserDefaults` and model files stored on disk. This document defines the core data entities, their relationships, and the storage strategy.

---

## 2. Entity Relationship Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        AppState                                  │
│  (Central observable state — in memory)                         │
│                                                                  │
│  appStatus ──────────────► AppStatus (enum)                     │
│  activationMode ─────────► ActivationMode (enum)                │
│  isRecording: Bool                                               │
│  audioLevel: Float                                               │
│  lastTranscription ──────► TranscriptionResult?                 │
│  currentModel ───────────► WhisperModelInfo                     │
│  micPermission ──────────► PermissionStatus (enum)              │
│  accessibilityPermission ► PermissionStatus (enum)              │
│  selectedLanguage: String                                        │
│  selectedAudioDevice ───► AudioDevice?                          │
│  updateChecker ─────────► UpdateChecker                          │
└──────────┬──────────────────────────┬───────────────────────────┘
           │                          │
           ▼                          ▼
┌─────────────────────┐    ┌─────────────────────────────────┐
│ TranscriptionResult │    │       WhisperModelInfo          │
│                     │    │                                  │
│ id: UUID            │    │ size: ModelSize (enum)           │
│ text: String        │    │ filePath: URL                    │
│ duration: Double    │    │ isDownloaded: Bool               │
│ language: String    │    │ isActive: Bool                   │
│ timestamp: Date     │    │ downloadProgress: Double?        │
│ audioLengthSec: Int │    │ fileSize: Int64                  │
│ modelUsed: ModelSize│    │ checksum: String                 │
└─────────────────────┘    └──────────────┬──────────────────┘
                                          │
                                          ▼
                            ┌──────────────────────────────┐
                            │        ModelSize (enum)       │
                            │                               │
                            │ .tiny      (39 MB, ~1 GB RAM) │
                            │ .base      (142 MB, ~1.5 GB)  │
                            │ .small     (466 MB, ~2 GB)    │
                            │ .medium    (1.5 GB, ~5 GB)    │
                            │ .largeV3   (3.1 GB, ~10 GB)   │
                            └──────────────────────────────┘

┌─────────────────────────────┐    ┌─────────────────────────────┐
│     UserSettings            │    │      SystemCapabilities     │
│  (Persisted: UserDefaults)  │    │     (Detected at runtime)   │
│                             │    │                              │
│ activationMode: String      │    │ isAppleSilicon: Bool         │
│ hotKeyCode: Int             │    │ physicalMemoryGB: Int        │
│ doubleTapThreshold: Double  │    │ processorName: String        │
│ silenceThreshold: Float     │    │ coreCount: Int               │
│ silenceDuration: Double     │    │ recommendedModel: ModelSize  │
│ selectedModelSize: String   │    │ supportsMetalAccel: Bool     │
│ selectedLanguage: String    │    └─────────────────────────────┘
│ launchAtLogin: Bool         │
│ audioDeviceID: String?      │    ┌─────────────────────────────┐
│ maxRecordingDuration: Int   │    │      AudioDevice             │
│ preserveClipboard: Bool     │    │   (Detected at runtime)     │
└─────────────────────────────┘    │                              │
                                   │ id: String                   │
                                   │ name: String                 │
                                   │ isDefault: Bool              │
                                   │ sampleRate: Double           │
                                    │ channelCount: Int            │
                                    └─────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                       Update Checker Domain                      │
│                                                                  │
│  GitHubRelease                                                   │
│    - tagName: String                                             │
│    - name: String                                                │
│    - body: String                                                │
│    - htmlURL: URL                                                │
│    - assets: [GitHubAsset]                                       │
│                                                                  │
│  GitHubAsset                                                     │
│    - name: String                                                │
│    - browserDownloadURL: URL                                     │
│    - size: Int                                                   │
│    - digest: String?  // "sha256:..."                           │
│                                                                  │
│  UpdateInfo                                                      │
│    - version: String                                             │
│    - tagName: String                                             │
│    - releaseNotes: String                                        │
│    - releasePageURL: URL                                         │
│    - dmgURL: URL                                                 │
│    - dmgSize: Int                                                │
│    - sha256: String?                                             │
│                                                                  │
│  UpdateState (enum)                                              │
│    - idle | checking | upToDate                                  │
│    - updateAvailable(UpdateInfo)                                 │
│    - downloading(progress)                                        │
│    - readyToInstall(dmgPath)                                     │
│    - error(message)                                              │
└──────────────────────────────────────────────────────────────────┘
```

---

## 3. Entity Definitions

### 3.1 `AppStatus` — Application State Machine

```
          ┌──────────────────────────────────────┐
          │                                      │
          ▼                                      │
     ┌─────────┐   hotkey    ┌───────────┐      │
     │  IDLE   │ ──pressed──►│ RECORDING │      │
     └─────────┘             └─────┬─────┘      │
          ▲                        │             │
          │                  hotkey released     │
          │                  or silence          │
          │                        │             │
          │                        ▼             │
          │                ┌──────────────┐      │
          │◄──completed────│  PROCESSING  │      │
          │                └──────┬───────┘      │
          │                       │              │
          │                  if error            │
          │                       │              │
          │                       ▼              │
          │                ┌──────────────┐      │
          └◄──dismissed────│    ERROR     │──────┘
                           └──────────────┘
```

```swift
enum AppStatus: String {
    case idle          // Ready for input, not recording
    case recording     // Actively capturing microphone audio
    case processing    // Transcribing audio via WhisperKit
    case error         // Something went wrong, showing error state
}
```

### 3.2 `ActivationMode` — How Recording is Triggered

```swift
enum ActivationMode: String, CaseIterable, Codable {
    case pushToTalk       // Hold key to record, release to stop
    case doubleTapToggle  // Double-tap key to start, double-tap again to stop
}
```

### 3.3 `PermissionStatus` — Permission State

```swift
enum PermissionStatus: String {
    case notDetermined  // Haven't asked yet
    case granted        // Permission granted
    case denied         // Permission denied by user
}
```

### 3.4 `ModelSize` — Whisper Model Variants

```swift
enum ModelSize: String, CaseIterable, Codable, Identifiable {
    case tiny     = "tiny"
    case base     = "base"
    case small    = "small"
    case medium   = "medium"
    case largeV3  = "large-v3"

    var id: String { rawValue }

    /// Display name for the UI
    var displayName: String {
        switch self {
        case .tiny:    return "Tiny (Fastest)"
        case .base:    return "Base"
        case .small:   return "Small"
        case .medium:  return "Medium"
        case .largeV3: return "Large v3 (Best Quality)"
        }
    }

    /// Model file name in CoreML format
    var fileName: String {
        "openai_whisper-\(rawValue)"
    }

    /// Approximate file size on disk
    var fileSizeBytes: Int64 {
        switch self {
        case .tiny:    return 39_000_000
        case .base:    return 142_000_000
        case .small:   return 466_000_000
        case .medium:  return 1_500_000_000
        case .largeV3: return 3_100_000_000
        }
    }

    /// Approximate RAM required for inference
    var ramRequiredGB: Double {
        switch self {
        case .tiny:    return 1.0
        case .base:    return 1.5
        case .small:   return 2.0
        case .medium:  return 5.0
        case .largeV3: return 10.0
        }
    }

    /// Download URL from Hugging Face
    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/WhisperKit/resolve/main/\(fileName)")!
    }
}
```

### 3.5 `WhisperModelInfo` — Model Instance Metadata

```swift
struct WhisperModelInfo: Identifiable {
    let size: ModelSize
    var filePath: URL?
    var isDownloaded: Bool
    var isActive: Bool
    var downloadProgress: Double?  // 0.0 to 1.0 during download
    var checksum: String?

    var id: String { size.id }

    var statusDescription: String {
        if isActive { return "Active" }
        if isDownloaded { return "Downloaded" }
        if let progress = downloadProgress {
            return "Downloading (\(Int(progress * 100))%)"
        }
        return "Not Downloaded"
    }
}
```

### 3.6 `TranscriptionResult` — Output of a Transcription

```swift
struct TranscriptionResult: Identifiable {
    let id: UUID
    let text: String                // The transcribed text
    let duration: TimeInterval      // Time taken to transcribe
    let detectedLanguage: String    // ISO 639-1 language code
    let timestamp: Date             // When the transcription was performed
    let audioLengthSeconds: Double  // Length of the source audio
    let modelUsed: ModelSize        // Which model was used

    init(text: String, duration: TimeInterval, detectedLanguage: String,
         audioLengthSeconds: Double, modelUsed: ModelSize) {
        self.id = UUID()
        self.text = text
        self.duration = duration
        self.detectedLanguage = detectedLanguage
        self.timestamp = Date()
        self.audioLengthSeconds = audioLengthSeconds
        self.modelUsed = modelUsed
    }
}
```

### 3.7 `UserSettings` — Persisted User Preferences

```swift
struct UserSettings {
    // Activation
    var activationMode: ActivationMode = .pushToTalk
    var hotKeyCode: Int = 61                    // Right Option by default; selected key is reserved while running
    var doubleTapThreshold: Double = 0.4        // seconds

    // Audio
    var silenceThreshold: Float = 0.01          // RMS energy
    var silenceDuration: Double = 2.0           // seconds of silence to auto-stop
    var maxRecordingDuration: Int = 60          // seconds
    var selectedAudioDeviceID: String?          // nil = system default
    var selectedAudioDeviceName: String?        // last known display name for unavailable-device messaging

    // Model
    var selectedModelSize: ModelSize = .tiny
    var selectedLanguage: String = "auto"       // "auto" or ISO 639-1 code

    // Output polish (global defaults)
    var appendTrailingSpace: Bool = true        // Space after each completed utterance
    var autoCapitalize: Bool = true             // Capitalize sentence starts

    // Writing styles (per-app output shaping; overrides the polish defaults)
    var writingStyleEnabled: Bool = true
    var writingStyleDefault: WritingStyle = .plain
    var writingStyleBindings: [AppStyleBinding] = []  // JSON envelope in UserDefaults

    // Performance / power
    var autoPauseEnabled: Bool = false
    var autoPauseApps: [AutoPauseAppEntry] = [] // JSON in UserDefaults
    var autoPausePollIntervalSeconds: Double = 5
    var modelKeepAliveEnabled: Bool = false
    var modelKeepAliveIdleTimeoutSeconds: Double = 300

    // History
    var historyEnabled: Bool = true
    var historyKeepsAudio: Bool = true
    var historyRetention: HistoryRetention = .month   // day, week, month, forever

    // Shortcuts beyond the activation hotkey
    var escapeCancelsDictation: Bool = true
    var pasteLastShortcut: String = "9:9"      // HotKeyCombo.storageString ("keyCode:modifiers"), ⌃⌘V; "" = off
    var handsFreeShortcut: String = ""         // off until the user records one
    var mouseTriggerButton: Int = 0            // CGEvent button number; 0 = off, 2 middle, 3 back, 4 forward

    // Personal dictionary
    var customVocabulary: String = ""          // terms, newline-separated; also the Whisper prompt
    var wordReplacements: [WordReplacement] = []          // JSON in UserDefaults
    var dictionarySuggestions: [CorrectionSuggestion] = [] // JSON in UserDefaults
    var learnCorrectionsMode: LearnCorrectionsMode = .suggest
    var useScreenContext: Bool = true

    // App Behavior
    var launchAtLogin: Bool = false
    var preserveClipboard: Bool = true          // Restore clipboard after text injection
    var playSoundEffects: Bool = false          // Sound on start/stop recording
}
```

**Storage:** Each property maps to a `UserDefaults` key with the prefix `vocamac.`:
```
vocamac.activationMode     = "pushToTalk"
vocamac.hotKeyCode         = 61
vocamac.doubleTapThreshold = 0.4
vocamac.silenceThreshold   = 0.01
vocamac.appendTrailingSpace = true
vocamac.autoCapitalize = true
vocamac.autoPause.enabled = false
vocamac.autoPause.apps = "[]"
vocamac.modelKeepAlive.enabled = false
vocamac.modelKeepAlive.idleTimeoutSeconds = 300
vocamac.writingStyle.enabled = true
vocamac.writingStyle.defaultStyle = "plain"
vocamac.writingStyle.bindings = "{\"schemaVersion\":1,\"bindings\":[...]}"
vocamac.history.enabled = true
vocamac.history.keepAudio = true
vocamac.history.retention = "month"
vocamac.shortcuts.escapeCancels = true
vocamac.shortcuts.pasteLast = "9:9"
vocamac.shortcuts.handsFree = ""
vocamac.shortcuts.mouseButton = 0
vocamac.dictionary.replacements = <JSON [WordReplacement]>
vocamac.dictionary.suggestions = <JSON [CorrectionSuggestion]>
vocamac.dictionary.dismissedSuggestions = ["heard→Corrected", ...]
vocamac.dictionary.learnMode = "suggest"
vocamac.dictionary.screenContext = true
...
```

**Writing style bindings** are stored as a versioned JSON envelope rather than a
bare array, so the shape can change without a lossy migration.

Decoding is deliberately forgiving, because the failure mode it prevents is a
user losing every rule they configured:

- **Missing fields** in a `WritingStyleRules` payload take that field's default.
  A rule set written before a field existed keeps working when the field is
  added; synthesized `Codable` would throw instead.
- **One unreadable rule** is dropped and logged. The rest of the list survives.
- **A payload that is not JSON**, or one whose `schemaVersion` is newer than
  this build understands, degrades to "no bindings" — the default style, never
  a guess at an unknown shape.

See `WritingStyleBindingStore.decode(json:)` and `WritingStyleRules.init(from:)`.

### Wording and processing policy

`AppStyleBinding` also stores `intent` (`preserve`, `professional`, `casual`) and
`cleanup` (`inherit`, `off`, `raw`). Missing fields decode to `preserve` and
`inherit`, keeping existing rules inert with respect to wording changes. These
optional fields remain compatible with the version-1 binding envelope.

`WritingProfile` snapshots the resolved format, rules, intent, and policy for an
utterance. Formal/Casual require both the optional wording toggle and
Transcript Cleanup; model choice remains global. Code/Terminal bypass inference.
Raw returns the original speech-engine text without trimming, snippets, or polish.
Plain formatting continues to honor the global cleanup preference.

`DictationOutputPipeline` recognizes snippet triggers before inference and uses
validated ASCII tokens for exact spans. Command-bearing utterances and literal
escapes use deterministic formatting. Other eligible utterances receive one
cleanup-plus-intent inference, with original-wording fallback on rejected output,
missing models, unsupported language, or context limits. Custom cleanup prompts
apply only to Preserve; intent prompts have their own preservation contract.

`DictationOutputResult` retains original text, final text, and an outcome summary
in memory. Recording-generation checks discard obsolete results. A changed app
holds the result for explicit copying instead of injecting into the new app.
The next-dictation override is in-memory only and never edits app bindings.

Model evaluation: set `VOCAMAC_WRITING_EVALUATION_REPORT` to an absolute path and
run `swift test --filter WritingProfileModelEvaluationTests`. This uses an already
installed model, performs no downloads or text injection, and records rules-only,
LLM-only, and hybrid outputs over three repeated passes. Automated guards and
unit tests do not establish semantic equivalence or style quality; inspect the
report before changing the experimental status. Browser-tab and field identity
are not inferred from a bundle ID.

### Dictation history

`DictationHistoryStore` keeps a `DictationHistoryEntry` per dictation, newest
first. Each entry holds:

- the engine's raw text and the text that was typed, plus the pipeline summary
- the target app, model, language, and timings
- a status: `pending`, `completed`, `empty`, `failed`, `interrupted`, or `cancelled`
- the name of its WAV file (16-bit mono 16 kHz), when audio is kept

The WAV file is on disk **before** transcription starts.

Every change to an entry is appended synchronously to `journal.jsonl` as one
line holding the entry's latest state, or its deletion. The line is on disk
before VocaMac moves on, so a completed dictation survives a crash or force
quit. `index.json` holds the full history. It is rewritten at launch, after
bulk changes (Delete All, Delete Audio), and whenever the journal reaches 500
lines, and the journal is then cleared.

At launch the journal is replayed over the index, and a torn last line is
skipped. Then:

- A `pending` entry becomes `interrupted`, so a crash mid-dictation still
  leaves the audio to retry.
- An entry whose WAV file is missing is shown without audio. That covers a
  crash during the audio write, and a failed write.
- A file in `audio/` that no entry refers to is deleted. Each entry is
  journaled, naming its WAV file, before the file is written, so such a file
  can only be audio whose deletion was saved before its removal ran. Deleted
  recordings never come back.
- A recording is only deleted from disk after the journal or index write that
  drops it has succeeded. A deletion that can't be saved leaves the file in
  place, so the history on disk never points at audio that's already gone.

Storage limits:

- A successful dictation drops its audio when "Keep audio recordings" is off.
  Failed, interrupted, and cancelled dictations keep their audio until they are
  retried or deleted.
- At most 2,000 entries are kept.
- Audio is capped at 1 GB. The oldest recordings lose their audio first; their
  text stays.
- Retention (1 day, 7 days, 30 days, or forever) is applied at launch, at each
  dictation, and whenever the setting changes.

### Personal dictionary

`DictionaryCorrector` runs inside `DictationOutputPipeline`, after the Raw
check and before snippets, styles, and cleanup. It does three things, in this
order:

1. **Replacements.** Case-insensitive, whole-word matching; longest spoken form first.
2. **Vocabulary terms.** Letters are matched ignoring case, spaces, and
   punctuation, over up to four spoken words. On top of that, a conservative
   fuzzy match fixes terms of 5 or more letters: edit distance ≤ 1 (≤ 2 for 9
   or more letters), same first sound. It never applies when every word in the
   match is ordinary vocabulary according to the spell checker (English only).
3. **Screen terms.** Letter match only, never fuzzy. Several words are joined
   into a camelCase, snake_case, or kebab-case identifier only for the Code and
   Terminal formats.

A term whose casing formatting could change (`iPhone`, `kubectl`, `GitHub`)
travels through the snippet mask, so neither sentence case nor cleanup alters it.

`CorrectionObserver` reads the focused field about 0.8 s after injection. It
reads it again when the next dictation starts, or after 20 s. The text itself
is never stored. `CorrectionLearner` reduces the two readings to spelling-level
substitutions inside the dictated span. Depending on
`vocamac.dictionary.learnMode`, those become suggestions or are added directly.

### 3.8 `SystemCapabilities` — Hardware Detection Result

```swift
struct SystemCapabilities {
    let isAppleSilicon: Bool
    let physicalMemoryGB: Int
    let processorName: String
    let coreCount: Int
    let supportsMetalAcceleration: Bool
    let recommendedModel: ModelSize

    var summaryDescription: String {
        """
        Processor: \(processorName)
        Architecture: \(isAppleSilicon ? "Apple Silicon (ARM64)" : "Intel (x86_64)")
        Memory: \(physicalMemoryGB) GB
        Cores: \(coreCount)
        Metal: \(supportsMetalAcceleration ? "Supported" : "Not Available")
        Recommended Model: \(recommendedModel.displayName)
        """
    }
}
```

### 3.9 `AudioDevice` — Audio Input Device

```swift
struct AudioDevice: Identifiable, Hashable {
    let id: String              // Core Audio device UID
    let name: String            // Human-readable name
    let isDefault: Bool         // Is this the system default input?
    let sampleRate: Double      // Native sample rate
    let channelCount: Int       // Number of input channels
}
```

### 3.10 `GitHubRelease` — Latest Release API Payload

```swift
struct GitHubRelease: Codable {
    let tagName: String
    let name: String
    let body: String
    let htmlURL: URL
    let prerelease: Bool
    let draft: Bool
    let publishedAt: String
    let assets: [GitHubAsset]
}
```

### 3.11 `GitHubAsset` — Release Asset Metadata

```swift
struct GitHubAsset: Codable {
    let name: String
    let size: Int
    let browserDownloadURL: URL
    let contentType: String
    let digest: String?
}
```

### 3.12 `UpdateInfo` — Processed Update Candidate

```swift
struct UpdateInfo: Equatable {
    let version: String
    let tagName: String
    let releaseNotes: String
    let releasePageURL: URL
    let dmgURL: URL
    let dmgSize: Int
    let sha256: String?
}
```

### 3.13 `UpdateState` — Update UI/Service State

```swift
enum UpdateState: Equatable {
    case idle
    case checking
    case updateAvailable(UpdateInfo)
    case updateAvailableViaHomebrew(info: UpdateInfo, install: HomebrewInstall)
    case upToDate
    case downloading(progress: Double, bytesDownloaded: Int64, totalBytes: Int64, estimatedSecondsRemaining: Double)
    case verifying
    case readyToInstall(dmgPath: URL)
    case error(String)
}
```

---

## 4. Persistence Strategy

| Data | Storage | Lifetime |
|------|---------|----------|
| User settings | `UserDefaults` | Permanent (until app uninstall or reset) |
| Model files | `~/Library/Application Support/VocaMac/models/` | Permanent (user can delete) |
| Audio buffers | In-memory `[Float]` | Discarded after transcription |
| Transcription results | `~/Library/Application Support/VocaMac/History/` (`index.json` + `audio/*.wav`) | Per the history retention setting; off when history is disabled |
| App state | In-memory `AppState` | Rebuilt on each launch |
| System capabilities | Computed at launch | Rebuilt on each launch |
| Update check cache | `UserDefaults` (`vocamac.update.*`) | Persisted across launches |

### 4.1 File System Layout

```
~/Library/Application Support/VocaMac/
├── models/
│   ├── openai_whisper-tiny          ← Always present (bundled or downloaded)
│   ├── openai_whisper-base          ← Optional (downloaded)
│   ├── openai_whisper-small         ← Optional (downloaded)
│   ├── openai_whisper-medium        ← Optional (downloaded)
│   └── openai_whisper-large-v3     ← Optional (downloaded)
├── History/
│   ├── index.json             ← Dictation history snapshot
│   ├── journal.jsonl          ← Changes since the snapshot (replayed at launch)
│   └── audio/<entry-id>.wav   ← Recordings kept for playback and retry
└── logs/                      ← Future: debug logging
```

---

## 5. State Transitions

### 5.1 Recording State Machine

```
                    ┌─────────────┐
         ┌─────────│  App Launch  │──────────┐
         │         └─────────────┘           │
         ▼                                    ▼
  ┌──────────────┐                   ┌──────────────────┐
  │ Permissions  │                   │   Load Settings  │
  │   Check      │                   │   from Defaults  │
  └──────┬───────┘                   └────────┬─────────┘
         │                                     │
         ▼                                     ▼
  ┌──────────────┐                   ┌──────────────────┐
  │  Load Model  │◄──────────────────│  Detect Hardware │
  │  (tiny/def)  │                   │  & Recommend     │
  └──────┬───────┘                   └──────────────────┘
         │
         ▼
  ┌──────────────┐
  │    IDLE      │◄──────────────────────────────┐
  │   (Ready)    │                               │
  └──────┬───────┘                               │
         │ hotkey                                 │
         ▼                                       │
  ┌──────────────┐                               │
  │  RECORDING   │──── silence / hotkey ────┐    │
  │  (Capturing) │                          │    │
  └──────────────┘                          │    │
                                            ▼    │
                                     ┌───────────┴──┐
                                     │  PROCESSING  │
                                     │ (Transcribing│
                                     └──────┬───────┘
                                            │
                                            ▼
                                     ┌──────────────┐
                                     │ TEXT INJECT  │
                                     │ (Paste text) │
                                     └──────┬───────┘
                                            │
                                            ▼
                                        Back to IDLE
```

### 5.2 Model State Machine

```
  ┌──────────────┐
  │ NOT_DOWNLOADED│
  └──────┬───────┘
         │ user requests download
         ▼
  ┌──────────────┐
  │ DOWNLOADING  │──── cancel ────► NOT_DOWNLOADED
  │ (progress %) │
  └──────┬───────┘
         │ download complete + checksum verified
         ▼
  ┌──────────────┐
  │  DOWNLOADED  │
  │  (on disk)   │
  └──────┬───────┘
         │ user selects as active model
         ▼
  ┌──────────────┐
  │   LOADING    │──── error ────► DOWNLOADED (retry)
  │ (into memory)│
  └──────┬───────┘
         │ loaded successfully
         ▼
  ┌──────────────┐
  │    ACTIVE    │
  │ (in use)     │
  └──────────────┘
```

---

## 6. Key Constants

```swift
enum VocaMacConstants {
    static let appSupportDirectory = "VocaMac"
    static let modelsSubdirectory = "models"
    static let userDefaultsPrefix = "vocamac."

    // Audio
    static let whisperSampleRate: Double = 16000.0
    static let audioBufferSize: UInt32 = 4096
    static let audioChannelCount: UInt32 = 1

    // Defaults
    static let defaultHotKeyCode: Int = 61          // Right Option
    static let defaultDoubleTapThreshold: Double = 0.4
    static let defaultSilenceThreshold: Float = 0.01
    static let defaultSilenceDuration: Double = 2.0
    static let defaultMaxRecordingDuration: Int = 60
    static let defaultModelSize: ModelSize = .tiny
    static let defaultLanguage: String = "auto"

    // Text Injection
    static let clipboardSettleDelay: UInt32 = 50_000   // 50ms in microseconds
    static let pasteEventDelay: UInt32 = 10_000         // 10ms between key events
    static let clipboardRestoreDelay: Double = 0.15     // 150ms before restoring clipboard

    // Model Download
    static let downloadTimeoutSeconds: TimeInterval = 300
    static let downloadRetryAttempts: Int = 3
}
```
