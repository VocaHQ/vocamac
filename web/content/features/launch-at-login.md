---
title: "Launch at login"
seoTitle: "Launch at Login on Mac: Start VocaMac at Startup"
subtitle: "Start VocaMac with your Mac so the menu-bar shortcut is ready when you are."
description: "Turn on Launch at Login and macOS opens VocaMac when you sign in, using Apple's SMAppService, so push-to-talk dictation is ready in the menu bar."
keywords: "launch at login macOS, auto start menu bar app, SMAppService, startup app mac, always ready dictation"
icon: "🚀"
related: ["github-release-updates", "fully-configurable", "push-to-talk"]
---

## Ready in the menu bar

![VocaMac Settings showing Launch at Login toggle](/screenshots/settings-application.png)

Enable **Launch at Login** in VocaMac's Application settings and macOS starts the app when you sign in. VocaMac uses Apple's SMAppService login-item API, and the setting is also visible in **System Settings → General → Login Items** (called **Login Items and Extensions** on macOS 15 and later). Onboarding offers the same switch, so most people never need to look for it.

## Turn it on, check it, turn it off

1. Click the VocaMac icon in the menu bar and choose **Settings…** (⌘,).
2. Go to **VocaMac → Application** and switch on **Launch at Login** ("Opens VocaMac in the menu bar when you sign in").
3. To confirm, open **System Settings → General → Login Items**. VocaMac appears under **Open at Login**.
4. To stop it, switch the toggle off in VocaMac.

Because VocaMac registers itself through SMAppService, there is no helper app, LaunchAgent plist or `launchatlogin` script to manage by hand.

This controls when the app starts; it does not force a speech model to stay loaded. Model loading and model keep-alive behavior remain separate settings so you can choose the resource trade-off that fits your Mac.

## Local and quiet

The menu-bar app can be ready without opening a large window. Audio is captured only during a recording session, and transcription uses the selected model (local by default). Custom Endpoint uploads recordings when you choose it. Model downloads, update checks, and release downloads are separate network actions; enabling launch at login does not turn on website analytics or telemetry.

You can disable the login item from VocaMac or from macOS System Settings. Release builds are Developer ID signed; ad-hoc source builds may require permissions again after rebuilding.
