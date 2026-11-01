---
title: "System Audio Transcription"
seoTitle: "Transcribe System Audio on Mac, No Virtual Driver | VocaMac"
subtitle: "Capture what your Mac is playing, up to 20 minutes, and turn it into text on your Mac."
description: "Transcribe a video, webinar or call your Mac is playing. VocaMac captures system audio without a virtual audio driver and transcribes it on-device."
keywords: "transcribe system audio mac, transcribe what mac is playing, transcribe zoom audio mac, transcribe youtube video mac offline, mac system audio to text, no blackhole driver"
icon: "🔊"
related: ["transcribe-audio-files", "speech-engines", "translation"]
---

## Turn What Your Mac Plays Into Text

Sometimes the speech you want written down isn't yours: a webinar, a recorded talk, a video tutorial, or the other side of a call. System audio transcription captures whatever your Mac is playing and transcribes it with your selected speech model.

1. Click the VocaMac icon in the menu bar and choose **System Audio**.
2. In the **System Audio Transcription** window, click **Start Capture** and play the audio.
3. Click **Stop and Transcribe**. Copy the transcript or save it as a text file.

Playback continues normally while VocaMac listens; nothing is muted. A timer shows how much of the 20-minute limit you have used.

## No Virtual Audio Driver

Capturing system audio on a Mac used to mean installing a loopback driver and rerouting your sound output. VocaMac uses the system audio tap that Apple added in macOS 14.2, so there is nothing to install and your sound settings stay as they are.

The first time, macOS asks you to allow VocaMac under **System Settings → Privacy and Security → Screen and System Audio Recording**. If a capture comes back silent, that permission is the first thing to check.

## What to Expect

- **macOS 14.2 or later** is required for capture.
- **Up to 20 minutes** per capture. If you reach the limit, VocaMac transcribes what it has.
- **System output only.** Your microphone is not recorded, so on a call you get the other participants, not yourself. Use [push-to-talk](/features/push-to-talk/) dictation for your own words.
- **Text after you stop.** There is no live caption while capturing, and the transcript has no speaker labels.

For audio that is already in a file, [Transcribe Audio and Video Files](/features/transcribe-audio-files/) is quicker: no need to play it back in real time.

## Privacy

Captured audio is transcribed by your selected speech model. With an on-device model, which is the default, it never leaves your Mac. If you selected [Custom Endpoint](/features/custom-endpoint/) as your speech model, the captured audio is sent to the server you configured; keep that server on this Mac, on a trusted local network, behind Tailscale, or on HTTPS. Recording other people may need their consent where you live.
