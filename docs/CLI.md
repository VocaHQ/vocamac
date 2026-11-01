# Command-line transcription

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

To check how "Process while speaking" would handle a recording, add `--pieces`. The file is decoded whole and then piece by piece, cut at pauses the way a live dictation is, and the response reports both texts, a word difference rate between them, and the projected wait after stop. Add `--cleanup <cleanup-model-id>` (for example `ministral3_3b_q4_k_m`) to clean both with a downloaded cleanup model, and `--pause-seconds` or `--min-piece-seconds` to try other cut thresholds:

```bash
/Applications/VocaMac.app/Contents/MacOS/VocaMac \
  --transcribe-file /path/to/audio.wav \
  --pieces --cleanup ministral3_3b_q4_k_m \
  --json
```

One-shot CLI mode loads the selected model in a separate process for each request. This preserves isolation from the running menu bar app, but the first request has the normal model-loading cost.

## Lip reading from a video

Silent Mode's lip reader can read a video of a face mouthing English, with the same face tracking, mouth crops and model as the app:

```bash
/Applications/VocaMac.app/Contents/MacOS/VocaMac --read-lips ~/Movies/clip.mov --json
```

```json
{"duration_seconds": 2.9, "frames": 120, "frames_with_face": 120, "text": "hello how are you", "video_seconds": 4.0}
```

It needs the lip-reading model (`make lip-reading-model` in the source folder). `frames_with_face` counts frames where a face was close and square enough to read; when it is well below `frames`, move closer or face the camera.

