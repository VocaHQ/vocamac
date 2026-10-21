---
title: "Privacy Policy"
description: "What VocaMac does with your voice, your text, and your Mac. Short version: dictation runs on your Mac, there is no account, and VocaHQ collects nothing."
keywords: "VocaMac privacy policy, on-device dictation privacy, offline voice typing mac, no telemetry dictation"
---

_Last updated: October 21, 2026_

This policy covers VocaMac for macOS, whether you install it from the Mac App Store, Homebrew, or a DMG from GitHub Releases. VocaMac is made by VocaHQ and is open source under AGPL-3.0, so every statement here can be checked against [the source code](https://github.com/VocaHQ/vocamac).

## The short version

- **VocaHQ collects no data from VocaMac.** No account, no analytics, no advertising, no tracking, and no telemetry of any kind.
- **Dictation runs on your Mac.** Your audio is transcribed by a speech model on your own computer. It is not sent to VocaHQ or to any cloud speech service.
- **Optional features that use another server are off until you set them up**, and they talk only to a server you choose.

## Your voice and your text

VocaMac listens only while you hold (or toggle) the dictation shortcut. Audio is turned into text by the on-device engine you pick: WhisperKit, Parakeet, Apple Speech, or an ONNX model. The text is typed where your cursor is.

**History.** VocaMac keeps a history of your dictations on your Mac so you can search, copy, replay, and retry them. You choose how long entries are kept (from one day to forever) and whether the audio is kept, and you can delete everything in one click or turn History off. History is never uploaded or synced.

**Usage statistics** (words dictated, speaking speed, streaks) are calculated and stored only on your Mac. You can reset them at any time.

**Apple Speech.** If you choose Apple Speech, transcription uses Apple's on-device speech recognition, and macOS may download language assets from Apple. Apple's privacy policy applies to that.

## macOS permissions

- **Microphone**: to hear you while you dictate.
- **Accessibility**: to type the transcript into the app you are using and, for features such as spacing and editing commands, to read the text around your cursor in the focused field. That text is used on your Mac at that moment and is never stored or sent anywhere.
- **Input Monitoring**: to notice your dictation shortcut in any app. VocaMac does not record or log your keystrokes.

## When VocaMac uses the network

- **Model downloads.** Speech and cleanup models are downloaded from their public hosts (mainly Hugging Face) when you choose them. Like any download, those hosts see your IP address. No audio or text is sent.
- **Update check** (GitHub and Homebrew builds only). The direct-download app asks the GitHub Releases API whether a newer version exists. The Mac App Store version leaves updates to the App Store.
- **Custom Endpoint** (optional, off by default). If you point VocaMac at a speech server you run, each recording is uploaded to *that* server for transcription. VocaHQ never receives it.
- **Remote cleanup** (optional, off by default). If you connect Ollama, LM Studio, or another OpenAI-compatible endpoint, the transcript text (never audio) is sent to that endpoint to be cleaned up. API keys are kept in your macOS Keychain. The privacy policy of whichever service you choose applies to that text.

## Crash reports

If VocaMac crashes, it can offer to open a pre-filled bug report on GitHub the next time it starts. Nothing is sent unless you choose to post that report. Paths that contain your user name are removed from it, and you can review and edit it before posting.

## Your data, your control

Everything VocaMac stores stays on your Mac: settings, history, statistics, and downloaded models. Delete history and statistics from Settings, delete models from the Models page, or remove the app and its data entirely. Because VocaHQ holds no data about you, there is nothing for us to export, correct, or delete on our side.

## Children

VocaMac is a general-purpose productivity tool. It does not knowingly collect information from anyone, including children.

## Changes

If this policy changes, the new version will be posted on this page with a new date. The full history is in the [public repository](https://github.com/VocaHQ/vocamac/commits/main/web/content/privacy.md).

## Contact

Questions about privacy: [hello@vocahq.com](mailto:hello@vocahq.com), or open an issue on [GitHub](https://github.com/VocaHQ/vocamac/issues).
