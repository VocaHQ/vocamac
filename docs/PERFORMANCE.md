# Dictation performance

Use a release build on a fixed Mac, OS version, model and language. Record cold
model preparation separately from warm dictation. Hosted CI timing is noisy and
must not become a hard latency threshold.

## Engine and capture behavior

Apple Speech preheats its first analyzer during model loading. GUI recording
feeds a bounded stream while the microphone runs. Each subsequent utterance
creates a fresh analyzer while recording; a finished analyzer is never reused.
The router serializes the complete session with model changes and unloads.
The CLI uses the same preparation/conversion code with pull-based batch chunks.

The capture stream buffers at most 32 tap chunks. Overflow, sample discontinuity,
or an incomplete stream triggers batch decoding of the full retained recording;
partial streamed text is never injected. Cancellation releases the consumer and
allows queued model operations to finish. Whisper, Parakeet and ONNX retain their
batch decoding behavior and accuracy policies.

Capture reuses mono/conversion PCM buffers and reserves sample storage before
installing the tap. It transfers the final sample array on stop. Streaming alone
makes an additional owned copy per tap chunk, since the converter reuses its
scratch buffer. ONNX segmentation retains ranges and materializes one segment at
a time. Recovery framing and attempt limits remain unchanged; retries reuse
preparation storage and expose separate timings.

Accessibility queries run on serial workers with bounded messaging timeouts;
overlay queries never accumulate while another query is pending. Results from a
previous overlay or frontmost app are discarded. Clipboard access stays on the
main queue, yielding between batches of representations and restarting when the
clipboard generation changes. A single promised representation supplied by
another app can still block that individual read. Preservation never silently
drops formats to meet a time budget. Paste and clipboard-restore delays remain
50 ms and 150 ms. An uncertain Accessibility write does not trigger a second paste.

## Instruments

Record Time Profiler, Allocations, and Points of Interest for subsystem
`com.vocamac`, category `Performance`. Existing hotkey/start/model/stop intervals
remain available. Additional intervals/events distinguish:

- `OperationQueueWait`: waiting for earlier model/inference work.
- `AppleSpeechPreparation`, `AppleSpeechAudioConversion`, `StreamingFinalize`:
  analyzer setup, chunk conversion, and remaining work after stop.
- `ONNXFirstAttempt`, `ONNXRecoveryAttempt`: initial inference versus recovery.
- `CaretAccessibilityQuery`, `TextAccessibilityQueryAndWrite`: cross-process IPC.
- `ClipboardSnapshot`: preservation cost; debug logging reports snapshot bytes.
- `TextDeliveryQueueAndDispatch`, `PasteEventPosted`, `AccessibilityTextInserted`:
  queued delivery through dispatch and clipboard restoration.
- `StreamingBatchFallback`: invalidated live session using the complete recording.

`StopToResultQueued` ends when AppState queues delivery, not when text appears in
another app. `PasteEventPosted` also cannot prove that the target has consumed the
paste. Measure target-side appearance separately in manual UI acceptance.

## Repeatable checks

```sh
swift test
VOCAMAC_TEST_APPLE_SPEECH=1 swift test --filter AppleSpeechAudioTests
VOCAMAC_KEEP_RUNNING=1 CODE_SIGN_IDENTITY=- ./scripts/build.sh release
```

The Apple Speech acceptance test uses existing English system assets and skips
when they are absent. It does not record a microphone or install speech assets.

For an optional release benchmark, use a local audio fixture and write the report
outside the checkout:

```sh
VOCAMAC_BENCHMARK_AUDIO=/tmp/dictation.wav \
VOCAMAC_BENCHMARK_OUTPUT=/tmp/dictation-performance.json \
swift test -c release -Xswiftc -enable-testing --disable-swift-testing --filter DictationPerformanceTests
```

This compares prepared batch time with stop-to-result time after feeding the
same clip at microphone pace. The report includes both transcripts for accuracy
review. It measures engine behavior, not microphone startup, total energy, or
actual paste consumption. Stop other builds before collecting timings.

Before release, compare short and long clips, selected and automatic languages,
built-in/USB/Bluetooth microphones, rapid start/stop, cancellation, model changes,
clipboard images/rich text, and unresponsive target apps. Track median/p95 latency,
peak resident memory, idle wakeups and transcription accuracy together.
