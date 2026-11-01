---
title: "Snippets"
seoTitle: "Voice Text Expansion on Mac: Dictation Snippets | VocaMac"
subtitle: "Say a short phrase, get the full text: your email address, a sign-off, a link or a paragraph you type every day."
description: "Save text once and type it by voice. Say a snippet's trigger phrase while dictating and VocaMac types your email address, sign-off or link instead."
keywords: "voice text expansion mac, dictation snippets, text expander voice, dictate email address mac, voice shortcuts typing, speech text replacement"
icon: "📋"
related: ["custom-vocabulary", "writing-styles", "command-mode"]
---

## Say a Phrase, Type the Whole Thing

Some text is tedious to say and easy to get wrong: email addresses, long links, your address, a standard reply. Snippets let you save it once and type it by voice. While dictating, say the snippet's trigger phrase and VocaMac types the saved text in its place.

![VocaMac Settings showing the Snippets page with trigger phrases and expansion text](/screenshots/settings-snippets.png)

## Add a Snippet

1. Open **Settings → Snippets** (under **Writing**).
2. Click **Add Snippet…**.
3. Enter a **Trigger Phrase**, such as "my mail", and the **Expansion Text**, such as your email address.
4. Dictate as usual. "Send it to my mail" comes out with your address in place of "my mail".

Once you have more than a handful, a search box appears so you can find one quickly.

## How Matching Works

- **Whole words, any case.** "My Mail", "my mail" and "MY MAIL" all match; "mymailbox" does not.
- **Longest trigger wins.** If you have both "my mail" and "my mail work", saying the longer one types the longer snippet.
- **Your text stays exact.** Expanded text is protected from later formatting and [transcript cleanup](/features/transcript-cleanup/), so a link or address is never "corrected".
- **Every engine.** Snippets work with Whisper, Parakeet, Apple Speech and the ONNX models. They are skipped only for a dictation set to come out exactly as transcribed, with no formatting at all.

## Snippets, Replacements or Vocabulary?

VocaMac has three ways to shape the words it types:

| Use | For | Example |
|---|---|---|
| **Snippets** | Typing a block of saved text from a short spoken phrase | "my sign-off" → a three-line signature |
| **Replacements** | Fixing a word the model keeps mishearing | "get hub" → GitHub |
| **Vocabulary** | Getting names and jargon spelled right | Grafana, kubectl |

Replacements and Vocabulary live on the Dictionary page; see [Custom Vocabulary](/features/custom-vocabulary/).

## Private and Portable

Snippets are stored on your Mac and never uploaded. They are included when you use **Export Settings…** on the Application page, so you can move them to another Mac along with the rest of your preferences.
