# Speech models

VocaMac runs four on-device speech engines plus an optional Custom Endpoint, and picks among them in **Settings → Speech Model**, where models are grouped by engine. Local engines run on this Mac. Custom Endpoint uploads each recording to the server you configure.

Models download once when you choose them and are cached locally: Whisper and Parakeet from Hugging Face, the specialized models from sherpa-onnx's model releases. Tiny Whisper ships with the app.

## Parakeet — fastest, recommended for dictation

NVIDIA Parakeet TDT models running as CoreML on the Apple Neural Engine (via [FluidAudio](https://github.com/FluidInference/FluidAudio)).

| Model | Size | Speed | Languages |
|-------|------|-------|-----------|
| **Parakeet Ultra** | ~632 MB | ⚡⚡⚡⚡⚡ | Parakeet v3 post-trained by moondream: more accurate at the same speed, same 25 European languages |
| **Parakeet v3** | ~483 MB | ⚡⚡⚡⚡⚡ | 25 European languages + Japanese, auto-detected |
| **Parakeet Unified** | ~614 MB | ⚡⚡⚡⚡⚡ | English only, NVIDIA's newest Parakeet: punctuation, capitals, and numbers written as digits |
| **Parakeet v2** | ~464 MB | ⚡⚡⚡⚡⚡ | English only, highest recall |
| **Parakeet 110M** | ~227 MB | ⚡⚡⚡⚡⚡ | English only, smaller download and faster first load |
| **Nemotron Unified** | ~626 MB | ⚡⚡⚡⚡⚡ | 25 European languages with punctuation and capitals: NVIDIA's multilingual build of Parakeet Unified ([OpenMDW-1.1](https://github.com/OpenMDW/OpenMDW/blob/main/1.1/LICENSE.OpenMDW-1.1)) |
| **SenseVoice Neural Engine** | ~240 MB | ⚡⚡⚡⚡⚡ | Chinese, Japanese, Korean, Cantonese, English: the SenseVoice model below, as CoreML on the Neural Engine, up to 100 s in one pass |

Onboarding suggests **Parakeet Unified** for English (110M where Unified doesn't fit), and **Parakeet v3** for Parakeet's other European languages that have no specialist below. On a 45-sentence English set spoken by five macOS voices, scored after normalizing how numbers are written, the Parakeet models made these errors:

| Model | Word error rate | Decode per sentence (warm, M1 Pro) |
|-------|-----------------|------------------------------------|
| Parakeet Unified | 1.6 % | 0.18 s |
| Parakeet v3 | 2.2 % | 0.10 s |
| Parakeet Ultra | 2.8 % | 0.10 s |
| Parakeet 110M | 4.7 % | 0.05 s |

Nemotron Unified and SenseVoice Neural Engine are not suggested by onboarding yet: neither has been measured against v3 or the ONNX SenseVoice on recorded speech in their languages. Nemotron takes its language at load (the one you pick, or your only spoken language, or automatic language ID), so changing the language reloads it. FluidInference's model card reports its int8 encoder, which VocaMac uses, a little worse than fp16 on French (8.6 against 6.9 % on five FLEURS clips).

### Transcribe as you speak (Parakeet Unified and Nemotron Unified)

Settings › System › **Transcribe as you speak** loads the streaming export of either Unified model instead of the batch one: audio is decoded each second while you talk (2.08 s behind you), and the streamed transcript is the result, so at stop only the last window is left. It is off by default. The streaming encoder is a second download (~592 MB for Parakeet Unified, ~596 MB for Nemotron), and NVIDIA reports it slightly less accurate than the batch export (6.14 % against 5.91 % average WER on the Open ASR Leaderboard sets). Silence and hallucination checks run on the whole recording at stop, as on the batch path; Process while speaking is skipped for these models while it is on.

Measured on an M1 Pro (Parakeet Unified, int8, warm), 30 clips: 10 macOS-voice sentences with references and 20 real dictations of 2–31 s:

| | Batch export | Streaming export |
|---|---|---|
| Wait after stop, median | 0.20 s | 0.10 s |
| Wait after stop, longest (30.6 s dictation) | 0.96 s | 0.23 s |
| Word error rate, 10 synthetic sentences | 8.6 % | 8.6 % (identical text) |
| Words that differ from the batch text, all 30 clips | — | 9 of 468 (1.9 %) |

The 8.6 % is mostly numbers written as digits against a reference that spells them out. The differences on real dictations go both ways ("togle", "Vocar Mac" against the batch text's "toggle", "voca max"). Twenty recordings from one speaker is a small sample; the streaming export's accuracy on long or noisy dictation is not measured.

Nemotron Unified on the same 30 clips, prompted with English: 6.3 % (batch) and 7.0 % (streaming) on the synthetic sentences, and a median wait after stop of 0.28 s (batch) against 0.12 s (streaming). Its batch export dropped the last four words of the 30.6 s dictation; the streaming export kept them. It was not measured in any other language.

Synthetic speech is a weak stand-in for real voices. FluidAudio's published numbers on real speech put Ultra ahead of v3 (LibriSpeech test-clean 2.13 vs 2.27 %, FLEURS 11.67 vs 14.81 %), so Ultra stays in the catalog. The suggestion changes only when a measurement on recorded speech favours it.

## Whisper — widest language coverage

OpenAI Whisper models via WhisperKit's CoreML format. The only engine that supports **translation to English**. Dictionary vocabulary is a recognition hint for Whisper, Apple Speech, Qwen3 ASR, and Parakeet (through a ~98 MB vocabulary boost model, fetched on its own once the Dictionary has words); every engine gets the spelling fixes after transcription. The app auto-detects your hardware and recommends a variant.

| Model | Size | Memory | Quality | Best For |
|-------|------|--------|---------|----------|
| **Tiny** | 77 MB | ~0.5 GB | Good | Fastest; short commands and quick notes. Ships with the app |
| **Base** | 147 MB | ~1 GB | Better | A small step up in accuracy for very little extra weight |
| **Small** | 487 MB | ~1.5 GB | Great | A sensible default on 8 GB Macs |
| **Large v3 Turbo (Compact)** | 646 MB | ~2 GB | Excellent | The best accuracy-per-second trade-off for most people |
| **Distil Large v3 (Compact)** | 595 MB | ~2 GB | Excellent | Distilled for speed, English-focused |
| **Distil Large v3 Turbo** | 607 MB | ~2 GB | Excellent | The fastest of the distilled variants |
| **Large v3 Latest (Compact)** | 627 MB | ~2 GB | Best | Full large-model accuracy, compressed |
| **Large v3 Latest** | 1.6 GB | ~3.5 GB | Best | Highest accuracy, largest download |
| **Voca Hinglish** | 824 MB | ~1.5 GB | Best for Hindi | Hindi speech written in Roman script ([Oriserve's Hindi2Hinglish Apex](https://huggingface.co/Oriserve/Whisper-Hindi2Hinglish-Apex) fine-tune of Large v3 Turbo, 8-bit compressed and [hosted by VocaHQ](https://huggingface.co/VocaHQ/whisperkit-coreml)) |

Sizes are on disk; memory is the app's own estimate for a load from CoreML's cache (`ModelSize.fileSizeBytes` and `ramRequiredGB`). A first load on a new macOS build compiles the model for the Neural Engine and needs more. Medium, Large v3 and the uncompressed Turbo builds are still accepted from older preferences but are no longer listed.

Voca Hinglish always decodes as English, which is how it was trained to write romanized Hindi, so it ignores the language setting.

## Apple Speech — managed by macOS (macOS 26+)

Apple's on-device SpeechAnalyzer engine. Assets are managed by macOS (language packs may download on first use) and are not stored in VocaMac's model folder. Covers roughly 30 locales.

## Specialized (ONNX) — niche needs

Community models via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). These run on the **CPU**, so on Apple Silicon prefer Parakeet unless you need one of these specifically.

| Model | Size | Best For |
|-------|------|----------|
| **Moonshine v2 Tiny** | ~44 MB | Very low-RAM Macs, English |
| **Moonshine v2 Base** | ~142 MB | Low-RAM Macs, English |
| **SenseVoice** | ~241 MB | Chinese, Japanese, Korean, Cantonese, English |
| **GigaAM v3** | ~225 MB | Russian, with punctuation |
| **Canary 180M Flash** | ~207 MB | English, Spanish, German, French |
| **Qwen3 ASR 0.6B** | ~1 GB | Accurate transcription across 30 languages and Chinese dialects |
| **Cohere Transcribe** | ~2.9 GB | The most accurate model on the set above (1.2 % word error rate, 0.40 s per sentence), in 14 languages: Arabic, Chinese, Dutch, English, French, German, Greek, Italian, Japanese, Korean, Polish, Portuguese, Spanish, Vietnamese. Needs about 4.5 GB of memory and takes about 5 s to load. |

Cohere Transcribe has no language detection: it transcribes in the language chosen in Settings, or English when that is Automatic or a language it doesn't know. It is only suggested to someone who speaks exactly one of its languages.

When the transcription language is Automatic and you list two or more languages that Cohere Transcribe or Canary support (Settings › Language), VocaMac picks one of them for each dictation with Whisper Tiny's language detection on the first 10 seconds, choosing only among your languages. This needs Whisper Tiny on the Mac (it ships with the app) and is skipped for recordings under a second, for the live overlay, and for Process while speaking pieces, which keep the language the model loaded with. The first dictation after the model loads may still use that language while language detection loads.

Not offered yet: Qwen3 ASR 1.7B and Moonshine v2 Small and Medium have no sherpa-onnx release export (only community uploads, which VocaMac does not pin to). Moonshine Tiny and Base above are already the v2 builds.

Recordings longer than a model's single-pass limit are split at natural pauses and decoded segment by segment, since these models — unlike Whisper and Parakeet — do not chunk internally.

> **Note:** SenseVoice (both builds), Canary, Cohere Transcribe and Nemotron Unified fix their language when the model loads, so changing the transcription language reloads the active model (Canary and Cohere can still be switched per dictation by the language detection above). Whisper and Parakeet take the language per transcription.

> **Note:** Of these, only Qwen3 ASR takes Dictionary words as a recognition hint. Moonshine, SenseVoice, GigaAM, and Canary have no way to listen for a word, so for them the Dictionary only fixes spellings after transcription: a near-miss of a listed term, or a run of words that sounds exactly like one.

## Custom Endpoint (optional, remote)

Select Custom Endpoint to upload each recording as a WAV file to a Whisper-compatible server you host (OpenAI audio API or whisper.cpp). This is opt-in and off by default. It is distinct from VocaGateway.

## Why the Whisper engine uses WhisperKit

The Whisper path uses [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) instead of raw whisper.cpp because:

| | WhisperKit | whisper.cpp |
|---|-----------|-------------|
| **Language** | Pure Swift (native) | C++ (requires bridging) |
| **Apple Silicon** | CoreML + Neural Engine | Metal only |
| **SPM Integration** | One-line dependency | Complex vendoring |
| **Model Format** | CoreML (optimized per device) | GGML (generic) |
| **Streaming** | First-class async/await | Manual threading |
| **Quality** | Same OpenAI Whisper models | Same OpenAI Whisper models |
| **Maintenance** | Argmax Inc. (commercial) | Community |

Same accuracy, dramatically better Apple platform integration.

