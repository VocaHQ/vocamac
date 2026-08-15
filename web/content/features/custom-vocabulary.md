---
title: "Custom Vocabulary"
subtitle: "Teach VocaMac the names, brands, and jargon you use so they're transcribed right, every time."
description: "Add names, technical terms, and jargon to VocaMac's custom vocabulary so the Whisper path can use your preferred spellings locally."
keywords: "custom vocabulary dictation, whisper glossary, proper noun transcription, technical jargon speech to text, fix misspelled names dictation macOS"
icon: "📝"
---

## Teach VocaMac Your Words

Speech models handle everyday language well but stumble on the words that matter most to you: coworkers' names, product names, acronyms, and technical jargon. "kubectl" becomes "cube control." "Grafana" becomes "graph on a." Every transcription ends with a manual fix.

Custom Vocabulary targets exactly the words you use. Give VocaMac a short list of the terms it keeps getting wrong, and it hints them to the model so they come out spelled correctly from the start.

<!-- SCREENSHOT PLACEHOLDER: add web/static/screenshots/settings-vocabulary.png (General tab → Custom Vocabulary section, ~1344×1260) -->
![VocaMac Settings showing the Custom Vocabulary editor](/screenshots/settings-vocabulary.png)

## How It Works

Open **Settings → General → Custom Vocabulary** and type the terms you care about, one per line or comma-separated:

```
kubectl, PostgreSQL, nginx, Grafana
```

VocaMac passes these to Whisper as a transcription hint, biasing it toward your spelling. Keep the list focused and put your most-mistranscribed terms near the top; WhisperKit applies its own prompt-token budget. There is no training step. The updated list is used on the next transcription attempt, although it remains a hint rather than a promise.

For best results, enter terms in the language you dictate and set a matching transcription language above. In Auto-detect, your vocabulary can even nudge VocaMac toward the right language.

## Private by Design

Your word list never leaves your Mac. Like every other part of VocaMac, custom vocabulary is applied entirely on-device — nothing is uploaded to build or store a dictionary. Your names, projects, and jargon stay yours.
