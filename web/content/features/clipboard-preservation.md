---
title: "Clipboard Preservation"
subtitle: "Your clipboard is saved and restored after text injection. Nothing gets overwritten."
description: "VocaMac preserves your clipboard contents during text injection. Your copied text is saved before injection and restored afterward, so nothing is lost."
keywords: "clipboard preservation dictation, save clipboard voice typing, paste without overwrite, clipboard restore macOS, text injection clipboard, non-destructive dictation"
icon: "📋"
---

## The Problem

Most voice dictation apps use a simple approach to inject text into your document: they paste the transcribed words directly using keyboard commands (Cmd+V). This works, but it has a critical flaw.

When you paste, macOS uses your clipboard. The text you want to inject goes into the clipboard, then gets pasted into your document. But here's the issue: **whatever was on your clipboard before gets overwritten**. If you had copied a link, a code snippet, or an important note, it's gone.

Imagine this scenario:

1. You copy a code snippet you want to reference: `function getData() { ... }`
2. You open a text editor and start dictating
3. VocaMac transcribes your words and pastes them
4. Your clipboard now contains the dictation text
5. You try to paste that code snippet later, only to discover it's gone

This is inconvenient. This is frustrating. And it's completely preventable.

## How VocaMac Solves It

VocaMac uses **clipboard preservation** to ensure your original clipboard contents are never lost. The process is simple but elegant:

1. **Before injecting text**: VocaMac saves whatever is currently on your clipboard to temporary storage
2. **Inject the transcribed text**: VocaMac pastes the dictated words into your document (using your clipboard)
3. **After injection**: VocaMac restores your original clipboard contents

The end result: your dictated words appear in your document, and your clipboard is exactly as it was before you started dictating.

This happens in milliseconds. You won't see any flickering or delay. It's seamless.

## How Text Injection Works Under the Hood

Text injection in VocaMac relies on macOS's accessibility APIs. Here's what happens when you dictate:

**Step 1: Grab focus**

VocaMac uses the Accessibility API to identify the currently active text field (the place where your cursor is).

**Step 2: Prepare the text**

The transcribed text from WhisperKit is cleaned up: punctuation is added where appropriate, extra spaces are removed, and the text is formatted for readability.

**Step 3: Handle the clipboard**

Here's where clipboard preservation comes in. VocaMac:
- Reads the current clipboard using `NSPasteboard`
- Saves it to a temporary variable
- Writes the transcribed text to the clipboard
- Simulates a paste command (Cmd+V) to inject the text into the active field

**Step 4: Restore the clipboard**

Immediately after the paste completes, VocaMac:
- Checks that the paste was successful
- Restores the original clipboard contents
- Returns to idle state

The paste-and-restore window is kept to roughly 200 milliseconds, giving the target app enough time to consume the paste event while preserving your original clipboard.

## Enabling and Disabling

Clipboard preservation is enabled by default in VocaMac. It's the smart, safe default.

If you ever need to disable it (though this is rare), you can do so in **Settings → General → Text Injection → Preserve Clipboard**.

When disabled, VocaMac will inject text without saving and restoring your clipboard. This is slightly faster but carries the risk of losing your clipboard contents. We recommend keeping it enabled.

## Edge Cases and Reliability

VocaMac's clipboard preservation handles several edge cases gracefully:

**Empty clipboard**

If your clipboard is empty when you start dictating, VocaMac will restore it to empty after injection. No problem.

**Clipboard changes during dictation**

If you copy something new while VocaMac is in the middle of recording, your clipboard will contain the new item (as expected). VocaMac restores whatever was on the clipboard at the moment recording *started*, so the new item is preserved.

**Multiple pastes**

If VocaMac needs to inject text into multiple locations (in a future multi-cursor feature, for example), it will restore the original clipboard only after all injections are complete.

**Clipboard managers and sync**

If you use a clipboard manager or iCloud clipboard, VocaMac respects those tools:
- Clipboard managers see the save and restore sequence
- iCloud clipboard will sync with your iPad and iPhone during that process
- VocaMac doesn't bypass or interfere with these systems

**Failed injection**

In rare cases where the paste fails (an app doesn't respond to the accessibility API), VocaMac will still restore your original clipboard. Nothing is lost.

## Why This Matters

Clipboard preservation is a small feature that makes a big difference in daily workflows:

**Creative professionals**: writers, designers, and developers who frequently copy and paste references, code, or inspiration can dictate freely without losing their clipboard

**Knowledge workers**: researchers, students, and analysts can have multiple sources open, copy relevant snippets, and dictate notes without losing those snippets

**Power users**: anyone with a clipboard manager or custom clipboard workflow benefits from VocaMac's non-destructive approach

**Peace of mind**: you can dictate without worrying about accidentally losing something important

## Comparison with Other Dictation Tools

Many voice-to-text apps on macOS handle clipboard carelessly. VocaMac is one of the few that prioritizes your data integrity. Here's how we compare:

| Feature | VocaMac | Typical App |
|---------|---------|-------------|
| **Preserves clipboard** | Yes | No |
| **On-device transcription after model download** | Yes | No |
| **Adjustable silence detection** | Yes | Rare |
| **Menu bar integration** | Yes | No |
| **Open source** | Yes | No |

Clipboard preservation is just one example of how VocaMac is designed with your workflow in mind, not against it.

## Technical Implementation

For developers interested in how this works, VocaMac's clipboard preservation is implemented using:

- **NSPasteboard**: Apple's standard API for reading and writing clipboard contents
- **Accessibility APIs**: to detect the active text field and simulate paste commands
- **Timing precision**: ensuring operations happen in the correct order without race conditions

The implementation is part of VocaMac's open source codebase. If you're curious, you can review the exact implementation on GitHub.
