---
title: "Launch at login"
subtitle: "Start VocaMac with your Mac so the menu-bar shortcut is ready when you are."
description: "VocaMac can register as a macOS login item using SMAppService and remain ready in the menu bar without a manual launch."
keywords: "launch at login macOS, auto start menu bar app, SMAppService, startup app mac, always ready dictation"
icon: "🚀"
---

## Ready in the menu bar

![VocaMac Settings showing Launch at Login toggle](/screenshots/settings-general.png)

Enable **Launch at Login** in VocaMac's General settings and macOS starts the app when you sign in. VocaMac uses Apple's SMAppService login-item API, and the setting is also visible in **System Settings → General → Login Items**.

This controls when the app starts; it does not force a speech model to stay loaded. Model loading and model keep-alive behavior remain separate settings so you can choose the resource trade-off that fits your Mac.

## Local and quiet

The menu-bar app can be ready without opening a large window. Audio is captured only during a recording session, and transcription uses the selected local model. Model downloads, update checks, and release downloads are separate network actions; enabling launch at login does not turn on website analytics or telemetry.

You can disable the login item from VocaMac or from macOS System Settings. Release builds are Developer ID signed; ad-hoc source builds may require permissions again after rebuilding.
