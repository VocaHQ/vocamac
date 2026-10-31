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

## MCP server

`--mcp` runs VocaMac as a [Model Context Protocol](https://modelcontextprotocol.io) server on stdin and stdout, so a local coding agent can use your dictations, your Dictionary, and VocaMac's speech models. It opens no network port: the agent starts the binary and talks to it through a pipe, and nothing leaves the Mac. Settings → Advanced → Coding agents copies the setup command for your copy of the app.

Claude Code:

```bash
claude mcp add vocamac -- /Applications/VocaMac.app/Contents/MacOS/VocaMac --mcp
```

Cursor (`~/.cursor/mcp.json`), and other clients that take the same JSON:

```json
{
  "mcpServers": {
    "vocamac": {
      "command": "/Applications/VocaMac.app/Contents/MacOS/VocaMac",
      "args": ["--mcp"]
    }
  }
}
```

Tools:

| Tool | What it does |
|---|---|
| `transcribe_file` | Transcribes an audio or video file with a downloaded model (`path`, optional `model` and `language`), the same as `--transcribe-file`. |
| `list_models` | The `--list-models` catalog. |
| `latest_dictation` | The most recent dictations (`count`, 1 to 50): the typed text, what was heard when cleanup changed it, the app, and when. |
| `search_history` | Dictations containing every word of `query`, newest first (`limit`, 1 to 50). |
| `dictionary_terms` | Vocabulary terms and replacements. |
| `add_dictionary_term` | Adds a `term`, plus a replacement from `heard` when the engine writes it differently. A running VocaMac picks the change up at once. |
| `start_dictation`, `stop_dictation` | Ask the running app to start recording, or to stop and type the transcript. VocaMac asks you to confirm the first time. |

Each dictation is also a resource, `vocamac://history/<id>`, readable as Markdown; `resources/list` names the newest 100.

What the server can see follows the app's own settings: dictations into apps you keep out of History were never saved, and turning History off stops new ones being saved. History is read from its files without changing them, so the server never interferes with a running VocaMac. The server is not in the Mac App Store build, whose sandbox keeps its files out of reach of a process started from a terminal.
