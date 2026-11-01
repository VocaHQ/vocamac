---
title: "Command Mode"
seoTitle: "Edit Text by Voice on Mac: Command Mode | VocaMac"
subtitle: "Select text in any app, press a shortcut, and say what to change. With nothing selected, say what to write."
description: "Select text in any Mac app and say “make this shorter” or “translate to Spanish”. VocaMac rewrites it with Apple Intelligence or a local model you choose."
keywords: "edit text by voice mac, voice commands mac, rewrite selected text mac, ai writing tools mac, dictation command mode, voice text editing"
icon: "✨"
related: ["transcript-cleanup", "writing-styles", "snippets"]
---

## Edit by Voice

Dictation gets words onto the page. Command Mode changes the words that are already there. Select a sentence, a paragraph or a whole email in any app, press the Command Mode shortcut, and say what you want:

- "make this shorter"
- "fix grammar and spelling"
- "make it more formal"
- "turn this into bullet points"
- "translate to Spanish"
- "sort these lines"

VocaMac replaces the selection with the result. If nothing is selected, Command Mode writes instead: say "write a polite reply" and the text is typed at your cursor. Say "undo that" or "put it back" to restore the original.

If the text can't be edited, such as a web page or a PDF, you get the answer shown instead of a paste. After an edit, the menu bar keeps **Copy Original** and **Copy Result** so nothing is lost.

## Turn It On

Command Mode is off until it has a shortcut. Open **Settings → Command Mode** (under **Writing**) and either record your own shortcut or click **Use ⌃⌥⌘E** for the suggested one. Press it once, speak, and press again, or hold it while you speak. Command Mode needs the Accessibility permission to read and replace the selection.

## Quick Edits That Need No Model

Some instructions are handled by plain rules, instantly and with no language model at all:

- **Case:** uppercase, lowercase, title case, sentence case, camel case, snake case, kebab case, Pascal case, constant case
- **Lines:** sort, reverse, remove duplicates, join lines, trim
- **Lists:** bulleted or numbered list
- **Wrapping:** quotes, brackets, backticks, or a code block

That makes Command Mode handy for code as well as prose: select `user id` and say "camel case" to get `userId`.

## Saved Commands

Instructions you use often can be saved under **Saved Commands**. Say a saved command's name in Command Mode, or give it its own shortcut to run it on the selection without speaking at all. One click adds three starters: "Fix grammar", "Shorter" and "More formal".

## Review Before Replacing

**Review edits before replacing** shows what changed and waits: press the Command Mode shortcut to replace, or Esc to discard. Choose **Never** (the default), **Long selections** or **Always**.

Some terminals and editors don't share selected text with other apps. **Copy the selection when an app hides it** (off by default) copies it with ⌘C and puts your clipboard back right away. Clipboard managers may briefly see the selected text.

## Which Model Does the Editing

Rewrites need a language model. You choose which one:

- **Apple Intelligence**, on macOS 26 with Apple Intelligence turned on. It runs on your Mac.
- **A local model** that VocaMac downloads and runs on your Mac, from Qwen 2.5 1.5B up to Qwen 2.5 7B. VocaMac suggests one that fits your Mac's memory.
- **A server you run**: Ollama, LM Studio or an OpenAI-compatible endpoint.

With Apple Intelligence or a local model, the selected text and your instruction stay on your Mac. **If you choose a server, the selected text and your instruction are sent to the endpoint you configured.** Use a server on this Mac (localhost), on a trusted local network, over Tailscale, or over HTTPS; VocaMac requires HTTPS for anything that is not on this Mac or your local network.

## Voice Actions (Optional)

**Voice actions** are off by default. When you turn them on, Command Mode can also act on what you say: "open Safari", "search the web for…", "remind me to…" or "run the shortcut…". Only your spoken words start an action, never the selected text. A web search opens Google in your browser, reminders go through the Reminders app (macOS asks for Automation permission the first time), and only the Apple Shortcuts you list under **Shortcuts VocaMac may run** can ever run.
