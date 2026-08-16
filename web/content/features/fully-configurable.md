---
title: "Fully Configurable"
subtitle: "Choose hotkeys, models, languages, silence detection. Settings window with model management."
description: "VocaMac is fully configurable with a comprehensive settings window. Customize hotkeys, choose Whisper models, set languages, tune silence detection, and more."
keywords: "configurable dictation app, custom hotkey voice typing, whisper model settings, silence detection settings, voice to text preferences macOS"
icon: "⚙️"
---

## Make VocaMac Your Own

![VocaMac Settings - General tab](/screenshots/settings-general.png)

VocaMac understands that everyone has different preferences. Some people use dictation occasionally. Others rely on it for hours every day. Some work in quiet offices. Others dictate in bustling environments. The app adapts to your workflow through comprehensive, intuitive settings.

Every major aspect of VocaMac can be customized. Hotkeys, audio behavior, transcription models, languages, and more. The settings window is organized into clear tabs that match how you think about the app.

## Hotkey Configuration

Your hotkey is how you activate VocaMac. The app respects how you work and lets you pick the single activation key that suits you best.

Start from a preset — Right Option, Left Option, Right Command, Right Shift, Right Control, Fn, or a function key (F5–F12). Prefer something else? Click **Record**, press any key, and VocaMac captures it (press Escape to cancel). Your choice shows up as a "Custom" key, and while VocaMac is running that key is reserved for activation.

The hotkey is global while VocaMac is running, so you can trigger it while working in Mail, Slack, a browser, or another app. The target app still needs to expose a text field for insertion.

## Model Management

VocaMac includes multiple Whisper models, each offering different tradeoffs between speed, memory, and accuracy. The settings window gives you control over which models are available on your Mac.

The Base model is a small download and transcribes quickly. It is useful for quick notes or when speed and disk space matter more than maximum accuracy.

Small, compact Large, and Distil variants offer different accuracy and speed trade-offs. Choose among the models shown in Settings rather than assuming every legacy Whisper size is part of the stable catalog.

The model management interface shows how much disk space each model uses. Download the models you want and switch the selected model from Settings. Model deletion is available in newer nightly/source builds, not the v0.7.2 release catalog.

## Audio Settings

Audio behavior can make or break the dictation experience. VocaMac includes granular controls for how it handles microphone input and silence detection.

Set the silence detection threshold to match your environment. In a quiet office, a lower threshold may work well; in a noisier space, a higher threshold can help avoid accidental stops. Test the setting with your microphone and speaking style.

Configure the maximum recording duration. If you prefer shorter bursts of dictation, set a reasonable limit. The app will automatically stop recording when you reach it, preventing accidental marathon recording sessions.

Choose your audio input device. Leave it on **System Default** to follow macOS, or pin VocaMac to a specific microphone — an external mic, a USB headset, or AirPods Pro. Pinning is non-invasive: VocaMac uses your chosen device without changing the system-wide default for other apps. If that device disconnects, VocaMac falls back to System Default automatically and resumes using it when the device reconnects. Plugged something in? Hit **Refresh Devices** to update the list.

## Language and Transcription Settings

Set your primary language for more accurate transcription. If you dictate in multiple languages, enable auto-detection. The app will listen to what you're saying and automatically recognize which language you're using.

Language settings are remembered across sessions. Switch languages whenever you need to. The change takes effect immediately.

## General Preferences

The General tab includes behavior options that fine-tune how VocaMac fits into your workflow.

Preserve clipboard content. By default, VocaMac doesn't overwrite what's already in your clipboard. If you copy something before dictating, it will be safe.

Show a cursor indicator while recording. A subtle visual indicator in the menu bar helps you know when VocaMac is listening.

Enable sound effects for recording and transcription. Some people love the audio feedback. Others prefer silence. Choose what works for you.

Launch VocaMac automatically when you log in. The app is most useful when it's always available, so auto-launch makes sense for most users.

## About Tab

The About tab shows your app version, links to documentation, and quick access to system information. It's your reference point for understanding what you're running and where to find help.

## Designed for Simplicity

All of these options exist, but none of them overwhelm you. VocaMac follows Apple's philosophy of powerful defaults. The out-of-the-box settings work beautifully for most people. The settings window is there for those who want to customize.

Everything is organized logically. Related options are grouped together. Explanations are clear and concise. You can make changes in seconds, and they take effect immediately. No restarts needed. No confusing configuration files to edit.

Whether you're fine-tuning every detail or accepting sensible defaults, VocaMac gives you the control you need to make it work exactly how you want.
