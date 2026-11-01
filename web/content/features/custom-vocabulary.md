---
title: "Custom Vocabulary"
seoTitle: "Custom Vocabulary for Speech to Text on Mac | VocaMac"
subtitle: "Teach VocaMac the names, brands, and jargon you use so they're transcribed right, every time."
description: "Add names, product terms and jargon to VocaMac's custom vocabulary so Mac dictation spells them your way. Whisper, Parakeet and Apple Speech all use it."
keywords: "custom vocabulary dictation, whisper glossary, proper noun transcription, technical jargon speech to text, fix misspelled names dictation macOS"
icon: "📝"
related: ["transcript-cleanup", "languages", "smart-model-selection"]
---

## Teach VocaMac Your Words

Speech models handle everyday language well but stumble on the words that matter most to you: coworkers' names, product names, acronyms, and technical jargon. "kubectl" becomes "cube control." "Grafana" becomes "graph on a." Every transcription ends with a manual fix.

Custom Vocabulary targets exactly the words you use. Give VocaMac a short list of the terms it keeps getting wrong, and it hints them to the model so they come out spelled correctly from the start.

![VocaMac Settings showing the Dictionary page with Vocabulary, Replacements and Learning](/screenshots/settings-dictionary.png)

## How It Works

Open **Settings → Dictionary** (under **Writing**) and add terms in the **Vocabulary** group, one at a time:

```
kubectl
PostgreSQL
nginx
Grafana
```

VocaMac passes these to the speech model as a hint, biasing it toward your spelling: Whisper takes them as a prompt, Apple Speech as contextual strings, and Parakeet through an optional vocabulary boost model. Every model, including the specialized ones, also gets a spelling fix after transcription. Matches ignore case and spaces, so "voca mac" comes out as VocaMac, and close misspellings are corrected too. Keep the list focused: each engine caps how many hints it takes (WhisperKit has a prompt-token budget), and when a long list is trimmed, the most recently added terms are the ones kept. There is no training step. The updated list is used on the next transcription attempt, although it remains a hint rather than a promise.

For best results, enter terms in the language you dictate and set a matching transcription language. In Auto-detect, your vocabulary can even nudge VocaMac toward the right language.

## Vocabulary or Replacements?

The Dictionary page has two lists, and they solve different problems:

| Use | When | Example |
|---|---|---|
| **Vocabulary** | The model hears the word but spells it wrong | Grafana, kubectl, a colleague's name |
| **Replacements** | You say one thing and want something else typed | "get hub" → GitHub |

Replacements match whole words, ignoring case. Separate several spoken forms with commas when one term has more than one way of coming out. Raw transcription skips replacements, so you can always see what the model actually heard.

## Learn From Your Corrections

When you fix a word VocaMac just typed, it can notice. **Learn from my corrections** has three settings:

- **Suggest words** (the default): your spelling appears under **Suggested Words** at the top of the Dictionary page, and you decide whether to add it.
- **Add automatically**: your spelling goes into the dictionary straight away.
- **Off**: VocaMac doesn't look at text after typing it.

## Spell Names From the Screen

**Spell names from the screen** is on by default. When you start dictating, VocaMac reads the visible text in the field you are typing into and spells matching names and code identifiers the same way, so "user id" becomes `userId` in a file that already uses it. The text is read once and never saved, it needs Accessibility permission, and password fields are never read.

## Parakeet Vocabulary Boost

Parakeet is fast, but on its own it only fixes spelling after the fact. If you use a Parakeet model and have vocabulary terms, the Vocabulary group offers **Vocabulary boost for Parakeet**, a separate 98 MB download. That small second model checks the audio for your words and fixes ones Parakeet heard far off ("in video" → NVIDIA), at the cost of a short extra pass after each dictation. You can remove it from the same row.

## Tips for a Vocabulary That Works

- **Add what actually goes wrong.** A list of every term you know dilutes the hint. Start with the five words you fix most often.
- **Use the exact spelling you want.** Capitalisation, internal capitals and dots all count: `macOS`, `iOS`, `Next.js`.
- **Prefer Replacements for spoken shortcuts.** If you want a spoken phrase to type something different, that is a replacement, not a vocabulary word. For reusable blocks of text, use [Snippets](/features/snippets/).
- **Pick a model that listens.** Whisper, Parakeet and Apple Speech use the list while transcribing; the specialized ONNX models get the spelling fix afterwards. See [Smart Model Selection](/features/smart-model-selection/) for choosing a model.

## Private by Design

Your word list never leaves your Mac. Vocabulary is applied on-device, and nothing is uploaded to build or store a dictionary. Names, projects, and jargon stay yours. If you select [Custom Endpoint](/features/custom-endpoint/), recordings are uploaded for transcription; the vocabulary list is not.
