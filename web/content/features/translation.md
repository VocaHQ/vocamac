---
title: "Translation"
subtitle: "Whisper can translate supported speech into English while it runs locally on your Mac."
description: "VocaMac's Whisper path supports local speech translation into English after the required model is available on your Mac."
keywords: "offline speech translation macOS, voice translator mac, speak translate type, whisper translation, local speech translation, voice to text translation mac"
icon: "🌐"
---

## Translate While You Speak

Language barriers shouldn't slow down your work. VocaMac's Whisper path can translate supported speech into English while the model runs locally on your Mac. This is an engine-specific capability, not a general-purpose translation service.

This opens possibilities that traditional voice typing simply cannot match: multilingual collaboration, language learning, cross-cultural meetings, and more. All without sending your voice data to cloud servers.

## How Translation Works

VocaMac uses OpenAI's Whisper model, which has a built-in translation capability. Here's what happens when you enable translation:

1. **You speak** in your chosen source language (Spanish, French, German, Mandarin, etc.)
2. **Whisper transcribes** your speech to intermediate text (keeping your original language)
3. **Whisper translates** that transcription to English
4. **VocaMac inserts** the translated English text at your cursor

The speech-processing step happens on your Mac. VocaMac does not send dictation audio to a Voca cloud endpoint; separate actions such as model and release downloads still need a network connection.

The available source languages and results depend on the selected Whisper model. The stable app exposes its supported language hints in Settings; it does not promise every language in Whisper's training data.

## Setting Your Source Language

By default, VocaMac automatically detects the language you're speaking. Whisper's detection is remarkably accurate, even for short utterances.

For more predictable results, you can manually set your source language in **Settings → Models → Language**. Select from the language hints exposed by the stable app. With a hint selected, VocaMac uses that language for the Whisper path (and translates to English when translation is enabled).

Changing languages is as simple as picking a new option from the dropdown. No restarts, no waiting. The change takes effect immediately.

## Real-World Use Cases

### Multilingual Meetings

You're in a video call with colleagues from different countries. Some speak Spanish, some German, some English. Instead of struggling through a shared language, everyone can speak naturally in their native tongue and have their words transcribed in the meeting notes in English. VocaMac handles the transcription and translation seamlessly while you focus on the conversation.

### Language Learning

Learning a new language is accelerated by speaking and hearing yourself. With VocaMac's translation, you can:

- Speak in your target language and see the English translation to check your accuracy
- Practice translating concepts from English to your target language by speaking them aloud
- Build confidence by comparing your spoken output to the translated text

The immediate visual feedback strengthens learning retention and helps identify pronunciation issues.

### International Notes and Documentation

You're documenting a client conversation in Spanish, but your project notes are in English. Instead of transcribing manually or copying text between translation tools, you speak in Spanish and VocaMac delivers English text directly into your document. Context and meaning flow seamlessly across languages.

### Research and Knowledge Work

Researchers working with multilingual sources can speak notes in their preferred language and have them automatically translated and inserted into English-language documents. This bridges the gap between thinking in one language and writing in another.

### Cross-Border Communication

Support teams, customer success, and engineering teams spanning multiple countries can communicate asynchronously. VocaMac lets each person speak in their native language, with translation happening automatically. Reduces friction, improves clarity, and makes async communication feel more personal.

## Local translation after the model download

This is the key boundary of VocaMac's translation feature: once the selected model is available, processing happens locally.

Other voice translation services (Google Translate, Microsoft Translator, Amazon Transcribe) require internet connectivity and send your audio or transcription to cloud servers. This introduces latency, battery drain, and privacy concerns.

VocaMac's translation is local after the model download. The first model download still requires a network connection. This makes VocaMac suitable for:

- Offline work environments
- Sensitive conversations
- Regions with unreliable internet
- Users who simply prefer not to transmit their voice data

Once the Whisper model is downloaded, the speech-processing step can run without a network connection. Review translated text before using it for high-stakes work.

## Accuracy Considerations

Whisper's translation accuracy is generally excellent for common languages and clear audio. However, like all speech recognition systems, accuracy depends on several factors:

- **Audio quality**: clear voice, minimal background noise, appropriate microphone distance
- **Accents and pronunciation**: Whisper handles most accents well, but some regional variations may require repeated attempts
- **Domain-specific terminology**: specialized vocabulary (medical, legal, technical) may be transcribed or translated less accurately than everyday speech
- **Language pair**: some language-to-English translations are more reliable than others

For critical applications (legal documents, medical records), always review the translated output. For casual notes, messages, and everyday dictation, accuracy is typically excellent.

You can always make corrections manually after VocaMac inserts the text. Think of it as a starting point that eliminates the need to type from scratch.

## Toggling Translation On and Off

Translation is disabled by default. To enable it, open **Settings → General → Translation** and toggle it on.

Once enabled, all recordings will be transcribed and translated to English automatically. You can toggle translation on and off anytime without restarting VocaMac.

If you want to transcribe in your source language without translation, simply disable translation in Settings. VocaMac will then transcribe directly without the translation step.

## The Private Alternative to Cloud Translation

VocaMac's translation feature represents a fundamentally different approach than cloud-based translation services. By keeping everything local, you get:

- **Privacy**: your voice and words never leave your computer
- **Speed**: no network round trip for the speech-processing step
- **Offline capability**: work anywhere, anytime
- **No subscription fees**: translation is included with VocaMac

This is ideal for anyone who speaks multiple languages and values both convenience and privacy in their workflow.
