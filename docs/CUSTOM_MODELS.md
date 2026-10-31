# Bring your own model

VocaMac can run a speech model or a Writing AI model you supply: a Whisper fine-tune converted to CoreML, a sherpa-onnx model, or a GGUF for Smart Cleanup and Command Mode. Import it in **Settings → Models → All models → Your own models**, choose **Use**, and it runs like any built-in model. Everything stays on the Mac.

An imported model is not measured with VocaMac. Read what it writes before relying on it, and check its accuracy on your own recordings.

## The folder

A model is a folder with the model files and a `vocamodel.json`. You can import the folder or a `.zip` of it. The Mac App Store build imports folders only.

```json
{
  "id": "whisper-small-tamil-q8",
  "name": "Whisper Small Tamil",
  "engine": "whisperKit",
  "languages": ["ta"],
  "sha256": "…",
  "source": "https://huggingface.co/…",
  "license": "MIT"
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | 2 to 63 lowercase letters, digits, `.`, `_` or `-`. Unique on the Mac, and not the id of a built-in model. |
| `name` | yes | What Settings shows. |
| `engine` | yes | `whisperKit`, `sherpaOnnx`, or `cleanup`. |
| `languages` | no | ISO 639-1 codes. Empty means a Whisper model covers Whisper's languages and an ONNX model is treated as English. |
| `fileSizeBytes` | no | Filled in on import. Memory is estimated from it, so the free-memory check before a load keeps working. |
| `sha256` | no | Checked on import (see below). A model without one imports, marked "No checksum". |
| `source`, `license` | no | Shown next to the model, so you can tell where it came from. |
| `sherpa` | for `sherpaOnnx` | The recognizer type and its files. |
| `gguf` | for `cleanup` | The `.gguf` file's name in the folder. |
| `contextTokens` | no | A GGUF's context window. Defaults to 4,096. |

## Whisper (CoreML)

The folder holds `MelSpectrogram.mlmodelc`, `AudioEncoder.mlmodelc`, `TextDecoder.mlmodelc`, `tokenizer.json`, and `tokenizer_config.json`, the layout WhisperKit's own models use.

Convert a Hugging Face Whisper fine-tune with Argmax's [whisperkittools](https://github.com/argmaxinc/whisperkittools). What worked for Voca Hinglish:

1. Use Python 3.11 and a fresh virtual environment.
2. Use uniform 8-bit palettization. Set `argmaxtools.test_utils.TEST_DEFAULT_NBITS = 8` in a small wrapper script and run `scripts.generate_model.cli()` with the PSNR thresholds set to 0. The mixed-bit option (`--generate-quantized-variants`) ran for hours and failed with "Hash collision".
3. Swap the fp16 `MelSpectrogram.mlmodelc` back in afterwards.
4. If the fine-tune's `generation_config.json` has no `alignment_heads`, copy them from the base OpenAI model, or the decoder conversion fails.
5. Compare the converted model's word error rate with the original on real recordings before sharing it. 8-bit cost Voca Hinglish 0.9% WER; 6-bit cost 3.4%.

Copy the tokenizer files into the folder and add `vocamodel.json`. The first load compiles the model for the Neural Engine, which can take minutes.

## sherpa-onnx

The folder holds `tokens.txt` and the model files, and the manifest says which recognizer to build:

```json
{
  "id": "nemo-ctc-ukrainian",
  "name": "NeMo CTC Ukrainian",
  "engine": "sherpaOnnx",
  "languages": ["uk"],
  "sherpa": { "type": "nemoCtc", "model": "model.int8.onnx" }
}
```

| `type` | Files |
|---|---|
| `moonshine` | `encoder`, `mergedDecoder` |
| `senseVoice` | `model` |
| `nemoCtc` | `model` |
| `canary` | `encoder`, `decoder`, and `languages` it can be told to transcribe |
| `qwen3Asr` | `convFrontend`, `encoder`, `decoder`, and a `tokenizer` folder |

Transducer models are not supported. The [sherpa-onnx model list](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/index.html) has ready exports; unpack one and add the manifest.

## Writing AI (GGUF)

```json
{
  "id": "my-instruct-3b",
  "name": "My Instruct 3B",
  "engine": "cleanup",
  "gguf": "model-Q4_K_M.gguf",
  "contextTokens": 8192
}
```

Before importing a GGUF:

- **Architecture.** VocaMac reads `general.architecture` from the file and refuses hybrid attention/recurrent designs such as `qwen35`. They return empty text after the first dictation, because VocaMac reuses the model's cache between dictations. `qwen2`, `qwen3`, `mistral3`, `llama`, `gemma3`, and `granite` are fine.
- **Size.** Q4_K_M of a 0.5B to 4B instruct model. Larger models slow every dictation.
- **Language.** Try dictation in each language you speak. Some models translate it to English.
- **Read the outputs**, not just whether something came back. A tone change that turns into a letter addressed to "[Recipient's Name]" is a failure.

Once imported, the model appears in Settings → Models → Writing AI for Smart Cleanup and in Command Mode's model list.

## Checksums

`sha256` is compared on import, and a mismatch is refused.

- For a GGUF, it is the SHA-256 of the `.gguf` file, as Hugging Face shows it:

  ```bash
  shasum -a 256 model-Q4_K_M.gguf
  ```

- For a folder, it is a digest of every file except `vocamodel.json` and hidden files:

  ```bash
  cd my-model
  find . -type f ! -name vocamodel.json ! -name '.*' -print0 \
    | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256
  ```

## From the command line

`--list-models` lists imported models by their `id`, and `--model <id>` uses one for a single request without changing the app's choice. Measure a model this way before you rely on it:

```bash
/Applications/VocaMac.app/Contents/MacOS/VocaMac \
  --transcribe-file sample.wav --model whisper-small-tamil-q8 --json
```

## Community models

Settings also lists community models that VocaHQ has checked, from `community-models.json` in [VocaHQ/whisperkit-coreml](https://huggingface.co/VocaHQ/whisperkit-coreml). VocaMac asks for the list once a day, on the same schedule as the update check, and nothing downloads until you choose a model. The Mac App Store build doesn't fetch the list.

The file looks like this:

```json
{
  "version": 1,
  "models": [
    {
      "manifest": { "id": "whisper-small-tamil-q8", "name": "Whisper Small Tamil", "engine": "whisperKit", "languages": ["ta"] },
      "downloadURL": "https://huggingface.co/VocaHQ/whisperkit-coreml/resolve/main/whisper-small-tamil-q8.zip",
      "downloadBytes": 253000000,
      "archiveSHA256": "…",
      "notes": "Fine-tuned on Common Voice Tamil"
    }
  ]
}
```

Only `https` downloads are listed. `archiveSHA256` is checked before the zip is unpacked, and the manifest inside is checked like any import.

## Where they live

Imported models are copied to `~/Library/Application Support/VocaMac/models/custom/<id>/`. Deleting one in Settings removes the folder; if it was in use, VocaMac switches to another model first.
