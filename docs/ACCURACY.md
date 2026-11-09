# Measuring transcription accuracy

VocaMac's accuracy harness decodes recorded speech with each model through the same `TranscriptionRouter` the app uses (silence trimming, decoding options, retries), runs the result through the same output rules and, optionally, the real cleanup model, and scores every stage against human references. It is `SpeechAccuracyBenchmarkTests`. Ordinary `swift test` runs skip it; it runs when you point it at a corpus, locally or in the opt-in nightly workflow.

No audio is committed to this repository. The corpus lives outside the checkout.

## What it reports

Per file and per model, in a JSON report (`$TMPDIR`, or `VOCAMAC_ACCURACY_OUTPUT`) and a short summary on stdout:

| Measure | What it counts |
|---|---|
| **WER** | Word error rate against `<name>.txt`. Case and punctuation are ignored, and numbers are folded so "three", "3", "twenty one" and "21" compare equal (`WordErrorRate`, `NumberFolding`). Corpus WER is total errors over total reference words. |
| **CER** | Character error rate, used instead of WER for files whose reference is mostly Chinese, Japanese, Thai, Lao, Khmer or Burmese, where words are not separated by spaces. Reported as its own corpus number, never mixed into WER. |
| **Dropped edge words** | Files whose first or last reference word is missing (deleted, not misheard): what a late microphone start or an early stop costs. Empty transcripts are counted separately. |
| **Term recall** | For words in the vocabulary or `<name>.terms.txt`: how many said occurrences came through with the exact spelling ("GitHub", not "github" or "get hub"), and how many times a term appeared where it was not said. |
| **Final text WER** | With `VOCAMAC_ACCURACY_FINAL=1`, or a cleanup model set: the text after the output rules (and the cleanup model) against `<name>.intended.txt`, or `<name>.txt` when there is none. |
| **Punctuation and capitalization** | For the final text: precision, recall and F1 of the mark after each word (`. , ? ! : ;`) and of capital first letters, over the words both texts share. Only meaningful when the reference is written with punctuation. |
| **Timing** | Model load, the first decode after loading, and the median warm decode. |

## Building a corpus

Lay the corpus out as one flat directory:

```
corpus/
  meeting-notes-01.wav          # the recording
  meeting-notes-01.txt          # what was said, word for word
  meeting-notes-01.intended.txt # optional: what the speaker meant, written as text
  meeting-notes-01.terms.txt    # optional: words that must be spelled exactly so, one per line
```

- **Recordings.** Real microphone recordings find far more than synthetic `say` audio does (synthetic speech never reproduced, for example, the sherpa-onnx Canary long-segment drop). Record at the app's input settings or any rate; the loader converts to 16 kHz mono. Cover short and long dictations, quiet and noisy rooms, built-in, USB and Bluetooth microphones, several speakers and accents, and the names and jargon your users dictate. Include a few clips that start speaking the instant recording starts and stop on the last syllable, so the edge-word measure has something to find.
- **`.txt`** is a verbatim transcript: every word spoken, including "um" and restarts. Punctuation and case do not matter for WER.
- **`.intended.txt`** is the text the speaker wanted, punctuated and capitalized as it should appear: fillers and false starts removed, corrections applied. Write it whenever the verbatim transcript is not what should be pasted. Formatting scores need it.
- **`.terms.txt`** lists Dictionary words for that clip. They are passed to the engine as recognition hints (as the app's Dictionary is) and scored for recall.
- **Languages.** Keep one language per clip and set `VOCAMAC_ACCURACY_LANGUAGE` per run, or leave it unset for automatic detection. Run each language as its own corpus, so its numbers are not averaged with another's.
- **Licences and consent.** Only use audio you may redistribute to whoever runs the benchmark: your own recordings with every speaker's written consent, or public sets whose licence allows it, such as LibriSpeech (CC BY 4.0), FLEURS (CC BY 4.0) or Common Voice (CC0). Note each source and licence in a `SOURCES.md` inside the corpus. Never use dictations collected from users.
- **Size.** Fifty to a hundred clips per language is enough to see a regression of a point or two of WER; the nightly runner is a hosted Mac VM, so keep the total under an hour of audio.

## Running it locally

```sh
VOCAMAC_ACCURACY_CORPUS=/path/to/corpus \
VOCAMAC_ACCURACY_MODELS=parakeet-unified-en-0.6b,tiny \
swift test --filter SpeechAccuracyBenchmarkTests
```

| Variable | Effect |
|---|---|
| `VOCAMAC_ACCURACY_MODELS` | Comma-separated model ids (`--list-models` prints them). Default `tiny`. |
| `VOCAMAC_ACCURACY_ALLOW_DOWNLOAD=1` | Download missing speech and cleanup models; otherwise they are skipped. |
| `VOCAMAC_ACCURACY_LANGUAGE` | Language code; unset or `auto` detects. |
| `VOCAMAC_ACCURACY_VOCABULARY` | Comma-separated Dictionary terms for every file (each file's `.terms.txt` is added). |
| `VOCAMAC_ACCURACY_VOCABULARY_PAIRED=1` | Decode each file with and without the vocabulary and report WER and term recall for both, to see what hints buy on each engine and what they pull in where they were not said. Parakeet applies hints through a separate boost model: with `VOCAMAC_ACCURACY_ALLOW_DOWNLOAD=1` it is downloaded, otherwise the report lists the model under "hints not tested". |
| `VOCAMAC_ACCURACY_FINAL=1` | Also score the text after the output rules, with Smart Cleanup off. |
| `VOCAMAC_ACCURACY_CLEANUP_MODEL` | A cleanup model id (for example `qwen25_0_5b_q4_k_m`) or the path to its `.gguf`. Implies FINAL and runs the real model, skipped when the rules left nothing to do, as the app does by default. |
| `VOCAMAC_ACCURACY_CLEANUP_LEVEL` | `light`, `medium` (default), `grammar` or `high`. |
| `VOCAMAC_ACCURACY_MAX_WER` | Fail when any model's corpus WER is above this fraction. |
| `VOCAMAC_ACCURACY_BASELINE` | A baseline JSON to compare against (see below). |
| `VOCAMAC_ACCURACY_TOLERANCE` | How far above the baseline a rate may go, as a fraction (default the baseline's own, else `0.01`). |
| `VOCAMAC_ACCURACY_CORPUS_ID` | A name for this corpus version. A baseline recorded on a different one is not compared. |
| `VOCAMAC_ACCURACY_WRITE_BASELINE` | Write this run's numbers, in the baseline format, to this path. |
| `VOCAMAC_ACCURACY_OUTPUT` | Report path or directory. |

To check one recording by hand, the CLI takes the same hints: `VocaMac --transcribe-file clip.wav --json --vocabulary terms.txt` (see [CLI.md](CLI.md#recognition-hints)).

Stop other builds before collecting timings. Accuracy does not depend on load.

## The nightly workflow

`.github/workflows/accuracy-nightly.yml` runs the harness every night on `VocaHQ/vocamac`, and on demand from the Actions tab. It does nothing but print a notice until a corpus is configured:

| Setting | Kind | Purpose |
|---|---|---|
| `ACCURACY_CORPUS_URL` | secret | HTTPS URL of a `.tar.gz` of the corpus directory (the pairs at its root, or inside one top-level folder). A secret, so a pre-signed or private URL stays out of logs. |
| `ACCURACY_CORPUS_SHA256` | variable | Optional checksum of the archive; the run fails when it differs. |
| `ACCURACY_CORPUS_ID` | variable | Optional corpus version name, matched against the baseline's. |
| `ACCURACY_MODELS` | variable | Models to measure. Default `parakeet-unified-en-0.6b,tiny`: the English model onboarding suggests and the model a fresh install stores. |
| `ACCURACY_LANGUAGE` | variable | Optional language code. |
| `ACCURACY_CLEANUP_MODEL` | variable | Optional cleanup model id, to score the final text with the real model. |
| `ACCURACY_TOLERANCE` | variable | Optional tolerance override. |

The run downloads the models, scores the corpus, compares the result with `.github/accuracy/baseline.json`, and uploads the JSON report and a freshly recorded baseline as an artifact. It fails when a model's corpus WER, CER, final-text WER or edge-drop rate is worse than the baseline by more than the tolerance. Models missing from the baseline are measured but never fail the run.

### Recording a baseline

The checked-in baseline is a placeholder with no models, so nothing can fail until one is recorded:

1. Configure the corpus and run the workflow from the Actions tab.
2. Download the `accuracy-report` artifact and review `accuracy-report.json`: read the transcripts, not only the numbers.
3. Copy `accuracy-baseline.json` from the artifact over `.github/accuracy/baseline.json`, set `note` to the date, runner and corpus version, and open a PR.

Record the baseline on the hosted runner, not on a laptop: Core ML can pick other compute units on other hardware, and the numbers move slightly. Re-record it in the PR that changes the corpus, a model, or anything that improves accuracy on purpose, and say why in the PR.
