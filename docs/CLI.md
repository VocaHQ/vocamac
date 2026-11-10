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

Only the selected model and language follow your app preferences. Translate-to-English is always off in headless mode, and the app's Dictionary is never read: the engine gets recognition hints only from `--vocabulary` (see [Recognition hints](#recognition-hints)).

Successful transcription writes exactly one JSON object to stdout (see [Plain text and output files](#plain-text-and-output-files) for `--text` and `--output`):

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

Stable error categories and their exit codes:

| Category | Exit code |
|---|---|
| `invalid_arguments` | 2 |
| `invalid_audio` | 3 |
| `model_not_found`, `model_not_downloaded`, `model_unsupported` | 4 |
| `transcription_failed` | 5 |
| `output_failed` | 6 |

Use `--help` for command syntax; it exits without launching the GUI.

## Plain text and output files

For scripts that only want the words, use `--text` in place of `--json`. It writes just the transcript and a trailing newline:

```bash
/Applications/VocaMac.app/Contents/MacOS/VocaMac --transcribe-file memo.m4a --text
```

`--output <file>` writes the result to a file instead of stdout, as JSON with `--json` or as plain text with `--text`. The file is replaced in one step, so another program never reads a half-written file. If it can't be written, the command exits with `output_failed`.

```bash
/Applications/VocaMac.app/Contents/MacOS/VocaMac \
  --transcribe-file memo.m4a --text --output memo.txt
```

Errors are written to stderr as JSON in every mode, with the exit codes above, so a script can tell a missing model from unreadable audio. `--text` and `--output` apply only to `--transcribe-file`, and not to `--pieces`.

## Recognition hints

`--vocabulary` passes words the engine should expect, as the app's Dictionary does, so you can check what hints change on a recording:

```bash
/Applications/VocaMac.app/Contents/MacOS/VocaMac \
  --transcribe-file /path/to/audio.wav \
  --vocabulary "GitHub, Kubernetes, Namrata" \
  --json
```

The value is a file when one exists at that path (one term per line, or comma-separated), and otherwise a comma-separated list. A value ending in `.txt` or `.csv` that names no file is an error. Each engine uses hints its own way (Whisper as a prompt, Parakeet as a vocabulary boost, Apple Speech as contextual strings), and keeps as many as it can take. With `--vocabulary`, the JSON result adds `vocabulary_terms`, the number of terms passed. `--pieces` accepts it too.

To measure hints over a whole corpus, with and without them, see [ACCURACY.md](ACCURACY.md).

## Supported audio

Files are read with AVFoundation: WAV, AIFF, CAF, M4A/AAC, MP3, MP4, and MOV work as they are. WebM, Ogg, and Opus files, such as most chat-app voice notes, need converting first, for example with `ffmpeg -i note.ogg -ac 1 -ar 16000 note.wav`.

## Use with Hermes Agent

[Hermes Agent](https://github.com/NousResearch/hermes-agent) can use VocaMac to transcribe voice messages from its desktop app, Telegram, WhatsApp, Discord, Slack, and Signal on your Mac, with no cloud speech API.

**With the plugin (recommended).** [hermes-vocamac](https://github.com/VocaHQ/hermes-vocamac) adds a `vocamac` speech-to-text provider. It also gives the agent a tool for transcribing audio and video files. It converts WebM and Ogg voice notes with ffmpeg, and it works with VocaMac 1.2.0 and later:

```bash
brew install ffmpeg
hermes plugins install VocaHQ/hermes-vocamac --enable
hermes config set stt.provider vocamac
```

**Without a plugin.** A Hermes command provider can call VocaMac directly. Add this to `~/.hermes/config.yaml`; `normalize: true` makes Hermes convert voice notes to 16 kHz mono M4A with ffmpeg first:

```yaml
stt:
  provider: vocamac-cli
  providers:
    vocamac-cli:
      type: command
      normalize: true
      command: "/Applications/VocaMac.app/Contents/MacOS/VocaMac --transcribe-file {input_path} --text --output {output_path}"
```

Either way, Hermes uses the model selected in VocaMac, and that model has to be downloaded already.

To check how "Process while speaking" would handle a recording, add `--pieces`. The file is decoded whole and then piece by piece, cut at pauses the way a live dictation is, and the response reports both texts, a word difference rate between them, and the projected wait after stop. Add `--cleanup <cleanup-model-id>` (for example `ministral3_3b_q4_k_m`) to clean both with a downloaded cleanup model, and `--pause-seconds` or `--min-piece-seconds` to try other cut thresholds:

```bash
/Applications/VocaMac.app/Contents/MacOS/VocaMac \
  --transcribe-file /path/to/audio.wav \
  --pieces --cleanup ministral3_3b_q4_k_m \
  --json
```

One-shot CLI mode loads the selected model in a separate process for each request. This preserves isolation from the running menu bar app, but the first request has the normal model-loading cost.
