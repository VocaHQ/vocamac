---
title: "Transcript Cleanup"
seoTitle: "Remove Filler Words From Dictation, On-Device | VocaMac"
subtitle: "Optionally run a small language model over your dictation to drop the ums and punctuate what you said — on your Mac by default."
description: "VocaMac can pass a finished transcript through a local GGUF language model to remove filler words and false starts and add punctuation, on-device by default."
keywords: "remove filler words dictation, clean up speech to text, local llm transcript cleanup, on-device punctuation dictation macOS, um uh removal transcription"
icon: "✨"
related: ["writing-styles", "command-mode", "dictation-history"]
---

## Speech Is Messier Than Writing

Say a sentence out loud and read the transcript back. It is all there — the "um", the "I was, I was going to say", the sentence that restarts halfway through. Speech recognition is doing its job faithfully; the problem is that nobody writes the way they talk.

Transcript Cleanup runs a small language model over the finished transcript, on your Mac by default, before the text is typed. Filler words go, false starts go, and what you said gets punctuated.

![VocaMac Settings showing the Cleanup page with its model list and Try It panel](/screenshots/settings-cleanup.png)

## What It Actually Does

```
so um i was i was thinking we could ship it on friday comma maybe after the review you know

  ↓

So I was thinking we could ship it on Friday, maybe after the review.
```

Filler words removed, the repeated "I was" collapsed, the spoken "comma" written as a comma, and the sentence capitalised.

It is deliberately narrow. It does not summarise, rephrase, or answer — if you dictate a question, you get your question back, punctuated, not an answer to it. Anything the model returns that looks like a summary, a refusal, or a chatbot reply is discarded and your original transcript is used instead. The worst case is that nothing changes.

## Off by Default

Cleanup is opt-in and requires a one-time model download. Open **Settings → Smart Cleanup**, download a model, and turn it on.

| Model | Size | Notes |
|---|---|---|
| Qwen 2.5 0.5B | ~491 MB | The default. Writes dictated "comma" and "period" as marks and capitalises sentences. |
| Qwen 3 0.6B | ~397 MB | Smallest. Punctuates long paragraphs slightly better; leaves dictated punctuation as words. |
| Qwen 2.5 1.5B | ~1.12 GB | Also handles Command Mode. Slower than 0.5B for cleanup. |
| Ministral 3 3B Instruct | ~2.15 GB | Cleanup and Command Mode. A lighter, faster alternative to Qwen 3 4B. |
| Qwen 3 4B Instruct | ~2.50 GB | Strong Command Mode quality. Needs 16 GB of memory to stay comfortable. |
| Qwen 2.5 7B Instruct | ~4.68 GB | Largest on-device option. Slower; needs 16 GB of memory or more. |

Settings suggests a model from your Mac's memory: Qwen 2.5 0.5B below 16 GB, and Ministral 3 3B, which also serves Command Mode, from 16 GB up. Qwen 2.5 0.5B adds roughly two tenths of a second to a short dictation; the larger models are slower. If the model takes too long, returns nothing, or returns something implausible, VocaMac falls back to the raw transcript rather than making you wait.

## Try It Before You Trust It

The Cleanup settings page has a **Try It** box. Type what you would have said, run it through the model, and see exactly what dictation would have produced. It tells you which of four things happened — the text was cleaned, the model returned it unchanged, the rewrite was discarded (and why), or cleanup was skipped (and why) — so a model that is quietly doing nothing is visible rather than mysterious.

You can edit the prompt the model is given and try the edit immediately, before saving it.

## Honest Limits

The suggested models are small, chosen so cleanup finishes fast enough to sit in the middle of a dictation. They will not catch every filler, and the two smallest do not act on a spoken "scratch that". VocaMac resolves spoken corrections of a day, month, number, or time ("let's do it tomorrow, oh, no, Wednesday") with rules before the model sees the text, so they work at the Medium level and above even with Smart Cleanup off. In testing, the two smallest models left dictation in other languages as spoken; larger models vary, so check yours with Try It.

## Private by Design

By default the model runs on your Mac through llama.cpp with Metal acceleration, and your transcript stays there. Turning cleanup off unloads the model and frees the memory.

Under **Where Cleanup Runs** you can instead choose an Ollama, LM Studio, or OpenAI-compatible server. Then the cleanup prompt and your transcript text leave your Mac for the endpoint you configured, so keep that server on localhost, a trusted LAN, or Tailscale, or use HTTPS.
