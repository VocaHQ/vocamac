---
title: "Push-to-Talk"
seoTitle: "Push-to-Talk Dictation on Mac: Hold to Talk | VocaMac"
subtitle: "Hold a hotkey to record. Release to transcribe. Simple, predictable, no surprises."
description: "Hold Right Option or a hotkey you choose, speak, and let go: VocaMac types what you said at your cursor. Free, on-device push-to-talk voice typing for Mac."
keywords: "push to talk macOS, voice dictation hotkey, hold to record, speech to text shortcut, VocaMac push to talk"
icon: "🎯"
related: ["double-tap-toggle", "system-wide-text-injection", "visual-feedback"]
---

## How It Works

Push-to-Talk is the default activation mode in VocaMac. It's designed to feel as natural as using a walkie-talkie: **hold to speak, release to transcribe**.

1. **Press and hold** your chosen hotkey (Right Option ⌥ by default)
2. **Speak** naturally while the key is held down
3. **Release** the key when you're done
4. **Text appears** at your cursor, wherever you're typing

After you release the key, VocaMac processes the recording and inserts the result at the active cursor. The time varies with recording length, selected model, and Mac hardware.

## Why Push-to-Talk?

Most voice dictation apps use a click-to-start, click-to-stop model. That sounds simple, but in practice it creates ambiguity: *Am I recording right now? Did I forget to stop?*

Push-to-Talk eliminates that entirely:

- **No ambiguity**: if your finger is on the key, you're recording. If it's not, you're not.
- **No forgotten recordings**: release the key and recording stops automatically.
- **Clear feedback**: the menu bar and popover expose the active recording state; color is not the only signal.
- **Muscle memory**: after a few uses, it becomes second nature. Like holding Shift to capitalize.

## Choosing Your Hotkey

![VocaMac Settings showing activation mode and hotkey configuration on the Dictation page](/screenshots/settings-general.png)

VocaMac supports a wide range of hotkeys for Push-to-Talk activation:

- **Right Option (⌥)** - the default, ergonomic and rarely used by other apps
- **Left Option (⌥)** - if you prefer the left side
- **Right Command (⌘)** - for Command-key enthusiasts
- **Right Shift (⇧)** - another good ergonomic choice
- **Right Control (⌃)** - a comfortable reach for many keyboards
- **Function keys (F5-F12)** - if you prefer dedicated keys
- **Fn key** - the function key itself

Want a key that isn't in the list? Click **Record** next to the preset picker and press any key — VocaMac captures it and shows it as your "Custom" key (press Escape to cancel). While VocaMac is running, that key is reserved for activation.

You can change your hotkey anytime in **Settings → Dictation**.

## Set Up Push-to-Talk on Your Mac

1. **Install VocaMac** with Homebrew or the signed DMG, then open it. It lives in the menu bar, not the Dock.
2. **Grant three permissions** when asked: Microphone (to hear you), Input Monitoring (to notice the hotkey from any app), and Accessibility (to type the transcript at your cursor). Onboarding walks you through each one in System Settings → Privacy and Security.
3. **Pick a speech model.** Onboarding recommends one for your Mac's memory; the first download needs an internet connection, and after that transcription runs on your Mac.
4. **Hold Right Option, say a sentence, let go.** The words land wherever your cursor is.

## More Ways to Trigger Dictation

Holding a key is the default, but the **More Shortcuts** group on **Settings → Dictation** adds a few alternatives:

- **Mouse button**: use the middle button, or the back (button 4) or forward (button 5) button on a mouse that has them. It behaves exactly like the hotkey.
- **Hands-free dictation**: record a separate shortcut that you press to start and press again to stop, for when you would rather not hold a key. See [Double-Tap Toggle](/features/double-tap-toggle/) for the other hands-free option.
- **Escape cancels dictation**: on by default. Press Escape mid-recording to throw the dictation away instead of typing it.
- **Paste last dictation**: ⌃⌘V by default. Types your previous dictation again, for when it landed in the wrong window.

## How Long Can You Hold?

A recording stops on its own after the **Longest recording** limit in **Settings → Audio**, which is one minute by default. Choose anything from 15 seconds to 20 minutes. For long dictation, hands-free mode with [Silence Detection](/features/silence-detection/) usually feels better than holding a key for minutes.

## When the Hotkey Doesn't Respond

- **Nothing happens anywhere:** check that VocaMac is switched on under System Settings → Privacy and Security → Input Monitoring.
- **Recording works but no text appears:** check Accessibility in the same place, and make sure the cursor is in a field that accepts typed text.
- **It stops working in a password field or with Terminal's Secure Keyboard Entry:** macOS turns on Secure Event Input there. A lone modifier hotkey like Right Option keeps working; VocaMac also re-registers key combinations such as ⌥Space so they keep working while Secure Event Input is on.

## Visual Feedback

While recording, VocaMac gives you clear visual cues so you always know what's happening:

- **Menu bar icon and status text** indicate active recording
- **Audio level indicator** shows real-time input volume in the popover
- **Cursor indicator** (optional) shows a floating mic icon near your text cursor

## Works Across Text Fields

Push-to-Talk is intended for applications and fields that accept macOS text insertion, including:

- Text editors and IDEs (VS Code, Xcode, Sublime Text)
- Browsers (Chrome, Safari, Firefox, Arc)
- Communication apps (Slack, Teams, Discord)
- Productivity apps (Notes, Pages, Google Docs)
- Terminal emulators
- Email clients

VocaMac pastes the text at your cursor: it puts the transcript on the clipboard, sends ⌘V, then [restores your clipboard](/features/clipboard-preservation/), with an Accessibility-based fallback. The exact result depends on the target app, the active field, and Accessibility permission.

## Compared to Double-Tap Toggle

VocaMac also offers a **Double-Tap Toggle** mode as an alternative. Here's how they compare:

| Behavior | Push-to-Talk | Double-Tap Toggle |
|---|---|---|
| **Activate** | Hold key | Double-tap key |
| **Deactivate** | Release key | Double-tap again |
| **Best for** | Short dictations, quick notes | Longer dictations, hands-free |
| **Risk of forgetting** | None | Possible |
| **Physical effort** | Hold key continuously | Tap twice to start/stop |

Most users prefer Push-to-Talk for its simplicity and reliability. But if you regularly dictate for more than 30 seconds at a time, Double-Tap Toggle might be more comfortable.

You can switch between modes anytime in **Settings → Dictation**.
