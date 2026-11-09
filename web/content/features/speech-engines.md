---
title: "Speech Engines"
seoTitle: "Local Speech to Text on Mac: Whisper, Parakeet | VocaMac"
subtitle: "Four on-device speech engines in one app: Whisper, NVIDIA Parakeet, Apple Speech and specialized ONNX models."
description: "VocaMac runs speech to text locally on your Mac with Whisper, NVIDIA Parakeet, Apple Speech or compact ONNX models. Pick the engine that suits your language and Mac."
keywords: "local speech to text mac, on-device speech recognition mac, whisper mac app, parakeet mac, nvidia parakeet dictation, apple speechanalyzer, offline speech recognition macos, coreml speech to text"
icon: "🧩"
related: ["smart-model-selection", "languages", "apple-silicon-native"]
---

## More Than One Way to Hear You

No single speech model is best at everything. Whisper knows many languages, Parakeet is very fast, Apple's own engine needs no download, and some small models specialise in one family of languages. VocaMac includes all four kinds and runs every one of them on your Mac. You choose in **Settings → Speech Model**, and you can switch at any time.

![VocaMac Speech Model settings listing Whisper, Parakeet and Apple Speech models](/screenshots/settings-models.png)

## The Engines

| Engine | Runs on | Good at | Models |
|---|---|---|---|
| **Whisper** (WhisperKit) | CoreML on Apple Silicon | The widest language coverage, translation to English | Tiny to Large v3 Latest, Distil variants, Voca Hinglish |
| **Parakeet** (NVIDIA, via FluidAudio) | CoreML on the Neural Engine | Speed; English and 25 European languages | Parakeet 110M, v2, v3, Ultra, Unified |
| **Apple Speech** | macOS 26 system engine | No model download; assets managed by macOS | Apple Speech |
| **Specialized ONNX** (sherpa-onnx) | CPU only | Compact models for specific languages and low-memory Macs | Moonshine, SenseVoice, GigaAM v3, Canary 180M Flash, Qwen3 ASR 0.6B |

### Whisper

OpenAI's Whisper, compiled to CoreML by WhisperKit, is the generalist. It has the most selectable languages, can [translate speech into English](/features/translation/), and comes in sizes from Tiny (77 MB) to Large v3 Latest (1.6 GB). Voca Hinglish is a Whisper model fine-tuned to write Hindi speech in Roman script.

### Parakeet

NVIDIA's Parakeet models run on the Apple Neural Engine and are the fastest option in VocaMac. Parakeet 110M (227 MB), v2 and Unified are English-only; Unified adds punctuation, capitals and numbers as digits. Parakeet v3 and Ultra cover 25 European languages. Parakeet needs Apple Silicon, which every Mac VocaMac supports already has.

### Apple Speech

On macOS 26, VocaMac can use Apple's SpeechAnalyzer engine. There is nothing to download from VocaMac: macOS manages the language assets, and which languages are available is decided by macOS.

### Specialized ONNX Models

These run on the CPU through sherpa-onnx and suit particular languages or Macs with little memory:

- **Moonshine v2 Tiny and Base**: English, for very low-RAM Macs (44 MB and 142 MB)
- **SenseVoice**: Chinese, Japanese, Korean, Cantonese and English
- **GigaAM v3**: Russian, with punctuation
- **Canary 180M Flash**: English, Spanish, German and French
- **Qwen3 ASR 0.6B**: 30 languages, including Hindi, Arabic and Thai

## Which One Should I Use?

During setup, VocaMac asks which languages you speak and recommends a model:

| You mostly speak | Suggested starting point |
|---|---|
| English | Parakeet 110M |
| Russian | GigaAM v3 |
| Chinese, Japanese or Korean | SenseVoice |
| Spanish, German or French | Canary 180M Flash |
| Several languages | Whisper Small |

Tiny ships with the app, so dictation works before any download. All of these are starting points; [Smart Model Selection](/features/smart-model-selection/) explains how memory and accuracy trade off, and [Custom Vocabulary](/features/custom-vocabulary/) works with every engine.

## On-Device by Default

Every engine above transcribes on your Mac. A model needs an internet connection only for its first download (Apple Speech assets come from macOS). VocaMac also offers [Custom Endpoint](/features/custom-endpoint/), an opt-in choice that sends each recording to a Whisper-compatible server you configure instead. It is never the default, and if you use it, keep the server on this Mac, on a trusted local network, behind Tailscale, or on HTTPS.
