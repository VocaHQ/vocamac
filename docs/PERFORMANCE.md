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

Capture resamples each recording as one continuous signal: the converter keeps
its filter state from one tap buffer to the next and starts clean on each new
tap. At stop, a live session's input ends as soon as the microphone stops, so
the last piece decodes while History is written and the screen context is read.
Whisper is the exception while its screen terms are still arriving.

Every load and batch decode has a deadline (`Deadline`): 30 minutes for a first
Neural Engine compile or Apple Speech, 5 minutes for a load from CoreML's cache,
and 30 s plus three times the audio length (at least 60 s) for a decode. A miss
drops the model, so the next dictation loads a fresh copy instead of queueing
behind a call that never returns. A live session that is cancelled and does not
stop within 3 s gives the engine back the same way. Whisper and Parakeet run a
short warm-up decode after each load.

A push-to-talk press while the previous dictation is still finishing opens the
microphone at once. The queued dictation adopts that capture when it starts, or,
if the key already came up, is transcribed with the audio from while it was down.

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

For transcription accuracy, point the speech benchmark at a corpus of
`<name>.wav` + `<name>.txt` reference pairs kept outside the checkout:

```sh
VOCAMAC_ACCURACY_CORPUS=/path/to/corpus \
VOCAMAC_ACCURACY_MODELS=tiny,parakeet-tdt-0.6b-v3 \
swift test --filter SpeechAccuracyBenchmarkTests
```

Each model loads through the app's `TranscriptionRouter`, so silence trimming,
decoding options and retries match a real dictation. The JSON report (in
`$TMPDIR`, or `VOCAMAC_ACCURACY_OUTPUT`) has each file's transcript and word
error rate, the corpus WER per model, empty transcripts, and the first decode
after the load next to the median warm decode. Models that are not downloaded
are skipped unless `VOCAMAC_ACCURACY_ALLOW_DOWNLOAD=1`. Set
`VOCAMAC_ACCURACY_LANGUAGE`, `VOCAMAC_ACCURACY_VOCABULARY` (comma-separated
Dictionary terms), or `VOCAMAC_ACCURACY_MAX_WER` (for example `0.15`) to fail
on a regression. Real microphone recordings find more than synthetic `say`
audio does. Compare a change against the same corpus before and after.

Before release, compare short and long clips, selected and automatic languages,
built-in/USB/Bluetooth microphones, rapid start/stop, cancellation, model changes,
clipboard images/rich text, and unresponsive target apps. Track median/p95 latency,
peak resident memory, idle wakeups and transcription accuracy together.
