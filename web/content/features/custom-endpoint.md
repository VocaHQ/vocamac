---
title: "Custom Endpoint"
subtitle: "Optionally send each recording to a Whisper-compatible server you host — OpenAI audio API or whisper.cpp — instead of running a local speech model."
description: "VocaMac's Custom Endpoint speech model uploads each recording to your OpenAI-compatible or whisper.cpp server and pastes the returned transcript. Opt-in, never the default."
keywords: "custom speech endpoint macOS, whisper compatible api dictation, remote whisper transcription, openai audio transcriptions mac, whisper.cpp server dictation, self-hosted speech to text mac"
icon: "🌐"
---

## Your Server, Your Model

Most VocaMac speech engines stay on this Mac. Custom Endpoint is the opt-in exception: when you select it, each finished recording is uploaded as a WAV file to a Whisper-compatible HTTP endpoint you configure, and VocaMac pastes the transcript the server returns.

Use it when you already run whisper.cpp, an OpenAI-compatible audio API, or another self-hosted speech stack and want VocaMac's hotkeys and paste flow without downloading another local model.

![VocaMac Settings showing the Speech Model page, where Custom Endpoint lives](/screenshots/settings-models.png)

## What It Speaks

Open **Settings → Speech Model**, select **Custom Endpoint**, and fill in:

| Setting | Meaning |
|---|---|
| Endpoint kind | **OpenAI-compatible** (`POST <base>/v1/audio/transcriptions`) or **whisper.cpp server** (`POST <base>/inference`) |
| Base URL | Your server's origin. HTTPS for anything outside this Mac or your local network. A trailing `/v1` on OpenAI-style bases is fine — VocaMac normalizes it. |
| Model | Sent as the OpenAI `model` field when that kind is selected; whisper.cpp ignores it. |
| API key | Optional Bearer token, stored in Keychain. Never put credentials in the URL. |

Recordings leave this Mac only while Custom Endpoint is the selected model. Switching back to any local engine returns to on-device transcription.

## Honest Limits

- Vocabulary hints stay on this Mac; they are not uploaded with the recording.
- Redirects that would downgrade HTTPS to cleartext HTTP are rejected, even to localhost.
- There is no Voca-hosted speech cloud — the destination is whichever server you typed in.

## Private by Design (for local engines)

Custom Endpoint is opt-in and explicit. Local engines keep audio on your Mac after their models are available. If you do not select Custom Endpoint, nothing in this feature applies.
