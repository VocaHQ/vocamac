---
title: "Smart model selection"
subtitle: "VocaMac reads your Apple Silicon hardware and helps you choose a Whisper model that fits its memory and accuracy trade-offs."
description: "VocaMac recommends a Whisper model based on your Mac's hardware, while keeping model choice and downloads under your control."
keywords: "whisper model selection, auto detect hardware macOS, apple silicon whisper, coreml speech model, best whisper model mac, RAM based model recommendation"
icon: "🧠"
---

## A recommendation, not a lock-in

VocaMac can inspect the Mac's Apple Silicon hardware and available memory to recommend a practical model. You can keep that recommendation, choose another model, or switch later from Settings.

> **Note:** The stable release is an Apple Silicon build. Intel Macs are not supported.

## The stable model catalog

![VocaMac Settings showing model management and system information](/screenshots/settings-models.png)

The stable release includes Tiny, Base, Small, compact Large v3 and Distil Large variants, and the full Large v3 model. Their approximate download sizes range from 39 MB to 3.1 GB. VocaMac shows the local model state and resource guidance in Settings.

Start with Small on an 8 GB Mac if you want a balanced default. Choose Tiny or Base for a smaller download and lower memory use. Choose a compact Large or Distil model when accuracy matters and your Mac has the headroom. The full Large v3 model needs substantially more disk space and memory.

## Download, verify, switch

The first use of a model can download its files from the documented WhisperKit model repository. VocaMac caches the model locally, verifies the downloaded assets, and uses the selected model for later recordings. You can keep more than one model and delete downloaded models you no longer need from Settings.

The model choice affects speed, memory, and accuracy; it does not change the privacy boundary. Transcription remains on-device after the selected model is available.

## CoreML on Apple Silicon

WhisperKit supplies the CoreML model path used by the stable release. VocaMac coordinates the model on your Mac instead of sending audio to a hosted speech API. Actual speed varies by chip, memory pressure, recording length, and model size, so the site avoids unsupported benchmark promises.
