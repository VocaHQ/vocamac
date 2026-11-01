---
title: "Transcribe Audio and Video Files"
seoTitle: "Transcribe Audio and Video Files on Mac, Offline | VocaMac"
subtitle: "Drop a recording, a voice memo or a video and get the text back, using the speech model already on your Mac."
description: "Turn audio and video files into text on your Mac. Drop a file into VocaMac or use its command line; the selected on-device model does the work, up to 30 minutes."
keywords: "transcribe audio file mac, transcribe video to text mac, offline transcription mac, whisper transcribe file mac, speech to text file mac, command line transcription macos"
icon: "📁"
related: ["system-audio-transcription", "speech-engines", "languages"]
---

## Drop a File, Get the Text

Dictation isn't the only way speech reaches your Mac. Interviews, voice memos, lectures and screen recordings are already sitting in files. VocaMac transcribes them with the same speech model you dictate with.

1. Click the VocaMac icon in the menu bar and choose **Transcribe File**.
2. Drop an audio or video file onto the **Transcribe a File** window, or click **Choose File…**.
3. Transcription starts right away. When it finishes, **Copy** the transcript or **Save…** it as a plain-text file.

Any audio or movie format macOS can open is accepted, up to **500 MB and 30 minutes** per file. The window tells you where the work happens: "Processed on this Mac. Uses your selected speech model."

## What Applies to Files

File transcription uses your selected model and language, [translation to English](/features/translation/) if you turned it on, and your [custom vocabulary](/features/custom-vocabulary/). It does not run transcript clean-up, snippets or formatting, so you get what the model heard. Transcribed files count towards your [usage stats](/features/usage-stats/) but are not added to dictation history.

For the fastest results on long English recordings, try a Parakeet model; for other languages, see [Speech Engines](/features/speech-engines/) for which model fits.

## From the Command Line

VocaMac's app bundle doubles as a headless command-line tool. It never opens a window, never touches the microphone, and never downloads a model, so it suits scripts and batch jobs:

```
/Applications/VocaMac.app/Contents/MacOS/VocaMac --transcribe-file interview.m4a --json
```

The JSON response includes `text`, `model`, `engine`, `detected_language`, `duration_seconds` and `audio_length_seconds`. Other useful forms:

```
# pick a model and a language
/Applications/VocaMac.app/Contents/MacOS/VocaMac --transcribe-file memo.wav --json --model small --language de

# see which models are installed and which is selected
/Applications/VocaMac.app/Contents/MacOS/VocaMac --list-models --json
```

`--json` is required. Leave out `--model` and `--language` to follow the app's current settings. The model must already be downloaded in the app. Errors are written to stderr as JSON with an exit code: 2 for invalid arguments, 3 for audio that can't be read, 4 for a missing or unsupported model, and 5 if transcription fails. The same 500 MB and 30-minute limits apply.

## Privacy

With an on-device model, which is the default, the file is transcribed on your Mac and nothing is uploaded. If you selected [Custom Endpoint](/features/custom-endpoint/) as your speech model, the file's audio is sent to the server you configured, just like a dictation would be. Point Custom Endpoint at a server on this Mac, on a trusted local network, over Tailscale, or over HTTPS.
