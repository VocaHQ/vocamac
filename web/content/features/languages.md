---
title: "Language support"
subtitle: "Let Whisper detect a language or choose one of the languages exposed in VocaMac's stable settings picker."
description: "VocaMac's stable Whisper path supports automatic detection and 17 selectable language hints, with all transcription running locally on your Mac."
keywords: "multilingual dictation macOS, whisper language support, speech to text languages, auto detect language voice, multilingual voice typing mac"
icon: "🌍"
---

## Speak in your language

![VocaMac Settings showing language configuration](/screenshots/settings-general.png)

VocaMac's stable Whisper path supports automatic detection plus 17 language hints in Settings: English, Spanish, French, Italian, German, Portuguese, Dutch, Chinese, Japanese, Korean, Hindi, Arabic, Russian, Turkish, Polish, Swedish, and Ukrainian.

The underlying Whisper model was trained on more languages than VocaMac exposes as manual settings. The website describes the picker users can actually use, not a larger training-data figure.

## Automatic or chosen

Automatic detection is useful when you want VocaMac to infer the language from a full phrase. A manual hint can help when an utterance is short, an accent is unfamiliar, or you are dictating a predictable language for a long session.

Open **Settings → General → Transcription Language** to change the hint. The selected language is saved locally and can be changed without an account or a cloud service.

## Model size still matters

Every Whisper model has different speed, memory, and accuracy trade-offs. Smaller models are useful for quick notes; larger models generally give the recognizer more room for difficult audio and non-English speech. The model table on the home page reflects the stable release's actual catalog.

## Local processing

Language choice does not change the processing boundary: the selected Whisper model runs on your Mac. The model may need a one-time download, but VocaMac does not send dictation audio to a Voca cloud endpoint.

Accuracy depends on the model, microphone, accent, background noise, and length of the utterance. Treat the transcript as editable text, especially for names, specialist vocabulary, and short phrases.
